# Hand-test checklist (milestone 6)

What the agents could not click or watch. Run it on the packaged, sandboxed app unless a section says
otherwise:

```sh
scripts/release.sh                 # builds dist/imageconverter.app (ad hoc signed, sandboxed)
open dist/imageconverter.app
```

Use a scratch folder with copies of a few photos (a large JPEG, a PNG with transparency, a HEIC, an
image with GPS data) and an empty output folder. Each item: **steps**, then **expected**. Tick it or note what
happened.

Already checked by an agent in the sandboxed bundle (2026-11-14, see
`.superpowers/sdd/2026-11-14-milestone-6-packaging/task-5-report.md`): launch, `imageconverter://` links and their
sheets, document open with `open -a` (running and cold launch), Services registration and "Convert with
imageconverter" / "Convert with Preset 1" called programmatically, the pre-filled folder-access panel appearing,
writing into a folder opened with the app, presets in the container read by the app and the CLI.

Ad hoc builds: an app-scoped bookmark belongs to the app's signature. After rebuilding with `release.sh` the
remembered folders may show "Allow again". Test relaunch behaviour **without rebuilding in between**.

## 1. Window, animation and handles

- [ ] **Preview handle.** Click the small handle on the border between sidebar and preview, then click it again.
  Expected: the preview slides closed and the window shrinks to the sidebar in one smooth motion, then slides
  open again. The handle stays under the pointer. ⌥⌘P does the same.
- [ ] **Pipeline collapse.** Click the handle under the drop zone (⌥⌘L). Expected: the pipeline folds away and the
  window height follows in one ease-in-out motion, with no jump, flicker or scrollbar flash. Expand again.
- [ ] **Window height animation.** Add a step, open it, close it, remove it; switch Save to between New folder,
  Same folder and Overwrite. Expected: each change animates the window edge and content together.
- [ ] **Resizable expanded window.** With the pipeline expanded, drag the bottom edge down, then up. Expected: extra
  height appears between the last step and Output, and Output and Run stay at the bottom with a small gap above
  Output. A shorter window scrolls the steps. Quit and reopen: the height is kept. Collapsed, the window fits
  the content exactly and can't be resized vertically.
- [ ] **Hover help.** Rest the pointer on a step title (Resize, Metadata, Rename, Output, If … then … else) for
  1.5 s. Expected: a box with what it does, how to use it and tips. It closes when the pointer leaves, and on
  click, scroll or Escape, and never takes keyboard focus.
- [ ] **No images.** With an empty batch: Run, Clear, the Compare picker, the View menu's compare and zoom items
  and the privacy chip are disabled or hidden. Adding steps and choosing presets still work.
- [ ] **About.** App menu ▸ About imageconverter. Expected: the icon, version 0.1.0 (the same as `VERSION`) and
  build number, the licence, and a Privacy button.

## 2. Drag and drop

- [ ] **Drop on the drop zone.** Drag three images and a folder from Finder onto the drop zone. Expected: they
  are added (the folder recursively) and each file is listed once.
- [ ] **Drop anywhere.** Drag a file over the preview area. Expected: a soft accent border and tint with "Drop
  images or folders to add them". Dropping adds the file. During a run the overlay doesn't appear and nothing is
  added; **Add…** and File ▸ Add Images… are disabled too.
- [ ] **Drop on a step row.** Open a step and drag an image file from Finder onto that step's row (and onto an
  action row inside an If … then … else). Expected: the file is added, as anywhere else in the window, and the
  steps don't move.
- [ ] **Dock icon.** Drag images and a folder onto imageconverter's Dock icon, with the app running and with it
  quit. Expected: they are added to the batch in the main window, which comes to the front. **No extra empty
  window opens** (this was the bug fixed in Task 5).
- [ ] **Finder Open With.** Right-click an image ▸ Open With ▸ imageconverter. Expected: added like a Dock drop.
  imageconverter is listed but has not become the default app for images (double-clicking a JPEG still opens
  Preview).
