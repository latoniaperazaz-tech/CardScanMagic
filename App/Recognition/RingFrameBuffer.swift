import Foundation

/// Fixed storage with O(1) append. Its owner supplies synchronization.
final class RingFrameBuffer<Value> {
    let capacity: Int
    private var storage: [CaptureFrame<Value>?]
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int = 30) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: self.capacity)
    }

    @discardableResult
    func append(_ frame: CaptureFrame<Value>) -> CaptureFrame<Value>? {
        let replaced = storage[writeIndex]
        storage[writeIndex] = frame
        writeIndex = (writeIndex + 1) % capacity
        count = min(capacity, count + 1)
        return replaced
    }

    var latest: CaptureFrame<Value>? {
        guard count > 0 else { return nil }
        return storage[(writeIndex + capacity - 1) % capacity]
    }

    /// Chronological references, including only captures preceding the ID.
    func history(before frameID: UInt64, limit: Int) -> [CaptureFrame<Value>] {
        guard limit > 0 else { return [] }
        return Array(snapshot().filter { $0.id < frameID }.suffix(limit))
    }

    func snapshot() -> [CaptureFrame<Value>] {
        let first = (writeIndex + capacity - count) % capacity
        return (0..<count).compactMap { storage[(first + $0) % capacity] }
    }

    func reset() {
        for index in storage.indices { storage[index] = nil }
        writeIndex = 0
        count = 0
    }
}
