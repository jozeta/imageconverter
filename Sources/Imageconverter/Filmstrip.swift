import SwiftUI
import ImageconverterCore

/// A horizontal strip of the batch's thumbnails; ← and → move the selection while it has focus.
struct Filmstrip: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: LadaGlass.Spacing.s) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        thumbnail(index: index, item: item).id(index)
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

    private func thumbnail(index: Int, item: InputItem) -> some View {
        let isSelected = index == model.selectedItemIndex
        return Button {
            model.selectedIndex = index
            focused = true
        } label: {
            Group {
                if let image = model.thumbnails[item.source] {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(LadaGlass.Colors.muted)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: LadaGlass.Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: LadaGlass.Radius.small)
                    .strokeBorder(isSelected ? LadaGlass.accent.color : LadaGlass.Colors.border,
                                  lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.source.lastPathComponent)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: item.source) { await model.loadThumbnail(for: item.source) }
    }
}
