import SwiftUI
import ImageconverterCore

// MARK: - Metadata editor

/// The Metadata step's settings in collapsible groups: Remove, Describe, Date, Location and More fields,
/// plus the Templates menu. Also used inside condition branches ("Set metadata…").
struct MetadataEditor: View {
    @Binding var options: MetadataOptions
    @State private var open: Set<MetadataGroupKind> = {
        // Screenshot aid: `-debugExpandSteps` opens every group.
        CommandLine.arguments.contains("-debugExpandSteps") ? Set(MetadataGroupKind.allCases) : [.remove]
    }()

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            MetadataTemplatesMenu(options: $options)
        }
        MetadataGroup(kind: .remove, open: $open) { removeControls }
        MetadataGroup(kind: .describe, open: $open) { describeControls }
        MetadataGroup(kind: .date, open: $open) { MetadataDateEditor(options: $options) }
        MetadataGroup(kind: .location, open: $open) { MetadataLocationEditor(location: $options.location) }
        MetadataGroup(kind: .more, open: $open) { MetadataCustomFieldsEditor(fields: $options.custom) }
    }

    // MARK: Remove

    private static let keepLabels: [KeepField: String] = [
        .copyright: "Copyright", .author: "Author", .dateTaken: "Date taken", .cameraInfo: "Camera details",
        .location: "Location", .orientation: "Orientation (always applied)", .colorProfile: "Color profile (always kept)",
    ]

    @ViewBuilder private var removeControls: some View {
        Toggle("Remove all metadata", isOn: $options.removeAll)
            .accessibilityLabel("Remove all metadata")
        if options.removeAll {
            Text("Keep these:").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            ForEach(KeepField.allCases, id: \.self) { field in
                let always = field == .orientation || field == .colorProfile
                Toggle(Self.keepLabels[field] ?? field.rawValue, isOn: always ? .constant(true) : keepBinding(field))
                    .disabled(always)
                    .accessibilityLabel("Keep \(Self.keepLabels[field] ?? field.rawValue)")
            }
        } else {
            Toggle("Remove location (GPS)", isOn: $options.removeLocation)
                .accessibilityLabel("Remove location (GPS)")
            Toggle("Remove camera details", isOn: $options.removeCamera)
                .accessibilityLabel("Remove camera details")
            Toggle("Remove author", isOn: $options.removeAuthor)
                .accessibilityLabel("Remove author")
            Toggle("Remove embedded thumbnail", isOn: $options.removeThumbnail)
                .accessibilityLabel("Remove embedded thumbnail")
            Toggle("Remove IPTC", isOn: $options.removeIPTC)
                .accessibilityLabel("Remove IPTC")
            Toggle("Remove XMP", isOn: $options.removeXMP)
                .accessibilityLabel("Remove XMP")
                .help("Fully removed for JPEG and TIFF; PNG, HEIC and GIF keep EXIF and IPTC inside XMP.")
        }
    }

    private func keepBinding(_ field: KeepField) -> Binding<Bool> {
        Binding(get: { options.keepWhenRemovingAll.contains(field) },
                set: { isOn in
                    if isOn { options.keepWhenRemovingAll.insert(field) } else { options.keepWhenRemovingAll.remove(field) }
                })
    }

    // MARK: Describe

    @ViewBuilder private var describeControls: some View {
        SetFieldRow(title: "Title", text: $options.title)
        SetFieldRow(title: "Artist", text: $options.artist)
        SetFieldRow(title: "Copyright", text: $options.copyright, insert: "©")
        SetFieldRow(title: "Description", text: $options.description)
        KeywordsEditor(keywords: $options.keywords, mode: $options.keywordsMode)
        Text("Replaces any existing title, including its other languages. Leave a ticked field empty to remove it.")
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
        AltTextControls(options: $options)
    }
}

// MARK: - Alt text

/// "Generate alt text on this Mac" and "Also use it as the description". Hidden below macOS 27 unless the
/// settings already use it; on macOS 27 without a ready model, shown disabled with the system's reason (a ticked
/// option can still be unticked).
private struct AltTextControls: View {
    @Binding var options: MetadataOptions
    @State private var availability = SystemAltTextGenerator.shared.availability

