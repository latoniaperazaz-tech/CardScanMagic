import Foundation

/// Keeps diagnostic finalization behind the existing asynchronous UI delivery.
/// It never decides which records the UI accepts, and never blocks a queue.
final class DiagnosticRecordReceipt {
    private let lock = NSLock()
    private var recorder: CaptureDiagnostics?
    private var traceRun: RecognitionTraceSession?
    private let recognitionID: String?
    private let offered: [CardRecord]

    init(_ candidate: CaptureDiagnostics?, traceRun: RecognitionTraceSession? = nil,
         recognitionID: String? = nil, offered: [CardRecord] = []) {
        self.traceRun = traceRun; self.recognitionID = recognitionID; self.offered = offered
        recorder = candidate?.beginActivity() == true ? candidate : nil
    }

    func complete(accepted: [CardRecord], rejectReasons: [UUID: String] = [:], fallbackReason: String = "notAccepted") {
        lock.lock()
        let run = recorder
        let trace = traceRun
        recorder = nil
        traceRun = nil
        lock.unlock()
        run?.formalRecords(accepted)
        if let recognitionID {
            let acceptedIDs = Set(accepted.map(\.id))
            trace?.recordUI(recognitionID: recognitionID, records: offered.map {
                ["recordID": $0.id.uuidString, "card": $0.card.code,
                 "recordAccepted": acceptedIDs.contains($0.id),
                 "recordRejectReason": acceptedIDs.contains($0.id) ? NSNull() : (rejectReasons[$0.id] ?? fallbackReason) as Any]
            })
        }
        run?.endActivity()
    }

    deinit { complete(accepted: []) }
}
