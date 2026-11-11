import XCTest
@testable import HubCore

final class WireTests: XCTestCase {
    func testCRCMatchesTheStandardCheckValue() {
        XCTAssertEqual(CRC16.xmodem(Array("123456789".utf8)), 0x31C3)
    }

    func testFrameLayout() {
        let bytes = [UInt8](GlassesFrame(sequence: 0x1234, business: 19, payload: Data([1, 2, 3])).encoded())
        XCTAssertEqual(Array(bytes.prefix(8)), [0xAA, 0x55, 0x00, 0x07, 0x12, 0x34, 0x00, 19])
        XCTAssertEqual(bytes.count, 13)                       // length + 6
        let crc = CRC16.xmodem(bytes[4..<11])
        XCTAssertEqual(bytes[11], UInt8(crc >> 8)); XCTAssertEqual(bytes[12], UInt8(crc & 0xFF))
    }

    func testDecoderHandlesSplitJoinedAndDamagedData() {
        let a = GlassesFrame(sequence: 1, business: 19, payload: Data("hello".utf8)).encoded()
        let b = GlassesFrame(sequence: 2, business: 15, payload: Data(repeating: 7, count: 300)).encoded()
        var decoder = FrameStreamDecoder()
        var got = [GlassesFrame]()
        var stream = Data([0x00, 0xAA, 0x13]) + a + b          // junk in front
        var damaged = a; damaged[9] ^= 0xFF                     // a packet with a bad CRC
        stream += damaged + a
        var offset = 0
        for size in [1, 2, 7, 50, 3, 400, 1000] {              // arbitrary notification sizes
            guard offset < stream.count else { break }
            let end = min(stream.count, offset + size)
            got += decoder.append(stream.subdata(in: offset..<end)); offset = end
        }
        XCTAssertEqual(got.map(\.sequence), [1, 2, 1])
        XCTAssertEqual(got[1].payload.count, 300)
        XCTAssertEqual(got[0].payload, Data("hello".utf8))
        XCTAssertTrue(got.allSatisfy(\.isPlain))
        XCTAssertGreaterThan(decoder.dropped, 0)
    }

    func testDecoderReadsSlicedAndAddressedPackets() {
        // type byte 0x22: flags 2 (address byte present), one byte of slice info
        var body: [UInt8] = [0x00, 0x09, 0x22, 0xEE, 0x01, 19, 0x41]
        let length = body.count
        let crc = CRC16.xmodem(body)
        body = [0xAA, 0x55, UInt8(length >> 8), UInt8(length & 0xFF)] + body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        var decoder = FrameStreamDecoder()
        let frames = decoder.append(Data(body))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].business, 19)
        XCTAssertEqual(frames[0].payload, Data([0x41]))
        XCTAssertFalse(frames[0].isPlain)
    }

    func testEnvelopeRoundTrip() throws {
        let data = Envelope.encode(type: 5, json: ["sid": "abc", "mode": 3, "content": ["source_transcript": "Hi \"there\"\nline 2 °"]])
        XCTAssertEqual(Array(data.prefix(5)), [0x08, 0x01, 0x10, 0x05, 0x1A])
        let back = try XCTUnwrap(Envelope(data))
        XCTAssertEqual(back.type, 5)
        XCTAssertEqual(back.int("mode"), 3)
        XCTAssertEqual((back.json["content"] as? [String: Any])?["source_transcript"] as? String, "Hi \"there\"\nline 2 °")
        XCTAssertEqual(back.dataBytes, 0)
    }

    func testEnvelopeWithBinaryAndBadInput() {
        var data = Envelope.encode(type: 4, json: [:])
        data.append(contentsOf: [0x22, 0x03, 9, 9, 9])           // field 4: three bytes of audio
        XCTAssertEqual(Envelope(data)?.dataBytes, 3)
        XCTAssertNil(Envelope(Data([0x08, 0x02, 0x10, 0x05])))    // wrong version
        XCTAssertNil(Envelope(Data([0x08, 0x01, 0x10, 0x05, 0x1A, 0x50, 0x7B])))   // length runs off the end
        XCTAssertNil(Envelope(Data([0xFF, 0xFF, 0xFF])))
    }

    func testCaptionMessages() throws {
        let sid = CaptionWire.newSessionID()
        XCTAssertEqual(sid.count, 32)
        XCTAssertTrue(sid.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let config = try XCTUnwrap(Envelope(CaptionWire.configure(sid: sid, fontSize: 1, maxLines: 7)))
        XCTAssertEqual(config.type, 7)
        XCTAssertEqual(config.json["force"] as? Bool, false)      // never take the screen by force
        XCTAssertEqual(config.json["scope"] as? String, "temporary")
        XCTAssertEqual(Envelope.int((config.json["config"] as? [String: Any])?["max_lines"]), 7)
        let stop = try XCTUnwrap(Envelope(CaptionWire.stop(sid: sid)))
        XCTAssertEqual(stop.type, 3); XCTAssertEqual(stop.int("reason_code"), 10)
        let text = try XCTUnwrap(Envelope(CaptionWire.text(sid: sid, frame: "A")))
        XCTAssertEqual(text.int("status"), 0)
    }

    func testAFiveLineCardFitsOneBluetoothWrite() {
        let card = ["NFL 4:12 - 3rd", TextLayout.wide("KC 24 - BUF 17"), "KC ball: 2nd & 7 at KC 43",
                    "Last: Kelce 12-yd pass from Mahomes", "for a first down"].joined(separator: "\n")
        let packet = GlassesFrame(sequence: 9, business: 19, payload: CaptionWire.text(sid: CaptionWire.newSessionID(), frame: card)).encoded()
        XCTAssertLessThanOrEqual(packet.count, 512)
    }
}

