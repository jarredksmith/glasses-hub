import Foundation

// MARK: - Chord charts

public struct ChordStep: Equatable {
    public var chord: String
    public var lyric: String
}

public enum ChordChart {
    /// The notes of a chord as pitch classes (C = 0), or nil if the text isn't a chord name.
    public static func notes(of chord: String) -> Set<Int>? {
        var text = Substring(chord.trimmingCharacters(in: .whitespaces))
        if let slash = text.firstIndex(of: "/") { text = text[..<slash] }          // the bass note doesn't change the chord
        guard let letter = text.first, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter] else { return nil }
        text = text.dropFirst()
        var root = base
        if text.first == "#" { root += 1; text = text.dropFirst() } else if text.first == "b" { root -= 1; text = text.dropFirst() }
        let shapes: [String: [Int]] = [
            "": [0, 4, 7], "maj": [0, 4, 7], "m": [0, 3, 7], "min": [0, 3, 7], "5": [0, 7],
            "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "M7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "min7": [0, 3, 7, 10],
            "6": [0, 4, 7, 9], "m6": [0, 3, 7, 9], "9": [0, 2, 4, 7, 10], "add9": [0, 2, 4, 7], "m9": [0, 2, 3, 7, 10],
            "sus2": [0, 2, 7], "sus4": [0, 5, 7], "sus": [0, 5, 7], "7sus4": [0, 5, 7, 10],
            "dim": [0, 3, 6], "dim7": [0, 3, 6, 9], "aug": [0, 4, 8], "+": [0, 4, 8], "m7b5": [0, 3, 6, 10],
        ]
        guard let shape = shapes[String(text)] else { return nil }
        return Set(shape.map { (($0 + root) % 12 + 12) % 12 })
    }

    /// Reads a chart into the chord changes in order, each with the words sung over it. Takes chords in
    /// square brackets inside the words ("[G]Amazing [C]grace") or a line of chords above a line of words.
    public static func parse(_ text: String) -> [ChordStep] {
        var steps = [ChordStep]()
        func add(_ chord: String, _ lyric: String) {
            let words = lyric.trimmingCharacters(in: .whitespaces)
            if let last = steps.indices.last, steps[last].chord == chord {
                if !words.isEmpty { steps[last].lyric += (steps[last].lyric.isEmpty ? "" : " / ") + words }
            } else { steps.append(ChordStep(chord: chord, lyric: words)) }
        }
        func carry(_ lyric: String) {
            let words = lyric.trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty, let last = steps.indices.last else { return }
            steps[last].lyric += (steps[last].lyric.isEmpty ? "" : " / ") + words
        }
        var waiting = [String]()            // chords from a chord-only line, for the words on the next line
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("{") { continue }
            if line.contains("[") {
                for chord in waiting { add(chord, "") }
                waiting = []
                var rest = Substring(line)
                if let open = rest.firstIndex(of: "[") { carry(String(rest[..<open])); rest = rest[open...] }
                while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                    let chord = String(rest[rest.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                    rest = rest[rest.index(after: close)...]
                    let end = rest.firstIndex(of: "[") ?? rest.endIndex
                    if notes(of: chord) != nil { add(chord, String(rest[..<end])) } else { carry(String(rest[..<end])) }
                    rest = rest[end...]
                }
                continue
            }
            let words = line.split(separator: " ").map(String.init)
            if !words.isEmpty, words.allSatisfy({ notes(of: $0) != nil }) {
                for chord in waiting { add(chord, "") }
                waiting = words
            } else if let first = waiting.first {
                add(first, line)
                for chord in waiting.dropFirst() { add(chord, "") }
                waiting = []
            } else { carry(line) }
        }
        for chord in waiting { add(chord, "") }
        return steps
    }

    public struct Song: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var chart: String
    }

    /// Traditional songs, long out of copyright, with simple open-chord arrangements.
    public static let songs: [Song] = [
        Song(id: "grace", title: "Amazing Grace", chart: """
        [G]Amazing grace, how [C]sweet the [G]sound
        That saved a wretch like [D]me
        I [G]once was lost, but [C]now am [G]found
        Was blind, but [D]now I [G]see
        """),
        Song(id: "susanna", title: "Oh! Susanna", chart: """
        I [C]come from Alabama with my banjo on my [G]knee
        I'm [C]going to Louisiana, my true love [G]for to [C]see
        [F]Oh! Susanna, oh [C]don't you cry for [G]me
        I [C]come from Alabama with my banjo [G]on my [C]knee
        """),
        Song(id: "auld", title: "Auld Lang Syne", chart: """
        Should [G]auld acquaintance [D]be forgot
        And [G]never brought to [C]mind
        Should [G]auld acquaintance [D]be forgot
        And [Em]days of [C]auld lang [G]syne
        For [G]auld lang [D]syne, my dear
        For [G]auld lang [C]syne
        We'll [G]take a cup of [D]kindness yet
        For [Em]auld [C]lang [G]syne
        """),
        Song(id: "swing", title: "Swing Low, Sweet Chariot", chart: """
        Swing [D]low, sweet [G]chari[D]ot
        Coming for to carry me [A]home
        Swing [D]low, sweet [G]chari[D]ot
        Coming for to [A]carry me [D]home
        """),
        Song(id: "scarborough", title: "Scarborough Fair", chart: """
        [Am]Are you going to [G]Scarborough [Am]Fair
        [C]Parsley, [Am]sage, rose[D]mary and [Am]thyme
        Remember [C]me to one who lives [G]there
        [Am]She once [G]was a true love of [Am]mine
        """),
    ]
}

