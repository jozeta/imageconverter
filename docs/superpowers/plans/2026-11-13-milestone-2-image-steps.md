# Milestone 2: Image steps + pipeline UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the converter into a pipeline. Users add resize, crop, rotate/flip, canvas and color
profile steps, switch them on and off, reorder them, and every image in the batch goes through them
in order before it is written.

**Architecture:** A Codable `Pipeline` model (ordered `PipelineStep`s + `OutputSettings`) lives in
Core. The geometry maths (sizes, rects, anchors) are pure functions, tested without images. Each step
is a `CGImage → CGImage` function on Core Graphics contexts that keep the source's color space and
bit depth. `Pipeline.apply` runs the enabled steps in order, and `BatchRunner` takes a `Pipeline`
instead of `OutputSettings`. The runner's window also becomes memory-aware (weighted by pixel count).
The app's sidebar gets an accordion pipeline list (Låda Glass) with toggles, reordering, add/remove
and per-step editors.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, macOS 14+, ImageIO, Core Graphics, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md`. Read "The pipeline → Image
steps", "Main window" and "Tech".

**Out of scope here:** watermark (milestone 4), metadata and rename (3), presets and preview (5),
sandbox and packaging (6).

## Global Constraints

- Apple frameworks only; no network; macOS 14+.
- Image steps can be **reordered** and **switched off without deleting them**. Disabled steps are skipped.
- Resize modes: max width · max height · fit inside box (max width *and* max height) · exact width (height follows aspect) · exact height · exact width × height with **stretch / fit and pad / fill and crop**. "Don't enlarge smaller images" is **on by default** and applies to every mode except stretch.
- Crop: fixed pixel size *or* aspect ratio (UI presets 1:1, 4:5, 3:2, 16:9, custom). Anchor is a 9-point choice, **centre by default**.
- Rotate 90° / 180° / 270° **clockwise**, flip horizontal / vertical (applied after the rotation). Images are already upright from the loader.
- Canvas: equal padding in px *or* % (of the shorter side), *or* extend/clip to a fixed canvas size; anchor; background colour including transparent.
- Color profile: sRGB · Display P3 · Gray (Generic Gray Gamma 2.2) · keep.
- Pixel operations keep the source color space and use 16 bits per component when the source has more than 8; they never silently drop to 8-bit sRGB (except Gray, and the existing JPEG/BMP alpha flatten).
- All sizes are rounded to whole pixels and are at least 1 × 1. Invalid option values (0, negative, NaN) are clamped, never crash.
- UI: Låda Glass components/tokens only, keyboard accessible (reordering must be possible without dragging), English only, every control has an accessibility label.

## Review Focus

1. **Tiny inputs with "don't enlarge"** (a 300 px image, resize max width 1600) → stays 300 px. *Test in Task 2.*
2. **Nonsense option values** (width 0, aspect 0:5, padding −10, NaN percent) → clamped, valid output, no crash. *Tests in Task 2.*
3. **Phone portraits** (EXIF orientation 6) → resize and crop work on the upright image the user sees. *Test in Task 5.*
4. **Wide-gamut / 16-bit sources** (Display P3 16-bit PNG) through resize or crop → keep P3 and 16 bpc. *Test in Task 3.*
5. **Transparency through steps** (transparent PNG, canvas with a transparent background, output PNG) → alpha is preserved. *Test in Task 3.*

---

### Task 1: Pipeline model and step summaries

**Files:**
- Create: `Sources/ImageconverterCore/Pipeline.swift` (model types), `Sources/ImageconverterCore/StepSummary.swift`
- Test: `Tests/ImageconverterCoreTests/PipelineModelTests.swift`

**Interfaces:**
- Produces (all `public`, `Codable, Equatable, Sendable`, with public memberwise inits):
  - `enum Anchor: String, CaseIterable { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }` with `var displayName: String` ("top left", "top", "top right", "left", "center", "right", "bottom left", "bottom", "bottom right")
  - `struct RGBAColor { var red, green, blue, alpha: Double }` (0…1), with `static let white`, `static let black`, `static let clear`
  - `enum ExactFill: String, CaseIterable { case stretch, fitAndPad, fillAndCrop }`
  - `enum ResizeMode { case maxWidth(Int), maxHeight(Int), fitBox(width: Int, height: Int), exactWidth(Int), exactHeight(Int), exactSize(width: Int, height: Int, fill: ExactFill) }`
  - `struct ResizeOptions { var mode: ResizeMode = .maxWidth(1600); var allowEnlarge = false; var padColor: RGBAColor = .white }`
  - `enum CropMode { case size(width: Int, height: Int), aspect(width: Double, height: Double) }`
  - `struct CropOptions { var mode: CropMode = .aspect(width: 1, height: 1); var anchor: Anchor = .center }`
  - `enum Rotation: Int, CaseIterable { case none = 0, cw90 = 90, cw180 = 180, cw270 = 270 }`
  - `struct RotateFlipOptions { var rotation: Rotation = .cw90; var flipHorizontal = false; var flipVertical = false }`
  - `enum CanvasMode { case padding(pixels: Int), paddingPercent(Double), size(width: Int, height: Int) }`
  - `struct CanvasOptions { var mode: CanvasMode = .padding(pixels: 20); var anchor: Anchor = .center; var background: RGBAColor = .white }`
  - `enum ColorProfile: String, CaseIterable { case keep, sRGB, displayP3, gray }` with `displayName` ("Keep original", "sRGB", "Display P3", "Gray")
  - `enum ImageOperation { case resize(ResizeOptions), crop(CropOptions), rotateFlip(RotateFlipOptions), canvas(CanvasOptions), colorProfile(ColorProfile) }` with `var kind: StepKind`
  - `enum StepKind: String, CaseIterable { case resize, crop, rotateFlip, canvas, colorProfile }` with `displayName` ("Resize", "Crop", "Rotate / flip", "Canvas / padding", "Color profile") and `var defaultOperation: ImageOperation` (the defaults above; color profile default `.sRGB`)
  - `struct PipelineStep: Identifiable { var id = UUID(); var isEnabled = true; var operation: ImageOperation }`
  - `struct Pipeline { var schemaVersion = 1; var steps: [PipelineStep] = []; var output = OutputSettings() }`
  - `extension ImageOperation { var summary: String }` in StepSummary.swift; exact strings below

Summary strings (use `×` U+00D7 and a middle dot ` · `):
| Operation | Summary |
|---|---|
| maxWidth(1600) | `max width 1600 px` |
| maxHeight(1200) | `max height 1200 px` |
| fitBox(1600, 1200) | `fit 1600 × 1200` |
| exactWidth(1600) / exactHeight(1200) | `width 1600 px` / `height 1200 px` |
| exactSize(1600, 1200, .stretch / .fitAndPad / .fillAndCrop) | `1600 × 1200 · stretch` / `· pad` / `· crop` |
| crop size(1200, 800), anchor center | `1200 × 800 px · center` |
| crop aspect(4, 5), anchor top | `4:5 · top` (whole numbers print without decimals; 1.91 prints `1.91`) |
| rotateFlip(cw90, flipH) / (none, none) | `90° · flip H` / `no change`; flips: `flip H`, `flip V`, both `flip H+V` |
| canvas padding(20) / paddingPercent(5) / size(2000, 2000) | `+20 px` / `+5 %` / `2000 × 2000` |
| colorProfile | its `displayName` |

- [ ] **Step 1: Write the failing tests.** `testDefaultsPerKind` (each `StepKind.defaultOperation` equals the defaults above). `testPipelineCodableRoundTrip` (a pipeline with one step of every kind, one disabled, non-default values, encode → decode → equal; JSON contains `"schemaVersion":1`). `testSummaries` (one assertion per row of the table). `testAnchorDisplayNames`.
- [ ] **Step 2: Run `swift test --filter PipelineModelTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** the types. Use Swift's synthesized Codable for the enums with associated values.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): pipeline model and step summaries`.

