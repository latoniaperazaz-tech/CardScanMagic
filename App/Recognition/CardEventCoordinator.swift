import CoreGraphics
import Foundation

struct CardEventUpdate {
    let records: [CardRecord]
    /// These are confirmed tracks, not raw per-frame model output. The UI uses
    /// them for overlays so a visible label always agrees with a card that is
    /// eligible to be written to the history.
    let stableDetections: [CardDetection]
}

/// Converts noisy detector output into one record per card pass. A label must
/// survive two geometrically plausible observations before it can be displayed
/// or recorded. This intentionally favors a missed blurred frame over a wrong
/// card in the magic routine's permanent history.
final class CardEventCoordinator {
    private struct Vote {
        let label: CardFace
        let confidence: Float
    }

    private struct Track {
        let id: UUID
        var box: CGRect
        var orientedImageSize: CGSize
        var velocity: CGPoint
        var votes: [Vote]
        var lastSeen: Date
        var hitCount: Int
        var wasRecorded: Bool

        init(detection: CardDetection, date: Date) {
            id = UUID()
            box = detection.boundingBox
            orientedImageSize = detection.orientedImageSize
            velocity = .zero
            votes = [Vote(label: detection.card, confidence: detection.confidence)]
            lastSeen = date
            hitCount = 1
            wasRecorded = false
        }
    }

    /// A just-recorded card can briefly receive a different high-confidence
    /// label while it leaves the frame. Keep a very short spatial memory so
    /// that label flicker cannot become a second card in the history.
    private struct RecentRecordedPass {
        let date: Date
        let box: CGRect
        let velocity: CGPoint
    }

    private var tracks: [Track] = []
    private var recentRecordedPasses: [RecentRecordedPass] = []
    private var recordedCards = Set<CardFace>()
    private var lastTimestamp: Date?

    // The upstream model detects the rank/suit printed in a card corner, not
    // the outline of the whole physical card. Those corner boxes are often
    // only 0.002 of the image area and can be very narrow (especially for a
    // suit symbol), so full-card geometry thresholds discard every result.
    // Keep a modest per-frame confidence gate here; the two-frame vote below
    // remains the main protection against blur and table-texture false hits.
    private let minimumDetectionConfidence: Float = 0.45
    private let minimumConfirmedConfidence: Float = 0.58
    private let minimumBoxArea: CGFloat = 0.0007
    // A close card can legitimately enter with its printed corner partly at
    // the edge of the frame. The two-frame, same-label confirmation below is
    // a much stronger false-positive guard than discarding that useful first
    // edge observation outright.
    private let minimumVisibleFraction: CGFloat = 0.20
    private let minimumShortSide: CGFloat = 0.015
    private let minimumShortSidePixels: CGFloat = 18
    private let minimumShortToLongAspect: CGFloat = 0.20
    private let confirmationWindow = 5
    private let requiredMatchingVotes = 2
    private let trackTimeout: TimeInterval = 0.38
    private let initialLinkWindow: TimeInterval = 0.09
    private let minimumOverlap: CGFloat = 0.02
    // A near card grows substantially between two 30 fps inference samples.
    // The first bridge is intentionally looser because it still requires the
    // same label plus spatial continuity before receiving its second vote.
    // Once a track exists, retain a tighter gate so neighbouring physical
    // cards are not inadvertently merged.
    // 0.92 permits roughly a 12x area jump on the first bridge. That is
    // realistic when a card moves from the normal wide-camera focus range
    // into the 14 Pro's macro range between two 30 fps model inputs.
    private let maximumInitialAreaDifference: CGFloat = 0.92
    private let maximumTrackedAreaDifference: CGFloat = 0.72
    private let maximumPredictionGap: TimeInterval = 0.35
    private let maximumTrackSpeed: CGFloat = 8.0
    private let unresolvedLabelConflictWindow: TimeInterval = 0.075
    private let recentPassGuardWindow: TimeInterval = 0.12

    func reset() {
        tracks.removeAll()
        recentRecordedPasses.removeAll()
        recordedCards.removeAll()
        lastTimestamp = nil
    }

    /// Compatibility entry point used by the unit tests and callers that only
    /// care about permanent records.
    func process(_ detections: [CardDetection], at date: Date) -> [CardRecord] {
        processUpdate(detections, at: date).records
    }

    func processUpdate(_ detections: [CardDetection], at date: Date) -> CardEventUpdate {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            return CardEventUpdate(records: [], stableDetections: [])
        }

        // Camera timestamps are monotonic. Ignore a late Vision result instead
        // of allowing it to move a track backwards and create a duplicate.
        if let lastTimestamp, date < lastTimestamp {
            return CardEventUpdate(records: [], stableDetections: [])
        }
        lastTimestamp = date

