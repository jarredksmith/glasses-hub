package com.jarredsmith.glasseshub.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WireTest {
    private fun report(extras: Map<String, Any?>, packed: Boolean = false): GlassesFrame {
        val data = mapOf("data" to mapOf("extras" to extras))
        val json = mapOf("cmd" to "analytics_log", "payload" to (if (packed) Json.encode(data) else data))
        return GlassesFrame(1, 15, Envelope.encode(76, json))
    }

    @Test fun crcMatchesTheStandardCheckValue() {
        assertEquals(0x31C3, CRC16.xmodem("123456789".toByteArray()))
    }

    @Test fun frameLayoutAndDecoder() {
        val frame = GlassesFrame(0x1234, 19, byteArrayOf(1, 2, 3)).encoded()
        assertEquals(13, frame.size)
        assertEquals(listOf(0xAA, 0x55, 0x00, 0x07, 0x12, 0x34, 0x00, 19, 1, 2, 3), frame.take(11).map { it.toInt() and 0xFF })
        val decoder = FrameStreamDecoder()
        // split anywhere, with junk in front and two packets joined
        assertTrue(decoder.append(byteArrayOf(9, 9) + frame.copyOfRange(0, 5)).isEmpty())
        val got = decoder.append(frame.copyOfRange(5, frame.size) + frame)
        assertEquals(2, got.size)
        assertEquals(0x1234, got[0].sequence); assertEquals(19, got[0].business)
        assertEquals(listOf<Byte>(1, 2, 3), got[1].payload.toList())
        // a damaged packet is skipped and the next one still read
        val bad = frame.copyOf(); bad[9] = 77
        assertEquals(1, decoder.append(bad + frame).size)
    }

    @Test fun envelopeRoundTrip() {
        val bytes = Envelope.encode(5, mapOf("sid" to "abc", "n" to 3, "nested" to mapOf("ok" to true), "text" to "line \"one\"\nÉ"))
        val back = assertNotNull(Envelope.decode(bytes))
        assertEquals(5, back.type)
        assertEquals("abc", back.json["sid"])
        assertEquals(3, back.int("n"))
        assertEquals(true, back.json["nested"].at("ok"))
        assertEquals("line \"one\"\nÉ", back.json["text"])
        assertNull(Envelope.decode(byteArrayOf(1, 2, 3)))
        assertEquals("""{"a":[1,2.5,null],"b":"x"}""", Json.encode(mapOf("b" to "x", "a" to listOf(1, 2.5, null))))
    }

    @Test fun captionMessages() {
        val configure = assertNotNull(Envelope.decode(CaptionWire.configure("s1", 2, 5)))
        assertEquals(7, configure.type)
        assertEquals(false, configure.json["force"])
        assertEquals(5, configure.json["config"].at("max_lines").int())
        val text = assertNotNull(Envelope.decode(CaptionWire.text("s1", "Hello")))
        assertEquals(0, text.int("status")); assertEquals(3, text.int("mode"))
        assertEquals("Hello", text.json["content"].at("source_transcript"))
        assertEquals(32, CaptionWire.newSessionID().length)
    }

    @Test fun sessionSendsOnlyAfterSubscribingAndAtMostOncePerSecond() {
        val s = CaptionSession(fontSize = 2, maxLines = 5, sequenceStart = 40000)
        s.show("first")
        assertTrue(s.tick(0.0).isEmpty())
        assertEquals(listOf<CaptionSession.Action>(CaptionSession.Action.Subscribe), s.start(0.0))
        val setup = s.subscribed(0.1)
        assertTrue(setup.any { it is CaptionSession.Action.Write && !it.text })
        assertTrue(s.tick(0.2).isEmpty())                               // the setup write hasn't come back
        s.writeFinished(true, 0.3)
        assertEquals(CaptionSession.Phase.active, s.phase)
        assertTrue(s.tick(1.0).isEmpty())                               // a second's pause after setup
        val first = s.tick(1.4)
        assertTrue(first.single() is CaptionSession.Action.Write)
        s.writeFinished(true, 1.5)
        s.show("second")
        assertTrue(s.tick(2.0).isEmpty())
        assertEquals(1, s.tick(2.5).size)
        s.writeFinished(true, 2.6)
        assertTrue(s.tick(10.0).isEmpty())                              // nothing new
        assertEquals(1, s.tick(33.0).size)                              // refreshed after half a minute
        assertEquals(3, s.framesSent)
        // packets count up from the starting number
        val frames = FrameStreamDecoder().append((setup.first { it is CaptionSession.Action.Write } as CaptionSession.Action.Write).packet)
        assertEquals(40000, frames.single().sequence)
    }

    @Test fun refusalAndFailuresEndTheSession() {
        val s = CaptionSession()
        s.start(0.0); s.subscribed(0.0); s.writeFinished(true, 0.0)
        val no = GlassesFrame(7, 19, Envelope.encode(8, mapOf("sid" to s.sid, "code" to 3)))
        val actions = s.received(no, 1.0)
        assertTrue(actions.any { it is CaptionSession.Action.Release })
        assertEquals(CaptionSession.Phase.closed, s.phase)
        val t = CaptionSession()
        t.start(0.0); t.subscribed(0.0); t.writeFinished(true, 0.0)
        val other = GlassesFrame(7, 19, Envelope.encode(3, mapOf("sid" to "someone-else")))
        assertTrue(t.received(other, 1.0).isEmpty())
        t.show("x"); t.tick(2.0)
        assertTrue(t.writeFinished(false, 2.1).any { it is CaptionSession.Action.Release })
    }

    @Test fun stopWaitsForAWriteInFlight() {
        val s = CaptionSession()
        s.start(0.0); s.subscribed(0.0)
        assertTrue(s.stop(0.1).isEmpty())
        val stop = s.writeFinished(true, 0.2)
        val packet = (stop.single() as CaptionSession.Action.Write).packet
        val message = assertNotNull(Envelope.decode(FrameStreamDecoder().append(packet).single().payload))
        assertEquals(3, message.type); assertEquals(s.sid, message.json["sid"])
        assertTrue(s.writeFinished(true, 0.3).any { it is CaptionSession.Action.Release })
    }

    @Test fun crownAndBatteryReports() {
        assertEquals(GlassesReport.Action.CrownTurn, GlassesReport.from(report(mapOf("action_type" to "scroll", "action_result" to "fail")))?.action)
        assertEquals(GlassesReport.Action.CrownBack(2), GlassesReport.from(report(mapOf("action_type" to "scroll", "action_result" to "success", "history_depth" to 2)))?.action)
        assertEquals(GlassesReport.Action.CrownClick, GlassesReport.from(report(mapOf("event_name" to "KEY_PRESS")))?.action)
        assertEquals(GlassesReport.Action.HeadRaise, GlassesReport.from(report(mapOf("action_type" to "raise_head")))?.action)
        assertEquals(GlassesReport.Action.DoubleClick, GlassesReport.from(report(mapOf("trigger_action" to "double_click")))?.action)
        assertEquals(GlassesReport.Action.HoldExit, GlassesReport.from(report(mapOf("exit_type" to "crown_long_press"), packed = true))?.action)
        assertEquals(64, GlassesReport.from(report(mapOf("battery_level" to 64)))?.battery)
        assertNull(GlassesReport.from(report(mapOf("battery_level" to 164))))
        val blocked = GlassesReport.from(report(mapOf("conflict_app_name" to "ai_subtitle", "display_result" to "fail", "package_name" to "com.whatsapp")))
        assertEquals("com.whatsapp", blocked?.blockedNotification)
        assertEquals("WhatsApp", AppNames.name("com.whatsapp"))
        assertEquals("Thing", AppNames.name("org.example.thing"))
    }

    @Test fun layoutBasics() {
        assertEquals("it's - \"fine\"...", TextLayout.clean("it’s —  “fine”… 😀"))
        val screen = Screen.of(TextSize.large)
        val lines = TextLayout.wrap("The quick brown fox jumps over the lazy dog and keeps on running through the field", screen.columns)
        assertTrue(lines.size >= 2 && lines.all { TextLayout.measure(it) <= screen.columns })
        assertEquals("ＨＩ　１", TextLayout.wide("HI 1"))
        assertEquals("abcdef..", TextLayout.fit("abcdefghijkl", 8))
        assertEquals(listOf(listOf("a", "b", "(1/2)"), listOf("c", "d", "(2/2)")), TextLayout.pages(listOf("a", "b", "c", "d"), 3))
        assertEquals("[#####-----]", TextLayout.bar(0.5))
        assertEquals("1:02:09", ReaderClock.span(3729.0))
        assertEquals("in 25 min", HubClock.until(1500.0, 0.0))
        val centred = TextLayout.centered(listOf("hi"), 34, each = true)
        assertTrue(centred[0].startsWith("　") && centred[0].endsWith("hi"))
        assertEquals(listOf("m", "　", "a", "b", "　", "　"), TextLayout.withScrollRoom(listOf("a", "b"), 5, "m"))
    }
}