---

### Task 2: Geometry maths (pure)

**Files:**
- Create: `Sources/ImageconverterCore/Geometry.swift`
- Test: `Tests/ImageconverterCoreTests/GeometryTests.swift`

**Interfaces:**
- Consumes: Task 1 types
- Produces:
  - `extension Anchor { public func origin(content: CGSize, container: CGSize) -> CGPoint }`: the top-left of `content` placed in `container`, in **top-left-origin** coordinates (y down); centred offsets use floor
  - `public enum ResizePlan: Equatable { case unchanged, scale(to: CGSize), fitAndPad(content: CGSize, canvas: CGSize), fillAndCrop(scaled: CGSize, crop: CGSize) }`
  - `public enum Geometry`:
    - `static func resizePlan(source: CGSize, options: ResizeOptions) -> ResizePlan`
    - `static func cropRect(source: CGSize, options: CropOptions) -> CGRect` (top-left origin, inside the source)
    - `static func canvas(source: CGSize, options: CanvasOptions) -> (canvas: CGSize, imageOrigin: CGPoint)` (top-left origin; the origin may be negative when a fixed canvas is smaller, which clips)

Rules:
- Rounding: `.rounded()` on each dimension, then at least 1.
- Clamping: any width/height < 1 becomes 1; NaN or negative percent becomes 0; aspect parts ≤ 0 or NaN become 1; negative padding becomes 0.
- Without `allowEnlarge`, a scale factor > 1 is capped at 1 for maxWidth, maxHeight, fitBox, exactWidth, exactHeight, and for fitAndPad's content. In those cases fitAndPad still pads to the full canvas, and fillAndCrop with a factor > 1 crops the unscaled source to at most the target size. Stretch always scales.
- When the result equals the source size, return `.unchanged`.
- Crop: `size` is clamped to the source size. `aspect` gives the largest rect of that ratio that fits the source. Both are positioned by the anchor.
- Canvas: `padding(p)` → canvas = source + 2p on each axis, image at (p, p). `paddingPercent(x)` → p = round(min(w, h) × x / 100). `size` → canvas as given, image placed by the anchor.