/// How much of each of the twelve notes is sounding, whatever the octave.
public enum Chroma {
    /// Twelve values adding up to 1 (C first), and how loud the sound was overall.
    public static func compute(_ samples: [Float], sampleRate: Double) -> (chroma: [Double], level: Double) {
        let count = samples.count
        guard count >= 1024, sampleRate > 0 else { return ([Double](repeating: 0, count: 12), 0) }
        var windowed = [Double](repeating: 0, count: count)
        var power = 0.0
        for i in 0..<count {
            let value = Double(samples[i])
            power += value * value
            windowed[i] = value * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(count - 1)))
        }
        var chroma = [Double](repeating: 0, count: 12)
        for midi in 40...88 {                                   // the guitar's low E up to the E four octaves above
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            guard frequency < sampleRate / 2 else { break }
            let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
            var s1 = 0.0, s2 = 0.0
            for value in windowed { let s0 = value + coefficient * s1 - s2; s2 = s1; s1 = s0 }
            let magnitude = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2).squareRoot()
            chroma[midi % 12] += magnitude
        }
        let total = chroma.reduce(0, +)
        if total > 0 { for i in 0..<12 { chroma[i] /= total } }
        return (chroma, (power / Double(count)).squareRoot())
    }

    /// How well the sound fits a chord: the share of it on the chord's notes, less the share that's elsewhere.
    public static func score(_ chroma: [Double], notes: Set<Int>) -> Double {
        var inside = 0.0
        for note in notes where chroma.indices.contains(note) { inside += chroma[note] }
        return inside - (1 - inside) * 0.5
    }
}

/// Follows a player through a chord chart, moving on when the next chord is heard.
public struct ChordFollower: Equatable {
    public private(set) var steps: [ChordStep]
    public private(set) var index = 0
    private var streak = 0
    /// Sounds quieter than this are ignored (room noise, fingers on strings).
    public var gate = 0.01

    public init(steps: [ChordStep]) { self.steps = steps }

    public var finished: Bool { !steps.isEmpty && index >= steps.count - 1 }
    public mutating func step(_ by: Int) {
        guard !steps.isEmpty else { return }
        index = min(steps.count - 1, max(0, index + by)); streak = 0
    }
    public mutating func restart() { index = 0; streak = 0 }

    /// Takes a moment of sound. True when it moved on to the next chord.
    public mutating func hear(chroma: [Double], level: Double) -> Bool {
        guard steps.indices.contains(index + 1), level >= gate,
              let now = ChordChart.notes(of: steps[index].chord), let next = ChordChart.notes(of: steps[index + 1].chord), now != next else {
            streak = 0; return false
        }
        let ahead = Chroma.score(chroma, notes: next), here = Chroma.score(chroma, notes: now)
        if ahead > 0.25, ahead - here > 0.12 { streak += 1 } else { streak = 0 }
        guard streak >= 2 else { return false }
        index += 1; streak = 0
        return true
    }

