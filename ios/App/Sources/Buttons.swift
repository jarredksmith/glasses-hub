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
    /// Called for two presses of the same button in quick succession. Only looked for when
    /// `detectDoubles` is on, because a single press then has to wait a moment to see if a second follows.
    var onDouble: ((Int) -> Void)?
    var detectDoubles = false
    private var pending: Task<Void, Never>?
    private var pendingDirection = 0
    private var watch: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    /// Where the volume is put back to after each press, and the last level seen.
    private var resting: Float = 0.5
    private var last: Float = 0.5
    private var restoring: Task<Void, Never>?

    var isOn: Bool { watch != nil }

    func set(_ on: Bool) {
        if on, watch == nil {
            let session = AVAudioSession.sharedInstance()
            resting = min(0.8, max(0.2, session.outputVolume))
            last = session.outputVolume
            attachSlider()
            watch = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let level = change.newValue else { return }
                Task { @MainActor in self?.changed(to: level) }
            }
            if abs(last - resting) > 0.001 { restore() }            // start away from the ends of the range
        } else if !on, watch != nil {
            watch?.invalidate(); watch = nil
            volumeView?.removeFromSuperview(); volumeView = nil
            pending?.cancel(); pending = nil
            restoring?.cancel(); restoring = nil
        }
    }

    private func changed(to level: Float) {
        let previous = last
        last = level
        // Landing back on the resting level is this class putting the volume back, not a press.
        guard abs(level - resting) > 0.001, abs(level - previous) > 0.001 else { return }
        // Each press is judged against the level before it, so presses still count if putting the
        // volume back is slow or iOS refuses it.
        let direction = level > previous ? 1 : -1
        restore()
        guard detectDoubles else { onPress?(direction); return }
        if pending != nil, pendingDirection == direction {
            pending?.cancel(); pending = nil
            onDouble?(direction)
            return
        }
        if pending != nil { pending?.cancel(); pending = nil; onPress?(pendingDirection) }     // the other button: don't lose it
        pendingDirection = direction
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.onPress?(direction)
        }
    }

    /// Put the volume back, so presses keep registering and the user's volume doesn't creep. Uses the
    /// system volume slider, the only handle iOS offers, and tries a few times because iOS sometimes
    /// ignores it. If it never takes, move the resting point off the ends so presses both ways still show.
    private func restore() {
        restoring?.cancel()
        restoring = Task { @MainActor [weak self] in
            for attempt in 0..<4 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 60_000_000 : 200_000_000)
                guard !Task.isCancelled, let self else { return }
                if abs(AVAudioSession.sharedInstance().outputVolume - self.resting) < 0.02 { return }
                if self.volumeView == nil { self.attachSlider() }
                if let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first {
                    slider.setValue(self.resting, animated: false)
                    slider.sendActions(for: .touchUpInside)
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let level = AVAudioSession.sharedInstance().outputVolume
            if abs(level - self.resting) > 0.02, level > 0.1, level < 0.9 { self.resting = level }
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