final class CaptionSessionTests: XCTestCase {
    private func writes(_ actions: [CaptionSession.Action]) -> [(Envelope, Bool)] {
        actions.compactMap { action in
            guard case .write(let data, let text) = action else { return nil }
            var decoder = FrameStreamDecoder()
            guard let frame = decoder.append(data).first, let message = Envelope(frame.payload) else { return nil }
            return (message, text)
        }
    }
    private func reply(_ session: CaptionSession, type: UInt32, _ extra: [String: Any] = [:], sid: String? = nil) -> GlassesFrame {
        var json = extra; json["sid"] = sid ?? session.sid
        return GlassesFrame(sequence: 1, business: 19, payload: Envelope.encode(type: type, json: json))
    }
    private func released(_ actions: [CaptionSession.Action]) -> Bool {
        actions.contains { if case .release = $0 { return true }; return false }
    }

    /// Runs a session up to the point where it can show text.
    private func opened(font: Int = 1, lines: Int = 7) -> CaptionSession {
        var s = CaptionSession(fontSize: font, maxLines: lines, sequenceStart: 100)
        XCTAssertEqual(s.start(now: 0), [.subscribe])
        let setup = writes(s.subscribed(now: 0.1))
        XCTAssertEqual(setup.first?.0.type, 7)
        XCTAssertTrue(s.writeFinished(ok: true, now: 0.2).isEmpty)
        XCTAssertEqual(s.phase, .active)
        return s
    }

    func testNothingIsWrittenBeforeTheReceiveChannelIsOn() {
        var s = CaptionSession()
        s.show("early")
        XCTAssertEqual(s.start(now: 0), [.subscribe])
        XCTAssertTrue(s.tick(now: 1).isEmpty)
        XCTAssertTrue(s.tick(now: 5).isEmpty)
        XCTAssertTrue(released(s.tick(now: 9)))                 // gave up; nothing was ever sent
        XCTAssertEqual(s.phase, .closed)
    }

