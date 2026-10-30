# Still design system

Still is one product on three surfaces: a native Mac app (Swift), a Tauri app for Windows and Linux (`Desktop/web`), and the Still Cloud sharing site (`Cloud/static`). They share one visual language: a neutral graphite palette, soft grouped surfaces, system type, line icons, and a white tile carrying the capture-frame mark with its folded corner (`assets/brand/mark.svg`). This document is the reference for that language. The brand itself (name, mark, voice) is in [BRAND.md](BRAND.md).

Tokens live in three places and must stay in step:

| Surface | Where tokens live | How they are used |
| :--- | :--- | :--- |
| Mac | `Sources/Still/Design.swift` (`Studio`) | `Studio.accent`, `Studio.onAccent`, `Studio.paper`, `Studio.surface`, `Studio.Radius`, `Studio.glass` |
| Windows and Linux | `Desktop/web/style.css` (`:root`) | CSS custom properties; every page style uses `var(--…)` |
| Still Cloud | `Cloud/static/style.css` (`:root`) | Same names as the desktop app; the server fills `{{ACCENT}}` |

`Desktop/test/design-tokens.test.js` fails the build when a page style uses a raw colour outside the token blocks, uses an inline style with a colour, or sets text below 10px.

## Principles

1. **The capture is the hero.** Chrome is quiet and neutral so screenshots and recordings carry the colour. The accent is graphite, never a brand hue competing with the content.
2. **One primary action per surface.** A single filled graphite control marks the main action (Copy, Save, Upload, Connect). Everything else is a soft surface button.
3. **Same words everywhere.** Capture History, Floating Preview, Capture Bar, Annotate, Still Cloud. The Mac app, the Windows/Linux app and the website use the same names for the same things.
4. **Both appearances, equally.** Light mode is cool white and grey; dark mode is space grey. Every colour is a token with a value in each appearance, and contrast is checked in both.
5. **Respect the system.** System font, native materials (under-window material on Mac, Acrylic on Windows), reduced motion and reduced transparency, visible focus rings on every control.

## Colour

### Semantic colours

| Token | Light | Dark | Use |
| :--- | :--- | :--- | :--- |
| `--accent` / `Studio.accent` | `#707075` (Mac `#6E6E73`) | `#98989D` | The primary action, the selected segment, the active sidebar row, focus rings |
| `--accent-text` / `Studio.onAccent` | `#FFFFFF` | `#171719` | Text and glyphs on the accent. Never write `#fff` on an accent background: the accent lightens in dark mode and its text must darken |
| `--red` | `#FF453A` (Cloud `#D84550` / `#FF6B6B`) | same | Recording, destructive and error states |
| `--yellow` | `#FFD60A` | same | Paused recording |
| `--selection` | `#0A84FF` | same | Functional only: selection handles, crop frames and window outlines drawn over a screenshot. Never used for chrome |

### Surfaces and text

| Token | Light | Dark | Use |
| :--- | :--- | :--- | :--- |
| `--bg` | `#F5F5F7` | `#1C1C1E` | Window background |
| `--bg-elevated` | `#FFFFFF` | `#2C2C2E` | Cards, grouped lists, menus, fields |
| `--sidebar` | `#EFEFF2` | `#232325` | Settings and library sidebars |
| `--surface` | black 4.5% | white 6% | Hover fills, segmented control track |
| `--surface-strong` | black 8% | white 11% | Default button fill, key caps |
| `--border` | black 10% | white 10% | Hairlines and card borders |
| `--canvas` | `#E7E7EB` | `#111113` | Behind images: editor stage, thumbnails |
| `--text` | `#1D1D1F` | `#F5F5F7` | Body text |
| `--text-2` | text at 68% | text at 68% | Secondary text, hints, placeholders. Passes 4.5:1 on every surface above |
| `--text-3` | text at 45% | text at 42% | Decorative only (glyphs, dividers). Not for readable text |

On Windows, Settings, History and the editor sit on Acrylic: `body.win32.glass` turns `--bg`, `--sidebar` and `--bg-elevated` translucent, and `prefers-reduced-transparency` turns them solid again. On Mac, `Studio.paper` and `Studio.surface` are translucent for the same reason.

### Always-dark chrome

The Capture Bar, the recording HUD, the Floating Preview card, toasts and overlay badges look the same in both appearances, so they use their own tokens instead of the themed surfaces:

| Token | Value | Use |
| :--- | :--- | :--- |
| `--chrome` | `#1E1E20` | Floating Preview card |
| `--chrome-deep` | `#111113` | Behind the preview image |
| `--hud` | `rgba(30,30,32,.92)` | Capture Bar, HUD, toasts, badges on thumbnails |
| `--chrome-surface` / `--chrome-surface-strong` | white 10% / 16% | Hover and secondary buttons on chrome |
| `--chrome-border` | white 12% | Hairline around chrome |
| `--on-chrome` / `--on-chrome-2` | `#F5F5F7` / 65% | Text on chrome, secondary text and placeholders on chrome |

A selected segment on chrome still uses `--accent` with `--accent-text`: a dark text pill on light graphite in dark mode, and white on graphite in light mode.

### Category tiles

Settings categories use the system's category colours behind a white glyph, the way System Settings does. They are data in `settings.js`, not theme tokens: Setup and General `#8E8E93`, Shortcuts `#5E5CE6`, Floating Preview `#30B0C7`, Screenshots `#34C759`, Recording `#FF3B30`, Annotate `#FF9F0A`, Cloud `#5AC8FA`, About `#0A84FF`.

### Content palettes

The annotation colours (`ColorPalette.swift`, `editor.js` `COLORS`) and the background gradients (`Models.swift`, `editor.js` `GRADIENTS`) are content, not chrome. They are deliberately saturated and are the same list on every platform.

