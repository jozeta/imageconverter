# Milestone 4: Watermark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Watermark image step that stamps text or an image (e.g. a logo) on every image,
with position, size, opacity and margin.

**Architecture:** `ImageOperation.watermark(WatermarkOptions)` is a normal, reorderable image step.
Placement is pure geometry, sized relative to the image's shorter side and clamped to fit inside the
margins. Rendering uses Core Graphics, with Core Text for text. An image watermark is loaded **once
per batch**, through the same untrusted-input loader (pixel guard), and passed to
`Pipeline.apply` as an asset. A missing or unreadable watermark image fails each file with a clear
reason; it never crashes.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, macOS 14+, Core Graphics, Core Text, ImageIO, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-13-imageconverter-design.md`, "Image steps → Watermark" row.

## Global Constraints

- Watermark is **text or image** **(Johan)**. Position: 9-point anchor + margin. Size: relative to the image's shorter side. Opacity: 0–100 %. Text: font and colour.
- **Size rule:**
  - Image watermark: the watermark's **width** = shorter side × size % (default **20 %**).
  - Text: **font size** = shorter side × size % (default **4 %**).
  - Either way, the watermark is then scaled down (never up) to fit inside the image minus the margins on both axes.
- **Margin** = shorter side × margin % (default **3 %**), applied on the anchored edges. Centre-anchored axes get none.
- **Defaults:** anchor bottom right, opacity **65 %**, text `© ` + the user's full name from `NSFullUserName()` when the step is added in the app (Core default `"©"`), font **Helvetica-Bold**, colour white.
- An unknown font name falls back to the system bold font. Empty text makes the step a no-op that returns the same image.
- The watermark never adds transparency to an opaque image and keeps the image's color space and bit depth (the milestone 2 rules).
- A watermark image is untrusted input. It is loaded with `ImageLoader.load` (pixel guard, orientation). If it is missing or unreadable, every file fails with the reason **"Couldn't read the watermark image"**.
- The image path is stored as a plain path string for now. Sandbox bookmarks come in milestone 6.
- UI: Låda Glass only, keyboard accessible, English only, accessibility labels on every control.

## Review Focus

1. **Opaque wide-gamut JPEG with a watermark** → the output is still opaque Display P3. *Test in Task 2.*
2. **Missing, corrupt or oversized watermark image** → each file fails with the stated reason, the batch continues, no crash. *Test in Task 3.*
3. **Text longer than the image, or tiny images (16×16)** → the watermark is scaled to fit inside the margins and never drawn out of bounds. *Tests in Tasks 1 and 2.*
4. **Mixed sizes and orientations in one batch** → the same proportion relative to the shorter side, on the upright image. *Test in Task 3.*
5. **An unknown font name** (from another machine) → falls back to the system bold font, no crash. *Test in Task 2.*

---

### Task 1: Model, summaries and placement geometry

**Files:**
- Create: `Sources/ImageconverterCore/Watermark.swift` (model + geometry)
- Modify: `Sources/ImageconverterCore/Pipeline.swift` (`StepKind.watermark`, `ImageOperation.watermark`, `defaultOperation`), `Sources/ImageconverterCore/StepSummary.swift`, plus any `switch` that must now handle the new case (`apply`, `walk`) with a temporary pass-through until Task 3
- Test: `Tests/ImageconverterCoreTests/WatermarkModelTests.swift`

**Interfaces (public, Codable/Equatable/Sendable, public inits, lenient `init(from:)` with defaults like milestone 3):**
- `enum WatermarkContent { case text(TextWatermark), image(ImageWatermark) }`
- `struct TextWatermark { var text = "©"; var fontName = "Helvetica-Bold"; var color: RGBAColor = .white }`
- `struct ImageWatermark { var path = "" }`
- `struct WatermarkOptions { var content: WatermarkContent = .text(.init()); var anchor: Anchor = .bottomRight; var sizePercent = 4.0; var opacity = 0.65; var marginPercent = 3.0 }`
- `StepKind.watermark`: `displayName` "Watermark", default operation `.watermark(WatermarkOptions())`, last in `allCases`.
- `Geometry.watermarkRect(imageSize: CGSize, contentSize: CGSize, options: WatermarkOptions) -> CGRect?` (top-left origin). It returns nil when the content is empty or zero-sized, or when nothing fits.
  - Target: an image watermark gets width = shorter × size % with its height from the content aspect. Text gets the given `contentSize` scaled so its height = shorter × size %.
  - Then scale down to fit `imageSize` minus the margins on both axes.
  - Then place it with `anchor.origin` inside the inset rect.
  - Clamping: size % to 0…100, opacity to 0…1, margin % to 0…25; NaN becomes the default.
- Summary: `"<text or file name> · <anchor> · <size> %"`, e.g. `© Johan · bottom right · 4 %`, `logo.png · top left · 20 %`. Text is truncated to 20 characters with `…`; an empty image path shows `no image`.

- [ ] **Step 1: Write the failing tests.**
  - `testDefaultsAndSummary`
  - `testCodableRoundTripAndPartialDecode`: `{"content": …}` only, so the rest take defaults.
  - `testImageWatermarkSizedByShorterSide`: image 4000×3000, content 500×250, 20 % → width 600, height 300, at bottom-right with margin 90 → x 3310, y 2610.
  - `testTextScaledByHeight`: shorter side 1000, 4 %, content 300×50 (aspect 6:1) → height 40, width 240.
  - `testTooWideIsScaledDownToFit` (Review Focus 3): image 400×300, text content 3000×50, 10 % → the width fits within 400 − 2 × margin.
  - `testTinyImage`: 16×16 still gives a rect inside the bounds, or nil, never out of bounds.
  - `testCenterAnchorNoMargin`
  - `testNaNAndOutOfRangeClamped`
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass, including the existing step and summary tests.
- [ ] **Step 5: Commit** `feat(core): watermark model and placement`.

---

### Task 2: Rendering

**Files:**
- Modify: `Sources/ImageconverterCore/ImageOps.swift` (add the operation)
- Test: `Tests/ImageconverterCoreTests/WatermarkRenderTests.swift`

**Interfaces:**
- `ImageOps.watermark(_ image: CGImage, _ options: WatermarkOptions, asset: CGImage?) throws -> CGImage`
  - **Text:** build a `CTLine` with the font (`CTFontCreateWithName`; if the resulting font's PostScript name differs from the request, use `CTFontCreateUIFontForLanguage(.emphasizedSystem, …)`). Measure the typographic bounds as the content size. If the text is empty, return the input as is (`===`).
  - **Image:** the `asset` is required. If it is nil, throw `ConversionError.watermarkImageUnreadable`, added in this task with the reason "Couldn't read the watermark image".
  - **Drawing:** a context from `makeContext(like:)` with `alpha: hasAlpha(image)`. Draw the image, then `setAlpha(opacity)`, then draw the content in the rect from `Geometry.watermarkRect` (convert to y-up). If the rect is nil, return the input.

- [ ] **Step 1: Write the failing tests.**
  - `testImageWatermarkLandsBottomRight`: white 400×300 with a red 100×50 asset, 20 %, opacity 1 → a pixel near the bottom-right corner (inside the rect) is red, and the top-left pixel is white.
  - `testOpacityBlends`: opacity 0.5 → the pixel is about (255, 128, 128) ± 3.
  - `testTextDrawsSomething`: black 400×300, white text "TEST", 10 %, bottom left → some non-black pixels in the bottom-left quadrant and none in the top-right.
  - `testEmptyTextIsNoOp` (`===`)
  - `testUnknownFontFallsBack` (Review Focus 5): font "NoSuchFont-XYZ" draws without throwing.
  - `testOpaqueP3StaysOpaqueP3` (Review Focus 1): output color space Display P3, no alpha, and JPEG encode keeps "P3".
  - `testMissingAssetThrows`
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): render text and image watermarks`.

