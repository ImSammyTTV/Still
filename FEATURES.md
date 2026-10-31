# Still features

What Still can do on each platform, and how far each feature has been checked.

| Mark | Meaning |
|---|---|
| ✅ | Built and checked: by an automated test, the self-test on real Windows/Linux machines, or by hand on a Mac |
| ☑️ | Built, but not yet checked by hand or by a test |
| — | Not available on this platform yet |

The Mac app is native Swift. The Windows and Linux app is built with Tauri and shares one code base.

## Capture

| Feature | Mac | Windows & Linux |
|---|---|---|
| Area capture with crosshair, magnifier, size label | ✅ | ✅ |
| Scroll wheel zooms the magnifier (2× to 16×, remembered) | ☑️ | ☑️ |
| Hold Space to capture a window | ✅ | ✅ Windows · ☑️ Linux (X11 only) |
| Whole-screen capture, per display | ✅ | ✅ |
| Capture Bar (modes, exact size, aspect lock, timer) | ✅ | ✅ |
| Open menus and Spotlight stay in the capture | ✅ | ☑️ |
| Timed capture (3, 5, 10 s) | ☑️ | ☑️ |
| Arrow-key nudging and resizing of the selection | ☑️ | ☑️ |
| Escape cancels and Enter confirms, even when another app had focus | ✅ keyboard policy tested | ☑️ Windows takes focus for the overlay; Escape works without it |
| Capture the previous area again | ☑️ | ☑️ |
| Scrolling capture | ☑️ | ☑️ down or sideways, worked out from how you scroll · Auto Scroll stops at the end of the page · off on Wayland |
| Hide desktop icons while capturing | ☑️ | ☑️ Windows · — Linux |
| Copy text from the screen (OCR) | ✅ | ✅ English |
| QR code reading | ☑️ | ☑️ |

## Floating Preview and after capture

| Feature | Mac | Windows & Linux |
|---|---|---|
| Floating Preview with action bar (copy, save, edit, pin, upload, close) | ✅ | ✅ |
| Copies to the clipboard automatically | ✅ | ✅ |
| Closes on its own after 15 s, pauses while hovered | ✅ | ☑️ |
| Drag the capture into another app | ☑️ | ☑️ |
| Save to an export folder, Save As | ☑️ | ☑️ |
| Pinned captures (move, resize, opacity, click-through) | ☑️ | ☑️ |
| Capture History with search, rename, delete | ☑️ | ✅ opens and reopens captures |

## Editor

| Feature | Mac | Windows & Linux |
|---|---|---|
| Tool rail: select, arrow, rectangle, filled rectangle, ellipse, line, pen, highlight, text, counter, redact, blur, pixelate, spotlight, crop | ✅ | ✅ |
| Move, resize, duplicate, delete marks; undo and redo | ✅ | ✅ |
| Solid redaction that survives export | ✅ | ☑️ |
| Arrow styles (plain, filled, double, curved) and text styles | ☑️ | ☑️ |
| Resize, rotate and flip | ☑️ | ☑️ |
| Combine images by dropping them in | ☑️ | ☑️ |
| Backgrounds: gradients, own image, padding, corners, shadow, aspect ratio | ✅ | ✅ |
| Copy, save, Drag to share, pin, upload | ✅ | ✅ copy · ☑️ others |
| Editable projects (reopen and change annotations later) | ✅ | ✅ |

## Recording