    func testTextWaitsASecondAfterSetupThenReplacesAtMostOncePerSecond() {
        var s = opened()
        s.show("one")
        XCTAssertTrue(s.tick(now: 0.5).isEmpty)                 // too soon after the setup write
        let first = writes(s.tick(now: 1.3))
        XCTAssertEqual((first.first?.0.json["content"] as? [String: Any])?["source_transcript"] as? String, "one")
        XCTAssertEqual(first.first?.1, true)
        s.show("two")
        XCTAssertTrue(s.tick(now: 1.4).isEmpty)                 // previous write still in flight
        _ = s.writeFinished(ok: true, now: 1.5)
        XCTAssertTrue(s.tick(now: 1.9).isEmpty)                 // under a second since the last screen
        XCTAssertEqual(writes(s.tick(now: 2.4)).count, 1)
        _ = s.writeFinished(ok: true, now: 2.5)
        XCTAssertTrue(s.tick(now: 10).isEmpty)                  // unchanged: nothing to send
        XCTAssertEqual(s.framesSent, 2)
    }

    func testUnchangedScreenIsRefreshedButScrollingTextIsLeftAlone() {
        var s = opened()
        s.show("board")
        _ = s.tick(now: 2); _ = s.writeFinished(ok: true, now: 2.1)
        XCTAssertTrue(s.tick(now: 20).isEmpty)
        XCTAssertEqual(writes(s.tick(now: 33)).count, 1)        // 30-second refresh
        _ = s.writeFinished(ok: true, now: 33.1)
        s.show("long text", scrolls: true)
        _ = s.tick(now: 35); _ = s.writeFinished(ok: true, now: 35.1)
        XCTAssertTrue(s.tick(now: 200).isEmpty)                 // never re-sent, so the crown position holds
    }

    func testSequenceNumbersCountUp() {
        var s = CaptionSession(sequenceStart: 65535)
        _ = s.start(now: 0)
        var decoder = FrameStreamDecoder()
        var seen = [UInt16]()
        for action in s.subscribed(now: 0) { if case .write(let d, _) = action { seen += decoder.append(d).map(\.sequence) } }
        _ = s.writeFinished(ok: true, now: 0)
        s.show("x")
        for action in s.tick(now: 2) { if case .write(let d, _) = action { seen += decoder.append(d).map(\.sequence) } }
        XCTAssertEqual(seen, [65535, 0])                        // wraps instead of crashing
    }

    func testGlassesConfirmationUpdatesTheLayout() {
        var s = opened(font: 1, lines: 7)
        _ = s.received(reply(s, type: 8, ["code": 1, "effective_config": ["font_size": 2, "max_lines": 5, "content_width": 100]]), now: 0.4)
        XCTAssertTrue(s.acknowledged)
        XCTAssertEqual(s.fontSize, 2); XCTAssertEqual(s.maxLines, 5)
        XCTAssertEqual(s.phase, .active)
    }

    func testARefusalEndsTheSessionWithoutForcing() {
        var s = opened()
        let actions = s.received(reply(s, type: 8, ["code": 3]), now: 0.4)
        XCTAssertTrue(released(actions))
        XCTAssertEqual(s.phase, .closed)
        s.show("text")
        XCTAssertTrue(s.tick(now: 5).isEmpty)
    }

    func testRepliesForOtherSessionsAndAudioAreIgnored() {
        var s = opened()
        XCTAssertTrue(s.received(reply(s, type: 3, sid: "someoneelse"), now: 1).isEmpty)
        XCTAssertTrue(s.received(GlassesFrame(sequence: 1, business: 15, payload: Envelope.encode(type: 3, json: ["sid": s.sid])), now: 1).isEmpty)
        var audio = Envelope.encode(type: 3, json: ["sid": s.sid]); audio.append(contentsOf: [0x22, 0x01, 0x00])
        XCTAssertTrue(s.received(GlassesFrame(sequence: 1, business: 19, payload: audio), now: 1).isEmpty)
        XCTAssertEqual(s.phase, .active)
    }

    func testClosingOnTheGlassesEndsTheSession() {
        var s = opened()
        XCTAssertTrue(released(s.received(reply(s, type: 3), now: 3)))
        XCTAssertEqual(s.phase, .closed)
        XCTAssertTrue(s.stop(now: 4).isEmpty)                   // nothing further is sent
    }

