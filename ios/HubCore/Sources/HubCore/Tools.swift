import Foundation

// MARK: Tuner

/// Finds the pitch in a short stretch of microphone samples.
public enum Pitch {
    /// The fundamental frequency in Hz, or nil when there's no clear note (silence, noise).
    /// Autocorrelation with a normalised difference, searched between `low` and `high` Hz.
    public static func detect(_ samples: [Float], sampleRate: Double, low: Double = 60, high: Double = 1200) -> Double? {
        let n = samples.count
        guard n >= 1024, sampleRate > 0 else { return nil }
        var energy: Float = 0
        for s in samples { energy += s * s }
        guard energy / Float(n) > 1e-5 else { return nil }                 // too quiet to call
        let minLag = max(2, Int(sampleRate / high)), maxLag = min(n / 2, Int(sampleRate / low))
        guard maxLag > minLag + 2 else { return nil }
        // cumulative mean normalised difference (the heart of the YIN method)
        var diff = [Float](repeating: 0, count: maxLag + 1)
        let window = n - maxLag
        for lag in 1...maxLag {
            var sum: Float = 0
            var i = 0
            while i < window { let d = samples[i] - samples[i + lag]; sum += d * d; i += 1 }
            diff[lag] = sum
        }
        var running: Float = 0
        var norm = [Float](repeating: 1, count: maxLag + 1)
        for lag in 1...maxLag {
            running += diff[lag]
            norm[lag] = running > 0 ? diff[lag] * Float(lag) / running : 1
        }
        // first dip under the threshold, followed down to its bottom
        var best = -1
        var lag = minLag
        while lag < maxLag {
            if norm[lag] < 0.15 {
                while lag + 1 < maxLag, norm[lag + 1] < norm[lag] { lag += 1 }
                best = lag; break
            }
            lag += 1
        }
        guard best > 0 else { return nil }
        // parabolic interpolation between neighbours for a finer estimate
        var refined = Double(best)
        if best > 1, best < maxLag {
            let a = Double(norm[best - 1]), b = Double(norm[best]), c = Double(norm[best + 1])
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { refined += 0.5 * (a - c) / denom }
        }
        let hz = sampleRate / refined
        return hz >= low && hz <= high ? hz : nil
    }
}

public struct TunerReading: Equatable {
    public var hz: Double
    public var note: String        // "A", "C#"
    public var octave: Int
    /// How far off the note is, in hundredths of a semitone (−50…+50). Negative is flat.
    public var cents: Int

    public static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public init?(hz: Double, a4: Double = 440) {
        guard hz > 0, a4 > 0 else { return nil }
        let exact = 69 + 12 * log2(hz / a4)                  // MIDI note number
        let nearest = Int(exact.rounded())
        guard (12...119).contains(nearest) else { return nil }
        self.hz = hz
        note = TunerReading.names[nearest % 12]
        octave = nearest / 12 - 1
        cents = Int(((exact - Double(nearest)) * 100).rounded())
    }
    public var inTune: Bool { abs(cents) <= 5 }
}

public enum Tuner {
    public static func card(_ reading: TunerReading?, listening: Bool, screen: Screen, glyphs: Glyphs = .plain) -> Card {
        guard listening else { return Card(["Tuner", "Look up to start listening", "(uses the phone's microphone)"]) }
        guard let r = reading else { return Card(["Tuner", "Listening…", "Play a note near your phone."]) }
        let cells = min(21, max(9, (screen.columns - 6) | 1))       // odd, so there's a centre
        let mid = cells / 2
        let at = max(0, min(cells - 1, mid + Int((Double(r.cents) / 50 * Double(mid)).rounded())))
        var meter = ""
        for i in 0..<cells { meter += i == at ? "●" : (i == mid ? "|" : "-") }
        // plain letters only: the glasses' font has no flat, sharp or cent signs
        let verdict: String
        if r.inTune { verdict = "In tune" }
        else if r.cents < 0 { verdict = "Flat \(-r.cents) cents: tune up" }
        else { verdict = "Sharp \(r.cents) cents: tune down" }
        return Card(["Tuner", "\(r.note)\(r.octave)   \(String(format: "%.1f", r.hz)) Hz", "b " + meter + " #", verdict])
    }
}

// MARK: Metronome

public enum Metronome {
    public static let range = 30...240

    /// One bar of clicks as mono samples, to be played in a loop: a higher click on the first beat.
    public static func bar(bpm: Int, beats: Int, sampleRate: Double) -> [Float] {
        let bpm = min(range.upperBound, max(range.lowerBound, bpm)), beats = max(1, min(12, beats))
        let perBeat = Int((sampleRate * 60 / Double(bpm)).rounded())
        var out = [Float](repeating: 0, count: perBeat * beats)
        let length = min(perBeat, Int(sampleRate * 0.03))                 // a 30 ms tick
        for beat in 0..<beats {
            let freq = beat == 0 ? 1760.0 : 1175.0
            for i in 0..<length {
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 140)
                out[beat * perBeat + i] = Float(sin(2 * .pi * freq * t) * envelope * 0.9)
            }
        }
        return out
    }

    public static func tempoName(_ bpm: Int) -> String {
        switch bpm {
        case ..<60: return "Largo"; case 60..<76: return "Adagio"; case 76..<108: return "Andante"
        case 108..<120: return "Moderato"; case 120..<156: return "Allegro"; case 156..<176: return "Vivace"
        default: return "Presto"
        }
    }

    public static func card(bpm: Int, beats: Int, running: Bool, screen: Screen) -> Card {
        Card(["Metronome", "\(bpm) BPM   \(beats)/4", tempoName(bpm), running ? "● Playing on your phone" : "Stopped",
              "Turn: tempo   Look up: " + (running ? "stop" : "start")])
    }
}

