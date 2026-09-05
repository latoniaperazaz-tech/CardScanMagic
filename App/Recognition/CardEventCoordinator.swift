import CoreGraphics
import Foundation

/// Converts per-frame card detections into one record per physical-card pass.
final class CardEventCoordinator {
    private struct Vote {
        let label: CardFace
        let confidence: Float
    }

    private struct Track {
        let id = UUID()
        var box: CGRect
        var votes: [Vote]
        var lastSeen: Date
        var wasRecorded = false
    }

    private struct RecentRecord {
        let card: CardFace
        let date: Date
    }

    private var tracks: [Track] = []
    private var recentRecords: [RecentRecord] = []

    private let confirmationWindow = 3
    private let requiredMatchingVotes = 2
    private let confidenceThreshold: Float = 0.62
    private let trackTimeout: TimeInterval = 0.45
    private let duplicateGuard: TimeInterval = 0.65

    func reset() {
        tracks.removeAll()
        recentRecords.removeAll()
    }

    func process(_ detections: [CardDetection], at date: Date) -> [CardRecord] {
        recentRecords.removeAll { date.timeIntervalSince($0.date) > duplicateGuard }
        var matchedTrackIDs = Set<UUID>()

        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            if let trackIndex = bestTrack(for: detection, at: date, excluding: matchedTrackIDs) {
                tracks[trackIndex].box = detection.boundingBox
                tracks[trackIndex].votes.append(Vote(label: detection.card, confidence: detection.confidence))
                tracks[trackIndex].votes = Array(tracks[trackIndex].votes.suffix(confirmationWindow))
                tracks[trackIndex].lastSeen = date
                matchedTrackIDs.insert(tracks[trackIndex].id)
            } else {
                tracks.append(
                    Track(
                        box: detection.boundingBox,
                        votes: [Vote(label: detection.card, confidence: detection.confidence)],
                        lastSeen: date
                    )
                )
                matchedTrackIDs.insert(tracks[tracks.endIndex - 1].id)
            }
        }

        tracks.removeAll { date.timeIntervalSince($0.lastSeen) > trackTimeout }

        var records: [CardRecord] = []
        for index in tracks.indices where !tracks[index].wasRecorded {
            guard let stableCard = stableCard(in: tracks[index].votes),
                  !hasRecentlyRecorded(stableCard.card, at: date) else {
                continue
            }

            tracks[index].wasRecorded = true
            recentRecords.append(RecentRecord(card: stableCard.card, date: date))
            records.append(
                CardRecord(card: stableCard.card, confidence: stableCard.confidence, recordedAt: date)
            )
        }
        return records
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
                  date.timeIntervalSince(track.lastSeen) <= trackTimeout else {
                continue
            }

            let overlap = track.box.intersectionOverUnion(with: detection.boundingBox)
            let centerDistance = track.box.normalizedCenterDistance(to: detection.boundingBox)
            guard overlap >= 0.06 || centerDistance <= 0.18 else { continue }

            let score = overlap - (centerDistance * 0.25)
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func stableCard(in votes: [Vote]) -> (card: CardFace, confidence: Float)? {
        guard votes.count >= requiredMatchingVotes else { return nil }

        let grouped = Dictionary(grouping: votes, by: \.label)
        guard let winner = grouped.max(by: { $0.value.count < $1.value.count }),
              winner.value.count >= requiredMatchingVotes else {
            return nil
        }

        let meanConfidence = winner.value.map(\.confidence).reduce(0, +) / Float(winner.value.count)
        guard meanConfidence >= confidenceThreshold else { return nil }
        return (winner.key, meanConfidence)
    }

    private func hasRecentlyRecorded(_ card: CardFace, at date: Date) -> Bool {
        recentRecords.contains {
            $0.card == card && date.timeIntervalSince($0.date) <= duplicateGuard
        }
    }
}

private extension CGRect {
    func intersectionOverUnion(with other: CGRect) -> CGFloat {
        let intersection = self.intersection(other)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = width * height + other.width * other.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    func normalizedCenterDistance(to other: CGRect) -> CGFloat {
        let dx = midX - other.midX
        let dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
