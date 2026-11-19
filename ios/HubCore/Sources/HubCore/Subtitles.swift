import Foundation

/// One caption from a subtitle file: when it shows, when it goes, and what it says.
public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Reads .srt and .vtt subtitle files.
public enum SubtitleFile {
    /// Subtitle files come in whatever encoding their maker's computer used.
    public static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("\u{FFFD}") else { return text }             // not UTF-8 after all: an older Windows file
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? text
    }

    /// "01:02:03,450", "01:02:03.450" or "02:03.450" as seconds.
    public static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Takes out styling: <i>…</i>, {\an8}, and the spaces they leave behind.
    public static func plain(_ text: String) -> String {
        var out = "", depth: Character? = nil
        for ch in text {
            if let close = depth { if ch == close { depth = nil }; continue }
            if ch == "<" { depth = ">"; continue }
            if ch == "{" { depth = "}"; continue }
            out.append(ch)
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static let adverts = ["opensubtitles", "www.", "http", "subtitles by", "synced and corrected", "osdb"]

    public static func parse(_ raw: String) -> [SubtitleCue] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: "\n")
        var cues = [SubtitleCue](), i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard let arrow = line.range(of: "-->") else { continue }
            let after = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let endStamp = after.split(separator: " ").first.map(String.init) ?? ""
            guard let start = seconds(String(line[..<arrow.lowerBound])), let end = seconds(endStamp) else { continue }
            var text = [String]()
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].contains("-->") {
                text.append(plain(lines[i])); i += 1
            }
            // a file with no blank lines between captions: the next caption's number isn't dialogue
            if i < lines.count, lines[i].contains("-->"), let last = text.last, Int(last) != nil { text.removeLast() }
            let joined = text.filter { !$0.isEmpty }.joined(separator: "\n")
            let lowered = joined.lowercased()
            guard !joined.isEmpty, end > start, !adverts.contains(where: { lowered.contains($0) }) else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: joined))
        }
        return cues.sorted { $0.start < $1.start }
    }
}

/// Every spoken word of a film in order, set up so a few words overheard can be found in it.
public struct SubtitleIndex: Sendable {
    public let cues: [SubtitleCue]
    private let words: [String]
    private let wordCue: [Int]
    private let cueFirstWord: [Int]
    private let trigrams: [String: [Int]]

    /// Words as they would be recognised from speech: lower case, no punctuation, and none of the things
    /// nobody says, such as [door slams], (LAUGHS), ♪ lyrics marks or "JOHN:" before a line.
    public static func words(_ text: String) -> [String] {
        var spoken = "", depth: Character? = nil
        for ch in text {
            if let close = depth { if ch == close { depth = nil }; continue }
            if ch == "[" { depth = "]"; continue }
            if ch == "(" { depth = ")"; continue }
            spoken.append(ch)
        }
        var out = [String]()
        for line in spoken.components(separatedBy: "\n") {
            var rest = Substring(line)
            if let colon = rest.firstIndex(of: ":") {                    // a speaker's name in capitals
                let name = rest[..<colon]
                if !name.isEmpty, name.count <= 24, name == name.uppercased(), name.contains(where: \.isLetter) { rest = rest[rest.index(after: colon)...] }
            }
            var word = ""
            for ch in rest.lowercased() {
                if ch.isLetter || ch.isNumber { word.append(ch) }
                else if ch == "'" || ch == "\u{2019}" { continue }
                else if !word.isEmpty { out.append(word); word = "" }
            }
            if !word.isEmpty { out.append(word) }
        }
        return out
    }

    public init(cues: [SubtitleCue]) {
        self.cues = cues
        var words = [String](), wordCue = [Int](), first = [Int]()
        for (n, cue) in cues.enumerated() {
            first.append(words.count)
            for word in SubtitleIndex.words(cue.text) { words.append(word); wordCue.append(n) }
        }
        var trigrams = [String: [Int]]()
        if words.count >= 3 {
            for at in 0...(words.count - 3) { trigrams[words[at] + " " + words[at + 1] + " " + words[at + 2], default: []].append(at) }
        }
        self.words = words; self.wordCue = wordCue; self.cueFirstWord = first; self.trigrams = trigrams
    }