---

### Task 3: Watermark assets in batches

**Files:**
- Modify: `Sources/ImageconverterCore/Pipeline.swift` (`apply(to:assets:)`), `Sources/ImageconverterCore/BatchRunner.swift`
- Create: `Sources/ImageconverterCore/WatermarkAssets.swift`
- Test: `Tests/ImageconverterCoreTests/WatermarkBatchTests.swift`

**Interfaces:**
- `public struct WatermarkAssets: @unchecked Sendable { public static func load(for pipeline: Pipeline, maxPixels: Int) -> WatermarkAssets; public func image(for path: String) -> CGImage? }`
  - It loads each distinct image path used by an **enabled** watermark step, once, with `ImageLoader.load` (pixel guard). Unreadable paths map to nil.
- `Pipeline.apply(to image: CGImage, assets: WatermarkAssets = .empty) throws -> CGImage`. The existing `apply(to:)` keeps working by passing `.empty`.
- `BatchRunner.run` loads the assets once, after planning, before the task group, and passes them to `convert`.

- [ ] **Step 1: Write the failing tests.**
  - `testBatchStampsEveryImage`: 3 images of mixed sizes (800×600, 600×800 and a portrait JPEG with orientation 6) with a red logo, bottom right, 20 %. In each output, the red region's width ≈ 20 % of that image's shorter side (± 2 px), and it lies in the bottom-right quadrant of the upright image (Review Focus 4).
  - `testMissingWatermarkImageFailsEachFile` (Review Focus 2): path to a missing file → 2 inputs give 2 failures, each with the reason "Couldn't read the watermark image", and no outputs.
  - `testCorruptWatermarkImage`: same, with a junk `.png`.
  - `testOversizedWatermarkImage`: `maxPixels` set low in the test → same reason.
  - `testDisabledWatermarkStepIgnoresMissingImage`: a disabled step with a missing path → the run succeeds.
  - `testAssetsLoadedOnce`: two watermark steps with the same path → one entry. Assert through an internal load counter or the dictionary count.