- [ ] **Step 1: Write the failing tests** (explicit values):

```swift
func testDontEnlargeSmallImage() {   // Review Focus 1
    XCTAssertEqual(Geometry.resizePlan(source: .init(width: 300, height: 200), options: .init(mode: .maxWidth(1600))), .unchanged)
}
func testMaxWidthKeepsAspect()   // 4000×3000, maxWidth 1600 → scale(to: 1600×1200)
func testFitBoxPicksTighterSide()   // 4000×1000, fitBox 1600×1200 → 1600×400
func testExactSizeModes()   // 4000×3000 → 1000×1000: stretch → scale 1000×1000; fitAndPad → content 1000×750, canvas 1000×1000; fillAndCrop → scaled 1333×1000, crop 1000×1000
func testAllowEnlarge()   // 300×200, maxWidth 600, allowEnlarge → 600×400
func testCropAspectCentered()   // 4000×3000, aspect 1:1 center → rect x 500, y 0, 3000×3000
func testCropSizeClampedAndAnchored()   // 400×300, size 1000×100, anchor bottomRight → x 0, y 200, 400×100
func testCanvasPaddingAndPercent()   // 400×300 pad 20 → 440×340 at (20,20); 5 % → p 15 → 430×330
func testCanvasFixedSmallerClips()   // 400×300, size 200×200 center → canvas 200×200, origin (-100, -50)
func testNonsenseValuesAreClamped() {   // Review Focus 2
    // maxWidth(0) → width 1 (aspect kept, height ≥ 1); aspect(0, 5) → treated as 1:5; padding(-10) → unchanged canvas; paddingPercent(.nan) → unchanged canvas
}
func testAnchorOrigins()   // content 10×10 in 30×30: topLeft (0,0), center (10,10), bottomRight (20,20); content 10×10 in 25×25 center → (7,7)
```