    public var wordCount: Int { words.count }

    /// How many words are spoken between two moments of the film.
    public func wordsSpoken(from: Double, to: Double) -> Int {
        var total = 0
        for (n, cue) in cues.enumerated() where cue.start >= from && cue.start < to {
            let next = n + 1 < cueFirstWord.count ? cueFirstWord[n + 1] : words.count
            total += next - cueFirstWord[n]
        }
        return total
    }

    /// Roughly when the word at this place in the film has just been said.
    func spokenAt(_ at: Int) -> Double {
        let n = wordCue[at], cue = cues[n]
        let next = n + 1 < cueFirstWord.count ? cueFirstWord[n + 1] : words.count
        let count = max(1, next - cueFirstWord[n])
        let speech = min(cue.end - cue.start, Double(count) * 0.38)
        return cue.start + speech * Double(at - cueFirstWord[n] + 1) / Double(count)
    }

    public struct Match: Equatable, Sendable {
        /// Where the film is at the moment the last heard word was spoken.
        public let time: Double
        /// How many overlapping three-word runs agreed.
        public let hits: Int
    }

    /// Finds the last few words heard in the film. `near` is where the film is thought to be: a place close
    /// to it is believed on little evidence, a jump elsewhere only when several words in a row line up.
    public func locate(heard: [String], near: Double?) -> Match? {
        let tail = Array(heard.suffix(14))
        guard tail.count >= 3 else { return nil }
        // every place a three-word run of what was heard turns up, as (how far the film is ahead of the
        // heard words, which run)
        var found = [(shift: Int, run: Int, rare: Bool)]()
        for run in 0...(tail.count - 3) {
            guard let places = trigrams[tail[run] + " " + tail[run + 1] + " " + tail[run + 2]], places.count <= 40 else { continue }
            for place in places { found.append((place - run, run, places.count == 1)) }
        }
        guard !found.isEmpty else { return nil }
        found.sort { $0.shift < $1.shift }
        var best: (score: Double, match: Match)?
        var low = 0
        for high in found.indices {
            while found[high].shift - found[low].shift > 3 { low += 1 }           // a dropped or extra word or two is fine
            let group = found[low...high]
            let runs = Set(group.map(\.run))
            let rare = Set(group.filter(\.rare).map(\.run)).count
            guard let last = group.max(by: { $0.run < $1.run }) else { continue }
            let lastWord = min(words.count - 1, last.shift + last.run + 2)
            let trailing = tail.count - 1 - (last.run + 2)                        // words heard since, not in the file
            let time = spokenAt(lastWord) + Double(trailing) * 0.3
            let distance = near.map { abs(time - $0) } ?? .infinity
            let believed: Bool
            if distance <= 8 { believed = true }
            else if distance <= 60 { believed = runs.count >= 2 }
            else { believed = runs.count >= 3 || rare >= 2 }
            guard believed else { continue }
            // more agreement wins; among equals, the place nearest to where the film already is
            let score = Double(runs.count) * 1000 - min(distance, 900)
            if best == nil || score > best!.score { best = (score, Match(time: time, hits: runs.count)) }
        }
        return best?.match
    }
}

/// Follows a film: knows where it is from the dialogue it overhears, and runs on the clock in between.
public struct MovieTracker: Sendable {
    public enum State: Equatable, Sendable { case waiting, running, held }

    public let index: SubtitleIndex
    public private(set) var state: State = .waiting
    /// Speech recognition and the trip to the glasses both take a moment; captions are shown this much early.
    public var lead = 0.9
    /// Stops the captions when the room has gone quiet although the film should be talking.
    public var holdsWhenQuiet = true
    private var filmAt = 0.0
    private var clockAt = 0.0
    private var lastHeard = 0.0
    public private(set) var lastLock: Double?

    public init(cues: [SubtitleCue]) { index = SubtitleIndex(cues: cues) }

    public var isEmpty: Bool { index.cues.isEmpty }
    public var length: Double { index.cues.last?.end ?? 0 }

