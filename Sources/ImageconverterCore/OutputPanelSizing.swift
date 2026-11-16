import CoreGraphics
import Foundation

/// The Output panel's grab handle (pure maths; the app's `OutputPanel` applies it). A click collapses the panel to
/// one summary line or expands it again; a drag sets its height between that collapsed height and its full
/// content (the content scrolls inside a shorter panel), and the pipeline steps above give way.
public enum OutputPanelSizing {
    /// How the panel is shown: collapsed to its summary line, or open at `height` (nil: its full content).
    public struct State: Equatable, Sendable {
        public var collapsed: Bool
        public var height: CGFloat?

        public init(collapsed: Bool, height: CGFloat?) {
            self.collapsed = collapsed
            self.height = height
        }
    }

    /// Within this distance of the full height a drag or key press settles there.
    public static let snap: CGFloat = 6
    /// Within this distance of the collapsed line it collapses (so no sliver of the open panel is left).
    public static let collapseSnap: CGFloat = 20
    /// What an arrow key moves the panel's top edge by.
    public static let keyStep: CGFloat = 24
    /// A stored height above this is ignored (a hand-edited setting).
    static let maxStoredHeight: CGFloat = 4000

    /// The height while dragging: the start height plus how far the pointer moved up (a negative translation),
    /// clamped to collapsed…full.
    public static func dragged(from start: CGFloat, translation: CGFloat, collapsed: CGFloat, full: CGFloat) -> CGFloat {
        clamp(start - translation, collapsed: collapsed, full: full)
    }

    /// Where a drag ends: collapsed within `collapseSnap` of the line, full within `snap` of the top, otherwise that
    /// height.
    public static func settled(_ height: CGFloat, collapsed: CGFloat, full: CGFloat) -> State {
        let value = clamp(height, collapsed: collapsed, full: full)
        if value <= collapsed + collapseSnap { return State(collapsed: true, height: nil) }
        if value >= full - snap { return State(collapsed: false, height: nil) }
        return State(collapsed: false, height: value)
    }

    /// An arrow key on the focused handle: `direction` 1 makes the panel taller, -1 shorter.
    public static func stepped(from current: CGFloat, by direction: Int, collapsed: CGFloat, full: CGFloat) -> State {
        settled(current + CGFloat(direction.signum()) * keyStep, collapsed: collapsed, full: full)
    }

    /// The fixed height the open panel gets, or nil for its natural height (collapsed, full, or a stored height
    /// the content no longer reaches).
    public static func shownHeight(_ state: State, collapsed: CGFloat, full: CGFloat) -> CGFloat? {
        guard !state.collapsed, let height = state.height, height < full - 0.5 else { return nil }
        return clamp(height, collapsed: collapsed, full: full)
    }

    /// The tallest the open panel grows by itself (several output panels): this share of the screen's usable height,
    /// at least `minOpenCap`; taller content scrolls inside it, so the window never outgrows the screen.
    public static let screenShare: CGFloat = 0.6
    public static let minOpenCap: CGFloat = 240

    public static func maxOpenHeight(screenHeight: CGFloat) -> CGFloat {
        guard screenHeight.isFinite, screenHeight > 0 else { return .infinity }
        return max(minOpenCap, (screenHeight * screenShare).rounded())
    }

    /// The height the content can be shown at: all of it, or the cap when it is taller.
    public static func reachable(full: CGFloat, cap: CGFloat) -> CGFloat {
        min(full, cap)
    }

    /// A stored height, if it is a usable one.
    public static func storedHeight(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite, value > 0, value <= Double(maxStoredHeight) else { return nil }
        return CGFloat(value)
    }

    private static func clamp(_ value: CGFloat, collapsed: CGFloat, full: CGFloat) -> CGFloat {
        min(max(value, collapsed), max(full, collapsed))
    }
}

/// The collapsed Output panel's one line: format · quality · where the files go.
public enum OutputSummary {
    public static func line(_ output: OutputSettings, saveTo: OutputModeKind, folderName: String?, suffix: String,
                            extraOutputs: Int = 0) -> String {
        var parts = [output.format.displayName]
        if output.format.supportsQuality {
            switch output.compression {
            case .quality: parts.append("\(Int((output.clampedQuality * 100).rounded())) %")
            case .targetSize(let bytes): parts.append("target \(SizeFormat.bytes(bytes))")
            case .maxSize(let bytes): parts.append("max \(SizeFormat.bytes(bytes))")
            case .smart: parts.append("smart")
            }
        }
        switch saveTo {
        case .newFolder: parts.append(folderName ?? "no folder chosen")
        case .sameFolder: parts.append(suffix.isEmpty ? "same folder" : "same folder (\(suffix))")
        case .overwrite: parts.append("overwrite originals")
        }
        if extraOutputs > 0 { parts.append("+\(extraOutputs) \(extraOutputs == 1 ? "output" : "outputs")") }
        return parts.joined(separator: " · ")
    }
}

/// Defaults of the app's view settings that Core can state (and test).
public enum ViewDefaults {
    /// The comparison mode a preview starts in when none is saved (Johan, round 3: Split).
    public static let compareMode = "split"
    /// Where the compare mode is saved.
    public static let compareModeKey = "compareMode"

    /// The compare mode to start in: the saved one when it is a mode `Mode` knows, else `compareMode` (Split). The
    /// app's `CompareController` reads its mode only through this.
    public static func startingCompareMode<Mode: RawRepresentable>(in defaults: UserDefaults, as type: Mode.Type)
        -> Mode? where Mode.RawValue == String {
        defaults.string(forKey: compareModeKey).flatMap(Mode.init(rawValue:)) ?? Mode(rawValue: compareMode)
    }
}