- [ ] **Step 2: Run `swift test --filter GeometryTests`.** Expected: compile failure.
- [ ] **Step 3: Implement** per the rules.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): geometry for resize, crop, canvas and anchors`.

---

### Task 3: Pixel operations (resize, crop, rotate/flip, canvas)

**Files:**
- Create: `Sources/ImageconverterCore/ImageOps.swift`
- Modify: `Sources/ImageconverterCore/ConversionError.swift`: add `case processingFailed(String)` with reason `"Couldn't apply the \(step) step"` (step = `StepKind.displayName`)
- Test: `Tests/ImageconverterCoreTests/ImageOpsTests.swift` (add helpers to `Support/TestImages.swift` as needed: a two-colour image, writing a 16-bit Display P3 PNG)

**Interfaces:**
- Consumes: Tasks 1–2
- Produces: `public enum ImageOps`:
  - `static func resize(_ image: CGImage, _ options: ResizeOptions) throws -> CGImage`
  - `static func crop(_ image: CGImage, _ options: CropOptions) throws -> CGImage`
  - `static func rotateFlip(_ image: CGImage, _ options: RotateFlipOptions) throws -> CGImage`
  - `static func canvas(_ image: CGImage, _ options: CanvasOptions) throws -> CGImage`
  - `static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext?` (internal is fine). It keeps the image's color space (falling back to sRGB if the space can't back a bitmap context) and uses 16 bpc with premultiplied-last alpha when the source has more than 8 bpc, otherwise 8 bpc. Interpolation quality is `.high`.

Notes: Core Graphics contexts are y-up. Convert the top-left-origin rects and points from `Geometry`. A `.unchanged` resize plan returns the input image as is. Crop can use `CGImage.cropping(to:)`. A failed context throws `.processingFailed`.

- [ ] **Step 1: Write the failing tests.**
  - `testResizeDimensions` (4000×3000 maxWidth 1600 → 1600×1200)
  - `testFitAndPadFillsWithPadColor` (a red 400×200 to exactSize 200×200 fitAndPad on white: pixel (100, 5) is white, (100, 100) is red)
  - `testCropTakesAnchoredRegion` (left half red / right half blue, 200×100, crop size 100×100 anchor right → all blue)
  - `testRotate90Clockwise` (left half red / right half blue, 200×100, cw90 → 100×200, top half red, bottom half blue)
  - `testFlipHorizontal` (left red / right blue → left blue)
  - `testCanvasTransparentKeepsAlpha` (Review Focus 5: 10×10 opaque red, padding 5, background `.clear` → 20×20, pixel (1, 1) has alpha 0; encode as PNG and re-read: alpha still 0)
  - `testWideGamut16BitPreserved` (Review Focus 4: a 16-bit Display P3 image through resize and crop → `bitsPerComponent == 16` and the color space name is `CGColorSpace.displayP3`)
- [ ] **Step 2: Run `swift test --filter ImageOpsTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): resize, crop, rotate/flip and canvas operations`.

---

### Task 4: Color profile conversion

**Files:**
- Modify: `Sources/ImageconverterCore/ImageOps.swift` (add the function), `Sources/ImageconverterCore/ImageEncoder.swift` (property sanitising)
- Test: `Tests/ImageconverterCoreTests/ColorProfileTests.swift`

**Interfaces:**
- Consumes: Task 3 (`makeContext`)
- Produces: `static func convertColor(_ image: CGImage, to profile: ColorProfile) throws -> CGImage` on `ImageOps`.
  - `.keep` returns the input as is.
  - `.sRGB` and `.displayP3` draw into a context with that named color space, keeping the bit depth.
  - `.gray` uses `CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)`, 8 bpc, with no alpha (the alpha is flattened onto white first).
- `ImageEncoder` additionally drops the source property keys that describe the old color: `kCGImagePropertyProfileName`, `kCGImagePropertyColorModel`, `kCGImagePropertyDepth`. ImageIO then derives them from the image. Pixel-size keys are already dropped.

- [ ] **Step 1: Write the failing tests.**
  - `testP3ToSRGB`: the output color space name is `CGColorSpace.sRGB`; encode as JPEG, then the re-read `kCGImagePropertyProfileName` contains "sRGB".
  - `testGrayHasGrayModel`: encode as PNG, then `kCGImagePropertyColorModel` is `kCGImagePropertyColorModelGray`. A transparent input gives a white pixel.
  - `testKeepReturnsSameImage` (`===`).
  - `testStaleProfilePropertiesDropped`: pass P3 source properties while encoding an sRGB image, and the written profile name is not "Display P3".
- [ ] **Step 2: Run `swift test --filter ColorProfileTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): color profile conversion`.

---

### Task 5: Apply the pipeline in the batch runner

**Files:**
- Modify: `Sources/ImageconverterCore/Pipeline.swift` (add `apply`), `Sources/ImageconverterCore/BatchRunner.swift`, `Sources/Imageconverter/AppModel.swift` (call-site only: pass `Pipeline(output: output)` for now; the real pipeline state arrives in Task 8), existing `BatchRunnerTests`
- Test: `Tests/ImageconverterCoreTests/PipelineApplyTests.swift`, `BatchRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4
- Produces:
  - `extension Pipeline { public func apply(to image: CGImage) throws -> CGImage }` runs the enabled steps in order, dispatching to `ImageOps`.
  - **Breaking change:** `BatchRunner.run(_ items:, pipeline: Pipeline, mode:, maxPixels:, concurrency:, trash:, progress:)` replaces `output:`. It uses `pipeline.output` for planning and encoding and runs `pipeline.apply` between load and encode.