- [ ] **Step 2: Run the tests.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `swift test` twice.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(core): load watermark images once per batch`.

---

### Task 4: Watermark editor and docs

**Files:**
- Modify: `Sources/Imageconverter/StepEditors.swift` (or a new `WatermarkEditor.swift` if the file would pass the lint length), `Sources/Imageconverter/PipelineSection.swift` (adding a watermark step sets the text to `"© " + NSFullUserName()` when that is non-empty), `README.md`, `CHANGELOG.md`, `CLAUDE.md`

**Behaviour:**
- A segmented control: "Text" / "Image". Switching keeps the other kind's last values while the editor is open.
- **Text:**
  - text field;
  - font `Picker` over: Helvetica-Bold, Helvetica, AvenirNext-DemiBold, Georgia-Bold, Menlo-Bold, and "System bold" (stored as `".SystemBold"`, which falls back);
  - `ColorField`.
- **Image:**
  - "Choose image…" button (`NSOpenPanel`, image types, one file), then the file name with a small thumbnail, or "No image chosen" in the warn colour;
  - "Remove" clears the path.
- **Common:** `AnchorPicker`, plus sliders for Size (1–100 %, showing the value), Opacity (0–100 %) and Margin (0–25 %), each with the value as text and an accessibility value.
- **Docs:**
  - README Features and a "Add a watermark" how-to, explaining the size rule (shorter side %) and its defaults. The Configuration table gets the watermark defaults.
  - CHANGELOG Unreleased: "Watermark step: text (font, colour) or image (e.g. a logo), with position, size relative to the image, opacity and margin."
  - CLAUDE.md layout.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** Run `swift build && swift test && swiftlint --strict`. Expected: 0 warnings, all pass, 0 violations.
- [ ] **Step 3: Smoke-launch.** Run `swift run` for 5 s, then kill it and leave nothing running. In the report, list the interactive checks not done.
- [ ] **Step 4: Commit** `feat(app): watermark editor`.