    var body: some View {
        if availability != .unsupportedOS || options.generateAltText {
            Toggle("Generate alt text on this Mac", isOn: $options.generateAltText)
                .disabled(!availability.isAvailable && !options.generateAltText)
                .help("Apple's on-device model writes one sentence describing each image, after the image steps. "
                      + "Stored as IPTC alt text (accessibility) in XMP. Nothing leaves the Mac.")
                .accessibilityLabel("Generate alt text on this Mac")
                .onAppear { availability = SystemAltTextGenerator.shared.availability }
            if options.generateAltText {
                Toggle("Also use it as the description", isOn: $options.altTextAsDescription)
                    .padding(.leading, LadaGlass.Spacing.m)
                    .accessibilityLabel("Also use the alt text as the description")
            }
            if let reason = availability.reason {
                Text("Not available: \(reason).")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(options.generateAltText ? LadaGlass.Colors.warnText : LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if options.generateAltText {
                Text(options.removeXMP && !options.altTextAsDescription
                     ? "Remove XMP is on, so no alt text can be stored."
                     : "Takes a few seconds per image. Check the text before you publish it.")
                    .font(LadaGlass.Typography.label)
                    .foregroundStyle(options.removeXMP && !options.altTextAsDescription
                                     ? LadaGlass.Colors.warnText : LadaGlass.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Groups

enum MetadataGroupKind: CaseIterable {
    case remove, describe, date, location, more

    var title: String {
        switch self {
        case .remove: "Remove"
        case .describe: "Describe"
        case .date: "Date"
        case .location: "Location"
        case .more: "More fields"
        }
    }
}

/// A compact collapsible group inside the Metadata row.
private struct MetadataGroup<Content: View>: View {
    let kind: MetadataGroupKind
    @Binding var open: Set<MetadataGroupKind>
    @ViewBuilder var content: Content

    private var isOpen: Bool { open.contains(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) {
            Button {
                if isOpen { open.remove(kind) } else { open.insert(kind) }
            } label: {
                HStack(spacing: LadaGlass.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    Text(kind.title).font(LadaGlass.Typography.subtitle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(LadaGlass.Colors.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(kind.title) settings")
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen {
                VStack(alignment: .leading, spacing: LadaGlass.Spacing.s) { content }
                    .padding(.leading, LadaGlass.Spacing.m)
            }
        }
    }
}

// MARK: - Text fields

/// "Set <field>": a toggle and a text field. Ticked with empty text removes the field; the typed
/// text is kept in a draft so unticking and reticking does not lose it. `insert` adds a button that
/// appends a character such as "©".
struct SetFieldRow: View {
    let title: String
    @Binding var text: String?
    var insert: String?
    @State private var draft = ""

    var body: some View {
        FieldRow {
            Toggle("Set \(title.lowercased())", isOn: Binding(
                get: { text != nil },
                set: { text = $0 ? draft : nil }))
                .accessibilityLabel("Set \(title.lowercased())")
            TextField(title, text: Binding(get: { text ?? draft }, set: { draft = $0; text = $0 }),
                      prompt: Text("Leave empty to remove"))
                .textFieldStyle(.roundedBorder)
                .disabled(text == nil)
                .accessibilityLabel(title)
            if let insert {
                Button(insert) {
                    draft = (text ?? draft) + insert
                    text = draft
                }
                .disabled(text == nil)
                .help("Insert \(insert)")
                .accessibilityLabel("Insert \(insert) into \(title.lowercased())")
            }
        }
        .onAppear { draft = text ?? "" }
        // A preset switch or reset can set the text from outside; keep the draft in step.
        .onChange(of: text) { _, new in
            if let new, new != draft { draft = new }
        }
    }
}

/// Keywords as removable tokens. Nil keywords means "leave as they are"; in Replace mode an empty list clears them.
private struct KeywordsEditor: View {
    @Binding var keywords: [String]?
    @Binding var mode: KeywordsMode
    @State private var draft = ""
    @State private var ids: RowIDs
    @FocusState private var focused: Bool

    init(keywords: Binding<[String]?>, mode: Binding<KeywordsMode>) {
        _keywords = keywords
        _mode = mode
        _ids = State(initialValue: RowIDs(count: keywords.wrappedValue?.count ?? 0))
    }

    private var list: [String] { keywords ?? [] }

    var body: some View {
        FieldRow {
            Text("Keywords").font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.muted)
            // Switching the mode only changes how the keywords are applied; the typed ones stay.
            Picker("Keywords mode", selection: $mode) {
                Text("Add").tag(KeywordsMode.add)
                Text("Replace").tag(KeywordsMode.replace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Keywords mode")
        }
        if !list.isEmpty {
            KeywordFlow {
                ForEach(ids.rows(count: list.count), id: \.id) { row in
                    if list.indices.contains(row.index) {
                        token(list[row.index], at: row.index)
                    }
                }
            }
        }
        TextField("Add keywords", text: $draft, prompt: Text("Type a keyword, press Return"))
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: draft) { _, new in if new.contains(",") { commit() } }
            // A keyword typed but not confirmed still counts when the field loses focus.
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: list.count) { _, count in ids.sync(count: count) }
            .accessibilityLabel("New keyword")
        if mode == .replace && keywords != nil && list.isEmpty {
            Text("Replace with no keywords removes all keywords.")
                .font(LadaGlass.Typography.label).foregroundStyle(LadaGlass.Colors.warnText)
        }
    }

    private func token(_ word: String, at index: Int) -> some View {
        HStack(spacing: 2) {
            Text(word).font(LadaGlass.Typography.label)
            Button { remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove keyword \(word)")
        }
        .padding(.horizontal, LadaGlass.Spacing.s)
        .padding(.vertical, 2)
        .background(Capsule().fill(LadaGlass.Colors.muted.opacity(0.2)))
    }

    private func commit() {
        let words = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        draft = ""
        guard !words.isEmpty else { return }
        let merged = MetadataFields.normalizedKeywords(list + words)
        if merged != list { keywords = merged }
    }

    private func remove(at index: Int) {
        var updated = list
        guard updated.indices.contains(index) else { return }
        updated.remove(at: index)
        ids.remove(at: index)
        keywords = updated.isEmpty && mode == .add ? nil : updated
    }
}

/// Lays tokens out left to right and wraps to the next line.
private struct KeywordFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let gap: CGFloat = 4
        var origins: [CGPoint] = []
        var cursorX: CGFloat = 0, cursorY: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + size.width > width {
                cursorX = 0
                cursorY += rowHeight + gap
                rowHeight = 0
            }
            origins.append(CGPoint(x: cursorX, y: cursorY))
            cursorX += size.width + gap
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, cursorX - gap)
        }
        return (CGSize(width: maxX, height: cursorY + rowHeight), origins)
    }
}
