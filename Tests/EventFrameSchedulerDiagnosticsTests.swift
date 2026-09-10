import XCTest
@testable import CardScanMagic

final class EventFrameSchedulerDiagnosticsTests: XCTestCase {
    func testRingOverwriteCountsAcceptedFramesOnlyAndResetsPerGeneration() {
        let scheduler = EventFrameScheduler<Int>(ringCapacity: 3)
        scheduler.reset(generation: 1)
        for id in UInt64(1)...5 { scheduler.ingest(frame(id), triggered: false) }
        XCTAssertEqual(scheduler.statistics.retainedFrames, 3)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 2)

        scheduler.ingest(frame(6, generation: 2), triggered: false)
        scheduler.ingest(frame(5), triggered: false)
        scheduler.ingest(frame(6, timestamp: 4), triggered: false)
        XCTAssertEqual(scheduler.statistics.rejectedFrames, 3)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 2)
        XCTAssertEqual(scheduler.take()?.id, 5, "Diagnostic counting does not replace the valid baseline")

        let previous = scheduler.reset(generation: 2)
        XCTAssertEqual(previous.generation, 1)
        XCTAssertEqual(previous.ringOverwrites, 2)
        XCTAssertEqual(previous.rejectedFrames, 3)
        XCTAssertEqual(previous.dispatchedFrames, 1)
        XCTAssertEqual(scheduler.statistics.generation, 2)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 0)
        XCTAssertEqual(scheduler.statistics.rejectedFrames, 0)
        XCTAssertEqual(scheduler.statistics.retainedFrames, 0)
        scheduler.ingest(frame(6, generation: 2), triggered: false)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 0)
        XCTAssertEqual(scheduler.statistics.retainedFrames, 1)
    }

    func testPendingOverflowCountsEvictedFramesNotCaptureWindows() {
        let scheduler = EventFrameScheduler<Int>(ringCapacity: 6, preFrameCount: 6,
            postFrameCount: 0, maximumEventFrames: 7, maximumPendingEventFrames: 2)
        scheduler.reset(generation: 1)
        for id in UInt64(1)...6 { scheduler.ingest(frame(id), triggered: false) }
        let event = scheduler.ingest(frame(7), triggered: true)

        XCTAssertEqual(event?.frames.map(\.id), Array(UInt64(1)...7), "Evictions do not mutate the capture window")
        XCTAssertEqual(scheduler.statistics.triggeredEvents, 1)
        XCTAssertEqual(scheduler.statistics.completedEvents, 1)
        XCTAssertEqual(scheduler.statistics.droppedEventFrames, 5)
        XCTAssertEqual(scheduler.statistics.pendingEventFrames, 2)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 1)
        XCTAssertEqual(scheduler.take()?.id, 7)
        XCTAssertEqual(scheduler.take()?.id, 6)
        XCTAssertNil(scheduler.take())

        scheduler.reset(generation: 2)
        XCTAssertEqual(scheduler.statistics.droppedEventFrames, 0)
        XCTAssertEqual(scheduler.statistics.triggeredEvents, 0)
        XCTAssertEqual(scheduler.statistics.ringOverwrites, 0)
    }

    private func frame(_ id: UInt64, generation: UInt64 = 1,
                       timestamp: TimeInterval? = nil) -> CaptureFrame<Int> {
        CaptureFrame(id: id, generation: generation, timestamp: timestamp ?? Double(id),
                     value: Int(id), motionScore: 0, informationScore: Double(id))
    }
}