- [ ] **Step reorder.** Drag a pipeline step by its row onto another step. Expected: it moves there. Dragging a
  step never adds files, and the window-wide drop overlay doesn't appear.
- [ ] **Split divider and grid bar.** In Split compare, drag the divider; in Grid, drag the bar on top to make
  the area taller. Expected: both follow the pointer, and the split position is remembered.

## 3. Zoom and pan

- [ ] **Pinch.** Pinch on the before image in Side by side. Expected: both sides zoom around the pinch point and
  show the same region. The level shows next to "Preview" (up to 800 %).
- [ ] **Pan.** Two-finger scroll and mouse-drag while zoomed. Expected: both sides pan together.
- [ ] **Double-click.** Double-click a point. Expected: it toggles between fit and 100 % at that point.
- [ ] **Keyboard.** ⌘+, ⌘=, ⌘−, ⌘0, ⌥⌘0. Expected: zoom in, out, fit and actual size.
- [ ] **Encoded artifacts.** Set JPEG quality 10 %, zoom to 400 %. Expected: once the estimate is ready, the
  after side shows real JPEG blocks without smoothing.
- [ ] **Other modes.** Repeat pinch and pan in Split, Difference ("visible region" after zooming) and Single
  (hold Space over the image, or press B, to see Before).
- [ ] **Compare quality.** Compare quality… while zoomed. Expected: four tiles of the visible region with sizes.
  Clicking one sets that quality.

## 4. Editors and sliders

- [ ] **Adjust.** Drag each Adjust slider, then double-click it. Expected: it resets to 0, and the filled track
  is blue only while the value is not 0.
- [ ] **Resize presets.** Resize ▸ Presets menu: the groups (Print, Web, Devices, App & web assets, Social media,
  Resolutions). Pick a Print size. Expected: Print sheet mode at 300 dpi, fitted in the image's own orientation.
- [ ] **Watermark.** Add a text watermark, use Insert ▸ `{filename}`, drag the opacity, size, rotation, spacing
  and shadow sliders. Expected: the preview follows about 300 ms after you stop. Then choose an image watermark
  (PNG and SVG) with the file picker.
- [ ] **Conditions.** Add If … then … else, pick checks from each group, toggle **Not**, and type an invalid regular
  expression. Expected: it is marked in the editor and never matches. Add a "Save into subfolder" action with a
  token and check the preview name.
- [ ] **Rename.** Type a template with tokens. Expected: the live example below it updates.
- [ ] **Metadata.** Custom fields, the date editor and the templates menu (save, apply, delete).
- [ ] **Keyboard.** Tab through a step editor. Expected: every control is reachable with a visible focus ring.

## 5. Sheets and confirmations

- [ ] **Clear All.** More ▸ Clear All…. Expected: "Clear all images and pipeline steps?". Cancel keeps
  everything. Confirm empties the batch, resets the pipeline to "None (ad hoc)" and keeps presets and Save to.
- [ ] **Overwrite warning.** Switch Save to to Overwrite original files. Expected: a warning appears once, when
  selecting it, never at run time.
- [ ] **Links.** In Safari's address bar, open `imageconverter://preset?name=Web%20export`, then an `add?path=…`
  link for a file inside an allowed folder. Expected: a sheet says exactly what will happen. Escape and Cancel
  decline, and Return does **not** confirm. A second link while a sheet is open is dropped and counted in one
  toast afterwards.
- [ ] **Interrupted batch.** Start a large run and force-quit the app (Activity Monitor). Relaunch. Expected: the
  interrupted-batch sheet with Resume and Not Now. For overwrite, **Replace the original files** must be ticked.
  Not Now keeps it, and Run then asks "Discard the interrupted batch?".
- [ ] **Stop and quit.** Start a long run and press ⌘Q. Expected: "Stop and quit?" with Cancel as the default.
  Stopping keeps finished files and leaves no temp files in the output folder.
- [ ] **Unsaved preset.** Change a step of a selected preset and switch presets. Expected: "Discard changes to
  …?" before switching.

