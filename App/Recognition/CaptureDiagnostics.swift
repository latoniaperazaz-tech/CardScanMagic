import Darwin
import Foundation

/// Only bounded scalar samples are collected in capture callbacks. Formatting,
/// memory queries and printing belong to the background recognition queue.
final class CaptureDiagnostics {
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]
    private var captured = 0
    private var dropped = 0
    private var failedSnapshots = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var lastReport = ProcessInfo.processInfo.systemUptime
    private var peakResident: UInt64 = 0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(); captured = 0; dropped = 0; failedSnapshots = 0
        firstPTS = nil; lastPTS = nil; lastReport = ProcessInfo.processInfo.systemUptime
    }
    private func append(_ key: String, _ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples[key, default: []].append(seconds * 1000)
        if samples[key]!.count > 512 { samples[key]!.removeFirst() }
    }
    func capture(timestamp: Double, duration: Double, motionDuration: Double) {
        lock.lock(); defer { lock.unlock() }
        captured += 1
        if firstPTS == nil { firstPTS = timestamp }
        lastPTS = timestamp
        append("captureWorkMs", duration); append("motionMs", motionDuration)
    }
    func cameraDropped() { lock.lock(); dropped += 1; lock.unlock() }
    func snapshotFailed() { lock.lock(); failedSnapshots += 1; lock.unlock() }
    func cameraCallback(duration: Double) {
        lock.lock(); defer { lock.unlock() }; append("cameraCallbackMs", duration)
    }
    func eventCreatedOrUpdated(latency: Double) {
        lock.lock(); defer { lock.unlock() }; append("eventUpdateMs", latency)
    }
    func analysis(duration: Double, resultLatency: Double, hasResult: Bool, confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        append("analysisMs", duration)
        if hasResult { append("captureToResultMs", resultLatency) }
        if confirmed { append("captureToConfirmedMs", resultLatency) }
    }
    func summaryIfDue() -> String? {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 2 else { lock.unlock(); return nil }
        lastReport = now
        let measured = samples
        let duration = (lastPTS ?? 0) - (firstPTS ?? 0)
        let fps = duration > 0 ? Double(max(0, captured - 1)) / duration : 0
        let drops = dropped, failures = failedSnapshots
        lock.unlock()
        peakResident = max(peakResident, residentBytes())
        let quantiles = measured.keys.sorted().map { key -> String in
            let values = measured[key]!.sorted()
            let p50 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.50))]
            let p95 = values[min(values.count - 1, Int(Double(values.count - 1) * 0.95))]
            return String(format: "%@.p50=%.2f %@.p95=%.2f", key, p50, key, p95)
        }.joined(separator: " ")
        return String(format: "captureFPS=%.2f", fps)
            + " cameraDropped=\(drops) snapshotFailed=\(failures) residentPeakBytes=\(peakResident) \(quantiles)"
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
