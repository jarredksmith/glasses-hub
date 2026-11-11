import SwiftUI
import AVFoundation
import MediaPlayer

/// Turns the iPhone's volume buttons (and anything that presses them, like a Bluetooth scroll ring)
/// into page-turn buttons.
///
/// iOS doesn't hand apps the buttons themselves, only the volume they change. So this watches the volume,
/// treats a rise as "forward" and a fall as "back", then puts the volume back where it was. It works
/// while the app's audio session is active, which is the case whenever the display is on.
@MainActor
final class VolumeButtons: NSObject {
    var onPress: ((Int) -> Void)?
    /// Called once when a button is held down. Only looked for when `detectHolds` is on, because
    /// telling a hold from a press means waiting a moment before a press counts.
    var onHold: ((Int) -> Void)?
    var detectHolds = false
    private var pending: Task<Void, Never>?
    private var pendingDirection = 0
    private var holding = 0
    private var lastChange = Date.distantPast
    private var watch: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var resting: Float = 0.5
    private var ignoreUntil = Date.distantPast

    var isOn: Bool { watch != nil }

    func set(_ on: Bool) {
        if on, watch == nil {
            let session = AVAudioSession.sharedInstance()
            resting = min(0.9, max(0.1, session.outputVolume))
            attachSlider()
            watch = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let level = change.newValue else { return }
                Task { @MainActor in self?.changed(to: level) }
            }
        } else if !on, watch != nil {
            watch?.invalidate(); watch = nil
            volumeView?.removeFromSuperview(); volumeView = nil
        }
    }

    private func changed(to level: Float) {
        guard Date() >= ignoreUntil, abs(level - resting) > 0.001 else { return }
        let direction = level > resting ? 1 : -1
        restore()
        guard detectHolds else { onPress?(direction); return }
        // A held button keeps changing the volume. A second change the same way, soon after the first,
        // is a hold; a single change that nothing follows is a press.
        let now = Date()
        let soon = now.timeIntervalSince(lastChange) < 1.0
        lastChange = now
        if holding == direction, soon { return }                        // still being held
        if pending != nil, pendingDirection == direction, soon {
            pending?.cancel(); pending = nil
            holding = direction
            onHold?(direction)
            return
        }
        pending?.cancel()
        holding = 0; pendingDirection = direction
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.onPress?(direction)
        }
    }

    /// Put the volume back, so presses keep registering and the user's volume doesn't creep. Uses the
    /// system volume slider, the only handle iOS offers. If iOS won't allow it right now (it can refuse
    /// in the background), follow the new level instead and stay clear of the ends of the range.
    private func restore() {
        ignoreUntil = Date().addingTimeInterval(0.35)
        let target = resting
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            if let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
                slider.setValue(target, animated: false)
                slider.sendActions(for: .touchUpInside)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let level = AVAudioSession.sharedInstance().outputVolume
            if abs(level - target) > 0.02 { self.resting = level }      // the reset didn't take: track where it is
        }
    }

    private func attachSlider() {
        guard volumeView == nil else { return }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
        view.alpha = 0.01
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.addSubview(view)
        volumeView = view
    }
}

/// The system share sheet, for handing a text file to another app.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// "Send to teleprompter": saves the text as a file the RayNeo app can import, and offers to share it.
struct TeleprompterButton: View {
    @EnvironmentObject private var model: HubModel
    let title: String
    let text: String
    @State private var shared: SharedFile?

    var body: some View {
        Button {
            if let url = model.saveForTeleprompter(title: title, text: text) { shared = SharedFile(url: url) }
        } label: {
            Label("Send to teleprompter", systemImage: "square.and.arrow.up")
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .sheet(item: $shared) { file in ShareSheet(url: file.url) }
    }
}
