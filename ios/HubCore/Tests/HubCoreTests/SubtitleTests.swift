import XCTest
@testable import HubCore

final class SubtitleTests: XCTestCase {
    private let file = """
    1
    00:00:10,000 --> 00:00:12,500
    <i>Where were you last night?</i>

    2
    00:00:13,000 --> 00:00:16,000
    - I was at the harbour.
    - Doing what exactly?

    3
    00:00:20,000 --> 00:00:23,000
    {\\an8}[door slams]
    MARTHA: Nobody leaves until we find the ledger.

    4
    00:01:40,000 --> 00:01:43,000
    I don't know what you mean.

    5
    00:05:00,000 --> 00:05:03,000
    I don't know what you want from me, detective.

    6
    00:05:04,000 --> 00:05:06,000
    Subtitles by www.example.org

    7
    00:05:10,000 --> 00:05:13,500
    The ledger was never in the harbour office.
    """

    func testReadsSrtAndVtt() {
        let cues = SubtitleFile.parse(file)
        XCTAssertEqual(cues.count, 6)                                    // the advert is dropped
        XCTAssertEqual(cues[0], SubtitleCue(start: 10, end: 12.5, text: "Where were you last night?"))
        XCTAssertEqual(cues[1].text, "- I was at the harbour.\n- Doing what exactly?")
        XCTAssertEqual(cues[2].text, "[door slams]\nMARTHA: Nobody leaves until we find the ledger.")
        let vtt = SubtitleFile.parse("WEBVTT\n\n01:05.250 --> 01:07.000 align:start\nHello there\n\n1:00:00.000 --> 1:00:02.000\nAn hour in")
        XCTAssertEqual(vtt.map(\.start), [65.25, 3600])
        XCTAssertEqual(vtt[0].text, "Hello there")
        XCTAssertEqual(SubtitleFile.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")      // not UTF-8: read as Windows text
        XCTAssertTrue(SubtitleFile.parse("not a subtitle file").isEmpty)
    }

    func testWordsAreOnlyWhatIsSpoken() {
        XCTAssertEqual(SubtitleIndex.words("[door slams]\nMARTHA: Nobody leaves, (sighs) don't you see?"), ["nobody", "leaves", "dont", "you", "see"])
        XCTAssertEqual(SubtitleIndex.words("It's 10:30. Go!"), ["its", "10", "30", "go"])
    }

    func testFindsTheLineBeingSpoken() {
        let index = SubtitleIndex(cues: SubtitleFile.parse(file))
        // nothing known yet: three runs in a row are needed
        let found = index.locate(heard: ["nobody", "leaves", "until", "we", "find"], near: nil)
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.time, 21.9, accuracy: 1.0)
        XCTAssertNil(index.locate(heard: ["i", "dont", "know"], near: nil))                // too common to trust from nowhere
        XCTAssertNil(index.locate(heard: ["completely", "different", "words", "here"], near: 20))
        // near where the film already is, one run is enough, and the nearer of two places wins
        let early = index.locate(heard: ["i", "dont", "know"], near: 99)
        XCTAssertEqual(early!.time, 100.6, accuracy: 0.6)
        let late = index.locate(heard: ["i", "dont", "know"], near: 298)
        XCTAssertEqual(late!.time, 300.5, accuracy: 0.6)
        // a misheard word in the middle doesn't stop it
        XCTAssertNotNil(index.locate(heard: ["the", "ledger", "was", "never", "in", "a", "harbour", "office"], near: nil))
    }

    func testFollowsPausesAndCatchesUp() {
        var movie = MovieTracker(cues: SubtitleFile.parse(file))
        XCTAssertNil(movie.position(at: 0))
        XCTAssertNil(movie.cue(at: 0))
        XCTAssertFalse(movie.hear("some chatter in the room", at: 1000))
        XCTAssertTrue(movie.hear("nobody leaves until we find", at: 1002))
        XCTAssertEqual(movie.state, .running)
        XCTAssertEqual(movie.position(at: 1002)!, 21.9, accuracy: 1.0)
        XCTAssertEqual(movie.cue(at: 1002)?.start, 20)
        XCTAssertNil(movie.cue(at: 1012))                                                  // between lines: nothing on screen
        XCTAssertEqual(movie.cue(at: 1081)?.start, 100)
        // the film was paused for a while, then carried on from the same line
        _ = movie.hear("I don't know what you mean", at: 1300)
        XCTAssertEqual(movie.position(at: 1300)!, 102.3, accuracy: 1.0)
        // by hand
        movie.shift(-0.5, now: 1300)
        XCTAssertEqual(movie.position(at: 1300)!, 101.8, accuracy: 1.0)
        movie.toggleHold(now: 1301)
        XCTAssertEqual(movie.state, .held)
        XCTAssertEqual(movie.position(at: 1400)!, movie.position(at: 1301)!, accuracy: 0.01)
        movie.toggleHold(now: 1400)
        XCTAssertEqual(movie.position(at: 1410)!, 112.8, accuracy: 1.0)
    }

    func testHoldsWhenTheRoomGoesQuiet() {
        var cues = [SubtitleCue]()
        for n in 0..<40 { cues.append(SubtitleCue(start: Double(n) * 4, end: Double(n) * 4 + 3, text: "line number \(n) has six words")) }
        var movie = MovieTracker(cues: cues)
        XCTAssertTrue(movie.hear("line number 3 has six words", at: 500))
        movie.tick(now: 520)
        XCTAssertEqual(movie.state, .running)
        movie.tick(now: 530)                                                               // half a minute of talk went unheard
        XCTAssertEqual(movie.state, .held)
        XCTAssertTrue(movie.hear("line number 4 has six words", at: 700))
        XCTAssertEqual(movie.state, .running)
        XCTAssertEqual(movie.position(at: 700)!, 18.5, accuracy: 1.5)
        var manual = MovieTracker(cues: cues)
        manual.holdsWhenQuiet = false
        manual.toggleHold(now: 0)                                                          // start at the first line by hand
        manual.tick(now: 120)
        XCTAssertEqual(manual.state, .running)
        let screen = Screen(size: .large)
        XCTAssertEqual(manual.card(title: "Test", listening: false, note: "", now: 5, screen: screen).lines, ["line number 1 has six words"])
        XCTAssertEqual(MovieTracker.clock(3725), "1:02:05")
    }
}
