# Still brand

How Still looks and sounds, in one page. The design tokens that implement this are in [DESIGN-SYSTEM.md](DESIGN-SYSTEM.md).

## Name

**Still.** One word, capitalised, always with the period when it stands alone as a signature (the Floating Preview header). In sentences it is simply Still. The sharing server is **Still Cloud**. Never "Still App", "StillShot" or "still" in lowercase.

## Mark

A capture frame with a folded corner: a landscape rounded rectangle in a thick ink stroke (about a tenth of its width), with a viewfinder-style break at the top-left corner and a white page corner folding over the bottom-right, where the stroke stops beneath it. It sits on a white tile with a soft grey border, and the tile stays white in both appearances.

The vector source is `assets/brand/mark.svg` (32 grid, stroke 1.6, square caps). Every rendering of the mark is traced from `assets/brand/icon.png`; do not redraw it from memory.

- App icon and README: `assets/brand/icon.png`
- Mac menu bar: `Resources/MenuBarIcon.png`, a template image so macOS draws it black or white
- Windows and Linux tray: `Desktop/src-tauri/icons/tray-white.png` and `tray-black.png`
- Still Cloud: `assets/brand/mark.svg` inlined in `Cloud/static/index.html`

Keep the tile white, keep the folded corner at the bottom-right and the break at the top-left, and never colour the frame. The mark is the only place pure white is a brand colour.

## Tagline and voice

**A screenshot is only the beginning.** Secondary line: *Capture a moment, make your point, and keep moving.*

Still speaks plainly and briefly, like a knowledgeable friend. Verbs lead: Capture Area, Copy, Save, Pin to screen, Upload and copy link. Settings explain consequences in one sentence ("Screenshots stay on your computer unless you upload them"). Privacy is stated as fact, never as a boast. No exclamation marks, no jargon, no "powerful" or "seamless".

Product names are consistent on every platform: Capture Bar, Capture Area, Capture Window, Capture Fullscreen, Floating Preview, Capture History, Annotate, Record, Still Cloud.

## Colour

| Name | Value | Role |
| :--- | :--- | :--- |
| Ink | `#1D1D1F` | Text in light mode; the frame of the mark |
| Graphite | `#6E6E73` (light) / `#98989D` (dark) | The accent: primary buttons, selection, focus. Text on it is white in light mode and ink in dark mode |
| Cool white | `#F5F5F7` | Light mode background; text in dark mode |
| Space grey | `#1C1C1E` | Dark mode background |
| Signal red | `#FF453A` | Recording and destructive actions only |

Still has no brand hue. The graphite accent keeps the product neutral so the captures carry the colour. Badges and marketing use Graphite `#6E6E73` on Cool white, or Cool white on Space grey.

## Type

The system font of each platform (SF Pro, Segoe UI Variable, the Linux desktop font). Headlines are semibold with slightly tight tracking; body text is regular. Monospace (Cascadia Mono, JetBrains Mono or the system monospace) appears only for pixel dimensions.

## Imagery

Product imagery shows the capture, not the chrome: a screenshot with one clear arrow, a highlight or a numbered step, on a soft gradient background with a rounded corner and a gentle shadow. The README animation `assets/readme/capture-workflow.gif` is the reference. Line icons (Lucide, 1.8 stroke) replace emoji everywhere.

## Surfaces

Light mode is cool white and grey with translucent white panels over the window material. Dark mode is space grey with translucent grey panels. Floating chrome (the Capture Bar, the recording HUD, the Floating Preview) is always dark. Corners are soft: 8px controls, 12px cards, 16px floating panels, capsules for bars.

## Don't

- Don't tint the chrome with a colour; the accent stays graphite.
- Don't use emoji in the interface or documentation; use line icons.
- Don't shrink type below 11px to make metadata fit.
- Don't give a screen its own name; reuse the product's names.
- Don't put white text on the dark-mode accent.
