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

    var help: String {
        switch self {
        case .sideBySide: "Before and After next to each other"
        case .split: "One image: Before left of the divider, After right of it; drag the divider"
        case .difference: "The encoding's difference from the original, amplified"
        case .single: "After only; hold Space over the image or press B to see Before"
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
    /// The difference of `region` only (a crop, or the whole image scaled down at fit).
    let image: CGImage?
    let stats: ImageDifference.Stats?
    /// The full image's pixel size and the unit region `image` covers, so it is drawn in the right place.
    let fullSize: CGSize
    let region: CGRect
    /// True when `image` has fewer pixels than the region (figures are for the scaled-down pair).
    let scaled: Bool
    let unavailable: String?

    static func unavailable(_ item: URL, _ reason: String) -> DifferenceOutcome {
        DifferenceOutcome(item: item, image: nil, stats: nil, fullSize: .zero, region: QualityLadder.unitRegion,
                          scaled: false, unavailable: reason)
    }
}

/// The quality ladder of the selected item (empty while rendering or for formats without quality).
struct LadderOutcome {
    let item: URL
    /// Each rung keeps its encoded bytes and a crop of `region` only.
    var rungs: [QualityLadder.Rung]
    var region: CGRect
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
    /// Where the split divider sits, as a fraction of the image box's width; saved by `commitSplit()` (drag end,
    /// key presses), not on every drag event.
    var splitPosition: CGFloat
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
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored var resignObserver: NSObjectProtocol?
    @ObservationIgnored var spaceHeld = false
    /// Space only means "show Before" while the pointer is over the image, so it still presses a focused
    /// button or toggle elsewhere in the window. B works anywhere.
    @ObservationIgnored var pointerInPreview = false
    /// The batch's files, kept by the list view so per-row checks don't scan the whole batch.
    @ObservationIgnored var activeSources: Set<URL> = []

    static let modeKey = ViewDefaults.compareModeKey
    static let splitKey = "compareSplitPosition"
    static let browserKey = "batchBrowserMode"
    static let browserHeightKey = "batchBrowserHeight"
    static let browserHeights: ClosedRange<CGFloat> = 90...420
    static let splitRange: ClosedRange<CGFloat> = 0.02...0.98

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Split once for everyone on the first launch of round 3's version (Johan), then the user's choice; no saved
        // choice (the setting removed): Split too.
        ViewDefaults.applySplitDefaultOnce(in: defaults)
        mode = ViewDefaults.startingCompareMode(in: defaults, as: CompareMode.self) ?? .split
        let split = defaults.object(forKey: Self.splitKey) as? Double ?? 0.5
        splitPosition = min(max(CGFloat(split), Self.splitRange.lowerBound), Self.splitRange.upperBound)
        browserMode = defaults.string(forKey: Self.browserKey).flatMap(BrowserMode.init(rawValue:)) ?? .filmstrip
        let height = defaults.object(forKey: Self.browserHeightKey) as? Double ?? 180
        browserHeight = min(max(CGFloat(height), Self.browserHeights.lowerBound), Self.browserHeights.upperBound)
    }

    func moveSplit(by delta: CGFloat) {
        setSplit(splitPosition + delta)
        commitSplit()
    }

    func setSplit(_ value: CGFloat) {
        splitPosition = min(max(value, Self.splitRange.lowerBound), Self.splitRange.upperBound)
    }

    func commitSplit() { defaults.set(Double(splitPosition), forKey: Self.splitKey) }

    /// The list view's current batch: remembered for quick lookups, and facts of removed files are dropped.
    func setActiveSources(_ sources: Set<URL>) {
        activeSources = sources
        if summaries.keys.contains(where: { !sources.contains($0) }) {
            summaries = summaries.filter { sources.contains($0.key) }
        }
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
}
