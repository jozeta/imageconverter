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
                summary: "Changes the size of each image while keeping its proportions, in pixels, as a percentage or as a print size.",
                howTo: [
                    "Pick a mode: max width or height, fit inside a box, longest or shortest edge, or an exact size.",
                    "Use Presets for ready-made sizes: print sheets, web, devices, social media.",
                    "\"Don't enlarge\" keeps small images as they are instead of stretching them.",
                    "Resampling sets the quality of the scaling; Lanczos is the sharpest."
                ],
                tips: [
                    "Print sizes use the DPI you set, and a print sheet turns to match each photo's orientation.",
                    "Put Resize before Adjust or Watermark so they suit the final size."
                ])
        case .step(.crop):
            return StepHelpInfo(
                title: "Crop",
                summary: "Cuts each image to a fixed size or an aspect ratio, keeping the part around the anchor you choose.",
                howTo: [
                    "Choose Size for exact pixels, or Aspect ratio such as 1:1 or 16:9.",
                    "The anchor decides which part stays: centre, a corner or an edge.",
                    "Images already smaller than a fixed size are not enlarged."
                ],
                tips: ["For one image at a time with your own selection, crop in another app first."])
        case .step(.rotateFlip):
            return StepHelpInfo(
                title: "Rotate / flip",
                summary: "Turns images by 90 degrees or any angle, and mirrors them horizontally or vertically.",
                howTo: [
                    "Pick a 90 degree turn, or set an Angle between -180 and 180 degrees (clockwise).",
                    "For an angle, Fill corners paints the new corners; Crop to fit straightens without empty corners.",
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
                    "The result is cropped so no empty corners show."
                ],
                tips: ["If Auto finds no edges, the report says \"No document edges found\"; use the sliders instead."])
        case .step(.trim):
            return StepHelpInfo(
                title: "Trim",
                summary: "Removes an empty border around the picture: transparent pixels, one colour or the top-left pixel's colour.",
                howTo: [
                    "Choose what counts as border: Transparent, a Colour, or the Edge colour.",
                    "Tolerance (0 to 100 %) allows shades close to the border colour to be trimmed too.",
                    "Padding keeps a margin of pixels around what is left."
                ],
                tips: ["Handy for screenshots and product shots on a plain background."])
        case .step(.canvas):
            return StepHelpInfo(
                title: "Canvas / padding",
                summary: "Adds space around the image without cropping it: padding, a fixed canvas size or a set aspect ratio.",
                howTo: [
                    "Padding adds a border in pixels or percent on all sides.",
                    "Fixed size places the image on a canvas of exactly that size.",
                    "Ratio grows the shorter side until the image fits, such as 1:1 for a square.",
                    "Choose the anchor and the background colour of the new space."
                ],
                tips: ["Use a transparent background and a PNG output to keep the new space see-through."])
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
                    "Double-click a slider to set it back to 0, or press a group's Reset.",
                    "The filled part of a slider is blue only while the value is not 0."
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
                    "Choose Text or Image. Images can be PNG, JPEG or SVG logos with a transparent background.",
                    "Text can use tokens such as {filename} or {year}, filled in for each image.",
                    "Position uses a 3 x 3 grid; Tiled repeats the mark with spacing and staggered rows.",
                    "Size is a percentage of the shorter side, so the mark looks the same on every photo.",
                    "Set opacity, margin and rotation; Templates saves a watermark for reuse."
                ],
                tips: [
                    "SVG logos are checked first: scripts and links to other files are ignored.",
                    "Put the step after Resize and Crop so the mark fits the final image."
                ])
        case .step(.condition):
            return StepHelpInfo(
                title: "If ... then ... else",
                summary: "Treats images differently depending on what they are: size, format, orientation, location and more.",
                howTo: [
                    "Add up to 10 tests and choose whether all or any of them must match.",
                    "Tests look at the original file, not at the image part-way through the pipeline.",
                    "Fill Then and Else with image steps, a different output or metadata, or Copy original or Skip file.",
                    "Select an image to see in the preview which branch it takes."
                ],
                tips: [
                    "With several conditions, later settings win, and Skip beats Copy.",
                    "Copy original unchanged does not decode the file, so it stays byte for byte the same."
                ])
        case .metadata:
            return StepHelpInfo(
                title: "Metadata",
                summary: "Removes or sets the information stored inside each image, such as location, camera details, author and dates.",
                howTo: [
                    "Remove: strip everything (with a Keep list) or single groups like location or camera details.",
                    "Describe: set title, artist, copyright, description and keywords.",
                    "Date and Location: keep, set or shift the date taken; keep, remove or set the GPS position.",
                    "Templates apply ready-made settings such as Privacy or Web."
                ],
                tips: [
                    "Removals are a floor: a condition's branches can add more, but never bring back what is removed here.",
                    "Orientation and the colour profile are always kept so the picture still looks right."
                ])
        case .rename:
            return StepHelpInfo(
                title: "Rename",
                summary: "Gives each output file a new name built from a pattern with tokens, such as the date, camera or a counter.",
                howTo: [
                    "Type a pattern like {date:yyyy-MM-dd}_{camera}_{counter:000}, or build it with Insert.",
                    "The example line shows the name the first image would get.",
                    "Counter starts at sets the first number; it follows the order of the images.",
                    "Order: pattern, Find and replace, prefix and suffix, spaces, special characters, then upper or lower case."
                ],
                tips: [
                    "Two files with the same name get _2, _3 and so on; nothing is overwritten.",
                    "Rename is not available while Save to is set to overwrite originals."
                ])
        case .output:
            return StepHelpInfo(
                title: "Output",
                summary: "Chooses the file format and quality of the results, and where the converted files are saved.",
                howTo: [
                    "Format: JPEG, PNG, HEIC, TIFF and others macOS can write.",
                    "Compression: a set quality, a target or maximum size, or Smart (lowest quality that still looks the same).",
                    "The line below shows the estimated total size.",
                    "Save to: a new folder, the same folder as each original, or overwrite the originals."
                ],
                tips: [
                    "Overwrite moves the replaced original to the Trash first, so nothing is lost.",
                    "Output is always the last stage, after every step and after Metadata and Rename."
                ])
        }
    }
}