## 6. Folder access in the sandboxed bundle

Start with Help ▸ Folder Access… ▸ Remove All.

- [ ] **Output folder prompt.** Save to: New folder, choose an output folder with Choose folder…, add images,
  Run. Expected: no prompt (the panel already gave access), and files are written.
- [ ] **Same folder prompt.** Add images by **Add…** (files, not their folder), set Save to: Same folder, Run.
  Expected: an open panel already showing the images' folder, with "imageconverter needs access to “…” to save
  next to the originals. Choose this folder (or one that contains it) to allow it." and an **Allow** button.
  Allow, and the files are written. Run again: no prompt.
- [ ] **Wrong folder.** In that panel choose an unrelated folder. Expected: it asks again, starting "The folder you
  chose doesn't contain …". Cancel: "Not run: no access to …" and nothing written.
- [ ] **Remembered after relaunch.** Quit, reopen (don't rebuild) and repeat the Same-folder run. Expected: no
  prompt. Help ▸ Folder Access… lists the folder without "Allow again".
- [ ] **Output folder after relaunch.** Quit and reopen, then run New folder again. Expected: no prompt, written.
- [ ] **Dropped folder.** Drop a folder, Same folder mode, Run. Expected: no prompt in this session.
- [ ] **Add Folder….** Folder Access ▸ Add Folder…, choose a folder. Expected: it is listed. A link
  `imageconverter://add?path=<a file in it>` is now accepted, while a file outside any allowed folder gives
  "Ignored a link" with the sandbox explanation.
- [ ] **Watermark image after relaunch.** Choose a PNG watermark from a folder that isn't allowed, save the preset,
  quit, reopen, select the preset and run. Expected: the watermark is applied, with no "Couldn't open the watermark
  image — choose it again".
- [ ] **Preset applied by a condition.** Make preset A with an image watermark (chosen in this sandboxed app) and
  save it. In preset B add If … then Apply preset A. Quit, reopen, run B. Expected: the watermark from A is
  applied. A preset saved by the unsandboxed `swift run` app and imported here will probably report "Couldn't open
  the watermark image — choose it again" (its bookmark belongs to another app). Note which one you see.
- [ ] **Jobs.** Create a watch job with input and output folders chosen in the job editor. Quit, reopen. Expected:
  the job is still Watching and converts a newly copied file.
- [ ] **Remove during a run.** Start a long run, open Help ▸ Folder Access…. Expected: Remove and Remove All are
  disabled with "Folders can't be removed while a batch or a job is running." They work again after the run.
- [ ] **Output folder chosen again.** Choose the same output folder again with Choose folder…, quit, reopen, Run.
  Expected: no prompt.

### 6a. Overwrite with rename (sandboxed)

Prepare a folder `Shoot` (not allowed yet: Remove All first) with `a.jpg`, `b.jpg` and an unrelated file
`a_web.heic`.

- [ ] **Rename + new format.** Add `a.jpg` and `b.jpg` with **Add…** (files, not the folder). Save to: Overwrite
  original files; add a Rename step `{name}_web`; Format HEIC; Run. Expected:
  - the folder prompt once, "… to replace the originals", Allow;
  - `b_web.heic` is saved and `b.jpg` is in the Trash (Finder ▸ Trash ▸ Put Back works);
  - `a.jpg` becomes `a_web_2.heic` (the unrelated `a_web.heic` is untouched) and `a.jpg` is in the Trash;
  - the report's destinations show the new names.
- [ ] **Trash fails.** Copy a fresh `c.jpg` into `Shoot`, lock it (`chflags uchg Shoot/c.jpg`), run the same
  pipeline on it. Expected: `c_web.heic` is saved and the file is listed as written with "Converted, but couldn't
  move the original to the Trash: …" (not as failed). Unlock it afterwards (`chflags nouchg`).
- [ ] **Job, no multiplying.** Make a watch job on `Shoot` with that pipeline in Overwrite mode, let it run once,
  then Run Now again. Expected: the second run converts nothing new: no `*_web_web*` or extra `_2` files appear,
  and the outputs aren't picked up as new inputs.

### 6b. Resume in the sandbox

- [ ] **Same folder.** Interrupt a Same-folder run (force quit), reopen, Resume. Expected: it continues without
  asking, or asks only for a folder that didn't reopen.
- [ ] **Loose files, New folder.** Remove All, then add 30 images with **Add…** (files, not their folder) from a
  folder that isn't allowed, Save to: New folder, Run, force quit half-way. Reopen (don't rebuild), Resume.
  Expected: no prompt, and the remaining images are converted (they were reopened through their own bookmarks).