## Typography

System UI font everywhere: SF Pro on Mac, Segoe UI Variable on Windows, the desktop font on Linux. Headings use weight 650 with `-0.01em` tracking. Digits that line up use `tabular-nums`.

| Token | Desktop | Cloud | Use |
| :--- | :--- | :--- | :--- |
| `--text-xs` | 11px | 11px | Hints, group titles, tags, dates. The smallest readable size |
| `--text-sm` | 12px | 12px | Buttons on chrome, secondary rows, labels |
| `--text-md` | 13px | 14px | Body |
| `--text-lg` | 15px | 16px | Wordmark |
| `--text-xl` | 18px | 18px | About name, Cloud section headings |
| `--text-2xl` | 22px | 22px | Window titles (Settings page title, Capture History, Sign in) |
| `--text-3xl` | 30px | 26px | Setup headline, Cloud library title |

Mac: `Studio.heading` is 26pt semibold; panel labels are 10 to 12pt. The `.label` class (10px, 600, uppercase, `.08em`) is the one exception below 11px and is reserved for short stamps such as "Update available" and "Capture ready".

## Shape and space

| Token | Value | Use |
| :--- | :--- | :--- |
| `--radius-xs` | 4px | Key caps, tags |
| `--radius-sm` | 6px | Fields, segmented buttons, sidebar rows, menu rows |
| `--radius-md` | 8px | Buttons, tool rail buttons, app icon in lists (`Studio.Radius.control`) |
| `--radius-lg` / `--radius` | 12px | Cards, grouped lists, menus (`Studio.Radius.card`) |
| `--radius-xl` | 16px | Floating cards: preview, update, dialogs, Cloud cards (`Studio.Radius.panel`) |
| `--radius-pill` | 999px | Capture Bar, HUD, badges, drag handle |

Spacing is on a 4px grid: `--space-1` 4px through `--space-7` 28px (Cloud adds `--space-8` 40px). Rows in grouped lists are 40px tall with 12px side padding; controls are 28px tall.

Shadows: `--shadow` for menus, `--shadow-float` for floating chrome. Cards on glass get a soft two-layer shadow (`0 1px 2px` and `0 6px 16px`, black at 12% and 8%).

## Components

| Component | Variants | States | Where |
| :--- | :--- | :--- | :--- |
| Button `.btn` | default, `.primary`, `.icon`, `.plain` | hover (brightness), active, disabled (40%), focus ring | Everywhere |
| Segmented `.segmented` | — | hover, `.active` (accent) | History filter, editor undo/redo, window controls |
| Field `.field` | text, select | focus (accent border and 30% ring), placeholder (`--text-2`) | Settings, History search, Cloud forms |
| Switch `.switch` | — | on (accent), off | Settings rows |
| Grouped list `.group` / `.row` | with `.group-title` and `.hint` | — | Settings |
| Sidebar nav | icon tile and label | hover, `.active` (accent fill, `aria-current`) | Settings, Cloud |
| Card / tile | History `.tile`, Cloud `.capture-card` | hover (accent border, shadow), focus-within shows actions | Libraries |
| Capture Bar `.bar` | modes, dimensions, aspect lock | `.mode.active`, window mode | Overlay |
| Recording HUD `.hud` | recording, `.paused` | pulse dot (static with reduced motion) | Recording |
| Floating Preview `.card` | image, recording (badge) | leaving animation, hover pauses auto-close | After capture |
| Menu `.menu` | items, separators | hover (accent) | Context menus |
| Toast `.toast` / `#toast` | — | show for 1.8s (desktop) or 4.5s (Cloud) | Feedback |

Icons are Lucide at 16px with a 1.8 stroke on the desktop app, and matching inline line icons on Still Cloud. Settings tiles use 13px glyphs.

## States and accessibility

- Every control has a visible focus ring: 2px accent (desktop) or 3px accent at 60% (Cloud), offset 2 to 3px.
- Text contrast is at least 4.5:1 in both appearances; icons on the accent at least 3:1. The dark accent is paired with dark text for this reason.
- Icon-only buttons carry a `title`, which `refreshIcons()` copies to `aria-label`. Active sidebar rows set `aria-current="page"`.
- Hover-revealed actions (card tools) also show on `focus-within` and on touch screens (`hover: none`).
- `prefers-reduced-motion` removes animations and transitions. `prefers-reduced-transparency` makes glass surfaces solid.
- Explicit appearance choices set `data-theme` on the root and `color-scheme`, so native controls follow.

## Do and don't

| Do | Don't |
| :--- | :--- |
| Pair `--accent` with `--accent-text` (Mac: `Studio.accent` with `Studio.onAccent`) | Write `#fff` or `.white` on an accent background |
| Use `--text-2` for hints and placeholders | Use `--text-3` for anything that must be read |
| Use the chrome tokens for always-dark surfaces | Reuse the themed `--bg` on a bar that is dark in both modes |
| Pick a radius from the scale | Invent 7px, 9px, 14px corners |
| Keep text at 11px or larger | Shrink metadata to 9 or 10px to make it fit |
| Name things as the product does: Capture History, Floating Preview | Coin page-specific names ("The collection") |

## Checking a change

1. Run `npm test` in `Desktop` for the token guard and the unit tests.
2. Render the page in both appearances. The web pages run in any browser with a stubbed `window.__TAURI__`; Still Cloud runs with `python3 Cloud/server.py --data ./data`.
3. Check contrast of any new colour pairing in both appearances before it lands.

## Installation note

Keep the existing release signing identity when installing Mac updates. Use the signed preview workflow and `scripts/install-mac.sh`; a locally signed development build can invalidate an existing screen permission.