- [ ] **Step 1: Write the failing tests.**
  - `testDisabledStepsAreSkipped`
  - `testOrderMatters`: on a 400×200 image, crop 1:1 then resize maxWidth 100 → 100×100; resize maxWidth 100 then crop 1:1 → 50×50
  - `testBatchAppliesPipeline`: 3 PNGs of 800×600, resize maxWidth 400, JPEG → each output is 400×300
  - `testPortraitOrientationResizesUprightImage` (Review Focus 3): a JPEG of 400×200 with orientation 6, resize maxWidth 100 → output 100×200
  - Update the existing BatchRunner tests to the new signature.
- [ ] **Step 2: Run `swift test --filter PipelineApplyTests`.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` and `swift build`.** Expected: all pass, the app builds.
- [ ] **Step 5: Commit** `feat(core): run the image pipeline in batches`.

---

### Task 6: Memory-aware scheduling and readable-type filtering (milestone 1 follow-ups)

**Files:**
- Create: `Sources/ImageconverterCore/WorkWindow.swift`
- Modify: `Sources/ImageconverterCore/BatchRunner.swift`, `Sources/ImageconverterCore/ImageLoader.swift` (add a header-only pixel count), `Sources/ImageconverterCore/InputCollector.swift`
- Test: `Tests/ImageconverterCoreTests/WorkWindowTests.swift`, `InputCollectorTests.swift`

**Interfaces:**
- Produces:
  - `public struct WorkWindow { public init(maxItems: Int, maxWeight: Int); public func canStart(weight: Int) -> Bool; public mutating func start(weight: Int); public mutating func finish(weight: Int) }`. `canStart` is true when below `maxItems` and (`inFlightWeight + weight ≤ maxWeight` **or** nothing is in flight), so one oversized item always gets to run alone.
  - `ImageLoader.pixelCount(of url: URL) -> Int?` (header only; nil if unreadable)
  - `BatchRunner.run` gains `memoryBudgetPixels: Int = BatchRunner.defaultMemoryBudgetPixels`, where `defaultMemoryBudgetPixels = Int(ProcessInfo.processInfo.physicalMemory / 4 / 12)`: a quarter of RAM at about 12 bytes per pixel (a decoded copy plus working copies). Items are weighted by their pixel count (unreadable → 1). Scheduling stays in input order, waiting while `!canStart`.
  - `InputCollector` keeps only files whose UTType conforms to `.image` **and** whose identifier (or a supertype) is in `CGImageSourceCopyTypeIdentifiers()`. So `.svg` is ignored, and a broken `.jpg` is still kept.

- [ ] **Step 1: Write the failing tests.**
  - `testWindowLimitsItems`
  - `testWindowLimitsWeight` (budget 100: start 60 → `canStart(50)` false, `canStart(40)` true)
  - `testOversizedItemRunsAlone` (empty window, `canStart(1000)` true; with something in flight it's false)
  - `testFinishFreesWeight`
  - `testSVGIsIgnored` (add `logo.svg` to the collector fixture → not in the result)
  - Batch: `testTinyBudgetStillCompletes` (budget 1, 3 images → 3 written)
- [ ] **Step 2: Run the focused tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` twice** (the cancel test must stay stable). Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): memory-aware batch scheduling; ignore unreadable image types`.

---

### Task 7: Step editors (SwiftUI)

**Files:**
- Create: `Sources/Imageconverter/StepEditors.swift` (one small view per step kind plus `AnchorPicker` and `ColorField`)
- Test: none (UI). All logic it shows comes from Core summaries and types.

**Interfaces:**
- Consumes: Task 1 types
- Produces: `struct StepEditor: View { @Binding var operation: ImageOperation }`, which switches on the kind and shows:
  - **Resize:** a mode `Picker` ("Max width", "Max height", "Fit inside", "Exact width", "Exact height", "Exact size"); number fields (px) for the values that mode needs; for exact size, a fill segmented control ("Stretch", "Pad", "Crop") and, with Pad, a `ColorField` for the pad colour; a "Don't enlarge smaller images" toggle (bound to `!allowEnlarge`).
  - **Crop:** a segmented control ("Aspect", "Size"). For Aspect, a preset `Picker` (1:1, 4:5, 3:2, 16:9, Custom), with two number fields for custom. For Size, width and height fields. Then an `AnchorPicker`.
  - **Rotate / flip:** a rotation segmented control (0°, 90°, 180°, 270°) and toggles "Flip horizontally" and "Flip vertically".
  - **Canvas / padding:** a mode segmented control ("Padding px", "Padding %", "Canvas size"), the matching fields, `AnchorPicker` (for canvas size), and `ColorField` (with a "Transparent" option).
  - **Color profile:** a `Picker` over `ColorProfile.allCases` using `displayName`.
  - `AnchorPicker`: a 3×3 grid of buttons, the selected one highlighted. Each has an accessibility label from `Anchor.displayName`, and arrow keys move the selection.
  - `ColorField`: SwiftUI `ColorPicker` with opacity, converted to and from `RGBAColor` through sRGB components.
  - Number fields use `TextField(value:format: .number)` and clamp to at least 1 (padding at least 0).

- [ ] **Step 1: Implement.** Use Låda Glass tokens and spacing only.
- [ ] **Step 2: Run `swift build && swiftlint --strict`.** Expected: OK, 0 violations.
- [ ] **Step 3: Commit** `feat(app): editors for the image steps`.

---

### Task 8: Pipeline list in the sidebar, persistence and docs

**Files:**
- Create: `Sources/Imageconverter/PipelineSection.swift`
- Modify: `Sources/Imageconverter/AppModel.swift` (`output` becomes `pipeline: Pipeline`; run passes it), `Sources/Imageconverter/SidebarView.swift` (the old Output section becomes the fixed last row of the pipeline section), `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Behaviour:**
- **Section header:** "Pipeline · N steps" (N = enabled steps) with a Collapse/Expand button. Collapsed shows only the header line.
- **Each step** is an accordion row (`DisclosureGroup` styled with Låda Glass): a drag handle, an on/off toggle, the `displayName` and the summary (muted). Expanded, it shows the `StepEditor`. A disabled row is dimmed.
- **Reorder** by dragging *and* from the keyboard: each row has a context menu and a "⋯" menu with "Move Up", "Move Down" and "Remove". Remove has no confirmation; ⌘Z undo is not required this milestone.
- **"+ Add step"** is a `Menu` listing `StepKind.allCases`. The new step uses `defaultOperation`, is appended and starts expanded.
- **Below the image steps:** an "Always last" label, then the Output row (format, quality, TIFF compression, output mode summary). This is the existing output UI moved in.
- **Persistence:** the current pipeline is saved as JSON to `UserDefaults` key `"currentPipeline"` on every change, and restored at launch. An undecodable value is ignored, falling back to an empty pipeline. Presets come in milestone 5; this only keeps your work between launches **(Claude's call)**.
- **Run** passes `model.pipeline` to `BatchRunner.run`.
- **Docs:**
  - README "How to" gains "Build a pipeline" (add, reorder, switch off, step settings), and the Features list marks the image steps as available.
  - CHANGELOG Unreleased: "Pipeline steps: resize, crop, rotate/flip, canvas/padding and color profile; steps can be reordered, switched off and removed; the pipeline is kept between launches. Large images are scheduled by memory use; file types macOS can't read (e.g. SVG) are ignored when adding folders."
  - CLAUDE.md layout: list the new Core and app files.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** Run `swift build && swift test && swiftlint --strict`. Expected: 0 warnings, all pass, 0 violations.
- [ ] **Step 3: Smoke-launch.** Run `swift run` in the background, check it stays alive for 5 s, then kill it. Record in the report which interactive checks were *not* done: adding each step type, drag and keyboard reordering, collapsing, settings surviving a relaunch, and a real batch with resize and crop.
- [ ] **Step 4: Commit** `feat(app): pipeline list with reorderable, toggleable steps`, staging only this task's files.