- [ ] **Resume asks.** Repeat, but make the journal's bookmarks stop working before reopening: rebuild with
  `release.sh` (the ad hoc signature changes, so the old bookmarks no longer open), reopen, Resume. Expected:
  before anything runs, an open panel asks for the images' folder "… to read the images". Allow: the remaining
  images run. Repeat and Cancel: a toast "N files of the interrupted batch couldn't be opened" lists them; none is
  reported as missing and nothing is dropped silently.
- [ ] **Crash between save and Trash.** (Optional, hard to time.) Overwrite + Rename, force quit during the run,
  Resume. Expected: at worst one image exists as `name` and `name_2`, with its original in the Trash; nothing is
  lost.

## 7. Finder Services (Quick Actions)

Run `/System/Library/CoreServices/pbs -update` once after building (or log out and in).

- [ ] **Menu.** Right-click images in Finder ▸ Quick Actions (or Services). Expected: "imageconverter ▸ Convert
  with imageconverter" and "Convert with Preset 1…5". Folders also show them, PDFs don't.
- [ ] **Convert with imageconverter.** Expected: the selection is added to the batch and the window comes forward.
  Nothing runs.
- [ ] **Pinned preset.** Pin a preset (More ▸ Show in Finder Quick Actions), use "Convert with Preset n" on
  images. Expected: "Converting n with …" and files written per Save to. In Same folder mode the folder is asked
  for once. In Overwrite mode it asks "Replace n original images?" first.
- [ ] **Empty slot.** Use a slot with no preset. Expected: the hint "No preset for Convert with Preset n".
- [ ] **App not running.** Quit the app, use a Quick Action. Expected: it launches with one window and does the
  same.

## 8. AppleScript

The first script makes macOS ask whether Script Editor (or Terminal) may control imageconverter. Click OK.
Agents couldn't do this: the prompt was left open on the screen during Task 5, so if a stale
"iTerm wants access to control imageconverter" prompt is showing, answer it either way.

- [ ] `tell application "imageconverter" to presets`. Expected: the built-in and saved preset names.
- [ ] `tell application "imageconverter" to add files {POSIX file "<allowed folder>/a.jpg"}`. Expected: added.
  A file outside allowed folders: an error "… doesn't exist or can't be read. The sandboxed app can only use files
  and folders you gave it …".
- [ ] `convert {POSIX file "<allowed>/a.jpg"} using preset "Web export" to folder POSIX file "<not allowed>"`.
  Expected: an error "… isn't a folder you can write to." plus the sandbox explanation, and nothing written. With
  an allowed `to folder`, it returns the written files.
- [ ] `run batch` in Overwrite mode. Expected: a confirmation sheet in the app first. Cancel returns an error to
  the script.

## 9. Menu bar mode

- [ ] Jobs window ▸ **Keep running in the menu bar when the window is closed**. Close all windows. Expected: the
  Dock icon goes away and a menu bar item remains (photo stack icon, arrows while a job runs).
- [ ] The menu shows job status, Pause All Jobs, Open imageconverter, Jobs…, Quit. **Open imageconverter** brings
  back the main window (and the Dock icon). It is the existing window, not a second one.
- [ ] Switch the setting off. Expected: the menu bar item disappears.

## 10. Notifications

