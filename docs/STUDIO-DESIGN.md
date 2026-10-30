# Still design

Still uses a neutral graphite palette, soft grouped surfaces, a white captured-frame app icon with a lifted corner and a matching template menu icon. Keep the latest native Mac design and the Windows/Linux interface visually consistent.

## Surfaces and appearance

Mac windows use the native under-window material. Windows uses Acrylic where available; Linux keeps opaque surfaces. Light mode uses cool white and grey rather than the previous warm paper palette. Dark mode uses space grey. Native form controls follow the selected appearance. Web surfaces become opaque when reduced transparency is requested. Respect reduced motion.

## Navigation and interaction

Settings uses a searchable sidebar with a persistent About entry on Mac. Categories scroll independently on smaller windows. Search has an explicit empty state. Current categories are exposed to assistive technology. Focus rings stay visible; dark graphite controls use dark text to retain contrast.

Capture, editor and recording workflows retain their existing layouts. Sharing pages use the same rounded surfaces and line icons. Capture actions stay visible for touch input and keyboard focus. Narrow layouts allow the search and upload controls to wrap.

## Installation

Keep the existing release signing identity when installing Mac updates. Use the signed preview workflow and `scripts/install-mac.sh`; a locally signed development build can invalidate an existing screen permission.
