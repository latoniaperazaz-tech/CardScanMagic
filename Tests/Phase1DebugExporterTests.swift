import XCTest
@testable import CardScanMagic

final class Phase1DebugExporterTests: XCTestCase {
    func testAppBundleAllowsUsersToRetrieveDiagnosticReports() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, true)
    }

    func testWritesDecodableJSONAndReadableTextWithLatestCopies() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var summary = makeSummary(startedAt: 1000)
        summary.cameraFrames = 37
        summary.snapshotFailures = 2
        let files = try Phase1DebugExporter.write(summary, to: directory)

        let decoded = try readSummary(files.json)
        XCTAssertEqual(decoded.runID, summary.runID)
        XCTAssertEqual(decoded.sessionID, 1)
        XCTAssertEqual(decoded.startedAt, summary.startedAt)
        XCTAssertEqual(decoded.cameraFrames, 37)
        XCTAssertEqual(decoded.snapshotFailures, 2)
        XCTAssertEqual(files.json.deletingLastPathComponent().lastPathComponent, "Phase1Diagnostics")
        XCTAssertTrue(files.json.lastPathComponent.contains(summary.runID.uuidString))
        let text = try String(contentsOf: files.text, encoding: .utf8)
        XCTAssertTrue(text.contains("## TEST SESSION"))
        XCTAssertTrue(text.contains("cameraFrames = 37"))
        XCTAssertTrue(text.contains("snapshotFailures = 2"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Phase1DebugSummary.json")),
                       try Data(contentsOf: files.json))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Phase1DebugSummary.txt")),
                       try Data(contentsOf: files.text))
    }

    func testSameSessionNumberInDifferentRunsPreservesBothArchives() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeSummary(startedAt: 1000)
        let second = makeSummary(startedAt: 2000)
        let firstFiles = try Phase1DebugExporter.write(first, to: directory)
        let secondFiles = try Phase1DebugExporter.write(second, to: directory)

        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(firstFiles.json, secondFiles.json)
        XCTAssertNotEqual(firstFiles.text, secondFiles.text)
        XCTAssertEqual(try readSummary(firstFiles.json).runID, first.runID)
        XCTAssertEqual(try readSummary(secondFiles.json).runID, second.runID)
        XCTAssertTrue(try String(contentsOf: firstFiles.text, encoding: .utf8).contains(first.runID.uuidString))
        XCTAssertTrue(try String(contentsOf: secondFiles.text, encoding: .utf8).contains(second.runID.uuidString))
        XCTAssertEqual(try readSummary(directory.appendingPathComponent("Phase1DebugSummary.json")).runID, second.runID)
    }

    func testOlderRunFinishingLaterCannotReplaceLatestSummary() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var old = makeSummary(startedAt: 1000)
        old.finishedAt = Date(timeIntervalSince1970: 4000)
        let newest = makeSummary(startedAt: 2000)
        let newestFiles = try Phase1DebugExporter.write(newest, to: directory)
        let oldFiles = try Phase1DebugExporter.write(old, to: directory)

        XCTAssertEqual(try readSummary(oldFiles.json).runID, old.runID)
        XCTAssertEqual(try readSummary(newestFiles.json).runID, newest.runID)
        XCTAssertEqual(try readSummary(directory.appendingPathComponent("Phase1DebugSummary.json")).runID, newest.runID)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Phase1DebugSummary.txt")),
                       try Data(contentsOf: newestFiles.text))
    }

    private func makeSummary(startedAt: TimeInterval) -> Phase1DebugSummary {
        Phase1DebugSummary(runID: UUID(), sessionID: 1,
            startedAt: Date(timeIntervalSince1970: startedAt),
            finishedAt: Date(timeIntervalSince1970: startedAt + 10), reason: "test")
    }

    private func readSummary(_ url: URL) throws -> Phase1DebugSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Phase1DebugSummary.self, from: Data(contentsOf: url))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Phase1DebugExporterTests-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }
}
