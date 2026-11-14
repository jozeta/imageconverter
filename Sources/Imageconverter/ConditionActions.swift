import AppKit
import SwiftUI
import ImageconverterCore

// MARK: - Row ids

/// Stable row ids for a list whose elements have none (conditions, branch actions), kept in view state so a row's
/// editor state follows it when rows move or are removed. A change from outside (a preset) only grows or shrinks
/// the list from the end, so the rows that are still there keep their ids and stay open.
struct RowIDs {
    private(set) var ids: [UUID]

    init(count: Int) {
        ids = (0..<count).map { _ in UUID() }
    }

    mutating func sync(count: Int) {
        if ids.count < count {
            ids += (ids.count..<count).map { _ in UUID() }
        } else if ids.count > count {
            ids.removeLast(ids.count - count)
        }
    }

    mutating func append() { ids.append(UUID()) }

    @discardableResult
    mutating func remove(at index: Int) -> UUID? {
        ids.indices.contains(index) ? ids.remove(at: index) : nil
    }

    mutating func move(from: Int, to target: Int) {
        guard ids.indices.contains(from), ids.indices.contains(target) else { return }
        ids.insert(ids.remove(at: from), at: target)
    }

    func index(of id: UUID) -> Int? { ids.firstIndex(of: id) }

    /// One (id, index) per row that has an id; never makes ids while a view is drawn.
    func rows(count: Int) -> [(id: UUID, index: Int)] {
        zip(ids, 0..<count).map { (id: $0, index: $1) }
    }
}

// MARK: - Actions

/// What one branch does: its actions in order, each with an editor where it has settings, reorderable by
/// drag (handle), context menu or VoiceOver actions.
struct ActionList: View {
    let title: String
    @Binding var actions: [ConditionalAction]
    let defaults: BranchDefaults
    /// One stable id per action (actions have none), so editors keep their state when rows move.
    @State private var ids: RowIDs
    @State private var expanded: Set<UUID> = []
    @State private var draggedID: UUID?
    /// Rows a drag is over; when none is for a moment the drag has left or ended, so `draggedID` is cleared
    /// (SwiftUI tells a source nothing when a drag is cancelled).
    @State private var targetedRows: Set<UUID> = []

    init(title: String, actions: Binding<[ConditionalAction]>, defaults: BranchDefaults) {
        self.title = title
        _actions = actions
        self.defaults = defaults
        _ids = State(initialValue: RowIDs(count: actions.wrappedValue.count))
    }

