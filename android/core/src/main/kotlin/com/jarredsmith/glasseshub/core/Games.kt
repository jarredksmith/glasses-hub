package com.jarredsmith.glasseshub.core

import java.time.Instant
import java.time.ZoneId
import kotlin.math.max

// MARK: - Word game

/** Guess the hidden word a letter at a time. Turn to pick a letter, select to guess it; six misses allowed. */
data class WordGame(
    val word: String,
    /** The day number this word belongs to, or null for a free-play word. */
    val day: Int? = null,
    var tried: String = "",
    var cursor: String = "E",
) {
    val misses: Int get() = tried.count { it !in word }
    val solved: Boolean get() = word.all { it in tried }
    val lost: Boolean get() = misses >= lives
    val over: Boolean get() = solved || lost
    val shown: String get() = word.map { if (it in tried) it.toString() else "_" }.joinToString(" ")
    private val untried: List<Char> get() = alphabet.filter { it !in tried }

    /** Moves the picker to the next (or previous) letter not tried yet. */
    fun move(by: Int) {
        val left = untried
        if (over || left.isEmpty()) return
        val here = cursor[0]
        val at = left.indexOf(here)
        cursor = (if (at >= 0) left[(at + by).mod(left.size)] else (left.firstOrNull { it > here } ?: left[0])).toString()
    }

    fun guess() {
        val letter = cursor.firstOrNull() ?: return
        if (over || letter in tried) return
        tried += letter
        if (!over) move(1)
    }

    fun card(streak: Int, screen: Screen): Card {
        val title = if (day == null) "Word game" else "Daily word"
        if (solved) return Card(listOf(title, TextLayout.headline(word, screen),
            "Got it with $misses miss${if (misses == 1) "" else "es"}." + (if (day != null && streak > 1) " Streak $streak." else ""), "Look up: another word"))
        if (lost) return Card(listOf(title, "It was $word", "Out of guesses.", "Look up: another word"))
        val left = untried
        val at = max(0, left.indexOf(cursor[0]))
        val before = left[(at + left.size - 1) % left.size]; val after = left[(at + 1) % left.size]
        val lines = mutableListOf(title + "  " + "o".repeat(lives - misses) + "x".repeat(misses), shown, "$before  [ $cursor ]  $after")
        val wrong = tried.filter { it !in word }
        if (wrong.isNotEmpty()) lines.add("Not in it: " + wrong.toList().joinToString(" "))
        else if (screen.rows >= 4) lines.add("Turn: letter. Look up: guess")
        return Card(lines)
    }

    fun toMap(): Map<String, Any?> = mapOf("word" to word, "day" to day, "tried" to tried, "cursor" to cursor)

    companion object {
        const val lives = 6
        private val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".toList()

        fun from(map: Map<String, Any?>): WordGame? {
            val word = map["word"].str() ?: return null
            return WordGame(word.uppercase(), map["day"].int(), map["tried"].str() ?: "", map["cursor"].str()?.take(1)?.ifEmpty { "E" } ?: "E")
        }

        /** The day number for a date, in the wearer's own time zone, so the word changes at their midnight. */
        fun day(now: Double, zone: ZoneId = ZoneId.systemDefault()): Int =
            ((now + zone.rules.getOffset(Instant.ofEpochMilli((now * 1000).toLong())).totalSeconds) / 86400).toInt()
        fun daily(day: Int): String = words[(day.toLong() * 7919 + 13).mod(words.size)]
        fun random(not: String = ""): String {
            var pick = words[(Math.random() * words.size).toInt().coerceIn(0, words.size - 1)]
            if (pick == not) pick = words[(words.indexOf(pick) + 1) % words.size]
            return pick
        }

        val words: List<String> = """
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
        SQUIRREL STABLE STAPLER STARFISH STATION SUMMER SUNSET SWEATER TABLET TEACUP THIMBLE THUNDER TICKET TIGER TIMBER TOASTER TOMATO TRACTOR TRAVEL TROPHY
        TRUMPET TULIP TUNNEL TURTLE TWILIGHT UMBRELLA VALLEY VELVET VILLAGE VIOLIN VOYAGE WAFFLE WALNUT WALRUS WEATHER WHISTLE WILLOW WINDOW WINTER WIZARD
        WOODEN YELLOW YOGURT ZEBRA ZIPPER
        """.split(' ', '\n').map { it.trim() }.filter { it.isNotEmpty() }
    }
}