    public func card(title: String, listening: Bool, screen: Screen) -> Card {
        guard !steps.isEmpty else { return Card(["Chords", "No chords found.", "Add a chart in the app."]) }
        let step = steps[min(index, steps.count - 1)]
        let next = steps.indices.contains(index + 1) ? steps[index + 1].chord : "end"
        var lines = [TextLayout.wide(step.chord) + "\u{3000}" + "then " + next]
        let room = max(0, screen.rows - 2)
        if !step.lyric.isEmpty, room > 0 { lines += TextLayout.wrap(step.lyric, width: screen.columns, maxLines: room) }
        lines.append(TextLayout.fit("\(index + 1)/\(steps.count)  " + (listening ? "listening" : "Look up: listen"), width: screen.columns))
        return Card(lines)
    }
}

// MARK: - Drums

public enum Drum: String, CaseIterable, Codable, Sendable {
    case kick, snare, hat, tom
    public var name: String {
        switch self { case .kick: return "kick"; case .snare: return "snare"; case .hat: return "hi-hat"; case .tom: return "tom" }
    }
}

/// A groove written on a grid: bars of equal steps, each step naming the drums struck on it.
public struct DrumPattern: Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bars: [[Set<Drum>]]

    public init(name: String, bars: [[Set<Drum>]]) { self.name = name; self.bars = bars }

    public var steps: Int { bars.first?.count ?? 0 }
    public var usesToms: Bool { bars.contains { $0.contains { $0.contains(.tom) } } }

    /// Reads rows like "HH x-x-x-x-", "SD ----o---", "BD o-------", "TM ------oo". A repeated row starts a new bar.
    public static func parse(name: String, _ text: String) -> DrumPattern? {
        let labels: [String: Drum] = ["HH": .hat, "H": .hat, "HAT": .hat, "SD": .snare, "S": .snare, "SN": .snare,
                                      "BD": .kick, "K": .kick, "KD": .kick, "B": .kick, "TM": .tom, "T": .tom, "TOM": .tom]
        var bars = [[Drum: [Bool]]]()
        var current = [Drum: [Bool]]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "|" || $0 == ":" }),
                  let drum = labels[line[..<space].uppercased()] else { continue }
            let cells = line[space...].filter { !" |:".contains($0) }.map { !"-._".contains($0) }
            guard !cells.isEmpty else { continue }
            if current[drum] != nil { bars.append(current); current = [:] }
            current[drum] = cells
        }
        if !current.isEmpty { bars.append(current) }
        let length = bars.flatMap { $0.values.map(\.count) }.max() ?? 0
        guard length > 0, length <= 32 else { return nil }
        let built: [[Set<Drum>]] = bars.map { bar in
            (0..<length).map { step in Set(bar.compactMap { $0.value.indices.contains(step) && $0.value[step] ? $0.key : nil }) }
        }
        guard built.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }
        return DrumPattern(name: name, bars: built)
    }

    private static func make(_ name: String, _ text: String) -> DrumPattern { parse(name: name, text) ?? DrumPattern(name: name, bars: []) }

    /// Standard grooves to learn on, simplest first.
    public static let library: [DrumPattern] = [
        make("Kick and snare", "SD ----o-------o---\nBD o-------o-------"),
        make("Basic rock", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------"),
        make("Rock, extra kick", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-o-----"),
        make("Four on the floor", "HH --x---x---x---x-\nSD ----o-------o---\nBD o---o---o---o---"),
        make("Half time", "HH x-x-x-x-x-x-x-x-\nSD --------o-------\nBD o---------o-----"),
        make("Sixteenth hats", "HH xxxxxxxxxxxxxxxx\nSD ----o-------o---\nBD o-------o-o-----"),
        make("Shuffle", "HH x-xx-xx-xx-x\nSD ---o-----o--\nBD o-----o-----"),
        make("Rock with a fill", "HH x-x-x-x-x-x-x-x-\nSD ----o-------o---\nBD o-------o-------\nHH x-x-x-x---------\nSD ----o---oooo----\nTM ------------oooo\nBD o-------o-------"),
    ]
}

/// One thing the microphone heard hit: how its energy rose in the low, middle and high ranges.
public struct DrumHit: Equatable, Sendable {
    public var time: Double
    public var rise: [Double]
    public var level: Double
    public init(time: Double, rise: [Double], level: Double) { self.time = time; self.rise = rise; self.level = level }
    /// The rise as shares of the whole, so loud and soft hits compare.
    public var shape: [Double] {
        let total = rise.reduce(0, +)
        return total > 0 ? rise.map { $0 / total } : rise
    }
}

/// Listens to raw audio for drum hits. Feed it buffers in order; it remembers what it needs between them.
public struct DrumEar: Sendable {
    public let sampleRate: Double
    private let hop: Int
    private var filters = [Double](repeating: 0, count: 6)
    private var sums = [Double](repeating: 0, count: 3)
    private var filled = 0
    private var averages = [Double](repeating: 0, count: 3)
    private var previous = [Double](repeating: 0, count: 3)
    private var hops = 0
    private var lastHit = -1.0
    private var pending: (time: Double, rise: [Double], hopsLeft: Int)?
    /// How far above the recent level a band must jump to count as a hit.
    public var sensitivity = 4.0
    /// Hits quieter than this (as band energy) are ignored.
    public var floor = 1e-5

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(64, Int(sampleRate * 0.006))
    }

    private static func alpha(_ cutoff: Double, _ rate: Double) -> Double { 1 - exp(-2 * Double.pi * cutoff / rate) }

    public mutating func process(_ samples: [Float]) -> [DrumHit] {
        var hits = [DrumHit]()
        let aLow = DrumEar.alpha(150, sampleRate), aMidLow = DrumEar.alpha(250, sampleRate)
        let aMidHigh = DrumEar.alpha(2500, sampleRate), aHigh = DrumEar.alpha(6000, sampleRate)
        for sample in samples {
            let x = Double(sample)
            filters[0] += aLow * (x - filters[0]); filters[1] += aLow * (filters[0] - filters[1])              // below ~150 Hz
            filters[2] += aMidLow * (x - filters[2]); filters[3] += aMidHigh * (x - filters[3])                // 250 Hz to 2.5 kHz between these
            filters[4] += aHigh * (x - filters[4]); filters[5] += aHigh * (filters[4] - filters[5])            // above ~6 kHz is what's left
            let low = filters[1], mid = filters[3] - filters[2], high = x - filters[5]
            sums[0] += low * low; sums[1] += mid * mid; sums[2] += high * high
            filled += 1
            guard filled >= hop else { continue }
            let energy = sums.map { $0 / Double(hop) }
            sums = [0, 0, 0]; filled = 0; hops += 1
            let time = Double(hops * hop) / sampleRate
            var rise = [0.0, 0.0, 0.0], fired = false
            for band in 0..<3 {
                let jump = energy[band] - previous[band]
                if energy[band] > floor, energy[band] > averages[band] * sensitivity, jump > 0 { rise[band] = energy[band] - averages[band]; fired = true }
            }
            if var open = pending {
                // the hit is still building: keep the strongest reading of each band over a few hops
                for band in 0..<3 { open.rise[band] = max(open.rise[band], max(0, energy[band] - averages[band])) }
                open.hopsLeft -= 1
                if open.hopsLeft <= 0 {
                    hits.append(DrumHit(time: open.time, rise: open.rise, level: open.rise.reduce(0, +).squareRoot()))
                    pending = nil
                } else { pending = open }
            } else if fired, hops > 20, time - lastHit > 0.05 {
                pending = (time, rise, 3); lastHit = time
            }
            for band in 0..<3 {
                // the running level rises slowly and falls a little faster, so a ringing drum doesn't hide the next hit
                let rate = energy[band] > averages[band] ? 0.08 : 0.2
                averages[band] += rate * (energy[band] - averages[band])
                previous[band] = energy[band]
            }
        }
        return hits
    }
}