| Feature | Mac | Windows & Linux |
|---|---|---|
| Record an area or the whole screen | ✅ | ☑️ Windows · ☑️ Linux, not yet confirmed on real WebKitGTK |
| Windows: Still's own recorder (H.264 MP4, no screen picker, no "sharing your screen" bar, controls kept out of the video) | — | ✅ recorded on a real PC · self-test records 3 s |
| Microphone and computer audio | ☑️ | ✅ Windows: recorded on a real PC, Still's own recorder mixes both into one AAC track · ☑️ Linux: web engine |
| Stop from the menu bar or tray, with a timer | ✅ | ☑️ tray menu · click to stop on Windows |
| Stop with the Start / Stop Recording shortcut, even behind a full-screen app | ☑️ | ☑️ shortcut shown on the Stop button |
| Recording kept if something goes wrong: written to disk as it records, saved if the controls stop responding, a message instead of silence | (native recorder) | ☑️ MP4 falls back to WebM automatically |
| Pause, resume, restart, cancel | ☑️ | ☑️ |
| MP4 | ✅ export tested | ☑️ (MP4 or WebM, depending on the system) |
| GIF export | ✅ export tested | ☑️ up to 60 s and 1280 px |
| Recording quality (High, Balanced, Smaller File, named bitrate presets, or a bitrate you choose) | ☑️ | ☑️ custom bitrates and presets from 1 to 100 Mbit/s, stored as the Mac stores them |
| Camera bubble, click and keystroke overlays | ☑️ | ☑️ Windows · ☑️ Linux on X11 (camera also on Wayland; clicks and keys are off there) |
| Video editor: trim bar with drag handles, Set In/Out, trim points kept with the recording | ✅ | ☑️ trimmed exports re-encode in real time; untrimmed exports are exact copies |
| Video editor: background (gradients, padding, corners, shadow) | ✅ export tested | ☑️ gradients or your own picture · video and GIF exports checked in Chromium |
| Video editor: zooms (Add Zoom, Auto Zoom on recorded clicks) and click rings | ✅ export tested | ☑️ checked in Chromium · the pointer's path and clicks are noted while recording on Windows and on Linux with X11, not Wayland |
| Video editor: cursor size and smoothing | ✅ export tested | ☑️ Windows, with Settings → Recording → Cursor effects: the pointer is left out of the recording and drawn from its path · Linux: the pointer is part of the picture |
| Audio transcription | ☑️ | — |

## Sharing

| Feature | Mac | Windows & Linux |
|---|---|---|
| Upload to your own Still Cloud server and copy the link | ☑️ | ✅ tested against a real server |
| Link expiry, visibility (link, team, private) | ☑️ | ☑️ |
| Save to iCloud Drive (no share link) | ☑️ | ☑️ Windows with iCloud for Windows · — Linux |
| Upload to Google Drive and copy the link | ☑️ needs a sign-in client ([setup](docs/GOOGLE-DRIVE.md)) | ☑️ needs a sign-in client |
| Still Cloud server: uploads, passwords, expiry, comments, teams, SSO, SCIM | ✅ 14 server tests | (same server) |

## App

| Feature | Mac | Windows & Linux |
|---|---|---|
| Lives in the menu bar / tray, no Dock icon | ✅ | ✅ |
| Menu with icons and shortcuts | ✅ | ✅ |
| Configurable global shortcuts | ✅ | ☑️ |
| Settings: appearance, sounds, export folder, after-capture actions, start at login | ☑️ | ☑️ |
| Setup assistant for the first capture; leaves Settings once finished, reopens from General | ☑️ | ☑️ |
| Automatic updates | ☑️ check, download, verify, relaunch | ☑️ signed updates, install card, About button |
| `still://` actions (Mac) / `still --capture=…` (Windows & Linux) | ☑️ | ✅ |
| Right-click Services for images: Open in Still, Copy Text from Image, Pin Image | ☑️ | — |

## Not done yet

- **Windows and Linux:** audio transcription, and cursor styles other than the arrow. Linux can't hide desktop icons.
- **Mac:** Apple notarization (needs a paid Apple Developer account).
- **Windows:** code-signed downloads.
- **Windows:** "N" editions without the Media Feature Pack can't use Still's own recorder, so they record with the
  system web engine, which asks for a screen and shows its "sharing your screen" bar.
- **Windows and Linux:** recording needs a hands-on pass on real hardware after the 1.2.11 fixes.
- **Everywhere:** the ☑️ items above need a hands-on pass.

## How it's checked

- `swift test`: 40 Mac tests covering image processing, redaction, projects, backgrounds, text recognition,
  scrolling stitching and real MP4/GIF exports.
- `cd Desktop && npm test`: JavaScript and Rust tests for selection geometry, the library, settings and image encoding,
  plus a design check that fails when a page uses raw colours or text smaller than 10 px
  ([design system](docs/DESIGN-SYSTEM.md)).
- `still --self-test`: runs on real Windows and Linux machines in GitHub Actions and checks capture, the Floating Preview,
  copying, History, the editor, capturing the previous area, scrolling capture, hiding desktop icons, the camera bubble
  and click and keystroke overlays, text recognition and uploading to a Still Cloud server.
- `python3 -m unittest discover -s Cloud/tests`: 14 sharing-server tests.