    /// Where the film is, in seconds from its start. Nil until the first line has been recognised.
    public func position(at now: Double) -> Double? {
        switch state {
        case .waiting: return nil
        case .held: return filmAt
        case .running: return filmAt + (now - clockAt)
        }
    }

    private mutating func set(_ film: Double, now: Double) {
        filmAt = min(max(0, film), length + 5); clockAt = now
    }

    /// Words from the microphone. True when they moved the captions.
    public mutating func hear(_ text: String, at now: Double) -> Bool {
        let heard = SubtitleIndex.words(text)
        guard !heard.isEmpty else { return false }
        lastHeard = now
        let here = position(at: now)
        guard let match = index.locate(heard: heard, near: here) else { return false }
        lastLock = now
        guard state == .running, let here else {
            set(match.time, now: now); state = .running
            return true
        }
        let off = match.time - here
        if abs(off) < 1.5 { set(here + off * 0.35, now: now); return abs(off) > 0.3 }   // ease small corrections in
        set(match.time, now: now)
        return true
    }

    /// Call now and then: holds the captions when the film seems to have been paused.
    public mutating func tick(now: Double) {
        guard state == .running, let here = position(at: now) else { return }
        if here > length + 2 { set(length, now: now); state = .held; return }
        guard holdsWhenQuiet, now - lastHeard > 25 else { return }
        let quietFrom = here - (now - lastHeard)
        if index.wordsSpoken(from: quietFrom, to: here) >= 20 { set(max(0, quietFrom + 2), now: now); state = .held }
    }

    /// Starts the clock by hand at a point in the film, for when it can't be heard.
    public mutating func start(at film: Double, now: Double) {
        set(film, now: now); state = .running; lastHeard = now
    }

    public mutating func toggleHold(now: Double) {
        switch state {
        case .waiting: start(at: max(0, (index.cues.first?.start ?? 0) - lead), now: now)
        case .running: set(position(at: now) ?? 0, now: now); state = .held
        case .held: clockAt = now; lastHeard = now; state = .running
        }
    }

    /// Moves the captions earlier or later by hand.
    public mutating func shift(_ seconds: Double, now: Double) {
        guard let here = position(at: now) else { return }
        set(here + seconds, now: now)
        lastHeard = now
    }

    public mutating func reset() { state = .waiting; filmAt = 0; lastLock = nil }

    /// The caption on screen at this moment, if any.
    public func cue(at now: Double) -> SubtitleCue? {
        guard state != .waiting, let here = position(at: now) else { return nil }
        let t = here + lead
        var low = 0, high = index.cues.count
        while low < high {                                                  // the last caption starting at or before t
            let mid = (low + high) / 2
            if index.cues[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let cue = index.cues[low - 1]
        return t < cue.end ? cue : nil
    }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    public func card(title: String, listening: Bool, note: String, now: Double, screen: Screen) -> Card {
        let name = TextLayout.fit(title.isEmpty ? "Movie captions" : title, width: screen.columns)
        if isEmpty { return Card(["Movie captions"] + TextLayout.wrap(note.isEmpty ? "Pick a movie or show in the app." : note, width: screen.columns)) }
        switch state {
        case .waiting:
            let what = listening ? "Listening for the dialogue. Captions start by themselves once it hears a line."
                                 : (note.isEmpty ? "Select to start listening." : note)
            return Card([name] + TextLayout.wrap(what, width: screen.columns, maxLines: screen.rows - 2) + (listening ? ["Select: start at the first line"] : []))
        case .held:
            let at = MovieTracker.clock(position(at: now) ?? 0)
            return Card([name, "Paused at " + at] + TextLayout.wrap(listening ? "Carries on when the film does. Select: carry on now." : "Select: carry on.", width: screen.columns, maxLines: screen.rows - 2))
        case .running:
            guard let cue = cue(at: now) else { return Card([" "]) }
            var lines = [String]()
            for line in cue.text.components(separatedBy: "\n") { lines += TextLayout.wrap(line, width: screen.columns) }
            return Card(Array(lines.suffix(screen.rows)))
        }
    }
}
