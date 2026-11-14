import SwiftUI
import ImageconverterCore

/// The batch below the preview as a filmstrip, a grid or a list; the mode is remembered.
struct BatchBrowser: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            HStack {
                Picker("Show batch as", selection: Bindable(model.compare).browserMode) {
                    ForEach(BrowserMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show batch as")
                Spacer()
                Text("\(model.items.count) \(model.items.count == 1 ? "image" : "images")")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(LadaGlass.Colors.muted)
            }
            switch model.compare.browserMode {
            case .filmstrip: Filmstrip(model: model)
            case .grid: ResizableArea(compare: model.compare) { BatchGrid(model: model) }
            case .list: ResizableArea(compare: model.compare) { BatchTable(model: model) }
            }
        }
    }
}

/// A thumbnail on a checkerboard, so transparent images show as transparent.
struct BatchThumbnail: View {
    @Bindable var model: AppModel
    let item: InputItem
    let isSelected: Bool
    var side: CGFloat = 56

    var body: some View {
        Group {
            if let image = model.thumbnail(for: item.source) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(LadaGlass.Colors.muted)
            }
        }
        .frame(width: side, height: side)
        .background(Checkerboard())
        .clipShape(RoundedRectangle(cornerRadius: LadaGlass.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                .strokeBorder(isSelected ? LadaGlass.accent.color : LadaGlass.Colors.border,
                              lineWidth: isSelected ? 2 : 1))
        // The item's stage in the running (or last) batch.
        .overlay(alignment: .bottomTrailing) {
            if let stage = model.monitor.stage(for: item.source) { StageRing(stage: stage).padding(2) }
        }
        .task(id: item.source) { await model.loadThumbnail(for: item.source) }
    }
}

/// A horizontal strip of the batch's thumbnails; ← and → move the selection while it has focus.
struct Filmstrip: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: LadaGlass.Spacing.s) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        cell(index: index, item: item).id(index)
                    }
                }
                .padding(LadaGlass.Spacing.xs)
            }
            .onChange(of: model.selectedIndex) { _, new in
                withAnimation(LadaGlass.Motion.quick) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 56 + 2 * LadaGlass.Spacing.xs + 12)
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image filmstrip")
    }

    private func cell(index: Int, item: InputItem) -> some View {
        let isSelected = index == model.selectedItemIndex
        return Button {
            model.selectedIndex = index
            focused = true
        } label: {
            BatchThumbnail(model: model, item: item, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.source.lastPathComponent)
        .accessibilityValue(model.monitor.stage(for: item.source)?.title ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .processNextMenu(model: model, sources: [item.source])
    }
}

/// An adaptive grid of thumbnails with names; the arrow keys move the selection in two dimensions.
struct BatchGrid: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    @State private var columns = 1
    static let cell: CGFloat = 72
    static let spacing = LadaGlass.Spacing.s

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: Self.spacing)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        cell(index: index, item: item).id(index)
                    }
                }
                .padding(LadaGlass.Spacing.xs)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        columns = BrowserNavigation.columns(width: width - 2 * LadaGlass.Spacing.xs,
                                                            cell: Self.cell, spacing: Self.spacing)
                    }
                })
            }
            .onChange(of: model.selectedIndex) { _, new in
                withAnimation(LadaGlass.Motion.quick) { proxy.scrollTo(new) }
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let direction: BrowserNavigation.Direction = switch press.key {
            case .leftArrow: .left
            case .rightArrow: .right
            case .upArrow: .above
            default: .below
            }
            if let next = BrowserNavigation.move(from: model.selectedItemIndex ?? 0, direction: direction,
                                                 columns: columns, count: model.items.count) {
                model.selectedIndex = next
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image grid")
    }

    private func cell(index: Int, item: InputItem) -> some View {
        let isSelected = index == model.selectedItemIndex
        return Button {
            model.selectedIndex = index
            focused = true
        } label: {
            VStack(spacing: LadaGlass.Spacing.xxs) {
                BatchThumbnail(model: model, item: item, isSelected: isSelected, side: Self.cell - 8)
                Text(item.source.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? LadaGlass.Colors.text : LadaGlass.Colors.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: Self.cell)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.source.lastPathComponent)
        .accessibilityValue(model.monitor.stage(for: item.source)?.title ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .processNextMenu(model: model, sources: [item.source])
    }
}

/// The grid or list with a grab bar on top that changes its height (also with ↑ ↓ when the bar has focus).
struct ResizableArea<Content: View>: View {
    let compare: CompareController
    @ViewBuilder let content: Content
    @State private var dragStart: CGFloat?
    @State private var cursorPushed = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(LadaGlass.Colors.muted.opacity(0.6))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, minHeight: 10)
                .contentShape(Rectangle())
                .onHover { setCursor($0) }
                .onDisappear { setCursor(false) }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? compare.browserHeight
                        dragStart = start
                        compare.browserHeight = min(max(start - value.translation.height, CompareController.browserHeights.lowerBound),
                                                    CompareController.browserHeights.upperBound)
                    }
                    .onEnded { _ in dragStart = nil })
                .focusable()
                .onKeyPress(.upArrow) {
                    compare.resizeBrowser(by: 20)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    compare.resizeBrowser(by: -20)
                    return .handled
                }
                .accessibilityElement()
                .accessibilityLabel("Batch area height")
                .accessibilityValue("\(Int(compare.browserHeight)) points")
                .accessibilityAdjustableAction { direction in
                    compare.resizeBrowser(by: direction == .increment ? 20 : -20)
                }
            // Gives way (down to 60 pt) when the pane is short, so the preview above keeps its room.
            content.frame(minHeight: 60, maxHeight: compare.browserHeight)
        }
    }

    /// Push and pop stay paired even when the bar goes away under the pointer.
    private func setCursor(_ inside: Bool) {
        guard inside != cursorPushed else { return }
        cursorPushed = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
}

extension View {
    /// "Process Next" while a batch runs (keyboard: File > Process Selected Next).
    func processNextMenu(model: AppModel, sources: [URL]) -> some View {
        contextMenu {
            if model.isRunning {
                Button("Process Next") { model.processNext(sources) }
            }
        }
    }
}
