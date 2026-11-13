import Foundation

/// A tiny lock-protected array for collecting values from `@Sendable` callbacks in tests.
final class LockedLog<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: Element? { values.last }
}
