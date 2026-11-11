import Foundation
import CoreBluetooth
import HubCore

/// The Bluetooth side of the display.
///
/// Glasses Hub doesn't pair with the glasses or sign in to them. It joins the connection the RayNeo app
/// already has (iOS lets apps share one), opens its own caption page and writes text to it. Everything
/// about what gets written lives in `CaptionSession`; this class only moves bytes.
///
/// Things it never does: scan, pair, touch the pairing characteristic, send the RayNeo sign-in handshake,
/// change settings on the glasses, or close anything it didn't open.
@MainActor
final class GlassesLink: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum State: String { case off, looking, connecting, opening, showing, closing }

    @Published private(set) var state: State = .off
    @Published private(set) var status = "Display is off."
    @Published private(set) var log: [String] = []
    @Published private(set) var rows = 7
    @Published private(set) var framesSent = 0
    @Published private(set) var glassesName = ""
    /// The glasses' battery, when they've mentioned it.
    @Published private(set) var battery: Int?
    /// The crown was turned forward (+1), turned back (-1) or clicked (0) while this app's page was up.
    var onCrown: ((Int) -> Void)?
    private var lastDepth = 0
    private var lastBack = Date.distantPast
    /// The wearer tilted their head up while this app's page was up.
    var onHeadRaise: (() -> Void)?
    private var lastRaise = Date.distantPast
    private var lastTurn = Date.distantPast

    /// Called when a running display ends for any reason other than the user pressing Stop.
    var onEnded: ((String) -> Void)?

    private let service = CBUUID(string: "B81D")
    private let outgoingID = CBUUID(string: "EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9")
    private let incomingID = CBUUID(string: "7DB3E235-3608-41F3-A03C-955FCBD2EA4B")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var outgoing: CBCharacteristic?
    private var incoming: CBCharacteristic?
    private var session = CaptionSession()
    private var decoder = FrameStreamDecoder()
    private var wantsStart = false
    private var userStopped = false
    private var deadline: TimeInterval?
    private var sliceTask: Task<Void, Never>?
    private var telemetrySeen = Set<String>()
    /// When on, everything the glasses report is written to the log with its arrival time. For finding
    /// out whether crown turns and clicks reach the phone as they happen.
    var logEvents = false
    private var eventsLogged = 0
    private var run = 0

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
    var isRunning: Bool { state != .off }
    var isShowing: Bool { state == .showing }

    // MARK: Controls

    func start(size: TextSize, refresh: Bool, finishScrollingText: Bool = false) {
        guard state == .off else { return }
        session = CaptionSession(fontSize: size.fontSize, maxLines: size.rows)
        session.refreshInterval = refresh ? 30 : nil
        session.finishScrollingText = finishScrollingText
        decoder = FrameStreamDecoder()
        rows = size.rows; framesSent = 0; eventsLogged = 0
        userStopped = false; wantsStart = true; run += 1
        state = .looking; status = "Looking for your glasses…"
        deadline = now + 10
        note("Start requested (\(size.title)).")
        if let central {
            if central.state == .poweredOn { attach() }
            else { centralManagerDidUpdateState(central) }
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func stop() {
        guard state != .off else { return }
        userStopped = true; wantsStart = false
        if state == .looking || state == .connecting {
            finish("Display is off.")
            return
        }
        state = .closing; status = "Closing the display…"
        perform(session.stop(now: now))
    }

    /// The text to keep on the glasses. Sent on the next tick the session allows.
    func show(_ text: String, scrolls: Bool) {
        session.show(text, scrolls: scrolls)
    }

    /// Call a few times a second while the display is on.
    func tick() {
        guard state != .off else { return }
        if let deadline, now >= deadline, state == .looking || state == .connecting {
            self.deadline = nil
            fail(state == .looking ? "Bluetooth didn't become available." : "Couldn't reach the glasses.")
            return
        }
        perform(session.tick(now: now))
        if framesSent != session.framesSent { framesSent = session.framesSent }
    }

    func clearLog() { log.removeAll() }

    // MARK: Attaching

    private func attach() {
        guard wantsStart, let central, state == .looking else { return }
        wantsStart = false
        let found = central.retrieveConnectedPeripherals(withServices: [service])
        guard let target = found.first else {
            fail("Your glasses aren't connected to this iPhone. Open the RayNeo app, wait for it to connect, then try again.")
            return
        }
        if found.count > 1 { note("More than one pair of glasses is connected; using \(target.name ?? "the first").") }
        peripheral = target; target.delegate = self
        glassesName = target.name ?? "RayNeo glasses"
        state = .connecting; status = "Joining the glasses' connection…"
        deadline = now + 10
        central.connect(target, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: attach()
        case .unauthorized:
            if state != .off { fail("Glasses Hub isn't allowed to use Bluetooth. Turn it on in Settings > Glasses Hub.") }
        case .poweredOff:
            if state != .off { fail("Bluetooth is off.") }
        case .unsupported:
            if state != .off { fail("This device has no Bluetooth.") }
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, state == .connecting else { return }
        deadline = now + 10
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        fail("Couldn't join the glasses' connection.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        perform(session.connectionLost())
        let reason = userStopped ? "Display is off." : (session.closeReason ?? "The glasses disconnected.")
        finish(reason, notify: !userStopped)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, state == .connecting else { return }
        guard error == nil, let match = peripheral.services?.first(where: { $0.uuid == service }) else {
            fail("The glasses didn't offer the data service."); return
        }
        peripheral.discoverCharacteristics([outgoingID, incomingID], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, state == .connecting else { return }
        let all = service.characteristics ?? []
        outgoing = all.first { $0.uuid == outgoingID }
        incoming = all.first { $0.uuid == incomingID }
        guard error == nil, let outgoing, let incoming,
              outgoing.properties.contains(.write) || outgoing.properties.contains(.writeWithoutResponse),
              incoming.properties.contains(.notify) || incoming.properties.contains(.indicate) else {
            fail("The glasses' data channels weren't where they were expected. A firmware update may have moved them.")
            return
        }
        deadline = nil
        state = .opening; status = "Opening the display…"
        note("Joined \(glassesName). Write limit \(peripheral.maximumWriteValueLength(for: .withResponse)) bytes.")
        perform(session.start(now: now))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === incoming else { return }
        if error == nil, characteristic.isNotifying { perform(session.subscribed(now: now)) }
        else if state == .opening { fail("The glasses wouldn't open a receive channel.") }
    }

    // MARK: Sending

    private func perform(_ actions: [CaptionSession.Action]) {
        for action in actions {
            switch action {
            case .subscribe:
                if let peripheral, let incoming { peripheral.setNotifyValue(true, for: incoming) }
            case .write(let packet, let isText):
                if isText { lastDepth = 0 }             // a new screen starts at the bottom again
                send(packet, isText: isText)
            case .log(let line):
                note(line)
            case .release(let reason):
                release(reason)
            }
        }
        if session.phase == .active, state == .opening {
            state = .showing; status = "Showing on your glasses."
        }
        if rows != session.maxLines { rows = session.maxLines }
    }

    private func send(_ packet: Data, isText: Bool) {
        guard let peripheral, let outgoing, peripheral.state == .connected else {
            perform(session.writeFinished(ok: false, now: now)); return
        }
        if outgoing.properties.contains(.write), packet.count <= peripheral.maximumWriteValueLength(for: .withResponse) {
            peripheral.writeValue(packet, for: outgoing, type: .withResponse)       // answered in didWriteValueFor
            return
        }
        guard outgoing.properties.contains(.writeWithoutResponse) else {
            note("A \(packet.count)-byte screen is too big for one write and the glasses don't take streamed writes.")
            perform(session.writeFinished(ok: false, now: now)); return
        }
        // Too long for one write: send it as a stream of pieces. The glasses reassemble by the packet's own
        // length field. Used for long reading text; ordinary cards fit one write.
        let limit = max(20, min(512, peripheral.maximumWriteValueLength(for: .withoutResponse)))
        let pieces = stride(from: 0, to: packet.count, by: limit).map { packet.subdata(in: $0..<min(packet.count, $0 + limit)) }
        sliceTask?.cancel()
        sliceTask = Task { @MainActor [weak self] in
            let giveUp = Date().addingTimeInterval(5)
            for piece in pieces {
                while !peripheral.canSendWriteWithoutResponse, Date() < giveUp, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                guard let self, !Task.isCancelled, self.peripheral === peripheral else { return }
                guard Date() < giveUp, peripheral.state == .connected else {
                    self.perform(self.session.writeFinished(ok: false, now: self.now)); return
                }
                peripheral.writeValue(piece, for: outgoing, type: .withoutResponse)
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.perform(self.session.writeFinished(ok: true, now: self.now))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === outgoing else { return }
        if let error { note("Write failed: \((error as NSError).code).") }
        perform(session.writeFinished(ok: error == nil, now: now))
    }

    // MARK: Receiving

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === incoming, error == nil, let data = characteristic.value else { return }
        for frame in decoder.append(data) {
            if logEvents, eventsLogged < 400 { eventsLogged += 1; note(describe(frame)) }
            if let report = GlassesReport(frame) {
                if let level = report.battery, level != battery { battery = level }
                if let action = report.action, state == .showing {
                    switch action {
                    case .crownTurn:
                        // one notch of the crown reports twice; treat reports close together as one turn
                        if Date().timeIntervalSince(lastTurn) > 0.3 { onCrown?(1) }
                        lastTurn = Date(); lastDepth = 0
                    case .crownBack(let depth):
                        // only the first line scrolled back counts; a spin shouldn't flip several pages
                        if depth > lastDepth, Date().timeIntervalSince(lastBack) > 0.7 { lastBack = Date(); onCrown?(-1) }
                        lastDepth = depth
                    case .crownClick: onCrown?(0)
                    case .headRaise:
                        if Date().timeIntervalSince(lastRaise) > 1.5 { onHeadRaise?() }
                        lastRaise = Date()
                    }
                }
            }
            if frame.business == CaptionWire.business {
                perform(session.received(frame, now: now))
            } else if frame.business == 15, frame.isPlain, let message = Envelope(frame.payload),
                      let command = message.json["cmd"] as? String {
                // Status the glasses announce on their own (battery, worn or not, screen on or off).
                // Logged once each so we can learn what's there; nothing is sent in reply.
                let harmless: Set<String> = ["battery_change", "wear_status", "screen_status", "brightness_change", "device_status"]
                if harmless.contains(command), !telemetrySeen.contains(command) {
                    telemetrySeen.insert(command)
                    let body = (try? JSONSerialization.data(withJSONObject: message.json, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    note("Glasses status \(command): \(String(body.prefix(220)))")
                }
            }
        }
    }

    /// One line about a packet from the glasses, with anything that identifies the device blanked.
    private func describe(_ frame: GlassesFrame) -> String {
        var line = "EVENT ch\(frame.business)"
        guard frame.isPlain, let message = Envelope(frame.payload) else { return line + " (\(frame.payload.count) bytes, not readable)" }
        line += " type \(message.type)"
        if message.dataBytes > 0 { line += " +\(message.dataBytes) bytes" }
        func scrub(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out = [String: Any]()
                for (key, item) in dict {
                    let k = key.lowercased()
                    let hide = ["sn", "did", "mac", "sid", "uid", "token", "account", "serial"].contains { k == $0 || k.hasSuffix($0) || k.hasPrefix($0) }
                    out[key] = hide ? "-" : scrub(item)
                }
                return out
            }
            if let list = value as? [Any] { return list.prefix(6).map(scrub) }
            if let text = value as? String {
                // some fields hold JSON inside a string; open it so its fields are scrubbed too
                if text.hasPrefix("{"), let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return scrub(inner) }
                return text.count > 60 ? String(text.prefix(60)) + "…" : text
            }
            return value
        }
        let body = (try? JSONSerialization.data(withJSONObject: scrub(message.json), options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return line + " " + String(body.prefix(420))
    }

    // MARK: Ending

    private func release(_ reason: String) {
        sliceTask?.cancel(); sliceTask = nil
        if let peripheral, let central, peripheral.state != .disconnected {
            // Lets go of this app's share of the connection only. The RayNeo app keeps its own.
            status = userStopped ? "Display is off." : reason
            central.cancelPeripheralConnection(peripheral)          // finishes in didDisconnectPeripheral
            state = .closing
            deadline = nil
            let thisRun = run
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.run == thisRun, self.state == .closing else { return }
                self.finish(self.userStopped ? "Display is off." : reason, notify: !self.userStopped)
            }
        } else {
            finish(userStopped ? "Display is off." : reason, notify: !userStopped)
        }
    }

    private func fail(_ reason: String) {
        note(reason)
        if let peripheral, let central, peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
        finish(reason, notify: true)
    }

    private func finish(_ reason: String, notify: Bool = false) {
        guard state != .off else { return }
        sliceTask?.cancel(); sliceTask = nil
        peripheral?.delegate = nil; peripheral = nil; outgoing = nil; incoming = nil
        deadline = nil; wantsStart = false
        state = .off; status = reason
        framesSent = session.framesSent
        if notify { onEnded?(reason) }
    }

    private func note(_ line: String) {
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss.SS"
        let stamp = clock.string(from: Date())
        log.append("\(stamp)  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
