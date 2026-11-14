import Foundation

// MARK: - Word game

/// Guess the hidden word a letter at a time. Turn to pick a letter, select to guess it; six misses allowed.
public struct WordGame: Equatable, Codable {
    public static let lives = 6
    public var word: String
    public var tried: String
    public var cursor: String
    /// The day number this word belongs to, or nil for a free-play word.
    public var day: Int?

    public init(word: String, day: Int? = nil) {
        self.word = word.uppercased(); tried = ""; cursor = "E"; self.day = day
    }

    public var misses: Int { tried.filter { !word.contains($0) }.count }
    public var solved: Bool { word.allSatisfy { tried.contains($0) } }
    public var lost: Bool { misses >= WordGame.lives }
    public var over: Bool { solved || lost }
    public var shown: String { word.map { tried.contains($0) ? String($0) : "_" }.joined(separator: " ") }

    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var untried: [Character] { WordGame.alphabet.filter { !tried.contains($0) } }

    /// Moves the picker to the next (or previous) letter not tried yet.
    public mutating func move(_ by: Int) {
        let left = untried
        guard !over, !left.isEmpty else { return }
        let here = Character(cursor)
        if let at = left.firstIndex(of: here) {
            cursor = String(left[((at + by) % left.count + left.count) % left.count])
        } else {
            cursor = String(left.first { $0 > here } ?? left[0])
        }
    }

    public mutating func guess() {
        guard !over, let letter = cursor.first, !tried.contains(letter) else { return }
        tried.append(letter)
        if !over { move(1) }
    }

    public func card(streak: Int, screen: Screen) -> Card {
        let title = day == nil ? "Word game" : "Daily word"
        if solved {
            return Card([title, TextLayout.headline(word, screen: screen), "Got it with \(misses) miss\(misses == 1 ? "" : "es")." + (day != nil && streak > 1 ? " Streak \(streak)." : ""), "Look up: another word"])
        }
        if lost { return Card([title, "It was " + word, "Out of guesses.", "Look up: another word"]) }
        let left = untried
        let at = left.firstIndex(of: Character(cursor)) ?? 0
        let before = left[(at + left.count - 1) % left.count], after = left[(at + 1) % left.count]
        var lines = [title + "  " + String(repeating: "o", count: WordGame.lives - misses) + String(repeating: "x", count: misses),
                     shown,
                     "\(before)  [ \(cursor) ]  \(after)"]
        let wrong = tried.filter { !word.contains($0) }
        if !wrong.isEmpty { lines.append("Not in it: " + wrong.map(String.init).joined(separator: " ")) }
        else if screen.rows >= 4 { lines.append("Turn: letter. Look up: guess") }
        return Card(lines)
    }