/// Tells drums apart by the shape of their hits. Calibrating to the wearer's own kit replaces the defaults.
public struct DrumKit: Equatable, Codable, Sendable {
    public struct Voice: Equatable, Codable, Sendable { public var shape: [Double]; public var level: Double }
    public var voices: [Drum: Voice]
    /// True once the voices were learned from the wearer's own kit, so their loudness can be trusted.
    public var calibrated = false

    public static let standard = DrumKit(voices: [
        .kick: Voice(shape: [0.85, 0.13, 0.02], level: 1), .snare: Voice(shape: [0.05, 0.55, 0.40], level: 1),
        .hat: Voice(shape: [0.0, 0.08, 0.92], level: 0.3),
    ])

    public init(voices: [Drum: Voice]) { self.voices = voices }

    /// A voice learned from a few hits of one drum.
    public static func learn(_ hits: [DrumHit]) -> Voice? {
        guard !hits.isEmpty else { return nil }
        var shape = [0.0, 0.0, 0.0]
        for hit in hits { let s = hit.shape; for band in 0..<3 where s.indices.contains(band) { shape[band] += s[band] / Double(hits.count) } }
        return Voice(shape: shape, level: hits.map(\.level).reduce(0, +) / Double(hits.count))
    }

    /// The drum, or pair of drums struck together, that best explains a hit.
    public func identify(_ hit: DrumHit) -> Set<Drum> {
        let heard = hit.shape
        let known = Drum.allCases.filter { voices[$0] != nil }
        var options: [Set<Drum>] = known.map { [$0] }
        for (i, a) in known.enumerated() { for b in known.dropFirst(i + 1) { options.append([a, b]) } }
        var best: Set<Drum> = [], bestDistance = Double.infinity
        for option in options {
            var mix = [0.0, 0.0, 0.0]
            for drum in option { if let voice = voices[drum] { for band in 0..<3 { mix[band] += voice.shape[band] * voice.level * voice.level } } }
            let total = mix.reduce(0, +)
            guard total > 0 else { continue }
            var distance = 0.0
            for band in 0..<3 { let d = mix[band] / total - (heard.indices.contains(band) ? heard[band] : 0); distance += d * d }
            distance += option.count > 1 ? 0.004 : 0                    // when it's close, one drum is the likelier story
            if distance < bestDistance { bestDistance = distance; best = option }
        }
        guard calibrated else { return best }
        // A quiet drum under a loud one (a hi-hat with a kick) barely changes the shape. Look instead for
        // energy in its own range beyond what the drums already named would put there.
        let total = hit.rise.reduce(0, +)
        var expected = [0.0, 0.0, 0.0]
        for drum in best { if let voice = voices[drum] { for band in 0..<3 { expected[band] += voice.shape[band] * voice.level * voice.level } } }
        let scale = expected.reduce(0, +) > 0 ? total / expected.reduce(0, +) : 0
        for drum in known where !best.contains(drum) && best.count < 2 {
            guard let voice = voices[drum], let band = voice.shape.indices.max(by: { voice.shape[$0] < voice.shape[$1] }) else { continue }
            let own = voice.shape[band] * voice.level * voice.level
            let spare = hit.rise[band] - expected[band] * scale
            if own > 0, spare > own * 0.3, hit.rise[band] > expected[band] * scale * 3 { best.insert(drum) }
        }
        return best
    }
}

