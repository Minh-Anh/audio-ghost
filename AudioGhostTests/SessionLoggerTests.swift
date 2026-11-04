import XCTest
@testable import AudioGhost

/// The ring buffer behind every field CSV (spec §11.4).
final class SessionLoggerTests: XCTestCase {

    private func notes(_ logger: SessionLogger) -> [String] { logger.snapshot().map(\.note) }

    func testKeepsEverythingUntilFull() {
        let logger = SessionLogger(capacity: 3)
        logger.start()
        logger.event("a")
        logger.event("b")
        XCTAssertEqual(notes(logger), ["a", "b"])
    }

    func testOverwritesTheOldestAndStaysChronological() {
        let logger = SessionLogger(capacity: 3)
        logger.start()
        for note in ["a", "b", "c", "d", "e"] { logger.event(note) }
        XCTAssertEqual(notes(logger), ["c", "d", "e"])
        XCTAssertEqual(logger.count, 3)
    }

    func testRestartClearsTheBuffer() {
        let logger = SessionLogger(capacity: 2)
        logger.start()
        for note in ["a", "b", "c"] { logger.event(note) }
        logger.start()
        logger.event("fresh")
        XCTAssertEqual(notes(logger), ["fresh"])
    }

    func testIgnoresRowsWhenNotRecording() {
        let logger = SessionLogger(capacity: 2)
        logger.event("before")
        logger.start()
        logger.stop()
        logger.event("after")
        XCTAssertTrue(notes(logger).isEmpty)
    }
}