// MARK: Dice, coin, picker

public enum PickerMode: String, CaseIterable, Identifiable {
    case coin, d6, twoD6, d20, list
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .coin: return "Coin flip"; case .d6: return "One die"; case .twoD6: return "Two dice"
        case .d20: return "D20"; case .list: return "Pick from my list"
        }
    }
}

public struct PickerResult: Equatable {
    public var mode: PickerMode
    public var values: [Int]          // die faces, or 0/1 for the coin, or the index picked
    public var text: String           // "Heads", "7", the chosen option
}

public enum Picker {
    public static func options(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func roll(_ mode: PickerMode, options: [String] = [], using random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> PickerResult {
        switch mode {
        case .coin:
            let v = random(2); return PickerResult(mode: mode, values: [v], text: v == 0 ? "Heads" : "Tails")
        case .d6:
            let v = random(6) + 1; return PickerResult(mode: mode, values: [v], text: "\(v)")
        case .twoD6:
            let a = random(6) + 1, b = random(6) + 1; return PickerResult(mode: mode, values: [a, b], text: "\(a + b)")
        case .d20:
            let v = random(20) + 1; return PickerResult(mode: mode, values: [v], text: "\(v)")
        case .list:
            guard !options.isEmpty else { return PickerResult(mode: mode, values: [], text: "Add options in the app") }
            let i = random(options.count); return PickerResult(mode: mode, values: [i], text: options[i])
        }
    }

    /// A die face as three rows of pips.
    public static func face(_ value: Int) -> [String] {
        let on = "●", off = " "
        func row(_ a: Bool, _ b: Bool, _ c: Bool) -> String { "\(a ? on : off) \(b ? on : off) \(c ? on : off)" }
        switch value {
        case 1: return [row(false, false, false), row(false, true, false), row(false, false, false)]
        case 2: return [row(true, false, false), row(false, false, false), row(false, false, true)]
        case 3: return [row(true, false, false), row(false, true, false), row(false, false, true)]
        case 4: return [row(true, false, true), row(false, false, false), row(true, false, true)]
        case 5: return [row(true, false, true), row(false, true, false), row(true, false, true)]
        default: return [row(true, false, true), row(true, false, true), row(true, false, true)]
        }
    }

    public static func card(mode: PickerMode, result: PickerResult?, rolling: Bool, screen: Screen) -> Card {
        var lines = [mode.title]
        if rolling { return Card(lines + ["", "…"]) }
        guard let result, result.mode == mode else {
            let verb: String = mode == .coin ? "flip" : (mode == .list ? "pick" : "roll")
            lines.append("Look up to " + verb)
            lines.append("Turn: change what to roll")
            return Card(lines)
        }
        switch mode {
        case .d6:
            for row in face(result.values.first ?? 1) { lines.append("[ " + row + " ]") }
        case .twoD6:
            let a = face(result.values.first ?? 1), b = face(result.values.last ?? 1)
            for i in 0..<3 { lines.append("[ " + a[i] + " ]  [ " + b[i] + " ]") }
            lines.append("Total " + result.text)
        case .coin, .d20:
            lines.append(""); lines.append(TextLayout.wide(result.text))
        case .list:
            lines.append(""); lines.append(contentsOf: TextLayout.wrap(result.text, width: screen.columns))
        }
        return Card(lines)
    }
}

// MARK: Speed read

/// Shows text a few words at a time in one spot, so the eyes don't have to move.
public enum SpeedRead {
    public static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Seconds each chunk stays up. Never faster than `floor`, the quickest the glasses are sent screens.
    public static func interval(wpm: Int, chunk: Int, floor: Double = 0.3) -> Double {
        max(floor, 60 * Double(max(1, chunk)) / Double(max(60, wpm)))
    }

    /// The chunk starting at `index`, kept inside the row width (a long word still gets its own turn).
    public static func chunk(_ words: [String], at index: Int, size: Int, width: Int) -> (text: String, count: Int) {
        guard words.indices.contains(index) else { return ("", 0) }
        var text = words[index], count = 1
        while count < max(1, size), words.indices.contains(index + count), text.count + 1 + words[index + count].count <= width {
            text += " " + words[index + count]; count += 1
            if let last = text.last, ".!?".contains(last) { break }             // let a sentence end land on its own
        }
        return (text, count)
    }

    public static func card(words: [String], index: Int, size: Int, playing: Bool, wpm: Int, screen: Screen) -> Card {
        guard !words.isEmpty else { return Card(["Speed read", "Paste some text in the app,", "under Apps > Reader."]) }
        if index >= words.count { return Card(["Speed read", "The end.", "Look up to start over"]) }
        let piece = chunk(words, at: index, size: size, width: screen.columns).text
        let pad = String(repeating: " ", count: max(0, (screen.columns - piece.count) / 2))
        let done = Double(index) / Double(words.count)
        let status = (playing ? "\(wpm) wpm" : "Paused") + "  " + TextLayout.bar(done, cells: 8) + " \(Int(done * 100))%"
        let rows = screen.rows
        var lines = [String](repeating: "", count: max(3, rows))
        lines[0] = status
        lines[min(rows - 1, max(1, rows / 2))] = pad + piece
        return Card(lines)
    }
}