    /// The day number for a date, in the wearer's own time zone, so the word changes at their midnight.
    public static func day(_ date: Date, zone: TimeZone = .current) -> Int {
        Int((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86400)
    }
    public static func daily(day: Int) -> String { words[((day * 7919 + 13) % words.count + words.count) % words.count] }
    public static func random<G: RandomNumberGenerator>(using generator: inout G, not current: String = "") -> String {
        var pick = words.randomElement(using: &generator) ?? "GLASSES"
        if pick == current { pick = words[(words.firstIndex(of: pick)! + 1) % words.count] }
        return pick
    }

    public static let words: [String] = """
    ANCHOR APPLE ARROW AUTUMN BADGE BAKERY BALLOON BANJO BASKET BEACH BEACON BICYCLE BLANKET BLOSSOM BOTTLE BREEZE BRIDGE BRONZE BUBBLE BUCKET
    BUTTON CABIN CACTUS CAMERA CANDLE CANYON CAPTAIN CARPET CASTLE CEDAR CHERRY CHIMNEY CIRCLE CLOVER COBALT COFFEE COMET COMPASS COOKIE COPPER
    CORAL COTTON COUSIN CRADLE CRAYON CRYSTAL CURTAIN CUSHION DAISY DANCER DESERT DIAMOND DINNER DOLPHIN DONKEY DRAGON DRAWER DRUMMER EAGLE ECLIPSE
    ELBOW EMBER ENGINE ENVELOPE FABRIC FALCON FARMER FEATHER FENCE FIDDLE FINGER FLANNEL FLOWER FOREST FOSSIL FOUNTAIN FRECKLE FRIDAY FROSTY GALAXY
    GARDEN GARLIC GIRAFFE GLACIER GLITTER GOBLET GOLDEN GRAVEL GUITAR HAMMER HARBOR HARVEST HAZEL HELMET HERON HIGHWAY HOLIDAY HONEY HORIZON ICICLE
    ISLAND JACKET JAGUAR JIGSAW JOURNEY JUNGLE KETTLE KITCHEN KITTEN LADDER LAGOON LANTERN LAUNDRY LEMON LIBRARY LIZARD LOBSTER LOCKET LUMBER MAGNET
    MANGO MAPLE MARBLE MARKET MEADOW MELODY MIRROR MITTEN MONKEY MORNING MOUNTAIN MUFFIN MUSEUM MUSTARD NAPKIN NEEDLE NICKEL NOODLE NOTEBOOK OCEAN
    OLIVE ORANGE ORBIT ORCHARD OTTER OYSTER PADDLE PAINTER PALACE PANCAKE PARROT PEBBLE PELICAN PENCIL PEPPER PICNIC PILLOW PIRATE PLANET PLASTIC
    POCKET PONY POPCORN POTATO PRAIRIE PRETZEL PUDDLE PUMPKIN PUZZLE QUARTER QUILT RABBIT RACCOON RADIO RAINBOW RAVEN RECIPE RIBBON RIVER ROBIN
    ROCKET SADDLE SAILOR SALMON SANDAL SCARF SCHOOL SEASON SHADOW SHELTER SHOVEL SILVER SKETCH SLIPPER SNORKEL SOCCER SPARROW SPIDER SPINACH SPONGE
    SQUIRREL STABLE STAPLER STARFISH STATION SUMMER SUNSET SWEATER TABLET TEACUP THIMBLE THUNDER TICKET TIGER TIMBER TOASTER TOMATO TRACTOR TRAVEL
    TROPHY TRUMPET TULIP TUNNEL TURTLE TWILIGHT UMBRELLA VALLEY VELVET VILLAGE VIOLIN VOYAGE WAFFLE WALNUT WALRUS WEATHER WHISTLE WILLOW WINDOW
    WINTER WIZARD WOODEN YELLOW YOGURT ZEBRA ZIPPER
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}

// MARK: - Blackjack

/// One-hand-at-a-time blackjack against the dealer. Cards are ranks 1 (ace) to 13 (king) from an endless shoe.
public struct Blackjack: Equatable, Codable {
    public var chips = 100
    public var bet = 10
    public var player: [Int] = []
    public var dealer: [Int] = []
    /// True while the hand is the player's to play.
    public var playing = false
    public var stake = 10
    public var result = ""

    public init() {}

    public static func total(_ cards: [Int]) -> (value: Int, soft: Bool) {
        var sum = cards.reduce(0) { $0 + min(10, $1) }
        let soft = cards.contains(1) && sum + 10 <= 21
        if soft { sum += 10 }
        return (sum, soft)
    }
    static func name(_ card: Int) -> String {
        switch card { case 1: return "A"; case 11: return "J"; case 12: return "Q"; case 13: return "K"; default: return String(card) }
    }
    static func hand(_ cards: [Int]) -> String { cards.map(name).joined(separator: " ") }
    static func isNatural(_ cards: [Int]) -> Bool { cards.count == 2 && total(cards).value == 21 }

    public var canDouble: Bool { playing && player.count == 2 && chips >= bet * 2 }

    public mutating func deal<G: RandomNumberGenerator>(using generator: inout G) {
        if chips < bet { chips = 100 }                      // broke: a fresh stack
        stake = bet; result = ""
        player = [Int.random(in: 1...13, using: &generator), Int.random(in: 1...13, using: &generator)]
        dealer = [Int.random(in: 1...13, using: &generator), Int.random(in: 1...13, using: &generator)]
        playing = true
        if Blackjack.isNatural(player) || Blackjack.isNatural(dealer) { settle() }
    }

    public mutating func hit<G: RandomNumberGenerator>(using generator: inout G) {
        guard playing else { return }
        player.append(Int.random(in: 1...13, using: &generator))
        if Blackjack.total(player).value >= 21 { stand(using: &generator) }
    }

    public mutating func double<G: RandomNumberGenerator>(using generator: inout G) {
        guard canDouble else { return }
        stake = bet * 2
        player.append(Int.random(in: 1...13, using: &generator))
        stand(using: &generator)
    }

    public mutating func stand<G: RandomNumberGenerator>(using generator: inout G) {
        guard playing else { return }
        if Blackjack.total(player).value <= 21 {
            while Blackjack.total(dealer).value < 17 { dealer.append(Int.random(in: 1...13, using: &generator)) }
        }
        settle()
    }

    private mutating func settle() {
        playing = false
        let mine = Blackjack.total(player).value, theirs = Blackjack.total(dealer).value
        let natural = Blackjack.isNatural(player), dealerNatural = Blackjack.isNatural(dealer)
        var change = 0
        if natural && dealerNatural { result = "Both blackjack. Push." }
        else if natural { change = stake * 3 / 2; result = "Blackjack! +\(change)" }
        else if dealerNatural { change = -stake; result = "Dealer blackjack. -\(stake)" }
        else if mine > 21 { change = -stake; result = "Bust. -\(stake)" }
        else if theirs > 21 { change = stake; result = "Dealer busts. +\(stake)" }
        else if mine > theirs { change = stake; result = "You win. +\(stake)" }
        else if mine < theirs { change = -stake; result = "Dealer wins. -\(stake)" }
        else { result = "Push." }
        chips += change
    }

    public func card(screen: Screen) -> Card {
        if player.isEmpty { return Card(["Blackjack", "Chips \(chips)", "Look up: deal"]) }
        let mine = Blackjack.total(player)
        if playing {
            return Card(["Blackjack  Chips \(chips)",
                         "Dealer  \(Blackjack.name(dealer[0])) ?",
                         "You  \(Blackjack.hand(player))  = \(mine.soft ? "soft " : "")\(mine.value)",
                         canDouble ? "Turn: hit. Back: double." : "Turn: hit.",
                         "Look up: stand"].map { TextLayout.fit($0, width: screen.columns) })
        }
        return Card(["Blackjack  Chips \(chips)",
                     "Dealer  \(Blackjack.hand(dealer))  = \(Blackjack.total(dealer).value)",
                     "You  \(Blackjack.hand(player))  = \(mine.value)",
                     result,
                     "Look up: deal"].map { TextLayout.fit($0, width: screen.columns) })
    }
}

// MARK: - 20 questions

/// The wearer thinks of something; an AI asks yes/no questions and tries to guess it within twenty turns.
public struct TwentyQuestions: Equatable {
    public enum Phase: Equatable { case intro, waiting, asking, guessing, aiWon, playerWon, failed(String) }
    public enum Answer: String { case yes = "Yes.", no = "No.", unsure = "Not sure." }
    public struct Turn: Equatable { public var said: String; public var answer: Answer }

    public static let limit = 20
    public var phase: Phase = .intro
    public var turns: [Turn] = []
    /// The question or guess on screen.
    public var current = ""

    public init() {}

    public static let system = """
    You are playing 20 Questions. The player has thought of something: an object, animal, food, place, person or fictional character. \
    Ask one yes-or-no question at a time, in at most 12 words. When you are fairly confident, guess by replying exactly "GUESS: <thing>". \
    Questions and guesses both count toward a limit of 20 turns. Reply with only the question or the guess: no numbering, no commentary.
    """

    /// The conversation so far, as alternating user and assistant messages ending with the user's.
    public func messages() -> [[String: String]] {
        var list = [["role": "user", "content": "I've thought of something. Ask your first question."]]
        for (index, turn) in turns.enumerated() {
            list.append(["role": "assistant", "content": turn.said])
            var reply = turn.answer.rawValue
            if index == turns.count - 1, turns.count == TwentyQuestions.limit - 1 { reply += " This is your last turn: make your final guess." }
            list.append(["role": "user", "content": reply])
        }
        return list
    }

    public mutating func start() { self = TwentyQuestions(); phase = .waiting }

    /// Takes the AI's reply: a question, or a guess.
    public mutating func take(reply: String) {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = text.split(whereSeparator: \.isNewline).first { text = String(line) }
        guard !text.isEmpty else { phase = .failed("The AI sent nothing back."); return }
        if text.uppercased().hasPrefix("GUESS:") {
            var guess = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            while let last = guess.last, ".?!".contains(last) { guess.removeLast() }
            current = "GUESS: " + guess; phase = .guessing
        } else { current = text; phase = .asking }
    }

    /// The wearer's answer. Returns true when the AI should be asked for its next turn.
    public mutating func answer(_ answer: Answer) -> Bool {
        guard phase == .asking || phase == .guessing else { return false }
        let wasGuess = phase == .guessing
        turns.append(Turn(said: current, answer: answer))
        if wasGuess, answer == .yes { phase = .aiWon; return false }
        if turns.count >= TwentyQuestions.limit { phase = .playerWon; return false }
        phase = .waiting
        return true
    }

    public func card(screen: Screen) -> Card {
        let width = screen.columns
        switch phase {
        case .intro:
            return Card(["20 questions"] + TextLayout.wrap("Think of an object, animal, place or person. Then look up.", width: width))
        case .waiting:
            return Card(["20 questions", turns.isEmpty ? "Thinking of a question…" : "Thinking…"])
        case .asking:
            let room = max(1, screen.rows - 2)
            return Card(["Question \(turns.count + 1) of \(TwentyQuestions.limit)"] + TextLayout.wrap(current, width: width, maxLines: room)
                        + [TextLayout.fit("Fwd yes. Back no. Up unsure.", width: width)])
        case .guessing:
            let guess = String(current.dropFirst(7))
            return Card(["My guess (\(turns.count + 1) of \(TwentyQuestions.limit))"] + TextLayout.wrap("Is it " + guess + "?", width: width, maxLines: max(1, screen.rows - 2))
                        + [TextLayout.fit("Fwd yes. Back no.", width: width)])
        case .aiWon:
            return Card(["20 questions", "Got it in \(turns.count)!", "Look up: play again"])
        case .playerWon:
            return Card(["20 questions", "You win. I'm out of turns.", "Look up: play again"])
        case .failed(let why):
            return Card(["20 questions"] + TextLayout.wrap(why, width: width, maxLines: max(1, screen.rows - 2)) + ["Look up: try again"])
        }
    }
}
