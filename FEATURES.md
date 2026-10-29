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
| Hold Space to capture a window | ✅ | ✅ Windows · ☑️ Linux (X11 only) |
| Whole-screen capture, per display | ✅ | ✅ |
| Capture Bar (modes, exact size, aspect lock, timer) | ✅ | ✅ |
| Open menus and Spotlight stay in the capture | ✅ | ☑️ |
| Timed capture (3, 5, 10 s) | ☑️ | ☑️ |
| Arrow-key nudging and resizing of the selection | ☑️ | ☑️ |
| Capture the previous area again | ☑️ | — |
| Scrolling capture | ☑️ | — |
| Hide desktop icons while capturing | ☑️ | — |
| Copy text from the screen (OCR) | ✅ | ✅ English |
| QR code reading | ☑️ | — |

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
| Arrow styles (plain, filled, double, curved) and text styles | ☑️ | — |
| Resize, rotate and flip | ☑️ | — |
| Combine images by dropping them in | ☑️ | — |
| Backgrounds: gradients, own image, padding, corners, shadow, aspect ratio | ✅ | ✅ |
| Copy, save, Drag to share, pin, upload | ✅ | ✅ copy · ☑️ others |
| Editable projects (reopen and change annotations later) | ✅ | ✅ |

## Recording

| Feature | Mac | Windows & Linux |
|---|---|---|
| Record an area or the whole screen | ✅ | ☑️ Windows · ☑️ Linux where WebKitGTK supports screen sharing |
| Microphone and computer audio | ☑️ | ☑️ Windows (computer audio) |
| Stop from the menu bar (red stop button with timer) | ✅ | — |
| Pause, resume, restart, cancel | ☑️ | ☑️ |
| MP4 | ✅ export tested | ☑️ (MP4 or WebM, depending on the system) |
| GIF export | ✅ export tested | — |
| Camera bubble, click and keystroke overlays | ☑️ | — |
| Video editor: trim bar with drag handles, Set In/Out | ✅ | — |
| Video editor: zoom, background, cursor effects | ✅ export tested | — |
| Audio transcription | ☑️ | — |

## Sharing

| Feature | Mac | Windows & Linux |
|---|---|---|
| Upload to your own Still Cloud server and copy the link | ☑️ | ✅ tested against a real server |
| Link expiry, visibility (link, team, private) | ☑️ | ☑️ |
| Still Cloud server: uploads, passwords, expiry, comments, teams, SSO, SCIM | ✅ 13 server tests | (same server) |

## App

| Feature | Mac | Windows & Linux |
|---|---|---|
| Lives in the menu bar / tray, no Dock icon | ✅ | ✅ |
| Menu with icons and shortcuts | ✅ | ✅ |
| Configurable global shortcuts | ✅ | ☑️ |
| Settings: appearance, sounds, export folder, after-capture actions, start at login | ☑️ | ☑️ |
| Automatic updates | ☑️ check, download, verify, relaunch | ☑️ signed updates, install card, About button |
| `still://` actions (Mac) / `still --capture=…` (Windows & Linux) | ☑️ | ✅ |

## Not done yet

- **Windows and Linux:** scrolling capture, the video editor, GIF export, the camera bubble, click and keystroke
  overlays, QR codes, extra arrow and text styles, rotate/flip/resize, combining images and hiding desktop icons.
- **Mac:** Apple notarization (needs a paid Apple Developer account) and custom bitrate presets for recordings.
- **Windows:** code-signed downloads.
- **Windows and Linux:** recording hasn't been checked on real hardware yet.
- **Everywhere:** the ☑️ items above need a hands-on pass.

## How it's checked

- `swift test`: 21 Mac tests covering image processing, redaction, projects, backgrounds, text recognition,
  scrolling stitching and real MP4/GIF exports.
- `cd Desktop && npm test`: JavaScript and Rust tests for selection geometry, the library, settings and image encoding.
- `still --self-test`: runs on real Windows and Linux machines in GitHub Actions and checks capture, the Floating Preview,
  copying, History, the editor, text recognition and uploading to a Still Cloud server.
- `python3 -m unittest discover -s Cloud/tests`: 13 sharing-server tests.
