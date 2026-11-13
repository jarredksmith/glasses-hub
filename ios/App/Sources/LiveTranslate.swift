import SwiftUI
import Translation

/// The languages Live translate offers: how the iPhone's speech recognition names each one, and how its
/// translation does.
struct TranslateLanguage: Identifiable, Hashable {
    let name: String
    let speech: String
    let translation: String
    /// The plain language code the cloud service uses.
    var cloud: String { String(speech.prefix(2)) }
    var id: String { speech }

    static let all: [TranslateLanguage] = [
        TranslateLanguage(name: "English", speech: "en-US", translation: "en"),
        TranslateLanguage(name: "Spanish", speech: "es-ES", translation: "es"),
        TranslateLanguage(name: "Chinese (Mandarin)", speech: "zh-CN", translation: "zh-Hans"),
        TranslateLanguage(name: "Vietnamese", speech: "vi-VN", translation: "vi"),
        TranslateLanguage(name: "French", speech: "fr-FR", translation: "fr"),
        TranslateLanguage(name: "German", speech: "de-DE", translation: "de"),
        TranslateLanguage(name: "Italian", speech: "it-IT", translation: "it"),
        TranslateLanguage(name: "Portuguese", speech: "pt-BR", translation: "pt"),
        TranslateLanguage(name: "Japanese", speech: "ja-JP", translation: "ja"),
        TranslateLanguage(name: "Korean", speech: "ko-KR", translation: "ko"),
    ]
    static func named(_ speech: String) -> TranslateLanguage { all.first { $0.speech == speech } ?? all[0] }
}

/// Gives the model Apple's on-device translator. iOS only hands one out to a view, so this sits on the
/// app's root view and keeps the translator working for as long as Live translate is on.
struct TranslationHost: ViewModifier {
    // The shared model directly, not from the environment: this modifier sits outside the point where
    // the model is put into the environment, and asking the environment there crashes at launch.
    @ObservedObject private var model = HubModel.shared

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationTask(model.translationPair.map {
                TranslationSession.Configuration(source: Locale.Language(identifier: $0.from), target: Locale.Language(identifier: $0.to))
            }) { session in
                await model.translate(with: session)
            }
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
extension HubModel {
    /// Runs until Live translate is switched off or the languages change: takes phrases as they come
    /// and puts their translations on the glasses.
    func translate(with session: TranslationSession) async {
        let mine = translationRun
        do { try await session.prepareTranslation() }
        catch { translateNote = "Couldn't get that language pair ready. Open Glasses Hub and try again while online." }
        while !Task.isCancelled, mine == translationRun, translateOn {
            guard let job = nextTranslationJob() else {
                try? await Task.sleep(nanoseconds: 120_000_000)
                continue
            }
            do {
                let result = try await session.translate(job.text)
                finishTranslation(job, result.targetText)
            } catch {
                finishTranslation(job, job.text)                    // show the original before showing nothing
                translateNote = "Translation isn't working for this pair right now."
            }
        }
    }
}
