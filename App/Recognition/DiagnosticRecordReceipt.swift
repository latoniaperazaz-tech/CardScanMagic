import Foundation

/// Keeps diagnostic finalization behind the existing asynchronous UI delivery.
/// It never decides which records the UI accepts, and never blocks a queue.
final class DiagnosticRecordReceipt {
    private let lock = NSLock()
    private var recorder: CaptureDiagnostics?

    init(_ candidate: CaptureDiagnostics?) {
        recorder = candidate?.beginActivity() == true ? candidate : nil
    }

    func complete(accepted: [CardRecord]) {
        lock.lock()
        let run = recorder
        recorder = nil
        lock.unlock()
        run?.formalRecords(accepted)
        run?.endActivity()
    }

    deinit { complete(accepted: []) }
}
