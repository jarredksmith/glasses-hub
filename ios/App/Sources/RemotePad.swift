import SwiftUI
import UIKit

/// What a Bluetooth ring, clicker or keyboard can send that an iPhone app is able to see.
enum RemoteEvent: String, CaseIterable, Identifiable {
    case swipeUp, swipeDown, swipeLeft, swipeRight, tap, zoomIn, zoomOut, keyNext, keyPrevious, keySelect, keyMenu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .swipeUp: return "Swipe up"; case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"; case .swipeRight: return "Swipe right"
        case .tap: return "Tap"; case .zoomIn: return "Zoom in"; case .zoomOut: return "Zoom out"
        case .keyNext: return "Right, down, space or page down key"; case .keyPrevious: return "Left, up or page up key"
        case .keySelect: return "Return key"; case .keyMenu: return "Escape key"
        }
    }
    /// What it does unless the wearer says otherwise: 0 next, 1 select, 2 apps menu, 3 previous, 4 nothing.
    var usual: Int {
        switch self {
        case .swipeUp, .swipeLeft, .zoomIn, .keyNext: return 0
        case .swipeDown, .swipeRight, .zoomOut, .keyPrevious: return 3
        case .tap, .keySelect: return 1
        case .keyMenu: return 2
        }
    }
}

/// A dark full-screen pad that turns whatever a ring or clicker does on the phone's screen into steps on
/// the glasses. Rings like these work by faking swipes, taps and pinches, so the app has to be on screen
/// to see them; the pad keeps the screen awake and dim.
struct RemotePadView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var link: GlassesLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteCatcher { model.ring($0) }.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.gray) }
                        .accessibilityLabel("Close the remote pad")
                }
                Spacer()
                Image(systemName: "av.remote").font(.system(size: 44)).foregroundStyle(Color.gray.opacity(0.6))
                Text(model.ringLast.isEmpty ? "Press a button on your ring" : model.ringLast)
                    .font(.title3.weight(.semibold)).foregroundStyle(Color.green).multilineTextAlignment(.center)
                Text(link.isShowing ? "Leave this screen open. Swipes, taps and pinches anywhere on it drive the glasses."
                                    : "The glasses' display is off. Start it first, then come back here.")
                    .font(.footnote).foregroundStyle(.gray).multilineTextAlignment(.center)
                Spacer()
                Text(model.preview.isEmpty ? " " : model.preview)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.green.opacity(0.55))
                    .lineLimit(7).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .allowsHitTesting(true)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// The view underneath the pad that listens for touches, pinches, pointer scrolling and keys.
private struct RemoteCatcher: UIViewRepresentable {
    let onEvent: (RemoteEvent) -> Void
    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onEvent = onEvent
        return view
    }
    func updateUIView(_ view: CatcherView, context: Context) { view.onEvent = onEvent }
}

private final class CatcherView: UIView, UIGestureRecognizerDelegate {
    var onEvent: ((RemoteEvent) -> Void)?
    private var lastSent = Date.distantPast
    private var pinching = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedScrollTypesMask = .all                       // a ring that acts as a scroll wheel arrives here too
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    private func send(_ event: RemoteEvent) {
        // one press of a ring button is one step, however many touches it fakes
        guard Date().timeIntervalSince(lastSent) > 0.15 else { return }
        lastSent = Date()
        onEvent?(event)
    }

    func gestureRecognizer(_ first: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith second: UIGestureRecognizer) -> Bool { true }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, !pinching, pan.numberOfTouches <= 1 else { return }
        let move = pan.translation(in: self), speed = pan.velocity(in: self)
        let x = abs(move.x) > 12 ? move.x : speed.x / 20, y = abs(move.y) > 12 ? move.y : speed.y / 20
        guard max(abs(x), abs(y)) > 12 else { return }
        if abs(y) >= abs(x) { send(y < 0 ? .swipeUp : .swipeDown) } else { send(x < 0 ? .swipeLeft : .swipeRight) }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began: pinching = true
        case .ended, .cancelled, .failed:
            if pinch.scale > 1.08 { send(.zoomIn) } else if pinch.scale < 0.92 { send(.zoomOut) }
            // let the fingers lift before swipes count again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.pinching = false }
        default: break
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        if tap.state == .ended { send(.tap) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var used = false
        for press in presses {
            guard let key = press.key else { continue }
            switch key.keyCode {
            case .keyboardRightArrow, .keyboardDownArrow, .keyboardPageDown, .keyboardSpacebar: send(.keyNext); used = true
            case .keyboardLeftArrow, .keyboardUpArrow, .keyboardPageUp: send(.keyPrevious); used = true
            case .keyboardReturnOrEnter, .keypadEnter: send(.keySelect); used = true
            case .keyboardEscape: send(.keyMenu); used = true
            default: break
            }
        }
        if !used { super.pressesBegan(presses, with: event) }
    }
}
