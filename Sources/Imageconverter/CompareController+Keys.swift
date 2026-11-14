import AppKit

/// Single mode's keys: hold Space (pointer over the image) to see Before, or press B to toggle it.
extension CompareController {
    /// The monitor exists only while Single mode is shown in the preview (`active`); it is removed otherwise.
    func setKeyMonitor(active: Bool) {
        if active { installKeyMonitor() } else { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
                guard let self, flags.isEmpty,
                      let window = event.window, window === NSApp.mainWindow, window.isKeyWindow,
                      !Self.focusTakesKeys(window.firstResponder) else { return false }
                return self.handle(KeyPress(isDown: event.type == .keyDown, isRepeat: event.isARepeat,
                                            character: event.charactersIgnoringModifiers?.lowercased() ?? ""))
            }
            return used ? nil : event
        }
        // A held Space whose key-up goes to another window must not leave Before on screen.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseKeys() }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        resignObserver = nil
        releaseKeys()
    }

    private func releaseKeys() {
        spaceHeld = false
        showingBefore = false
    }

    /// Text fields and tables use letters and Space themselves (typing, type-select).
    private static func focusTakesKeys(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return responder is NSText }
        if view is NSText || view is NSTableView { return true }
        var parent = view.superview
        while let current = parent {
            if current is NSTableView { return true }
            parent = current.superview
        }
        return false
    }

    private struct KeyPress: Sendable {
        let isDown: Bool
        let isRepeat: Bool
        let character: String
    }

    /// True when the key was used.
    private func handle(_ key: KeyPress) -> Bool {
        guard mode == .single else { return false }
        switch (key.isDown, key.character) {
        case (true, " "):
            guard pointerInPreview || spaceHeld else { return false }
            if !key.isRepeat {
                spaceHeld = true
                showingBefore = true
            }
            return true
        case (false, " "):
            guard spaceHeld else { return false }
            releaseKeys()
            return true
        case (true, "b"):
            if !key.isRepeat { showingBefore.toggle() }
            return true
        default:
            return false
        }
    }
}
