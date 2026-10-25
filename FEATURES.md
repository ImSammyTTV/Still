# Still feature coverage

Still’s implementation and verification checklist. This file tracks local functionality, automated coverage and the checks that require system permissions, connected hardware or a deployed service.

Status meanings: **implemented** means code exists; **verified** means an automated or live check passed; **in progress** is incomplete; **pending** has not been implemented. No row implies exact parity until its detailed interaction checks pass.

| Area | Requirement | Status |
| --- | --- | --- |
| Interface | Menu-bar-first app; compact All-in-One capture bar | in progress |
| Interface | Native native preferences and sidebar | in progress |
| Interface | Compact editor toolbar and bottom quick actions | in progress |
| Interface | Light and dark appearance | in progress |
| Capture | Area, window, fullscreen, timer, Escape cancellation | implemented; permission-dependent live checks pending |
| Capture | Previous selection, dimensions and aspect lock | in progress |
| Capture | Crosshair, magnifier, freeze screen | in progress |
| Capture | Multi-display capture | in progress |
| Capture | Vertical and horizontal scrolling capture | in progress |
| Capture | Desktop-icon hiding and custom wallpaper | implemented; live checks pending |
| Overlay | Copy, save, annotate, pin, drag and dismiss | implemented; live checks pending |
| Overlay | Position, size, auto-close, restore, hide all | implemented; hover-aware timeout |
| Annotate | Select, move, resize, duplicate, delete | in progress |
| Annotate | Four arrow styles, line, shapes, filled rectangle | in progress |
| Annotate | Pencil, highlight, counter, seven text styles | in progress |
| Annotate | Solid redaction | verified: opaque pixels after PNG encoding |
| Annotate | Blur, pixelate and spotlight | in progress |
| Annotate | Crop and resize, rotate and flip | in progress |
| Annotate | Combine images by drag and drop | in progress |
| Annotate | Editable project files and history sidecars | in progress; independent `.stillshot` format |
| Annotate | Undo and redo | verified for basic marks and crop |
| Background | Twenty backgrounds, custom image, presets | in progress |
| Background | Padding, corner radius, shadow, aspect ratio | in progress |
| Background | Alignment and Auto Balance | implemented; aspect/alignment export test passed |
| OCR | On-device text recognition | verified by rendered text fixture |
| OCR | QR codes, language choice, line-break handling | implemented; live checks pending |
| Pin | Resize, opacity, arrow positioning, click-through lock | implemented; live checks pending |
| History | Restore, filters and retention | implemented; rename and cloud actions included; retention defaults forever and moves expired library files to Trash on the next capture |
| Recording | Window/display picker, H.264 MP4, cursor, mic/system audio | implemented; permission-dependent live checks pending |
| Recording | Area recording, FPS, quality, resolution and GIF | area/FPS/resolution/GIF implemented; custom bitrate quality pending |
| Recording | Pause/resume, camera, clicks and keystrokes | implemented; segment joining/alignment tested offline; hardware tests pending |
| Recording | Recording timer and stop controls | implemented; live checks pending |
| Video editor | Playback, trim and background | implemented; real MP4/GIF export tests passed |
| Video editor | Zooms, cursor metadata, smooth cursor and motion blur | implemented; compositor export test passed; interaction checks pending |
| Settings | Configurable shortcuts, filenames, after-capture actions | implemented; live capture checks pending |
| Settings | Login item, menu visibility, sounds and export defaults | in progress |
| Automation | URL scheme actions | implemented; registered still:// actions; live checks pending |
| Cloud | Uploads, links, access control, expiry, comments and tags | implemented independently; 11 server tests passed; viewer/comment browser smoke test passed |
| Cloud | Transcription, custom domains and team management | on-device transcription UI implemented, hardware/language assets unverified; team API tested; deployment example supplied, no remote host deployed |
| Distribution | Signed local Apple-silicon app | implemented |
| Distribution | Apple notarization and universal binary | pending; requires appropriate signing credentials/toolchain |

Public hosting, identity-provider integration and enterprise certifications require independent setup and validation. Local functionality can be built and tested without deploying a service.

## Remaining verification and interaction gaps

- The rebuilt binary still needs user-granted Screen Recording access. Screen/window/area capture, scrolling in actual applications, live audio/camera, keys and pause/resume remain unverified on this Mac.
- Exact pixel and interaction parity is not established. Native preferences, editor drawing/undo and background sheet were visually checked against official reference media.
- Multi-screen selection spanning displays, reverse scrolling, sticky/animated page handling and detailed keyboard-selection behavior need further work.
- Video redo, editable curved-arrow handles, text-height highlighting and camera/microphone device selection are implemented; live interaction checks remain. Explicit bitrate presets are incomplete.
- Speech transcription depends on locally installed Apple speech assets and has not been exercised with user audio.
- OIDC needs an actual identity provider integration test. SCIM Groups, enterprise compliance, remote storage operations, external security review, a deployed domain and Apple notarization are not supplied.
- All local image/project originals and recording metadata are preserved for editing; flattened redaction is verified, editable projects retain source pixels.

Latest offline suite: 17 native tests and 11 server tests. Native coverage includes curved-arrow control persistence, text-line geometry, rendered MP4 pixels and per-segment camera trimming.
