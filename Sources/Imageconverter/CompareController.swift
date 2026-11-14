import AppKit
import Observation
import ImageconverterCore

/// How the preview shows before and after.
enum CompareMode: String, CaseIterable, Identifiable {
    case sideBySide, split, difference, single
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: "Side by side"
        case .split: "Split"
        case .difference: "Difference"
        case .single: "Single"
        }
    }

    /// The View menu shortcut digit (⌘1…⌘4).
    var shortcut: Character {
        switch self {
        case .sideBySide: "1"
        case .split: "2"
        case .difference: "3"
        case .single: "4"
        }
    }
}

/// How the batch is shown below the preview.
enum BrowserMode: String, CaseIterable, Identifiable {
    case filmstrip, grid, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filmstrip: "Filmstrip"
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

/// The amplified difference of the selected item, or why there is none.
struct DifferenceOutcome {
    let item: URL
    let image: CGImage?
    let stats: ImageDifference.Stats?
    let unavailable: String?
}

/// The quality ladder of the selected item (empty while rendering or for formats without quality).
struct LadderOutcome {
    let item: URL
    let rungs: [QualityLadder.Rung]
    /// The source file's size, for the saving percentages.
    let originalBytes: Int?
    let failure: String?
}

/// Dimensions and file size of one batch item, read lazily for the list view.
struct ItemSummary {
    let width: Int?
    let height: Int?
    let bytes: Int?
}

/// The comparison mode, the batch browser's mode and the per-selection renders for the comparison.
/// Kept on the model so the View menu and the key monitor can reach it; modes are persisted.
@MainActor @Observable
final class CompareController {
    var mode: CompareMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            showingBefore = false
            if mode != .difference { difference = nil }
        }
    }
    /// Where the split divider sits, as a fraction of the image box's width.
    var splitPosition: CGFloat {
        didSet { defaults.set(Double(splitPosition), forKey: Self.splitKey) }
    }
    var browserMode: BrowserMode {
        didSet { defaults.set(browserMode.rawValue, forKey: Self.browserKey) }
    }
    /// The grid and list area's height in points.
    var browserHeight: CGFloat {
        didSet { defaults.set(Double(browserHeight), forKey: Self.browserHeightKey) }
    }
    /// Single mode: Before is shown instead of After (Space held or B toggled).
    var showingBefore = false
    /// The Compare quality panel is open.
    var showsQuality = false {
        didSet { if !showsQuality { ladder = nil } }
    }
    /// Only for the selected item; dropped when the selection or the inputs change.
    var difference: DifferenceOutcome?
    var ladder: LadderOutcome?
    /// List view facts per file; cleared with the batch.
    var summaries: [URL: ItemSummary] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var spaceHeld = false
    /// Space only means "show Before" while the pointer is over the image, so it still presses a focused
    /// button or toggle elsewhere in the window. B works anywhere.
    @ObservationIgnored var pointerInPreview = false

    static let modeKey = "compareMode"
    static let splitKey = "compareSplitPosition"
    static let browserKey = "batchBrowserMode"
    static let browserHeightKey = "batchBrowserHeight"
    static let browserHeights: ClosedRange<CGFloat> = 90...420
    static let splitRange: ClosedRange<CGFloat> = 0.02...0.98

    init(defaults: UserDefaults) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(CompareMode.init(rawValue:)) ?? .sideBySide
        let split = defaults.object(forKey: Self.splitKey) as? Double ?? 0.5
        splitPosition = min(max(CGFloat(split), Self.splitRange.lowerBound), Self.splitRange.upperBound)
        browserMode = defaults.string(forKey: Self.browserKey).flatMap(BrowserMode.init(rawValue:)) ?? .filmstrip
        let height = defaults.object(forKey: Self.browserHeightKey) as? Double ?? 180
        browserHeight = min(max(CGFloat(height), Self.browserHeights.lowerBound), Self.browserHeights.upperBound)
    }

    func moveSplit(by delta: CGFloat) {
        splitPosition = min(max(splitPosition + delta, Self.splitRange.lowerBound), Self.splitRange.upperBound)
    }

    func resizeBrowser(by delta: CGFloat) {
        browserHeight = min(max(browserHeight + delta, Self.browserHeights.lowerBound), Self.browserHeights.upperBound)
    }

    /// Selection change: per-item renders go, so only the selected item's large images are ever kept.
    func selectionChanged() {
        difference = nil
        ladder = nil
        showingBefore = false
    }

    func clear() {
        selectionChanged()
        summaries = [:]
    }

    /// Single mode: hold Space (pointer over the image) to see Before, or press B to toggle it. Only in the
    /// main window and not while a text field is being edited; other keys pass through.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
            guard let self, flags.isEmpty,
                  let window = event.window, window === NSApp.mainWindow, window.isKeyWindow,
                  !(window.firstResponder is NSText) else { return event }
            let key = KeyPress(isDown: event.type == .keyDown, isRepeat: event.isARepeat,
                               character: event.charactersIgnoringModifiers?.lowercased() ?? "")
            return MainActor.assumeIsolated { self.handle(key) } ? nil : event
        }
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
            spaceHeld = false
            showingBefore = false
            return true
        case (true, "b"):
            if !key.isRepeat { showingBefore.toggle() }
            return true
        default:
            return false
        }
    }
}
