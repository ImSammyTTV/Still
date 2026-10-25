const { desktopCapturer, screen } = require('electron');
const { spawn, execFile } = require('child_process');

// Grabs every display at full resolution. Returns [{ display, image }] where image is a NativeImage in physical pixels.
async function grabDisplays() {
  const displays = screen.getAllDisplays();
  const max = displays.reduce((acc, d) => ({
    width: Math.max(acc.width, Math.round(d.size.width * d.scaleFactor)),
    height: Math.max(acc.height, Math.round(d.size.height * d.scaleFactor))
  }), { width: 1, height: 1 });
  const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: max });
  return displays.map((display, index) => {
    const source = sources.find((s) => String(s.display_id) === String(display.id)) || sources[index] || sources[0];
    let image = source.thumbnail;
    const width = Math.round(display.size.width * display.scaleFactor), height = Math.round(display.size.height * display.scaleFactor);
    const size = image.getSize();
    if (size.width !== width || size.height !== height) image = image.resize({ width, height, quality: 'best' });
    return { display, image, sourceId: source.id };
  });
}

// ---- Window lists for Space-to-window selection --------------------------------------------

// A long-lived PowerShell helper keeps EnumWindows compiled, so each list takes milliseconds.
const windowsHelper = `
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class StillWindows {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")] static extern int DwmGetInt(IntPtr h, int a, out int v, int s);
  public static string List(uint skip) {
    SetProcessDPIAware();
    var sb = new StringBuilder("[");
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h) || IsIconic(h) || GetWindowTextLength(h) == 0) return true;
      if ((GetWindowLong(h, -20) & 0x80) != 0) return true;
      int cloaked; if (DwmGetInt(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
      uint pid; GetWindowThreadProcessId(h, out pid); if (pid == skip) return true;
      RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) return true;
      if (r.R - r.L < 40 || r.B - r.T < 40) return true;
      if (sb.Length > 1) sb.Append(',');
      sb.AppendFormat("{{\\"id\\":{0},\\"x\\":{1},\\"y\\":{2},\\"w\\":{3},\\"h\\":{4}}}", h.ToInt64(), r.L, r.T, r.R - r.L, r.B - r.T);
      return true;
    }, IntPtr.Zero);
    return sb.Append("]").ToString();
  }
}
'@
while (($line = [Console]::In.ReadLine()) -ne $null) { [Console]::Out.WriteLine([StillWindows]::List([uint32]$line)); [Console]::Out.Flush() }
`;

class WindowLister {
  constructor() { this.pending = []; this.buffer = ''; this.helper = null; }
  start() {
    if (process.platform !== 'win32' || this.helper) return;
    const encoded = Buffer.from(windowsHelper, 'utf16le').toString('base64');
    this.helper = spawn('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded], { windowsHide: true });
    this.helper.stdout.setEncoding('utf8');
    this.helper.stdout.on('data', (chunk) => {
      this.buffer += chunk;
      let index;
      while ((index = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, index).trim(); this.buffer = this.buffer.slice(index + 1);
        const resolve = this.pending.shift(); if (!resolve) continue;
        try { resolve(JSON.parse(line)); } catch { resolve([]); }
      }
    });
    this.helper.on('exit', () => { this.helper = null; this.pending.splice(0).forEach((resolve) => resolve([])); });
  }
  stop() { this.helper?.kill(); this.helper = null; }

  // Window frames in DIP global coordinates, front to back.
  async list() {
    if (process.platform === 'win32') return this.listWindows();
    if (process.platform === 'linux') return isWayland() ? [] : listX11();
    return [];
  }
  listWindows() {
    this.start();
    if (!this.helper) return Promise.resolve([]);
    return new Promise((resolve) => {
      const timer = setTimeout(() => { const i = this.pending.indexOf(done); if (i >= 0) this.pending.splice(i, 1); resolve([]); }, 2500);
      const done = (list) => { clearTimeout(timer); resolve(list.map((w) => ({ id: w.id, ...dip(screen.screenToDipRect(null, { x: w.x, y: w.y, width: w.w, height: w.h })) }))); };
      this.pending.push(done);
      this.helper.stdin.write(`${process.pid}\n`);
    });
  }
}

const dip = (r) => ({ x: r.x, y: r.y, w: r.width, h: r.height });
const isWayland = () => process.platform === 'linux' && (process.env.XDG_SESSION_TYPE === 'wayland' || !!process.env.WAYLAND_DISPLAY) && !process.env.DISPLAY;

const run = (file, args) => new Promise((resolve) => execFile(file, args, { timeout: 1500 }, (error, stdout) => resolve(error ? '' : stdout)));

// X11: _NET_CLIENT_LIST_STACKING is bottom to top; frame extents add the window manager's decorations.
async function listX11() {
  const stack = await run('xprop', ['-root', '_NET_CLIENT_LIST_STACKING']);
  const ids = (stack.match(/0x[0-9a-f]+/gi) || []).reverse();
  const scale = screen.getPrimaryDisplay().scaleFactor || 1;
  const windows = await Promise.all(ids.map(async (id) => {
    const [info, props] = await Promise.all([run('xwininfo', ['-id', id]), run('xprop', ['-id', id, '_NET_WM_PID', '_NET_FRAME_EXTENTS', '_NET_WM_STATE', '_NET_WM_WINDOW_TYPE'])]);
    if (!/Map State:\s+IsViewable/.test(info) || /_NET_WM_STATE_HIDDEN/.test(props) || /WINDOW_TYPE_(DOCK|DESKTOP)/.test(props)) return null;
    if (new RegExp(`_NET_WM_PID\\(CARDINAL\\) = ${process.pid}\\b`).test(props)) return null;
    const num = (label) => Number((info.match(new RegExp(`${label}:\\s+(-?\\d+)`)) || [])[1] || 0);
    const extents = ((props.match(/_NET_FRAME_EXTENTS\(CARDINAL\) = ([\d, ]+)/) || [])[1] || '0,0,0,0').split(',').map(Number);
    const [left, right, top, bottom] = extents;
    const w = num('Width') + left + right, h = num('Height') + top + bottom;
    if (w < 40 || h < 40) return null;
    return { id: parseInt(id, 16), x: (num('Absolute upper-left X') - left) / scale, y: (num('Absolute upper-left Y') - top) / scale, w: w / scale, h: h / scale };
  }));
  return windows.filter(Boolean);
}

module.exports = { grabDisplays, WindowLister, isWayland };
