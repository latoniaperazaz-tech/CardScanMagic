import Foundation

struct RecognitionTraceConfiguration {
    static var available: Bool {
        #if RECOGNITION_TRACE
        return true
        #else
        return false
        #endif
    }
    var enabled = false
    var testLabel = "UNLABELLED"
    var maximumQueuedBytes = 96 * 1024 * 1024
    var maximumSessionBytes = 768 * 1024 * 1024
    var maximumRecognitions = 500
    var maximumFrameMetadata = 20000
    var directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RecognitionTrace", isDirectory: true)

    static var device: RecognitionTraceConfiguration {
        var result = RecognitionTraceConfiguration()
        result.enabled = available && UserDefaults.standard.bool(forKey: "recognitionTraceEnabled")
        result.testLabel = UserDefaults.standard.string(forKey: "recognitionTraceLabel") ?? "UNLABELLED"
        return result
    }
}

enum RecognitionTraceJSON {
    static func safe(_ value: Any) -> Any {
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number : NSNull()
        }
        if let map = value as? [String: Any] { return map.mapValues(safe) }
        if let list = value as? [Any] { return list.map(safe) }
        if value is String || value is NSNull { return value }
        return String(describing: value)
    }
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: safe(value), options: [.prettyPrinted, .sortedKeys])
    }
}