/// Walks a player through a pattern: each right hit moves the marker on, and a finished bar reports the tempo.
public struct DrumTrainer: Equatable {
    public private(set) var pattern: DrumPattern
    public private(set) var bar = 0
    public private(set) var step = 0
    public private(set) var wrong = 0
    public private(set) var tempo: Int?
    public private(set) var laps = 0
    private var barStartTime: Double?
    private var barStartStep = 0
    /// Steps to a beat, for working out the tempo: 4 for sixteenths, 3 for a shuffle's triplets.
    public var perBeat: Int { pattern.steps % 3 == 0 && pattern.steps % 4 != 0 || pattern.steps == 12 ? 3 : 4 }

    public init(pattern: DrumPattern) {
        self.pattern = pattern
        step = DrumTrainer.firstNote(in: pattern.bars.first ?? [], from: 0) ?? 0
    }

    private static func firstNote(in bar: [Set<Drum>], from: Int) -> Int? { bar.indices.first { $0 >= from && !bar[$0].isEmpty } }

    public var expected: Set<Drum> {
        guard pattern.bars.indices.contains(bar), pattern.bars[bar].indices.contains(step) else { return [] }
        return pattern.bars[bar][step]
    }

    /// Whether what was heard will do for what's written. Kick and snare must be there; toms and snare
    /// stand in for each other; a lone hi-hat is satisfied by anything that isn't a kick or snare.
    public static func matches(heard: Set<Drum>, expected: Set<Drum>) -> Bool {
        let body: Set<Drum> = [.snare, .tom]
        if expected.contains(.kick) != heard.contains(.kick) { return false }
        let wantsBody = !expected.isDisjoint(with: body), hasBody = !heard.isDisjoint(with: body)
        return wantsBody == hasBody
    }

