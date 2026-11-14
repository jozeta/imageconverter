import AppKit
import SwiftUI
import ImageconverterCore

// MARK: - Actions

/// What one branch does: its actions in order, each with an editor where it has settings, reorderable by
/// drag (handle), context menu or VoiceOver actions.
struct ActionList: View {
    let title: String
    @Binding var actions: [ConditionalAction]
    let defaults: BranchDefaults
    /// One stable id per action (actions have none), so editors keep their state when rows move.
    @State private var ids: [UUID] = []
    @State private var expanded: Set<UUID> = []
    @State private var draggedID: UUID?

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
            let rows = rowIDs
            ForEach(Array(zip(rows, actions.indices)), id: \.0) { id, index in
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
                    dropped: { dropped($0, onto: id) })
            }
        }
        .onAppear {
            syncIDs()
            #if DEBUG
            // Screenshot aid: `-debugExpandSteps` opens the actions' editors too.
            if CommandLine.arguments.contains("-debugExpandSteps") { expanded = Set(ids) }
            #endif
        }
        .onChange(of: actions.count) { syncIDs() }
    }

    /// The ids in step with `actions`; a change from outside (a preset) that changes the count gets new ones.
    private var rowIDs: [UUID] {
        ids.count == actions.count ? ids : actions.indices.map { _ in UUID() }
    }

    private func syncIDs() {
        guard ids.count != actions.count else { return }
        ids = actions.indices.map { _ in UUID() }
        expanded = []
    }

    private func actionBinding(_ index: Int) -> Binding<ConditionalAction> {
        Binding(
            get: { actions.indices.contains(index) ? actions[index] : .skip },
            set: { if actions.indices.contains(index) { actions[index] = $0 } })
    }

    /// Which one-off actions the list already has (a second one would only override the first).
    private struct Present {
        var copy = false, skip = false, output = false, metadata = false, rename = false
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
            case .step: break
            }
        }
        return result
    }

    private var addMenu: some View {
        let present = has
        return Menu("+ Add") {
            Section("Image steps") {
                ForEach(StepKind.allCases.filter { $0 != .condition }, id: \.self) { kind in
                    Button(kind.displayName) { append(.step(PipelineStep(operation: AppModel.newOperation(kind)))) }
                }
            }
            Section("File") {
                Button("Set output…") { append(.output(defaults.output)) }.disabled(present.output)
                Button("Set metadata…") {
                    var metadata = defaults.metadata
                    metadata.isIncluded = true
                    metadata.isEnabled = true
                    append(.metadata(metadata))
                }
                .disabled(present.metadata)
                Button("Set rename…") {
                    var rename = defaults.rename
                    rename.isIncluded = true
                    rename.isEnabled = true
                    append(.rename(rename))
                }
                .disabled(present.rename || defaults.renameLockedHelp != nil)
                .help(defaults.renameLockedHelp ?? "")
            }
            Section("Instead") {
                Button("Copy original unchanged") { append(.copyOriginal) }.disabled(present.copy)
                Button("Skip file") { append(.skip) }.disabled(present.skip)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Add an action to \(title)")
    }

    private func append(_ action: ConditionalAction) {
        syncIDs()
        actions.append(action)
        ids.append(UUID())
    }

    private func remove(at index: Int) {
        guard actions.indices.contains(index) else { return }
        syncIDs()
        expanded.remove(ids[index])
        actions.remove(at: index)
        ids.remove(at: index)
    }

    private func move(from: Int, to target: Int) {
        guard actions.indices.contains(from), actions.indices.contains(target), from != target else { return }
        syncIDs()
        let action = actions.remove(at: from)
        actions.insert(action, at: target)
        let id = ids.remove(at: from)
        ids.insert(id, at: target)
    }

    /// Like steps: the dragged action lands at the target's index (above it from below, below it from above).
    private func dropEdge(onto id: UUID) -> VerticalEdge? {
        guard let dragged = draggedID, dragged != id, let from = ids.firstIndex(of: dragged),
              let target = ids.firstIndex(of: id) else { return nil }
        return from > target ? .top : .bottom
    }

    /// Only actions of this same list move here; anything else (a step, the other branch) is refused.
    private func dropped(_ payload: String, onto id: UUID) -> Bool {
        guard payload.hasPrefix(Self.dragPrefix),
              let dragged = UUID(uuidString: String(payload.dropFirst(Self.dragPrefix.count))),
              let from = ids.firstIndex(of: dragged), let target = ids.firstIndex(of: id) else { return false }
        move(from: from, to: target)
        draggedID = nil
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
        }
    }

    private var hasEditor: Bool {
        switch action {
        case .copyOriginal, .skip: return false
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
        } isTargeted: { isTargeted = $0 }
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
            if let help = defaults.renameLockedHelp {
                Text(help).font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
            }
            RenameEditor(options: Binding(
                get: { if case .rename(let current) = action { return current } else { return options } },
                set: { action = .rename($0) }), example: "")
        case .copyOriginal, .skip:
            EmptyView()
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
