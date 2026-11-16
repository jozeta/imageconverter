import CoreGraphics
import Foundation
@testable import ImageconverterCore

/// A generator with a fixed availability and answer; records every image it is asked about. Never a real model.
final class FakeAltTextGenerator: AltTextGenerator, @unchecked Sendable {
    enum Behaviour {
        case answer(String)
        case fail(Error)
        case hang(seconds: Double)
    }

    let availability: AltTextAvailability
    private let behaviour: Behaviour
    private let lock = NSLock()
    private var images: [CGImage] = []

    /// Blocks the model call's thread this long before answering (a slow model).
    private let delay: TimeInterval

    init(_ behaviour: Behaviour = .answer("A red square on a white table."), availability: AltTextAvailability = .available,
         delay: TimeInterval = 0) {
        self.behaviour = behaviour
        self.availability = availability
        self.delay = delay
    }

    var recorded: [CGImage] { lock.withLock { images } }

    func generate(for image: CGImage) async throws -> String {
        lock.withLock { images.append(image) }
        if delay > 0 { usleep(UInt32(delay * 1_000_000)) }   // blocks its thread, like a busy model
        switch behaviour {
        case .answer(let text):
            // An actor hop and a sleep, like a real async model call.
            await Hop.shared.touch()
            try await Task.sleep(nanoseconds: 2_000_000)
            return text
        case .fail(let error): throw error
        case .hang(let seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "too late"
        }
    }
}

/// The most callers inside at once.
final class ActiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var most = 0
    func enter() { lock.withLock { now += 1; most = max(most, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var peak: Int { lock.withLock { most } }
}

actor Hop {
    static let shared = Hop()
    private var count = 0
    func touch() { count += 1 }
}
