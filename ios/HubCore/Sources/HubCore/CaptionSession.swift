import Foundation

/// Runs one display session on the glasses' caption page, without knowing anything about Bluetooth.
///
/// The app feeds it what happens (subscribed, a packet arrived, a write finished, time passed) and it
/// answers with what to do next. That keeps every rule about what may be sent in one place that can be
/// tested off the phone:
///   - nothing is written until the app's own receive channel is on
///   - one write at a time, and at most one screen per `minInterval`
///   - only this session's own page is ever stopped
///   - no retries: a failed write ends the session
public struct CaptionSession {
    public enum Phase: String { case idle, subscribing, configuring, active, stopping, closed }

    public enum Action: Equatable {
        /// Turn on notifications for the glasses' outgoing channel.
        case subscribe
        /// Write this packet. `text` is true for a screen of text (which may need slicing if large).
        case write(Data, text: Bool)
        /// The session is over; let go of the local Bluetooth attachment.
        case release(String)
        case log(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sid = ""
    public private(set) var fontSize: Int
    public private(set) var maxLines: Int
    /// True once the glasses confirmed the layout. Text is sent either way; the confirmation often doesn't
    /// arrive on a shared connection.
    public private(set) var acknowledged = false
    public private(set) var framesSent = 0
    public private(set) var lastSentFrame: String?
    public private(set) var closeReason: String?

    public var minInterval: TimeInterval = 1.0
    /// Re-send an unchanged screen this often so the page doesn't go stale. Nil turns that off.
    public var refreshInterval: TimeInterval? = 30
    /// Experiment: send text meant for crown scrolling as "finished" (see CaptionWire.text).
    public var finishScrollingText = false

    private var sequence: UInt16
    private var busy: BusyWrite?
    private var busySince: TimeInterval = 0
    private var textAllowedAt: TimeInterval = .infinity
    private var lastTextAt: TimeInterval = -.infinity
    private var deadline: TimeInterval?
    private var wanted: String?
    private var wantedScrolls = false
    private var stopQueued = false
    private enum BusyWrite { case configure, text, stop }

    public init(fontSize: Int = 1, maxLines: Int = 7, sequenceStart: UInt16? = nil) {
        let font = min(2, max(1, fontSize))
        self.fontSize = font
        self.maxLines = font == 1 ? min(7, max(1, maxLines)) : min(5, max(1, maxLines))
        self.sequence = sequenceStart ?? UInt16.random(in: 32768...65000)
    }

    public var isRunning: Bool { phase == .subscribing || phase == .configuring || phase == .active }
    public var isOver: Bool { phase == .closed || phase == .idle }

    private mutating func packet(_ payload: Data) -> Data {
        let data = GlassesFrame(sequence: sequence, business: CaptionWire.business, payload: payload).encoded()
        sequence &+= 1
        return data
    }

    public mutating func start(now: TimeInterval) -> [Action] {
        guard phase == .idle || phase == .closed else { return [] }
        sid = CaptionWire.newSessionID()
        phase = .subscribing; acknowledged = false; framesSent = 0; lastSentFrame = nil; closeReason = nil
        busy = nil; stopQueued = false; textAllowedAt = .infinity; lastTextAt = -.infinity
        deadline = now + 8
        return [.subscribe]
    }

    public mutating func subscribed(now: TimeInterval) -> [Action] {
        guard phase == .subscribing else { return [] }
        phase = .configuring; busy = .configure; busySince = now; deadline = nil
        return [.log("Asking the glasses for a \(maxLines)-line caption page, text size \(fontSize)."),
                .write(packet(CaptionWire.configure(sid: sid, fontSize: fontSize, maxLines: maxLines)), text: false)]
    }

    /// The screen to show. Sent on the next `tick` that the rate limit allows.
    /// `scrolls` marks text longer than the page, which is left alone once sent so the crown can scroll it.
    public mutating func show(_ frame: String, scrolls: Bool = false) {
        wanted = frame; wantedScrolls = scrolls
    }

    public mutating func writeFinished(ok: Bool, now: TimeInterval) -> [Action] {
        guard let kind = busy else { return [] }
        busy = nil
        switch kind {
        case .configure:
            guard ok else { return close("The glasses didn't accept the setup write.") }
            if phase == .configuring { phase = .active; textAllowedAt = now + 1.0 }
        case .text:
            guard ok else { return close("A screen update failed to send.") }
        case .stop:
            return close(ok ? "Display closed." : "The close request failed to send. Hold the crown to leave the page.")
        }
        if stopQueued { return sendStop(now: now) }
        return []
    }

    public mutating func received(_ frame: GlassesFrame, now: TimeInterval) -> [Action] {
        guard phase != .idle, phase != .closed, frame.business == CaptionWire.business, frame.isPlain,
              let message = Envelope(frame.payload), message.dataBytes == 0,
              message.json["sid"] as? String == sid else { return [] }
        if message.type == CaptionWire.stopType {
            return close("The caption page was closed on the glasses.")
        }
        guard message.type == CaptionWire.acknowledgeType else { return [] }
        if let code = message.int("code"), code != 1 {
            // The glasses said no (something else owns the screen). Never force it.
            return close("The glasses declined the display (code \(code)). Close what's open on them and try again.")
        }
        acknowledged = true
        if let config = message.json["effective_config"] as? [String: Any] {
            if let font = Envelope.int(config["font_size"]), (1...2).contains(font) { fontSize = font }
            if let lines = Envelope.int(config["max_lines"]), (1...7).contains(lines) { maxLines = lines }
        }
        return [.log("The glasses confirmed: text size \(fontSize), \(maxLines) lines.")]
    }

    public mutating func tick(now: TimeInterval) -> [Action] {
        if let deadline, now >= deadline {
            self.deadline = nil
            switch phase {
            case .subscribing: return close("The glasses didn't open a receive channel.")
            case .stopping: return close("No answer to the close request. Hold the crown to leave the page if it's still up.")
            default: break
            }
        }
        if busy != nil, now - busySince > 6 {
            busy = nil
            return close("A write to the glasses timed out.")
        }
        guard phase == .active, busy == nil, now >= textAllowedAt, now - lastTextAt >= minInterval,
              let wanted, !wanted.isEmpty else { return [] }
        let changed = wanted != lastSentFrame
        let stale = !wantedScrolls && (refreshInterval.map { now - lastTextAt >= $0 } ?? false)
        guard changed || stale else { return [] }
        guard wanted.utf8.count <= CaptionWire.maxTextBytes else {
            lastSentFrame = wanted          // don't keep retrying an oversized screen
            return [.log("Skipped a screen that was too long to send.")]
        }
        busy = .text; busySince = now; lastTextAt = now; lastSentFrame = wanted; framesSent += 1
        return [.write(packet(CaptionWire.text(sid: sid, frame: wanted, finished: wantedScrolls && finishScrollingText)), text: true)]
    }

    /// Close this session's page. Safe to call at any point.
    public mutating func stop(now: TimeInterval) -> [Action] {
        switch phase {
        case .idle, .closed, .stopping: return []
        case .subscribing: return close("Stopped before anything was sent.")
        case .configuring, .active:
            if busy != nil { stopQueued = true; return [] }
            return sendStop(now: now)
        }
    }

    /// The Bluetooth link went away underneath the session.
    public mutating func connectionLost() -> [Action] {
        guard phase != .idle, phase != .closed else { return [] }
        phase = .closed; busy = nil; closeReason = "The glasses disconnected."
        return [.log("The glasses disconnected.")]
    }

    private mutating func sendStop(now: TimeInterval) -> [Action] {
        stopQueued = false
        phase = .stopping; busy = .stop; busySince = now; deadline = now + 4
        return [.write(packet(CaptionWire.stop(sid: sid)), text: false)]
    }

    private mutating func close(_ reason: String) -> [Action] {
        phase = .closed; busy = nil; deadline = nil; stopQueued = false; closeReason = reason
        return [.log(reason), .release(reason)]
    }
}