        tracks.removeAll { date.timeIntervalSince($0.lastSeen) > trackTimeout }
        recentRecordedPasses.removeAll {
            date.timeIntervalSince($0.date) > recentPassGuardWindow
        }

        let validDetections = detections
            .compactMap { sanitizedDetection($0) }
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
                tracks.append(Track(detection: detection, date: date))
                matchedTrackIDs.insert(tracks[tracks.endIndex - 1].id)
            }
        }

        var records: [CardRecord] = []
        for index in tracks.indices where !tracks[index].wasRecorded {
            guard let stableCard = stableCard(in: tracks[index].votes),
                  !recordedCards.contains(stableCard.card),
                  !hasUnresolvedLabelConflict(for: tracks[index], at: date),
                  !hasRecentPassConflict(for: tracks[index], at: date) else {
                continue
            }

            tracks[index].wasRecorded = true
            recordedCards.insert(stableCard.card)
            recentRecordedPasses.append(
                RecentRecordedPass(
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

        let stableDetections = tracks.compactMap { track -> CardDetection? in
            guard let stableCard = stableCard(in: track.votes) else { return nil }
            return CardDetection(
                card: stableCard.card,
                confidence: stableCard.confidence,
                boundingBox: track.box,
                orientedImageSize: track.orientedImageSize
            )
        }
        .sorted { $0.confidence > $1.confidence }

        // A single physical card can expose two corners at once. Since the
        // detector classifies corner snippets, that produces two stable tracks
        // with the same CardFace. Keep the strongest one for the overlay so
        // the UI shows one badge per card instead of flickering duplicates.
        var displayedCards = Set<CardFace>()
        let uniqueStableDetections = stableDetections.filter { detection in
            displayedCards.insert(detection.card).inserted
        }

        return CardEventUpdate(records: records, stableDetections: uniqueStableDetections)
    }

    private func sanitizedDetection(_ detection: CardDetection) -> CardDetection? {
        guard detection.confidence.isFinite,
              detection.confidence >= minimumDetectionConfidence else {
            return nil
        }

        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let original = detection.boundingBox.standardized
        guard original.minX.isFinite,
              original.minY.isFinite,
              original.maxX.isFinite,
              original.maxY.isFinite,
              original.width > 0,
              original.height > 0 else {
            return nil
        }

        let clipped = original.intersection(unitRect)
        guard !clipped.isNull,
              clipped.width > 0,
              clipped.height > 0,
              clipped.area >= minimumBoxArea,
              clipped.area / original.area >= minimumVisibleFraction else {
            return nil
        }

        let shortSide = min(clipped.width, clipped.height)
        let longSide = max(clipped.width, clipped.height)
        guard shortSide >= minimumShortSide,
              longSide > 0,
              shortSide / longSide >= minimumShortToLongAspect,
              min(detection.orientedImageSize.width, detection.orientedImageSize.height)
                  * shortSide >= minimumShortSidePixels else {
            return nil
        }

        guard detection.orientedImageSize.width.isFinite,
              detection.orientedImageSize.height.isFinite,
              detection.orientedImageSize.width > 0,
              detection.orientedImageSize.height > 0 else {
            return nil
        }

        return CardDetection(
            card: detection.card,
            confidence: detection.confidence,
            boundingBox: clipped,
            orientedImageSize: detection.orientedImageSize
        )
    }

    private func update(_ track: inout Track, with detection: CardDetection, at date: Date) {
        let oldCenter = track.box.center
        let newCenter = detection.boundingBox.center
        let elapsed = date.timeIntervalSince(track.lastSeen)
        if elapsed > 0.0005 {
            let safeElapsed = min(maximumPredictionGap, max(1.0 / 120.0, elapsed))
            let instantVelocity = CGPoint(
                x: (newCenter.x - oldCenter.x) / safeElapsed,
                y: (newCenter.y - oldCenter.y) / safeElapsed
            )
            .clampedMagnitude(to: maximumTrackSpeed)

            track.velocity = CGPoint(
                x: track.velocity.x * 0.60 + instantVelocity.x * 0.40,
                y: track.velocity.y * 0.60 + instantVelocity.y * 0.40
            )
            .clampedMagnitude(to: maximumTrackSpeed)
        }

        track.box = detection.boundingBox
        track.orientedImageSize = detection.orientedImageSize
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
            guard !excludedIDs.contains(track.id),
                  track.votes.last?.label == detection.card else {
                continue
            }

            let age = date.timeIntervalSince(track.lastSeen)
            guard age >= 0, age <= trackTimeout else { continue }

            let trackArea = max(0.0001, track.box.area)
            let detectionArea = max(0.0001, detection.boundingBox.area)
            let sizeDifference = abs(trackArea - detectionArea) / max(trackArea, detectionArea)
            let maximumAreaDifference = track.hitCount == 1
                ? maximumInitialAreaDifference
                : maximumTrackedAreaDifference
            guard sizeDifference <= maximumAreaDifference else { continue }

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

            let distanceGate: CGFloat
            if track.hitCount == 1 {
                // The first two model samples may be far apart during a very
                // fast pass. Only allow this wider bridge immediately after
                // the first sample, with the same label and a similar box.
                guard age <= initialLinkWindow else { continue }
                distanceGate = min(0.45, max(0.20, track.box.diagonal * 1.80 + 0.08))
            } else {
                let predictedDistance = track.box.diagonal * 0.95
                    + track.velocity.magnitude * predictionAge * 1.20 + 0.045
                distanceGate = min(0.42, max(0.18, predictedDistance))
            }

            guard overlap >= minimumOverlap || centerDistance <= distanceGate else { continue }

            let score = overlap * 2.5 - centerDistance * 1.10 - sizeDifference * 0.25
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }

        return best?.index
    }

    private func stableCard(in votes: [Vote]) -> (card: CardFace, confidence: Float)? {
        guard votes.count >= requiredMatchingVotes else { return nil }

        let grouped = Dictionary(grouping: votes, by: \.label)
        let candidates = grouped
            .map { card, cardVotes -> (card: CardFace, votes: [Vote]) in
                (card, cardVotes)
            }
            .sorted {
                if $0.votes.count != $1.votes.count {
                    return $0.votes.count > $1.votes.count
                }
                let lhsConfidence = $0.votes.reduce(Float.zero) { $0 + $1.confidence }
                let rhsConfidence = $1.votes.reduce(Float.zero) { $0 + $1.confidence }
                return lhsConfidence > rhsConfidence
            }

        guard let winner = candidates.first,
              winner.votes.count >= requiredMatchingVotes else {
            return nil
        }

        // Never choose arbitrarily when the recent window is split evenly
        // between two labels. A tie is a common symptom of motion blur or a
        // card edge crossing another card; waiting for one more agreeing frame
        // is safer than putting a wrong face in the magic history.
        if let runner = candidates.dropFirst().first,
           winner.votes.count <= runner.votes.count {
            return nil
        }

        let confidence = winner.votes.map(\.confidence).reduce(0, +) / Float(winner.votes.count)
        guard confidence >= minimumConfirmedConfidence else { return nil }
        return (winner.card, confidence)
    }

    /// When two labels both become stable in the same tiny region at the same
    /// instant, neither is reliable enough to add to a permanent magic-deal
    /// history. A real next card normally arrives after the previous one has
    /// left the frame, so its older conflicting track is already stale.
    private func hasUnresolvedLabelConflict(for track: Track, at date: Date) -> Bool {
        guard let stableTrackCard = stableCard(in: track.votes)?.card else {
            return false
        }

        return tracks.contains { other in
            guard other.id != track.id,
                  !other.wasRecorded,
                  let stableOtherCard = stableCard(in: other.votes)?.card,
                  stableOtherCard != stableTrackCard,
                  date.timeIntervalSince(other.lastSeen) <= unresolvedLabelConflictWindow else {
                return false
            }
            return describesSamePass(
                box: track.box,
                velocity: track.velocity,
                at: date,
                otherBox: other.box,
                otherVelocity: other.velocity,
                otherDate: other.lastSeen
            )
        }
    }

    private func hasRecentPassConflict(for track: Track, at date: Date) -> Bool {
        recentRecordedPasses.contains { recent in
            let elapsed = date.timeIntervalSince(recent.date)
            guard elapsed >= 0, elapsed <= recentPassGuardWindow else { return false }
            return describesSamePass(
                box: track.box,
                velocity: track.velocity,
                at: date,
                otherBox: recent.box,
                otherVelocity: recent.velocity,
                otherDate: recent.date
            )
        }
    }

    private func describesSamePass(
        box: CGRect,
        velocity: CGPoint,
        at date: Date,
        otherBox: CGRect,
        otherVelocity: CGPoint,
        otherDate: Date
    ) -> Bool {
        let elapsed = max(0, min(maximumPredictionGap, date.timeIntervalSince(otherDate)))
        let predictedOtherCenter = CGPoint(
            x: otherBox.center.x + otherVelocity.x * elapsed,
            y: otherBox.center.y + otherVelocity.y * elapsed
        )
        let predictedOtherBox = otherBox.offsetBy(
            dx: predictedOtherCenter.x - otherBox.center.x,
            dy: predictedOtherCenter.y - otherBox.center.y
        )
        let overlap = box.intersectionOverUnion(with: predictedOtherBox)
        let distance = box.center.distance(to: predictedOtherCenter)
        let distanceGate = min(
            0.12,
            max(0.045, min(box.diagonal, otherBox.diagonal) * 0.45
                + velocity.magnitude * elapsed * 0.25)
        )
        return overlap >= 0.34 || distance <= distanceGate
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
