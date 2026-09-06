import Foundation

struct FrameCandidateMetadata: Equatable {
    let timestamp: TimeInterval
    let sharpness: Double
}

/// Gives preference to a recent usable frame, rather than letting a sharper
/// background frame from earlier in the model-busy period win every time.
struct FrameCandidateWindow {
    private(set) var candidate: FrameCandidateMetadata?

    let maximumAge: TimeInterval
    let recencySharpnessRatio: Double

    init(
        // Do not keep a globally sharp table frame for too long. When a card
        // is very near the lens it naturally lowers whole-frame sharpness
        // while autofocus settles; a moderately softer *recent* frame is far
        // more useful than repeatedly analysing the old, empty tabletop. At
        // 120 fps, 55 ms still leaves several choices per model decision.
        maximumAge: TimeInterval = 0.055,
        recencySharpnessRatio: Double = 0.55
    ) {
        self.maximumAge = maximumAge
        self.recencySharpnessRatio = recencySharpnessRatio
    }

    mutating func insert(timestamp: TimeInterval, sharpness: Double) -> Bool {
        guard timestamp.isFinite, sharpness.isFinite, sharpness >= 0 else { return false }
        discardExpiredCandidate(at: timestamp)

        let incoming = FrameCandidateMetadata(timestamp: timestamp, sharpness: sharpness)
        guard let current = candidate else {
            candidate = incoming
            return true
        }

        guard timestamp >= current.timestamp else { return false }
        let isSharpEnoughToPreferRecency = sharpness >= current.sharpness * recencySharpnessRatio
        guard sharpness >= current.sharpness || isSharpEnoughToPreferRecency else { return false }

        candidate = incoming
        return true
    }

    mutating func take(at timestamp: TimeInterval) -> FrameCandidateMetadata? {
        guard timestamp.isFinite else { return nil }
        discardExpiredCandidate(at: timestamp)
        defer { candidate = nil }
        return candidate
    }

    mutating func discardExpiredCandidate(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        guard let candidate,
              timestamp - candidate.timestamp > maximumAge else {
            return
        }
        self.candidate = nil
    }

    mutating func reset() {
        candidate = nil
    }
}
