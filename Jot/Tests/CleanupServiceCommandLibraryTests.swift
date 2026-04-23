import XCTest
@testable import Jot

final class CleanupServiceCommandLibraryTests: XCTestCase {
    func testOutwardActionUtteranceStaysFresh() {
        assertFresh("add 2 pencils to my shopping list")
    }

    func testMakePrefixMatchesCommand() {
        assertCommand("make it friendlier", starter: "make")
    }

    func testChangePrefixMatchesCommand() {
        assertCommand("change that to formal", starter: "change")
    }

    func testLeadingFluffIsStrippedBeforeMatching() {
        assertCommand("please make it shorter", starter: "make")
    }

    func testMultiWordLeadingFluffIsStrippedBeforeMatching() {
        assertCommand("could you translate this to French", starter: "translate")
    }

    func testSendUtteranceStaysFresh() {
        assertFresh("send an email to Tejas")
    }

    func testBringUtteranceStaysFresh() {
        assertFresh("bring me two bottles of water")
    }

    func testBareStarterWordMatchesCommand() {
        assertCommand("shorten", starter: "shorten")
    }

    func testStarterWordWithTailMatchesCommand() {
        assertCommand("shorten that", starter: "shorten")
    }

    func testAdjectiveVariantDoesNotMatchCommandLibrary() {
        assertFresh("shorter please")
    }

    func testLeadingPunctuationAndMultipleFluffWordsAreRemoved() {
        XCTAssertEqual(
            CleanupService.normalizeCommandCandidate("... uh, please rewrite that as bullets"),
            "rewrite that as bullets"
        )
    }

    private func assertCommand(_ utterance: String, starter: String, file: StaticString = #filePath, line: UInt = #line) {
        let normalized = CleanupService.normalizeCommandCandidate(utterance)
        XCTAssertEqual(
            CleanupService.commandStarter(in: normalized),
            starter,
            file: file,
            line: line
        )
    }

    private func assertFresh(_ utterance: String, file: StaticString = #filePath, line: UInt = #line) {
        let normalized = CleanupService.normalizeCommandCandidate(utterance)
        XCTAssertNil(
            CleanupService.commandStarter(in: normalized),
            file: file,
            line: line
        )
    }
}
