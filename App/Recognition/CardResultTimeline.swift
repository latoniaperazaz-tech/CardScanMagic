import CoreGraphics
import Foundation

/// Reorders completed *whole-frame detections*, not partial rank/suit evidence.
/// Selecting informative historical frames must not manufacture capture times or
/// let the legacy coordinator silently discard a late-arriving valid capture.
/// Only this background-queue owner publishes physical-pass decisions.
final class CardResultTimeline {
    private struct Result {
        let frameID: UInt64
        let timestamp: TimeInterval
        let detections: [CardDetection]
    }
    private struct PublishedPass {
        var observations: [TimeInterval: CGRect]
        var lastSeen: TimeInterval
    }
    private let capacity: Int
    private var results: [Result] = []
    private var checkpoint = CardEventCoordinator()
    private var checkpointTimestamp = -Double.infinity
    private var publishedPasses: [UUID: PublishedPass] = [:]
    private var recordedFaces = Set<CardFace>()
    private(set) var rejectedOldResults = 0

    init(capacity: Int = 180) { self.capacity = max(13, capacity) }

    func reset() {
        results.removeAll(keepingCapacity: true)
        checkpoint.reset()
        checkpointTimestamp = -Double.infinity
        publishedPasses.removeAll()
        recordedFaces.removeAll()
        rejectedOldResults = 0
    }

    func insert(frameID: UInt64, timestamp: TimeInterval,
                detections: [CardDetection]) -> CardEventUpdate {
        guard timestamp.isFinite, timestamp > checkpointTimestamp else {
            rejectedOldResults += 1
            return CardEventUpdate(records: [], stableDetections: [])
        }
        guard !results.contains(where: { $0.frameID == frameID || $0.timestamp == timestamp }) else {
            return CardEventUpdate(records: [], stableDetections: [])
        }
        results.append(Result(frameID: frameID, timestamp: timestamp, detections: detections))
        results.sort { $0.timestamp < $1.timestamp }
        let replay = checkpoint.copy()
        var decisions: [CardPassDecision] = []
        var stable: [CardDetection] = []
        for result in results {
            let update = replay.processUpdate(result.detections,
                at: Date(timeIntervalSinceReferenceDate: result.timestamp))
            decisions.append(contentsOf: update.decisions)
            stable = update.stableDetections
        }
        let footprints = replay.trackObservationBoxes
        var delivered: [CardPassDecision] = []
        var records: [CardRecord] = []
        for decision in decisions {
            let observations = footprints[decision.eventID] ?? [:]
            let lastSeen = observations.keys.max() ?? decision.record.recordedAt.timeIntervalSinceReferenceDate
            let existingID = publishedPasses[decision.eventID] != nil ? decision.eventID
                : publishedPasses.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
                    sharesObservation(publishedPasses[$0]!.observations, observations)
                }
            if let existingID {
                publishedPasses[existingID]?.observations.merge(observations) { _, new in new }
                publishedPasses[existingID]?.lastSeen = lastSeen
                continue
            }
            publishedPasses[decision.eventID] = PublishedPass(observations: observations, lastSeen: lastSeen)
            let duplicate = !recordedFaces.insert(decision.record.card).inserted
            let published = CardPassDecision(eventID: decision.eventID, record: decision.record,
                captureTimestamps: Set(observations.keys), duplicateCard: duplicate)
            delivered.append(published)
            if !duplicate { records.append(decision.record) }
        }
        // Fold only the oldest contiguous observations into an immutable base.
        // Future frames older than that base are explicitly rejected and counted.
        while results.count > capacity {
            let oldest = results.removeFirst()
            _ = checkpoint.processUpdate(oldest.detections,
                at: Date(timeIntervalSinceReferenceDate: oldest.timestamp))
            checkpointTimestamp = oldest.timestamp
        }
        publishedPasses = publishedPasses.filter { $0.value.lastSeen >= checkpointTimestamp - 0.4 }
        return CardEventUpdate(records: records, stableDetections: stable, decisions: delivered)
    }

    private func sharesObservation(_ lhs: [TimeInterval: CGRect], _ rhs: [TimeInterval: CGRect]) -> Bool {
        for (timestamp, box) in rhs {
            guard let other = lhs[timestamp] else { continue }
            let overlap = box.intersection(other)
            let union = box.width * box.height + other.width * other.height
                - max(0, overlap.width) * max(0, overlap.height)
            if !overlap.isNull, union > 0,
               overlap.width * overlap.height / union >= 0.6 { return true }
        }
        return false
    }
}