// MARK: - 20 questions

/** The wearer thinks of something; an AI asks yes/no questions and tries to guess it within twenty turns. */
class TwentyQuestions {
    sealed class Phase {
        object Intro : Phase(); object Waiting : Phase(); object Asking : Phase(); object Guessing : Phase()
        object AiWon : Phase(); object PlayerWon : Phase()
        data class Failed(val why: String) : Phase()
    }
    enum class Answer(val text: String) { yes("Yes."), no("No."), unsure("Not sure.") }
    data class Turn(val said: String, val answer: Answer)

    var phase: Phase = Phase.Intro
    var turns = ArrayList<Turn>()
    /** The question or guess on screen. */
    var current = ""

    /** The conversation so far, as alternating user and assistant messages ending with the user's. */
    fun messages(): List<Map<String, String>> {
        val list = mutableListOf(mapOf("role" to "user", "content" to "I've thought of something. Ask your first question."))
        for ((index, turn) in turns.withIndex()) {
            list.add(mapOf("role" to "assistant", "content" to turn.said))
            var reply = turn.answer.text
            if (index == turns.size - 1 && turns.size == limit - 1) reply += " This is your last turn: make your final guess."
            list.add(mapOf("role" to "user", "content" to reply))
        }
        return list
    }

    fun start() { turns = ArrayList(); current = ""; phase = Phase.Waiting }

    /** Takes the AI's reply: a question, or a guess. */
    fun take(reply: String) {
        val text = reply.trim().lines().firstOrNull { it.isNotBlank() }?.trim() ?: ""
        if (text.isEmpty()) { phase = Phase.Failed("The AI sent nothing back."); return }
        if (text.uppercase().startsWith("GUESS:")) {
            current = "GUESS: " + text.substring(6).trim().trimEnd('.', '?', '!'); phase = Phase.Guessing
        } else { current = text; phase = Phase.Asking }
    }

    /** The wearer's answer. Returns true when the AI should be asked for its next turn. */
    fun answer(answer: Answer): Boolean {
        if (phase != Phase.Asking && phase != Phase.Guessing) return false
        val wasGuess = phase == Phase.Guessing
        turns.add(Turn(current, answer))
        if (wasGuess && answer == Answer.yes) { phase = Phase.AiWon; return false }
        if (turns.size >= limit) { phase = Phase.PlayerWon; return false }
        phase = Phase.Waiting
        return true
    }

    fun card(screen: Screen): Card {
        val width = screen.columns
        return when (val p = phase) {
            Phase.Intro -> Card(listOf("20 questions") + TextLayout.wrap("Think of an object, animal, place or person. Then look up.", width))
            Phase.Waiting -> Card(listOf("20 questions", if (turns.isEmpty()) "Thinking of a question…" else "Thinking…"))
            Phase.Asking -> Card(listOf("Question ${turns.size + 1} of $limit") + TextLayout.wrap(current, width, max(1, screen.rows - 2)) + TextLayout.fit("Fwd yes. Back no. Up unsure.", width))
            Phase.Guessing -> Card(listOf("My guess (${turns.size + 1} of $limit)") + TextLayout.wrap("Is it " + current.drop(7) + "?", width, max(1, screen.rows - 2)) + TextLayout.fit("Fwd yes. Back no.", width))
            Phase.AiWon -> Card(listOf("20 questions", "Got it in ${turns.size}!", "Look up: play again"))
            Phase.PlayerWon -> Card(listOf("20 questions", "You win. I'm out of turns.", "Look up: play again"))
            is Phase.Failed -> Card(listOf("20 questions") + TextLayout.wrap(p.why, width, max(1, screen.rows - 2)) + "Look up: try again")
        }
    }

    companion object {
        const val limit = 20
        const val system = "You are playing 20 Questions. The player has thought of something: an object, animal, food, place, person or fictional character. " +
            "Ask one yes-or-no question at a time, in at most 12 words. When you are fairly confident, guess by replying exactly \"GUESS: <thing>\". " +
            "Questions and guesses both count toward a limit of 20 turns. Reply with only the question or the guess: no numbering, no commentary."
    }
}