    private static let dragPrefix = "condition-action:"

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack {
                Text(title).font(LadaGlass.Typography.subtitle)
                Spacer()
                addMenu
            }
            if actions.isEmpty {
                Text(title == "Then" ? "Nothing: the image goes on unchanged by this step" : "Nothing")
                    .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            }
            ForEach(ids.rows(count: actions.count), id: \.id) { id, index in
                ActionRow(
                    action: actionBinding(index),
                    branch: title,
                    isExpanded: Binding(get: { expanded.contains(id) },
                                        set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }),
                    defaults: defaults,
                    canMoveUp: index > 0,
                    canMoveDown: index < actions.count - 1,
                    move: { move(from: index, to: index + $0) },
                    remove: { remove(at: index) },
                    dragPayload: Self.dragPrefix + id.uuidString,
                    dropEdge: { dropEdge(onto: id) },
                    dragStarted: { draggedID = id },
                    targetChanged: { if $0 { targetedRows.insert(id) } else { targetedRows.remove(id) } },
                    dropped: { dropped($0, onto: id) })
            }
        }
        .onAppear {
            syncIDs()
            #if DEBUG
            // Screenshot aid: `-debugExpandSteps` opens the actions' editors too.
            if CommandLine.arguments.contains("-debugExpandSteps") { expanded = Set(ids.ids) }
            #endif
        }
        .onChange(of: actions.count) { syncIDs() }
        .task(id: targetedRows.isEmpty) {
            guard targetedRows.isEmpty, draggedID != nil else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            if targetedRows.isEmpty { draggedID = nil }
        }
    }

    /// Keeps the ids in step with `actions` after a change from outside; open rows that remain stay open.
    private func syncIDs() {
        ids.sync(count: actions.count)
        expanded.formIntersection(ids.ids)
    }

    private func actionBinding(_ index: Int) -> Binding<ConditionalAction> {
        Binding(
            get: { actions.indices.contains(index) ? actions[index] : .skip },
            set: { if actions.indices.contains(index) { actions[index] = $0 } })
    }

    /// Which one-off actions the list already has (a second one would only override the first).
    private struct Present {
        var copy = false, skip = false, output = false, metadata = false, rename = false, subfolder = false
        var stop = false
    }

    private var has: Present {
        var result = Present()
        for action in actions {
            switch action {
            case .copyOriginal: result.copy = true
            case .skip: result.skip = true
            case .output: result.output = true
            case .metadata: result.metadata = true
            case .rename: result.rename = true
            case .subfolder: result.subfolder = true
            case .stop: result.stop = true
            case .step, .finderTags, .preset, .addKeywords, .note: break
            }
        }
        return result
    }

    private var isFull: Bool { actions.count >= ConditionalStep.maxActions }

    private var addMenu: some View {
        let present = has
        return Menu("+ Add") {
            Section("Steps") {
                ForEach(StepKind.allCases.filter { $0 != .condition }, id: \.self) { kind in
                    Button(kind.displayName) { append(.step(PipelineStep(operation: AppModel.newOperation(kind)))) }
                }
                Button("Apply a saved preset…") { append(.preset(PresetLink(PresetStore.builtIns[0]))) }
            }
            Section("Output & files") {
                Button("Set output…") { append(.output(defaults.output)) }.disabled(present.output)
                Button("Set rename…") {
                    var rename = defaults.rename
                    rename.isIncluded = true
                    rename.isEnabled = true
                    append(.rename(rename))
                }
                .disabled(present.rename)
                Button("Save into subfolder…") { append(.subfolder("{date:yyyy}/{date:MM}")) }.disabled(present.subfolder)
                Button("Add Finder tags…") { append(.finderTags(["Converted"])) }
                Button("Copy original unchanged") { append(.copyOriginal) }.disabled(present.copy)
            }
            Section("Metadata") {
                Button("Set metadata…") {
                    var metadata = defaults.metadata
                    metadata.isIncluded = true
                    metadata.isEnabled = true
                    append(.metadata(metadata))
                }
                .disabled(present.metadata)
                Button("Add keywords…") { append(.addKeywords(["Selected"])) }
            }
            Section("Flow") {
                Button("Skip file") { append(.skip) }.disabled(present.skip)
                Button("Stop checking later conditions") { append(.stop) }.disabled(present.stop)
                Button("Add a note to the report…") { append(.note("Checked: {name}")) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isFull)
        .help(isFull ? "At most \(ConditionalStep.maxActions) actions" : "")
        .accessibilityLabel("Add an action to \(title)")
    }

    private func append(_ action: ConditionalAction) {
        guard !isFull else { return }
        syncIDs()
        actions.append(action)
        ids.append()
    }

    private func remove(at index: Int) {
        guard actions.indices.contains(index) else { return }
        syncIDs()
        if let id = ids.remove(at: index) { expanded.remove(id) }
        actions.remove(at: index)
    }

    private func move(from: Int, to target: Int) {
        guard actions.indices.contains(from), actions.indices.contains(target), from != target else { return }
        syncIDs()
        actions.insert(actions.remove(at: from), at: target)
        ids.move(from: from, to: target)
    }

    /// Like steps: the dragged action lands at the target's index (above it from below, below it from above).
    private func dropEdge(onto id: UUID) -> VerticalEdge? {
        guard let dragged = draggedID, dragged != id, let from = ids.index(of: dragged),
              let target = ids.index(of: id) else { return nil }
        return from > target ? .top : .bottom
    }

    /// Only actions of this same list move here; anything else (a step, the other branch) is refused.
    private func dropped(_ payload: String, onto id: UUID) -> Bool {
        draggedID = nil
        guard payload.hasPrefix(Self.dragPrefix),
              let dragged = UUID(uuidString: String(payload.dropFirst(Self.dragPrefix.count))),
              let from = ids.index(of: dragged), let target = ids.index(of: id) else { return false }
        move(from: from, to: target)
        return true
    }
}

private struct ActionRow: View {
    @Binding var action: ConditionalAction
    let branch: String
    @Binding var isExpanded: Bool
    let defaults: BranchDefaults
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    let dragPayload: String
    let dropEdge: () -> VerticalEdge?
    let dragStarted: () -> Void
    let targetChanged: (Bool) -> Void
    let dropped: (String) -> Bool
    @State private var isTargeted = false
    @State private var handleHovered = false

    private var name: String {
        switch action {
        case .step(let step): return step.operation.kind.displayName
        case .output: return "Set output"
        case .metadata: return "Set metadata"
        case .rename: return "Set rename"
        case .copyOriginal: return "Copy original"
        case .skip: return "Skip file"
        case .subfolder: return "Save into subfolder"
        case .finderTags: return "Add Finder tags"
        case .preset: return "Apply preset"
        case .addKeywords: return "Add keywords"
        case .stop: return "Stop"
        case .note: return "Add a note"
        }
    }

    private var summary: String {
        switch action {
        case .step(let step): return step.operation.summary
        case .output(let settings): return "save as \(settings.format.displayName)"
        case .metadata(let options): return options.summary
        case .rename(let options): return options.summary
        case .copyOriginal: return "writes the file unchanged"
        case .skip: return "nothing is written"
        case .stop: return "later conditions aren't checked for this image"
        default: return action.summary
        }
    }

    private var hasEditor: Bool {
        switch action {
        case .copyOriginal, .skip, .stop: return false
        default: return true
        }
    }

    var body: some View {
        AccordionCard(isExpanded: $isExpanded, canExpand: hasEditor, title: "\(branch): \(name)") {
            HStack(spacing: LadaGlass.Spacing.s) {
                handle
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(LadaGlass.Typography.body)
                    Text(summary)
                        .font(LadaGlass.Typography.label)
                        .foregroundStyle(LadaGlass.Colors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                RemoveStepButton(label: "\(branch) action \(name)", action: remove)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Move Up") { move(-1) }.disabled(!canMoveUp)
                Button("Move Down") { move(1) }.disabled(!canMoveDown)
                Divider()
                Button("Remove", role: .destructive, action: remove)
            }
        } content: {
            VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) { editor }
        }
        .overlay(alignment: dropEdge() == .bottom ? .bottom : .top) {
            if isTargeted, let edge = dropEdge() {
                Capsule().fill(LadaGlass.accent.color).frame(height: 2)
                    .offset(y: edge == .bottom ? 1 : -1)
            }
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return dropped(payload)
        } isTargeted: {
            isTargeted = $0
            targetChanged($0)
        }
        .accessibilityAction(named: "Move up") { if canMoveUp { move(-1) } }
        .accessibilityAction(named: "Move down") { if canMoveDown { move(1) } }
    }

    @ViewBuilder private var editor: some View {
        switch action {
        case .step(let step):
            StepEditor(operation: Binding(
                get: { if case .step(let current) = action { return current.operation } else { return step.operation } },
                set: { new in
                    guard case .step(var current) = action else { return }
                    current.operation = new
                    action = .step(current)
                }))
        case .output(let settings):
            OutputFormatControls(output: Binding(
                get: { if case .output(let current) = action { return current } else { return settings } },
                set: { action = .output($0) }))
        case .metadata(let options):
            MetadataEditor(options: Binding(
                get: { if case .metadata(let current) = action { return current } else { return options } },
                set: { action = .metadata($0) }))
        case .rename(let options):
            RenameEditor(options: Binding(
                get: { if case .rename(let current) = action { return current } else { return options } },
                set: { action = .rename($0) }), example: "")
        case .copyOriginal, .skip, .stop:
            EmptyView()
        default:
            FileActionEditor(action: $action)
        }
    }

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(LadaGlass.Colors.muted)
            .frame(width: 20, height: 24)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    handleHovered = true
                    NSCursor.openHand.set()
                case .ended:
                    handleHovered = false
                    NSCursor.arrow.set()
                }
            }
            .onDisappear { if handleHovered { NSCursor.arrow.set() } }
            .draggable(dragPayload) {
                Text(name)
                    .font(LadaGlass.Typography.subtitle)
                    .padding(.horizontal, LadaGlass.Spacing.m)
                    .padding(.vertical, LadaGlass.Spacing.s)
                    .lgSurface()
                    .onAppear(perform: dragStarted)
            }
            .help("Drag to reorder")
            .accessibilityHidden(true)
    }
}
