import CoreGraphics
import Foundation

/// Converts noisy per-frame detections into one record per physical card pass.
///
/// The detector can briefly disagree while a card is moving or reflecting
/// light. A track therefore keeps a short, confidence-weighted vote history;
/// only a consensus (or an exceptionally strong single frame) is committed.
/// Tracks also carry velocity so a fast card is not split into several tracks
/// merely because its centre moved more than a fixed IoU threshold between
/// model frames.
final class CardEventCoordinator {
    private struct Vote {
        let label: CardFace
        let confidence: Float
    }

    private struct Track {
        let id: UUID
        var box: CGRect
        var velocity: CGPoint
        var votes: [Vote]
        var firstSeen: Date
        var lastSeen: Date
        var hitCount: Int
        var wasRecorded: Bool

        init(box: CGRect, vote: Vote, date: Date) {
            id = UUID()
            self.box = box
            velocity = .zero
            votes = [vote]
            firstSeen = date
            lastSeen = date
            hitCount = 1
            wasRecorded = false
        }
    }

    private struct RecentRecord {
        let card: CardFace
        let date: Date
        let box: CGRect
        let velocity: CGPoint
    }

    private var tracks: [Track] = []
    private var recentRecords: [RecentRecord] = []
    private var recordedCards = Set<CardFace>()
    private var lastTimestamp: Date?

    // These values are deliberately conservative for a moving card. They can
    // be tuned after an on-device sample, but avoid the old .88 one-frame fast
    // path that permanently stored many motion-blurred misclassifications.
    private let minimumDetectionConfidence: Float = 0.45
    private let minimumBoxArea: CGFloat = 0.001
    private let confirmationWindow = 5
    private let requiredMatchingVotes = 2
    private let confidenceThreshold: Float = 0.58
    private let fastPathConfidence: Float = 0.97
    private let trackTimeout: TimeInterval = 0.38
    private let duplicateGuard: TimeInterval = 1.20
    private let physicalDuplicateWindow: TimeInterval = 0.11
    private let maximumPredictionGap: TimeInterval = 0.35
    private let minimumMotionSpeed: CGFloat = 0.35
    private let maximumTrackSpeed: CGFloat = 8.0

    func reset() {
        tracks.removeAll()
        recentRecords.removeAll()
        recordedCards.removeAll()
        lastTimestamp = nil
    }

    func process(_ detections: [CardDetection], at date: Date) -> [CardRecord] {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return [] }

        // The camera timestamps are monotonic. Ignore a late result rather
        // than letting it move a track backwards and trigger a duplicate.
        if let lastTimestamp, date < lastTimestamp {
            return []
        }
        lastTimestamp = date

        recentRecords.removeAll {
            date.timeIntervalSince($0.date) > duplicateGuard
        }

        let validDetections = detections
            .compactMap { self.sanitizedDetection($0) }
            .sorted { $0.confidence > $1.confidence }

        var matchedTrackIDs = Set<UUID>()
        for detection in validDetections {
            if let trackIndex = bestTrack(
                for: detection,
                at: date,
                excluding: matchedTrackIDs
            ) {
                update(&tracks[trackIndex], with: detection, at: date)
                matchedTrackIDs.insert(tracks[trackIndex].id)
            } else {
                tracks.append(
                    Track(
                        box: detection.boundingBox,
                        vote: Vote(label: detection.card, confidence: detection.confidence),
                        date: date
                    )
                )
                matchedTrackIDs.insert(tracks[tracks.endIndex - 1].id)
            }
        }

        var records: [CardRecord] = []
        for index in tracks.indices where !tracks[index].wasRecorded {
            guard let stableCard = stableCard(in: tracks[index].votes),
                  !recordedCards.contains(stableCard.card),
                  !hasRecentlyRecorded(
                    stableCard.card,
                    for: tracks[index],
                    at: date,
                    includeStationarySingleFrameGuard: tracks[index].votes.count == 1
                  ) else {
                continue
            }

            tracks[index].wasRecorded = true
            recordedCards.insert(stableCard.card)
            recentRecords.append(
                RecentRecord(
                    card: stableCard.card,
                    date: date,
                    box: tracks[index].box,
                    velocity: tracks[index].velocity
                )
            )
            records.append(
                CardRecord(
                    card: stableCard.card,
                    confidence: stableCard.confidence,
                    recordedAt: date
                )
            )
        }