- [ ] Switch on a watched job for the first time. Expected: macOS asks whether imageconverter may send
  notifications. Allow.
- [ ] Copy images into the watched folder. Expected: one notification per run ("… converted"), at most one per
  job per minute. A failing file (a renamed `.txt` → `.jpg`) gives a failure notification.
- [ ] Run Now. Expected: the result shows as a toast in the main window, not as a notification.
- [ ] Deny notifications in System Settings. Expected: jobs still run, with no errors.

## 11. Jobs watching

- [ ] **Catch-up.** Create a watch job on a folder with images in it. Expected: they are processed at once (the
  catch-up run), then each new image after it has finished copying (unchanged for 2 s).
- [ ] **Large copy.** Copy a large file slowly (from a network share or an SD card). Expected: it is processed once,
  after the copy ends.
- [ ] **Follow-up run.** Drop more files during a run. Expected: one follow-up run afterwards. The status shows
  *Running 3/12*, then *Watching*.
- [ ] **Rename the folder.** Rename the watched folder in Finder. Expected: the job follows it, and already processed
  files aren't converted again.
- [ ] **Delete the folder.** Expected: the job switches off with "The input folder “…” can't be found."
- [ ] **Schedule.** Every 5 minutes. Expected: new images are picked up at the next tick.
- [ ] **Pause All.** Expected: watchers and schedules stop until it is switched off. A run in progress finishes.
- [ ] **Report.** Open Last Report. Expected: the CSV is next to the outputs, with paths relative to its folder.
- [ ] **Other runs.** Run a job while a big batch runs in the main window. Expected: the window stays responsive, and
  a file busy in one run is listed as *Busy in another run* in the other.

## 12. Feature round 1.1 (lossless edits, When finished, extra outputs)

- [ ] **Lossless edit.** A pipeline with only Metadata (remove location), JPEG output, on a JPEG from a camera or
  phone. Expected: the report says *Metadata only, pixels untouched*; the Privacy panel on the output shows no
  location and no embedded thumbnail; Preview shows the image unchanged and correctly rotated.
- [ ] **iPhone HEIC.** The same on an iPhone HEIC. Expected: usually re-encoded with a note (thumbnail or depth data),
  never an error.
- [ ] **When finished: Reveal.** Set *When finished* to reveal outputs, run a batch. Expected: Finder opens with the
  written files selected (extra outputs included).
- [ ] **When finished: Notify.** Set it to notify, start a batch, switch to another app. Expected: one notification
  with the count; clicking it brings the main window forward with the Report open. A cancelled run says *Run
  cancelled · converted N*; a run where every file fails says *No images converted · N failed*.
- [ ] **Notifications denied.** Deny notifications in System Settings, come back to the app. Expected: the hint
  under *When finished* appears without restarting.
- [ ] **Extra outputs.** In the Output panel, *+ Add output* twice (e.g. a 400 px JPEG thumbnail and a PNG).
  Expected: the size line lists each output, the preview table shows *+2 outputs* with the list on hover, and a run
  writes `<name>_thumb.jpg` etc. beside the main output.
- [ ] **Suffix errors.** Clear one extra output's suffix, then give two the same suffix. Expected: an inline error
  each time and Run disabled until fixed.
- [ ] **Overwrite with extras.** Overwrite mode plus one extra output and a format change. Expected: the original
  goes to the Trash once, the main output and the extra sit in the source folder, nothing else is trashed.

## 13. Vision features (smart crop, content conditions, Redact, ML enlarge, alt text)

On the packaged, sandboxed app unless noted. None of these can be automated: the tests use fake Vision detectors and
fake models, and never run the real ML enlarge or alt text model.

**Smart crop**
- [ ] **Subject and faces.** Crop 1:1 with Focus *Subject*, then *Faces*, on an off-centre portrait and a group photo.
  Expected: the crop lands on the subject or on all the faces.
- [ ] **Fallbacks.** A landscape with no faces, Focus *Faces*. Expected: cropped around the subject with the note
  "No faces found; cropped around the subject" (or the centre, with its note).