    /// Takes a hit. True when it was the right one and the marker moved.
    public mutating func hit(_ heard: Set<Drum>, at time: Double) -> Bool {
        guard !pattern.bars.isEmpty, !expected.isEmpty else { return false }
        guard DrumTrainer.matches(heard: heard, expected: expected) else { wrong += 1; return false }
        if barStartTime == nil { barStartTime = time; barStartStep = step }
        let notes = pattern.bars[bar]
        if let next = DrumTrainer.firstNote(in: notes, from: step + 1) { step = next; return true }
        // end of the bar: tempo from the first note to this one
        if let start = barStartTime, step > barStartStep, time > start {
            let beats = Double(step - barStartStep) / Double(perBeat)
            tempo = Int((60 * beats / (time - start)).rounded())
        }
        barStartTime = nil
        bar += 1
        if bar >= pattern.bars.count { bar = 0; laps += 1 }
        step = DrumTrainer.firstNote(in: pattern.bars[bar], from: 0) ?? 0
        return true
    }

    public mutating func restart() { self = DrumTrainer(pattern: pattern) }

    public func card(listening: Bool, note: String = "", arrows: Bool, screen: Screen) -> Card {
        guard pattern.bars.indices.contains(bar) else { return Card(["Drums", "No pattern.", "Pick one in the app."]) }
        if !note.isEmpty { return Card(["Drums"] + TextLayout.wrap(note, width: screen.columns, maxLines: max(1, screen.rows - 1))) }
        let notes = pattern.bars[bar]
        let blank = "\u{3000}"
        // show the whole bar if it fits beside the two-letter label, else the half the marker is in
        let room = max(4, screen.wideColumns - 2)
        var from = 0, to = notes.count
        if notes.count > room { let half = (notes.count + 1) / 2; from = step < half ? 0 : half; to = min(notes.count, from + half) }
        let showToms = pattern.usesToms && screen.rows >= 6
        func row(_ label: String, _ drums: [Drum], _ mark: String) -> String {
            var line = TextLayout.wide(label)
            for i in from..<to {
                if !showToms, drums.contains(.snare), notes[i].contains(.tom) { line += "ｔ" }
                else { line += drums.contains(where: { notes[i].contains($0) }) ? mark : "－" }
            }
            return line
        }
        var head = pattern.name + (pattern.bars.count > 1 ? "  \(bar + 1)/\(pattern.bars.count)" : "")
        if let tempo { head += "  \(tempo) bpm" }
        if !listening { head = "Look up: start. " + pattern.name }
        var lines = [TextLayout.fit(head, width: screen.columns), row("HH", [.hat], "ｘ")]
        if showToms { lines.append(row("TM", [.tom], "ｏ")) }
        lines.append(row("SD", [.snare], "ｏ"))
        lines.append(row("BD", [.kick], "ｏ"))
        if screen.rows >= lines.count + 1, step >= from, step < to {
            lines.append(blank + blank + String(repeating: blank, count: step - from) + (arrows ? "▲" : "＾"))
        }
        return Card(lines)
    }
}
