import SwiftUI
import ImageconverterCore

/// The editors of the branch actions that take a value: subfolder, Finder tags, preset, keywords and note.
struct FileActionEditor: View {
    @Binding var action: ConditionalAction
    @Environment(AppModel.self) private var model: AppModel?

    /// The example the subfolder and note editors render (a typical camera file).
    private static let sample: RenameContext = {
        var context = RenameContext(
            name: "IMG_0042", ext: "jpg", format: "JPEG", folder: "Photos", date: Date(), make: "Apple",
            model: "iPhone 15 Pro", lens: nil, iso: 100, width: 4032, height: 3024, counter: 1)
        context.labels = ["dog", "grass"]
        return context
    }()

    /// The rename tokens, with `{labels}` (what the image shows) in its plain form for folder names.
    private static let tokens = RenameTemplate.tokenExamples.filter { !$0.hasPrefix("{labels") } + [LabelToken.token]

    var body: some View {
        switch action {
        case .subfolder(let template): subfolderEditor(template)
        case .finderTags(let tags):
            ListTextField(values: tags, prompt: "tags, e.g. Portraits, Red", parse: FinderTags.parse,
                          label: "Finder tags, separated by commas") { action = .finderTags($0) }
            caption("Added to the written file's own tags (on this Mac). Up to \(FinderTags.maxTags). "
                    + "{labels} adds one tag per label the image shows.")
        case .preset(let link): presetPicker(link)
        case .addKeywords(let keywords):
            ListTextField(values: keywords, prompt: "keywords, e.g. travel, family", parse: FinderTags.parse,
                          label: "Keywords, separated by commas") { action = .addKeywords($0) }
            caption("Added to the file's keywords; {labels} adds one keyword per label the image shows. "
                    + "What the Metadata step removes stays removed.")
        case .note(let text):
            TextField("Note", text: Binding(get: { text }, set: { action = .note(String($0.prefix(ConditionalAction.maxNoteLength))) }),
                      prompt: Text("note, e.g. Needs retouching: {name}"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note for the report; rename tokens like {name} are filled in")
            caption("Shown in the report for this file. Tokens such as {name}, {camera}, {date} or {labels} are filled in.")
        default:
            EmptyView()
        }
    }

    private func subfolderEditor(_ template: String) -> some View {
        VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            TextField("Subfolder", text: Binding(get: { template }, set: {
                action = .subfolder(String($0.prefix(RenameTemplate.maxLength)))
            }), prompt: Text("e.g. Portraits or {date:yyyy}/{date:MM}"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Subfolder; slashes make nested folders, rename tokens are filled in")
            Menu("Insert token") {
                ForEach(Self.tokens, id: \.self) { token in
                    Button(token) { action = .subfolder(template + token) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            let folders = SubfolderTemplate.folders(template, context: Self.sample)
            caption(folders.isEmpty ? "No folder: the file goes into the output folder itself"
                    : "Example: \(folders.joined(separator: " › ")). Inside the output folder (or the image's own "
                        + "folder when saving next to the originals); at most \(SubfolderTemplate.maxDepth) levels; "
                        + "ignored when overwriting originals.")
        }
    }

    private func presetPicker(_ link: PresetLink) -> some View {
        let presets = model?.allPresets ?? PresetStore.builtIns
        let known = presets.contains { $0.id == link.id }
        return VStack(alignment: .leading, spacing: LadaGlass.Spacing.xs) {
            Picker("Preset", selection: Binding(get: { link.id }, set: { id in
                if let preset = presets.first(where: { $0.id == id }) { action = .preset(PresetLink(preset)) }
            })) {
                ForEach(presets) { Text($0.name).tag($0.id) }
                if !known { Text("\(link.name) (missing)").tag(link.id) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Preset to apply")
            caption(known ? "Its image steps run here; its output, and its metadata and rename when they are on, replace "
                        + "the pipeline's for this image. Its own conditions are not used."
                    : "This preset no longer exists: the report notes it and nothing is applied.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(LadaGlass.Typography.label)
            .foregroundStyle(LadaGlass.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