    func testStopClosesOnlyThisSessionAndWaitsForAWriteInFlight() throws {
        var s = opened()
        s.show("a")
        _ = s.tick(now: 2)                                      // a text write is in flight
        XCTAssertTrue(s.stop(now: 2.1).isEmpty)
        let stop = writes(s.writeFinished(ok: true, now: 2.2))
        let message = try XCTUnwrap(stop.first?.0)
        XCTAssertEqual(message.type, 3)
        XCTAssertEqual(message.json["sid"] as? String, s.sid)
        XCTAssertEqual(s.phase, .stopping)
        XCTAssertTrue(released(s.writeFinished(ok: true, now: 2.3)))
        XCTAssertEqual(s.phase, .closed)
    }

    func testFailuresEndTheSessionWithoutRetrying() {
        var s = opened()
        s.show("a")
        XCTAssertEqual(writes(s.tick(now: 2)).count, 1)
        XCTAssertTrue(released(s.writeFinished(ok: false, now: 2.1)))
        XCTAssertTrue(s.tick(now: 9).isEmpty)

        var t = opened()
        t.show("a"); _ = t.tick(now: 2)
        XCTAssertTrue(released(t.tick(now: 9)))                 // the write never finished

        var u = opened()
        _ = u.connectionLost()
        XCTAssertEqual(u.phase, .closed)
        XCTAssertTrue(u.stop(now: 1).isEmpty)
    }

    func testOversizedScreensAreSkipped() {
        var s = opened()
        s.show(String(repeating: "x", count: 5000))
        XCTAssertTrue(writes(s.tick(now: 2)).isEmpty)
        s.show("ok")
        XCTAssertEqual(writes(s.tick(now: 3.5)).count, 1)
    }

    func testLargeTextKeepsToFiveLines() {
        let s = CaptionSession(fontSize: 2, maxLines: 7)
        XCTAssertEqual(s.maxLines, 5)
    }
}

final class GlassesReportTests: XCTestCase {
    private func frame(_ json: String, business: UInt8 = 15, type: UInt32 = 76) -> GlassesFrame {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return GlassesFrame(sequence: 1, business: business, payload: Envelope.encode(type: type, json: object))
    }
    // shapes taken from a log of the owner's glasses (Strix OS 1.0.6.11), identifiers removed
    let scroll = #"{"cmd":"analytics_log","payload":{"data":{"extras":{"action_result":"fail","action_type":"scroll","history_depth":0},"packageName":"com.rayneo.liteos","type":"3CE0FD898F"},"mode":0,"value":0}}"#
    let click = #"{"cmd":"analytics_log","payload":{"data":{"extras":{"battery_level":46,"event_id":20,"event_name":"KEY_PRESS","result":"no_transition"},"packageName":"com.rayneo.liteos.state_machine"},"mode":0}}"#
    let double = #"{"cmd":"analytics_log","payload":{"data":{"extras":{"battery_level":46,"event_id":68,"event_name":"KEY_DOUBLE_CLICK"}}}}"#
    let stats = #"{"cmd":"analytics_log","payload":{"data":{"extras":{"bat":46,"bri":4,"charge":0}}}}"#
    let other = #"{"cmd":"analytics_log","payload":{"data":{"extras":{"component_type":"Stocks","refresh_result":"success"}}}}"#

    func testCrownAndBattery() {
        XCTAssertEqual(GlassesReport(frame(scroll))?.action, .crownTurn)
        XCTAssertEqual(GlassesReport(frame(click))?.action, .crownClick)
        XCTAssertEqual(GlassesReport(frame(click))?.battery, 46)
        XCTAssertNil(GlassesReport(frame(double))?.action)                 // a double click belongs to the assistant
        XCTAssertEqual(GlassesReport(frame(double))?.battery, 46)
        XCTAssertEqual(GlassesReport(frame(stats))?.battery, 46)
        XCTAssertNil(GlassesReport(frame(other)))
        XCTAssertNil(GlassesReport(frame(scroll, business: 19)))
        XCTAssertNil(GlassesReport(frame(#"{"cmd":"screen_status"}"#)))
    }
    func testInnerPartPackedAsText() {
        let packed = #"{"cmd":"analytics_log","payload":{"data":"{\"extras\":{\"action_type\":\"scroll\"}}"}}"#
        XCTAssertEqual(GlassesReport(frame(packed))?.action, .crownTurn)
    }
}
