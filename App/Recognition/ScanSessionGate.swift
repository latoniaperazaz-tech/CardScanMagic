import Foundation

/// Protects the active scan from work that finishes after a pause, clear, or
/// restart. A single inference stays in flight globally so a new session does
/// not build a backlog behind an older Core ML request.
final class ScanSessionGate {
    typealias SessionID = UInt64

    private let lock = NSLock()
    private var currentSessionID: SessionID = 0
    private var isRunning = false
    private var isCoordinatorReady = false
    private var inferenceInFlight = false

    func start() -> SessionID {
        lock.lock()
        defer { lock.unlock() }

        advanceSession()
        isRunning = true
        isCoordinatorReady = false
        return currentSessionID
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        advanceSession()
        isRunning = false
        isCoordinatorReady = false
    }

    /// Clearing keeps the camera running but starts a fresh recognition
    /// session, so an old in-flight result cannot restore a cleared record.
    func resetRecordedState() -> SessionID? {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return nil }
        advanceSession()
        isCoordinatorReady = false
        return currentSessionID
    }

    func activeSessionForSampling() -> SessionID? {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning, isCoordinatorReady else { return nil }
        return currentSessionID
    }

    func canStartInference(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return isRunning && isCoordinatorReady && currentSessionID == sessionID && !inferenceInFlight
    }

    func beginInference(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning,
              isCoordinatorReady,
              currentSessionID == sessionID,
              !inferenceInFlight else {
            return false
        }
        inferenceInFlight = true
        return true
    }

    func finishInference() {
        lock.lock()
        inferenceInFlight = false
        lock.unlock()
    }

    func shouldDeliver(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return isRunning && isCoordinatorReady && currentSessionID == sessionID
    }

    func shouldResetCoordinator(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return isRunning && currentSessionID == sessionID
    }

    func markCoordinatorReady(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning, currentSessionID == sessionID else { return false }
        isCoordinatorReady = true
        return true
    }

    /// Returns false when the failure belongs to a superseded session.
    func failCurrentSession(for sessionID: SessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning, currentSessionID == sessionID else { return false }
        isRunning = false
        isCoordinatorReady = false
        return true
    }

    private func advanceSession() {
        currentSessionID &+= 1
    }
}
