import Foundation

/// Help text for one pipeline item, shown in the hover box on a step's title.
public struct StepHelpInfo: Equatable, Sendable {
    public let title: String
    /// One or two sentences: what the step does.
    public let summary: String
    /// Short bullets on how to use the main settings.
    public let howTo: [String]
    /// Optional extra advice.
    public let tips: [String]
}

/// Which pipeline item a help text is for: an image step, or one of the fixed file steps and the Output panel.
public enum StepHelpTopic: Hashable, Sendable {
    case step(StepKind)
    case metadata, rename, output

    public static var all: [StepHelpTopic] {
        StepKind.allCases.map { .step($0) } + [.metadata, .rename, .output]
    }
}

/// Plain-English descriptions of every pipeline item.
public enum StepHelp {
    public static func info(for kind: StepKind) -> StepHelpInfo { info(for: .step(kind)) }

    // One case per topic keeps every text in one place.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public static func info(for topic: StepHelpTopic) -> StepHelpInfo {
        switch topic {
        case .step(.resize):
            return StepHelpInfo(
                title: "Resize",
                summary: "Changes the size of each image in pixels, as a percentage or as a print "
                    + "size; every mode except a stretched exact size keeps the proportions.",
                howTo: [
                    "Pick a mode: max or exact width or height, fit inside, longest or "
                        + "shortest edge, exact or minimum size, percentage, or a print size.",
                    "Use Presets for ready-made sizes: print, web, devices, app assets, social media and screen resolutions.",
                    "\"Don't enlarge\" keeps small images as they are; it doesn't apply to Percentage, Minimum size or print sizes.",
                    "Resampling sets how pixels are scaled; Lanczos, the default, "
                        + "is the sharpest. Set DPI only labels the print resolution."
                ],
                tips: [
                    "Print sizes use their own DPI (presets use 300), and a print sheet turns to match each photo's orientation.",
                    "Put Resize before Adjust or Watermark so they suit the final size."
                ])
        case .step(.crop):
            return StepHelpInfo(
                title: "Crop",
                summary: "Cuts each image to a fixed size or an aspect ratio, keeping the part around the anchor you choose.",
                howTo: [
                    "Choose Aspect for a ratio such as 1:1 or 16:9 (the largest area that fits), or Size for exact pixels.",
                    "The anchor decides which part stays: centre, a corner or an edge.",
                    "A fixed size larger than the image is limited to the image's own width or height; nothing is enlarged."
                ],
                tips: ["For one image at a time with your own selection, crop in another app first."])
        case .step(.rotateFlip):
            return StepHelpInfo(
                title: "Rotate / flip",
                summary: "Turns images by 90 degrees or any angle, and mirrors them horizontally or vertically.",
                howTo: [
                    "Pick a clockwise turn of 90, 180 or 270 degrees, and/or an Angle from -180 to 180 degrees (positive is clockwise).",
                    "For an angle, Fill corners fills the new corners with a colour or transparency; Crop to fit cuts them away.",
                    "Mirror flips left to right, Flip vertically flips top to bottom."
                ],
                tips: ["Photos are already turned upright from their camera orientation before the pipeline starts."])
        case .step(.perspective):
            return StepHelpInfo(
                title: "Perspective",
                summary: "Straightens photos taken at an angle, such as documents, screens or tall buildings.",
                howTo: [
                    "Auto looks for a document or screen and squares it up.",
                    "Vertical and Horizontal sliders correct keystone distortion; they run after Auto.",
                    "The slider correction is cropped so no empty corners show."
                ],
                tips: ["If Auto finds no edges, the image is left as it is and the "
                    + "report notes \"No document edges found\"; use the sliders."])
        case .step(.trim):
            return StepHelpInfo(
                title: "Trim",
                summary: "Removes an empty border around the picture: transparent pixels, one colour or the top-left pixel's colour.",
                howTo: [
                    "Choose what counts as border: Transparent edges, a Colour, or the Edge colour (the top-left pixel).",
                    "Tolerance (0 to 100 %) also trims shades close to the border colour, or nearly transparent pixels for Transparent.",
                    "Padding keeps a margin of that many pixels around what is left (never more than the image has)."
                ],
                tips: ["Handy for screenshots and product shots on a plain background."])
        case .step(.canvas):
            return StepHelpInfo(
                title: "Canvas / padding",
                summary: "Adds space around the image: padding, a fixed canvas size or an aspect ratio.",
                howTo: [
                    "Padding adds the same border on all sides, in pixels or as a percentage of the shorter side.",
                    "Canvas size places the image on a canvas of exactly that size; a smaller canvas cuts the image off.",
                    "Ratio grows one side until the canvas has that ratio, such as 1:1 for a square; it never crops.",
                    "The anchor places the image on a canvas size or ratio; choose the background colour of the new space."
                ],
                tips: ["Use a transparent background and a format with transparency, such as PNG, to keep the new space see-through."])
        case .step(.colorProfile):
            return StepHelpInfo(
                title: "Color profile",
                summary: "Converts the colours of each image to a standard profile so they look the same on other screens.",
                howTo: [
                    "sRGB is the safest choice for the web and email.",
                    "Display P3 keeps a wider range of colours for modern Apple screens.",
                    "Gray makes a black-and-white image; Keep original leaves the profile alone."
                ],
                tips: ["The Metadata step never removes the colour profile, so the result stays correct."])
        case .step(.adjust):
            return StepHelpInfo(
                title: "Adjust",
                summary: "Corrects light, colour and detail: exposure, contrast, saturation, warmth, sharpness and more.",
                howTo: [
                    "Open the Light, Colour and Detail groups and move the sliders; the preview updates as you go.",
                    "Most sliders run from -100 to 100, Hue from -180 to 180 degrees, Detail from 0 to 100.",
                    "Double-click a slider or its label to set it back to 0, or press a group's Reset."
                ],
                tips: [
                    "Put Adjust after Resize so sharpening suits the final size.",
                    "Gray, CMYK and indexed images come out as sRGB; add a Color profile step to go back to gray."
                ])
        case .step(.watermark):
            return StepHelpInfo(
                title: "Watermark",
                summary: "Stamps text or a logo on every image, once at a position or tiled over the whole picture.",
                howTo: [
                    "Choose Text or Image. An image can be any picture file (PNG, JPEG, HEIC, TIFF, ...) or a plain SVG logo.",
                    "Text tokens, filled in per image: {filename}, {filename.ext}, "
                        + "{date}, {date:yyyy-MM-dd}, {year}, {copyright}, {artist}.",
                    "Position uses a 3 x 3 grid; Tiled repeats the mark over the image with spacing and optional staggered rows.",
                    "Size is a percentage of the shorter side, so the mark looks the same on every photo.",
                    "Set opacity, margin, rotation and a shadow (text can also get an outline); Templates saves a watermark for reuse."
                ],
                tips: [
                    "SVGs may hold shapes, gradients, text and simple styles; files with "
                        + "scripts, embedded images or links to other files are refused.",
                    "Put the step after Resize and Crop so the mark fits the final image."
                ])
        case .step(.condition):
            return StepHelpInfo(
                title: "If ... then ... else",
                summary: "Treats images differently depending on what they are, e.g. "
                    + "name, date taken, camera, size, format, orientation or whether they have a location.",
                howTo: [
                    "Add up to 10 tests and choose whether all or any of them must match; tick Not to turn a test around.",
                    "Tests look at the original file, before any steps run, not at the image part-way through the pipeline.",
                    "Then and Else hold actions: image steps or a saved preset, output, metadata or rename settings, "
                        + "a subfolder, tags, keywords, Copy, Skip, Stop or a note.",
                    "Select an image to see in the preview which branch it takes."
                ],
                tips: [
                    "With several conditions, later output, metadata and rename settings win, and Skip beats Copy.",
                    "Copy original keeps the file byte for byte, unless the Metadata step removes something; then it is converted instead."
                ])
        case .metadata:
            return StepHelpInfo(
                title: "Metadata",
                summary: "Removes or sets the information stored inside each image, such as location, camera details, author and dates.",
                howTo: [
                    "Remove: Remove all metadata (with a Keep list), or single parts: location, camera, author, thumbnail, IPTC, XMP.",
                    "Describe: set title, artist, copyright, description and keywords (add or replace).",
                    "Date: keep, set or shift the date taken. Location: keep, remove or set the GPS position.",
                    "Templates apply ready-made settings such as Privacy or Web, or save your own."
                ],
                tips: [
                    "Removals are a floor: a condition's branches can add more, but never bring back what is removed here.",
                    "The colour profile is always kept and re-encoded photos are saved upright, so the picture still looks right.",
                    "Metadata only (no image steps, same format): JPEG and HEIC are copied without re-encoding; the quality is not used."
                ])
        case .rename:
            return StepHelpInfo(
                title: "Rename",
                summary: "Gives each output file a new name built from a pattern with tokens, such as the date, camera or a counter.",
                howTo: [
                    "Type a pattern like {date:yyyy-MM-dd}_{camera}_{counter:000}, or build it with Insert.",
                    "The example line shows the name the selected image (or the first) would get.",
                    "{counter} counts up from Counter starts at in the order of the images; {counter:000} pads it to three digits.",
                    "Order: pattern, Find and replace, prefix and suffix, Remove spaces, Special characters, then Case."
                ],
                tips: [
                    "Find and replace rules run in order; tick Regular expression to use one, with $1 for a captured group.",
                    "If a name is already taken, _2, _3 and so on is added; other existing files are never replaced.",
                    "When overwriting originals, the renamed file is saved next to the original, which then goes to the Trash."
                ])
        case .output:
            return StepHelpInfo(
                title: "Output",
                summary: "Chooses the file format and quality of the results, and where the converted files are saved.",
                howTo: [
                    "Format: JPEG, PNG, HEIC and TIFF, plus GIF, BMP, JPEG 2000 and AVIF where this Mac can write them.",
                    "Compression: Quality, Target size, Maximum size, or Smart (lowest quality that still looks the same, up to 95 %).",
                    "JPEG can be Progressive; Optimise PNG tries every PNG filter for "
                        + "the smallest file. The size line is for the selected image.",
                    "Save to: a new folder (flat, unless a condition picks a subfolder), the same folder (suffix "
                        + "such as _new only if the name is unchanged), or overwrite."
                ],
                tips: [
                    "Overwriting with the same name and format replaces the file. When the name or "
                        + "format changes, the original goes to the Trash after the new file is saved.",
                    "Output is always the last stage, after every step and after Metadata and Rename.",
                    "+ Add output writes more files per image (a thumbnail, a web copy), each with its own "
                        + "format, size and suffix; always new files next to the main one."
                ])
        }
    }
}