        // Keep a track through a short detector miss. At 30–60 effective
        // inferences/sec this covers several frames and prevents a new track
        // from being created when a card is briefly occluded by a hand.
        tracks.removeAll {
            date.timeIntervalSince($0.lastSeen) > trackTimeout
        }
        return records
    }

    private func sanitizedDetection(_ detection: CardDetection) -> CardDetection? {
        guard detection.confidence.isFinite,
              detection.confidence >= minimumDetectionConfidence else {
            return nil
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let box = detection.boundingBox.standardized
        guard box.minX.isFinite, box.minY.isFinite,
              box.maxX.isFinite, box.maxY.isFinite,
              box.width > 0, box.height > 0 else {
            return nil
        }

        let clipped = box.intersection(unitRect)
        guard !clipped.isNull,
              clipped.width > 0,
              clipped.height > 0,
              clipped.width * clipped.height >= minimumBoxArea else {
            return nil
        }

        return CardDetection(
            card: detection.card,
            confidence: detection.confidence,
            boundingBox: clipped
        )
    }

    private func update(_ track: inout Track, with detection: CardDetection, at date: Date) {
        let oldCenter = track.box.center
        let newCenter = detection.boundingBox.center
        let rawDelta = CGPoint(x: newCenter.x - oldCenter.x, y: newCenter.y - oldCenter.y)
        let elapsed = date.timeIntervalSince(track.lastSeen)
        if elapsed > 0.0005 {
            let safeElapsed = min(maximumPredictionGap, max(1.0 / 120.0, elapsed))
            let instantaneousVelocity = CGPoint(
                x: rawDelta.x / safeElapsed,
                y: rawDelta.y / safeElapsed
            ).clampedMagnitude(to: maximumTrackSpeed)

            // Exponential smoothing makes prediction useful without allowing
            // a single noisy box to fling a track across the whole frame.
            track.velocity = CGPoint(
                x: track.velocity.x * 0.65 + instantaneousVelocity.x * 0.35,
                y: track.velocity.y * 0.65 + instantaneousVelocity.y * 0.35
            ).clampedMagnitude(to: maximumTrackSpeed)
        }
        track.box = detection.boundingBox
        track.lastSeen = date
        track.hitCount += 1
        track.votes.append(Vote(label: detection.card, confidence: detection.confidence))
        track.votes = Array(track.votes.suffix(confirmationWindow))
    }

    private func bestTrack(
        for detection: CardDetection,
        at date: Date,
        excluding excludedIDs: Set<UUID>
    ) -> Int? {
        var best: (index: Int, score: CGFloat)?

        for index in tracks.indices {
            let track = tracks[index]
            // Once an event has been committed, do not let its old box absorb
            // the next card travelling through the same path. A later
            // detection of the same face is harmlessly rejected by
            // `recordedCards` and gets its own short-lived track instead.
            guard !excludedIDs.contains(track.id), !track.wasRecorded else { continue }

            let age = date.timeIntervalSince(track.lastSeen)
            guard age >= 0, age <= trackTimeout else { continue }

            let predictionAge = min(age, maximumPredictionGap)
            let predictedCenter = CGPoint(
                x: track.box.center.x + track.velocity.x * predictionAge,
                y: track.box.center.y + track.velocity.y * predictionAge
            )
            let predictedBox = track.box.offsetBy(
                dx: predictedCenter.x - track.box.center.x,
                dy: predictedCenter.y - track.box.center.y
            )
            let overlap = predictedBox.intersectionOverUnion(with: detection.boundingBox)
            let centerDistance = predictedCenter.distance(to: detection.boundingBox.center)
            let diagonal = max(0.01, track.box.diagonal)
            let speed = track.velocity.magnitude
            let distanceGate = min(
                0.52,
                max(0.14, diagonal * 0.90 + speed * predictionAge * 1.60 + 0.06)
            )
            guard overlap >= 0.02 || centerDistance <= distanceGate else { continue }

            let lastLabel = track.votes.last?.label
            let labelBonus: CGFloat = lastLabel == detection.card ? 0.16 : 0
            let trackArea = max(0.01, track.box.area)
            let detectionArea = max(0.01, detection.boundingBox.area)
            let sizeDifference = abs(trackArea - detectionArea) / max(trackArea, detectionArea)
            let score = overlap * 2.4 - centerDistance * 1.25
                - min(0.30, sizeDifference * 0.08) + labelBonus

            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func stableCard(in votes: [Vote]) -> (card: CardFace, confidence: Float)? {
        guard !votes.isEmpty else { return nil }

        struct Candidate {
            let card: CardFace
            let count: Int
            let weight: Float
            let meanConfidence: Float
        }

        let grouped = Dictionary(grouping: votes, by: \.label)
        let candidates = grouped.map { card, cardVotes in
            let weight = cardVotes.reduce(Float.zero) { partial, vote in
                partial + vote.confidence * vote.confidence
            }
            let mean = cardVotes.map(\.confidence).reduce(0, +) / Float(cardVotes.count)
            return Candidate(
                card: card,
                count: cardVotes.count,
                weight: weight,
                meanConfidence: mean
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight == rhs.weight { return lhs.count > rhs.count }
            return lhs.weight > rhs.weight
        }

        guard let winner = candidates.first,
              winner.meanConfidence >= confidenceThreshold else {
            return nil
        }

        // A single frame is only a fallback for an exceptionally confident,
        // otherwise unambiguous detection. Normal cards need two agreeing
        // observations, so a latest high-confidence wrong label cannot replace
        // an established consensus.
        if winner.count == 1 {
            guard votes.count == 1, winner.meanConfidence >= fastPathConfidence else {
                return nil
            }
            return (winner.card, winner.meanConfidence)
        }

        guard winner.count >= requiredMatchingVotes else { return nil }
        if let runner = candidates.dropFirst().first {
            // Count advantage matters when a single sharp but conflicting frame
            // is present; the weight margin prevents tied noisy votes from being
            // committed arbitrarily.
            if winner.count == runner.count {
                guard winner.weight >= runner.weight * 1.40
                        || winner.weight - runner.weight >= 0.18 else {
                    return nil
                }
            }
        }
        return (winner.card, winner.meanConfidence)
    }

    private func hasRecentlyRecorded(
        _ card: CardFace,
        for track: Track,
        at date: Date,
        includeStationarySingleFrameGuard: Bool
    ) -> Bool {
        for recent in recentRecords {
            let elapsed = date.timeIntervalSince(recent.date)
            guard elapsed >= 0 else { continue }

            // Exact-face de-duplication is the normal 52-card safeguard.
            if recent.card == card { return true }

            // If a track was split during a very short detector miss, suppress
            // a second event travelling along the same tiny path even if the
            // two transient labels disagree. The window is intentionally much
            // shorter than a normal deal interval so adjacent different cards
            // can still be recorded.
            guard elapsed <= physicalDuplicateWindow else { continue }
            let predictedCenter = CGPoint(
                x: recent.box.center.x + recent.velocity.x * elapsed,
                y: recent.box.center.y + recent.velocity.y * elapsed
            )
            let distance = predictedCenter.distance(to: track.box.center)

            // A one-frame, high-confidence candidate immediately on top of a
            // just-recorded event is more likely to be a label flicker than a
            // genuinely new card. Apply this narrow stationary guard only to
            // that risky one-frame path; confirmed two-frame cards are allowed
            // to follow closely.
            if includeStationarySingleFrameGuard,
               recent.velocity.magnitude < minimumMotionSpeed,
               distance <= 0.07 {
                return true
            }

            guard recent.velocity.magnitude >= minimumMotionSpeed,
                  track.velocity.magnitude >= minimumMotionSpeed else {
                continue
            }
            let displacement = CGPoint(
                x: track.box.center.x - recent.box.center.x,
                y: track.box.center.y - recent.box.center.y
            )
            let direction = recent.velocity
            let directionMagnitude = max(0.001, direction.magnitude)
            let forwardDistance = (displacement.x * direction.x + displacement.y * direction.y)
                / directionMagnitude
            guard forwardDistance >= -0.04 else { continue }

            let gate = max(0.06, min(0.13, recent.box.diagonal * 0.50))
            if distance <= gate { return true }
        }
        return false
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        width * height
    }

    var diagonal: CGFloat {
        (width * width + height * height).squareRoot()
    }

    func intersectionOverUnion(with other: CGRect) -> CGFloat {
        let intersection = self.intersection(other)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = area + other.area - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

private extension CGPoint {
    var magnitude: CGFloat {
        (x * x + y * y).squareRoot()
    }

    func distance(to other: CGPoint) -> CGFloat {
        CGPoint(x: x - other.x, y: y - other.y).magnitude
    }

    func clampedMagnitude(to maximum: CGFloat) -> CGPoint {
        guard maximum > 0 else { return .zero }
        let current = magnitude
        guard current > maximum else { return self }
        let scale = maximum / current
        return CGPoint(x: x * scale, y: y * scale)
    }
}
