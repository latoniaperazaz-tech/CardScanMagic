import CoreVideo
import XCTest
@testable import CardScanMagic

final class Phase1CaptureTests: XCTestCase {
    private func frame(_ id: UInt64, score: Double = 0) -> CaptureFrame<Int> {
        CaptureFrame(id: id, generation: 1, timestamp: Double(id) / 60, value: Int(id),
                     motionScore: score, informationScore: score)
    }
    func testTriggerImmediatelyRecoversSixFramesAndContinuesSameEvent() throws {
        let scheduler = EventFrameScheduler<Int>()
        scheduler.reset(generation: 1)
        for id in UInt64(1)...6 { XCTAssertNil(scheduler.ingest(frame(id), triggered: false)) }
        let initial = try XCTUnwrap(scheduler.ingest(frame(7, score: 1), triggered: true))
        XCTAssertEqual(initial.frames.map(\.id), Array(UInt64(1)...7))
        XCTAssertFalse(initial.isComplete)
        XCTAssertEqual(scheduler.take()?.id, 7, "Recognition can start at trigger, before post frames exist")
        for id in UInt64(8)...13 {
            let update = try XCTUnwrap(scheduler.ingest(frame(id), triggered: false))
            XCTAssertEqual(update.id, initial.id)
            XCTAssertEqual(update.frames.count, Int(id))
            XCTAssertEqual(update.isComplete, id == 13)
        }
    }
    func testRingOverwriteDoesNotDestroyLatchedEventAndOnlyValidFrame() throws {
        final class Payload { let valid: Bool; init(_ valid: Bool) { self.valid = valid } }
        let ring = RingFrameBuffer<Payload>(capacity: 6)
        let builder = CardEventBuilder<Payload>()
        builder.reset(generation: 1)
        func make(_ id: UInt64) -> CaptureFrame<Payload> {
            CaptureFrame(id: id, generation: 1, timestamp: Double(id), value: Payload(id == 4),
                         motionScore: 0, informationScore: 0)
        }
        for id in UInt64(1)...6 { ring.append(make(id)) }
        let event = try XCTUnwrap(builder.ingest(make(7), triggered: true,
            previousFrames: ring.history(before: 7, limit: 6)))
        weak var retained = event.frames.first { $0.id == 4 }?.value
        for id in UInt64(8)...30 { ring.append(make(id)) }
        XCTAssertNotNil(retained)
        XCTAssertEqual(event.frames.filter { $0.value.valid }.count, 1)
        XCTAssertEqual(event.frames.map(\.id), Array(UInt64(1)...7))
    }
    func testStartupMissingHistoryIsExplicitAndSessionResetDiscardsOldFrames() throws {
        let scheduler = EventFrameScheduler<Int>()
        scheduler.reset(generation: 1)
        let event = try XCTUnwrap(scheduler.ingest(frame(1), triggered: true))
        XCTAssertEqual(event.missingPreFrames, 6)
        scheduler.reset(generation: 2)
        XCTAssertNil(scheduler.ingest(frame(2), triggered: true))
        XCTAssertNil(scheduler.take(generation: 1))
        XCTAssertFalse(scheduler.hasFrames)
    }
    func testOverlappingEventsDoNotScheduleTheSameCaptureAgain() {
        let scheduler = EventFrameScheduler<Int>()
        scheduler.reset(generation: 1)
        var dispatched = Set<UInt64>()
        for id in UInt64(1)...40 {
            scheduler.ingest(frame(id, score: 1), triggered: true)
            while let selected = scheduler.take() { XCTAssertTrue(dispatched.insert(selected.id).inserted) }
        }
        XCTAssertEqual(dispatched.count, 40)
        XCTAssertEqual(scheduler.statistics.droppedEventFrames, 0)
    }
    func testCaptureContinuesDuringBlockedRecognitionAndRecoversOnlyValidFrame() throws {
        let entered = expectation(description: "recognizer blocked")
        let captured = expectation(description: "all captures return while recognition is blocked")
        let eventComplete = expectation(description: "13-frame event complete")
        let recorded = expectation(description: "sole valid frame records once")
        let release = DispatchSemaphore(value: 0)
        let card = try XCTUnwrap(CardFace.parse("10c"))
        var first = true
        let pipeline = ScanPipeline(recognizer: { buffer, _ in
            if first {
                first = false; entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return []
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let value = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self).pointee
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return value == 255 ? [CardDetection(card: card, confidence: 0.94,
                boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.6),
                hasIndependentSupport: true)] : []
        })
        defer { release.signal(); pipeline.stop() }
        pipeline.onCaptureEvent = { _, _, count, complete in
            if complete { XCTAssertEqual(count, 13); eventComplete.fulfill() }
        }
        pipeline.onRecords = { _, records in
            XCTAssertEqual(records.map(\.card), [card]); recorded.fulfill()
        }
        pipeline.start()
        let ready = expectation(description: "ready")
        pipeline.whenReady { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        let dark = try buffer(0), bright = try buffer(255)
        pipeline.submit(pixelBuffer: dark, timestamp: 100, orientation: .up)
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async {
            for index in 1...13 {
                pipeline.submit(pixelBuffer: index == 7 ? bright : dark,
                    timestamp: 100 + Double(index) / 60, orientation: .up)
            }
            captured.fulfill()
        }
        wait(for: [captured, eventComplete], timeout: 2)
        XCTAssertEqual(pipeline.captureStatistics.retainedFrames, 14)
        release.signal()
        wait(for: [recorded], timeout: 3)
    }
    private func buffer(_ value: Int32) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? value : 128,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