**Content conditions**
- [ ] **Shows, faces, text.** *Shows* "dog", *Face count* and *Contains text* pick the right branch on real photos;
  the label picker's search works.
- [ ] **Shows without labels.** Add a *Shows* check and choose no labels. Expected: the red line under it and Run
  disabled (also ⌘R), with a tooltip; choosing a label enables Run.
- [ ] **{labels}.** `{labels}` in a subfolder and in Finder tags gives real words.
- [ ] **macOS 14 or 15** (if a Mac is available). On macOS 14 the Aesthetics and Screenshot kinds can't be picked
  in the kind menu, and a preset that has one gets the "needs macOS 15" note once per run; a pipeline without them
  never shows that note.

**Redact**
- [ ] **Coverage.** Faces and text on real photos: a street sign, a document photo, a group photo, a rotated EXIF-6
  photo, and after a Crop and a Resize. Expected: the boxes cover the right pixels.
- [ ] **Strength.** Pixelate and blur hide the text and the faces well enough that a person can't read or recognise
  them. Text defaults to a solid fill.
- [ ] **Privacy panel.** The "Also look for faces and text" switch, the counts, and **Add a Redact step**.

**ML enlarge**
- [ ] **Consent and download.** On a Mac where the model is missing: the consent alert wording, then
  **Download…**. Watch Little Snitch or the network: only Apple hosts, and only after the button. Progress, then
  ready.
- [ ] **Tiles.** A 4× result on a 1921 px or larger image looks seamless.
- [ ] **Model missing in jobs and the CLI.** A job and a CLI run with the model missing say "Not enlarged… Open
  imageconverter…", and the job retries after the download (it doesn't give up).
- [ ] **Memory.** Activity Monitor during a 4× batch of 12 MP photos, and while editing with the preview and the size
  estimate open: editing a later step (an Adjust slider, the quality) doesn't run the model again.

**Alt text** (needs an Apple Intelligence Mac on macOS 27 with the model ready)
- [ ] **Sentences.** Real sentences: length, no "image of", no names, no copied text (a sign, a licence plate, a
  document). Emoji in the output survive.
- [ ] **Latency.** Real time per image, and a 20-image batch at default concurrency: how many get "no answer within
  30 seconds"? (Expected none on a healthy model: an image's 30 s start at its turn.)
- [ ] **Together.** A manual batch and a job running together with alt text: no app-wide stall, the preview stays
  responsive, and its alt text row answers ahead of the waiting batch images.
- [ ] **Cancel.** Cancel mid-batch: it stops within about a second.
- [ ] **Background.** The app in the background or in menu-bar mode during a job: does FoundationModels rate-limit
  (notes say "the model was busy")?
- [ ] **Preview edits.** Drag an Adjust slider while a job generates: do batch items get "busy" notes?
- [ ] **Not responding.** If the model ever hangs: after three timeouts in a row the rest get "Alt text not
  generated: the on-device model stopped responding" at once, and the preview says the same, until a restart.
- [ ] **Apple Intelligence off, then on.** The editor's reason updates the next time it appears.
- [ ] **Readers.** Exported XMP read by Photoshop, Lightroom or exiftool (`Iptc4xmpCore:AltTextAccessibility`,
  lang-alt x-default). A screen reader (VoiceOver in Preview, a CMS import) picks it up.

**Cross-feature**
- [ ] **One pipeline.** Crop (Faces) → Redact (faces and text) → Resize ML 2× → Metadata alt text on 10 photos plus
  one extra output. Expected: report notes in order, extras redacted, alt text present, no face regions in XMP.
- [ ] **Branches.** A condition branch that adds Redact through a preset, with Copy original on the other branch.
  Expected: the preset branch's images are redacted; the copy branch's are copied unchanged. With a Redact step in the
  main pipeline too, the copies are converted with it instead ("Converted to redact: …"), and a preset's other image
  steps on a copy branch are named ("Not applied to the converted copy: …").
