//! Still's own screen recorder on Windows.
//!
//! The system web engine can record the screen too, but it shows its own "sharing your screen" bar, which ends up in
//! whole-screen recordings, asks the user to pick a screen every time, and keeps the controls' page in the loop for
//! saving. Here Still records by itself: Windows.Graphics.Capture delivers the display, the selected area is cut out
//! on the GPU, and Media Foundation encodes it to an H.264 MP4. The recording controls only send commands.
//!
//! Media Foundation is missing on Windows "N" editions and on Windows Server without its media feature, so it is
//! loaded at run time: where it is absent, `available()` says why and the web engine records instead.
//!
//! Sound comes from WASAPI: what the computer plays (loopback on the default speakers) and the default microphone,
//! both converted by Windows to 48 kHz 16-bit stereo, mixed on the recorder's clock and encoded to AAC in the same MP4.

use std::path::PathBuf;

/// Where and how to record.
pub struct Options {
    /// A point on the display to record, in physical screen pixels.
    pub monitor: (i32, i32),
    /// The area to keep, in physical pixels within that display. Rounded to even sizes, which H.264 needs.
    pub crop: (u32, u32, u32, u32),
    pub fps: u32,
    /// "high", "balanced" or "compact"; see `bitrate`.
    pub quality: String,
    pub cursor: bool,
    /// Record what the computer plays.
    pub system_audio: bool,
    pub microphone: bool,
    /// The MP4 to write.
    pub path: PathBuf,
}

/// A finished recording.
pub struct Finished {
    pub path: PathBuf,
    /// Seconds of video, not counting pauses.
    pub duration: f64,
    pub frames: u64,
    /// Frames the encoder couldn't keep up with.
    pub dropped: u64,
    /// Whether a hardware encoder did the work.
    pub hardware: bool,
    /// Share of the last frame's pixels that aren't black: a capture that returned nothing reads 0.
    pub lit: f64,
    /// Whether the file has a sound track.
    pub audio: bool,
}

/// Share of BGRA pixels brighter than near-black. Tells a real capture from an empty one.
pub fn lit_share(pixels: &[u8]) -> f64 {
    let total = pixels.len() / 4;
    if total == 0 { return 0.0; }
    let lit = pixels.chunks_exact(4).filter(|p| p[0] > 8 || p[1] > 8 || p[2] > 8).count();
    lit as f64 / total as f64
}

/// Rounds a selection to the even pixel sizes H.264 requires, and to at least 2×2.
pub fn even_crop(x: f64, y: f64, w: f64, h: f64, display_w: u32, display_h: u32) -> (u32, u32, u32, u32) {
    let x = x.max(0.0).round() as u32;
    let y = y.max(0.0).round() as u32;
    let x = x.min(display_w.saturating_sub(2));
    let y = y.min(display_h.saturating_sub(2));
    let w = (w.round() as u32).min(display_w - x);
    let h = (h.round() as u32).min(display_h - y);
    (x, y, (w / 2 * 2).max(2), (h / 2 * 2).max(2))
}

/// The Mac app's qualities, in bits per pixel per frame: "high", "balanced" or "compact" (Smaller File), kept within
/// sensible bounds.
pub fn bitrate(width: u32, height: u32, fps: u32, quality: &str) -> u32 {
    // A bitrate chosen in Settings, stored as the Mac stores it: "bitrate:12000000", 1 to 100 Mbit/s.
    if let Some(chosen) = quality.strip_prefix("bitrate:").and_then(|n| n.parse::<u64>().ok()).filter(|n| *n > 0) {
        return chosen.clamp(1_000_000, 100_000_000) as u32;
    }
    let factor = match quality { "compact" => 0.045, "balanced" => 0.09, _ => 0.18 };
    let bits = width as f64 * height as f64 * fps.max(1) as f64 * factor;
    bits.clamp(400_000.0, 100_000_000.0) as u32
}

#[cfg_attr(not(windows), allow(dead_code))]
/// Sound is kept as interleaved 16-bit stereo at this rate, which is what the AAC encoder takes.
pub const RATE: u32 = 48_000;

/// Sound waiting to be written, from one source.
#[cfg_attr(not(windows), allow(dead_code))]
type Queue = std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<i16>>>;

/// Takes `frames` stereo frames from every queue and adds them together. A source that has less (a microphone that
/// skipped, say) is padded with silence, and one that has fallen more than `slack` frames behind the others loses
/// its oldest sound, so a drifting device can't push the sound out of step with the picture.
#[cfg_attr(not(windows), allow(dead_code))]
fn mix(queues: &mut [std::collections::VecDeque<i16>], frames: usize, slack: usize) -> Vec<i16> {
    let mut out = vec![0i32; frames * 2];
    for queue in queues.iter_mut() {
        let excess = queue.len().saturating_sub((frames + slack) * 2) / 2 * 2;
        queue.drain(..excess);
        for (slot, sample) in out.iter_mut().zip(queue.drain(..(frames * 2).min(queue.len() / 2 * 2))) { *slot += sample as i32; }
    }
    out.into_iter().map(|v| v.clamp(i16::MIN as i32, i16::MAX as i32) as i16).collect()
}

/// Commands from the controls to the recorder's thread.
enum Cmd {
    Pause(bool),
    Restart,
    Stop(std::sync::mpsc::Sender<Result<Finished, String>>),
    Cancel,
}

/// A recording in progress. Every call is answered by the recorder's own thread.
pub struct Handle {
    tx: std::sync::Mutex<std::sync::mpsc::Sender<Cmd>>,
    /// Sound sources that were asked for but couldn't be opened, and why. The recording goes on without them.
    pub warnings: Vec<String>,
}

impl Handle {
    fn send(&self, cmd: Cmd) -> bool { self.tx.lock().map(|tx| tx.send(cmd).is_ok()).unwrap_or(false) }
    pub fn pause(&self, on: bool) { self.send(Cmd::Pause(on)); }
    /// Throws away what was recorded and begins again.
    pub fn restart(&self) { self.send(Cmd::Restart); }
    /// Ends the recording and finishes the file.
    pub fn stop(&self) -> Result<Finished, String> {
        let (tx, rx) = std::sync::mpsc::channel();
        if !self.send(Cmd::Stop(tx)) { return Err("The recorder had already stopped.".into()); }
        rx.recv_timeout(std::time::Duration::from_secs(30)).map_err(|_| "The recorder didn’t finish the file.".to_string())?
    }
    /// Ends the recording and deletes the file.
    pub fn cancel(&self) { self.send(Cmd::Cancel); }
}

/// The recording clock: time spent paused doesn't count, so the video has no gap and no jump.
struct Timeline { start: std::time::Instant, paused_total: std::time::Duration, paused_at: Option<std::time::Instant> }

impl Timeline {
    fn new() -> Self { Timeline { start: std::time::Instant::now(), paused_total: Default::default(), paused_at: None } }
    fn pause(&mut self, on: bool) {
        match (on, self.paused_at) {
            (true, None) => self.paused_at = Some(std::time::Instant::now()),
            (false, Some(at)) => { self.paused_total += at.elapsed(); self.paused_at = None; }
            _ => {}
        }
    }
    fn paused(&self) -> bool { self.paused_at.is_some() }
    /// Recorded time so far, in Media Foundation's 100-nanosecond units.
    fn now_hns(&self) -> i64 {
        let end = self.paused_at.unwrap_or_else(std::time::Instant::now);
        (end.duration_since(self.start).saturating_sub(self.paused_total).as_nanos() / 100) as i64
    }
}

#[cfg(windows)]
pub use imp::{available, start};

#[cfg(not(windows))]
pub fn available() -> Result<(), String> { Err("Still’s own recorder is Windows-only.".into()) }
#[cfg(not(windows))]
pub fn start(_: Options) -> Result<Handle, String> { Err("Still’s own recorder is Windows-only.".into()) }

#[cfg(windows)]
mod imp {
    use super::{bitrate, lit_share, mix, Cmd, Finished, Handle, Options, Queue, Timeline, RATE};
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::{Duration, Instant};
    use windows::core::{factory, Interface, HSTRING, PCWSTR};
    use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
    use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
    use windows::Graphics::DirectX::DirectXPixelFormat;
    use windows::Win32::Foundation::{HMODULE, POINT};
    use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE, D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    use windows::Win32::Graphics::Gdi::{MonitorFromPoint, MONITOR_DEFAULTTONEAREST};
    use windows::Win32::Media::Audio::*;
    use windows::Win32::Media::MediaFoundation::*;
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
    use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
    use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

    type Raw = *mut core::ffi::c_void;
    type Hr = windows::core::HRESULT;

    /// Media Foundation's few flat functions, looked up at run time so that Still still starts where it is missing.
    struct Mf {
        startup: unsafe extern "system" fn(u32, u32) -> Hr,
        shutdown: unsafe extern "system" fn() -> Hr,
        create_attributes: unsafe extern "system" fn(*mut Raw, u32) -> Hr,
        create_media_type: unsafe extern "system" fn(*mut Raw) -> Hr,
        create_sample: unsafe extern "system" fn(*mut Raw) -> Hr,
        create_memory_buffer: unsafe extern "system" fn(u32, *mut Raw) -> Hr,
        create_sink_writer_from_url: unsafe extern "system" fn(PCWSTR, Raw, Raw, *mut Raw) -> Hr,
    }

    fn load_mf() -> Result<Mf, String> {
        unsafe {
            let plat = LoadLibraryW(&HSTRING::from("mfplat.dll")).map_err(|_| "Media Foundation isn’t installed (on Windows N, add the Media Feature Pack).".to_string())?;
            let rw = LoadLibraryW(&HSTRING::from("mfreadwrite.dll")).map_err(|_| "Media Foundation’s writer isn’t installed.".to_string())?;
            let find = |module: HMODULE, name: &[u8]| GetProcAddress(module, windows::core::PCSTR(name.as_ptr())).ok_or_else(|| format!("Media Foundation has no {}.", String::from_utf8_lossy(&name[..name.len() - 1])));
            Ok(Mf {
                startup: std::mem::transmute(find(plat, b"MFStartup\0")?),
                shutdown: std::mem::transmute(find(plat, b"MFShutdown\0")?),
                create_attributes: std::mem::transmute(find(plat, b"MFCreateAttributes\0")?),
                create_media_type: std::mem::transmute(find(plat, b"MFCreateMediaType\0")?),
                create_sample: std::mem::transmute(find(plat, b"MFCreateSample\0")?),
                create_memory_buffer: std::mem::transmute(find(plat, b"MFCreateMemoryBuffer\0")?),
                create_sink_writer_from_url: std::mem::transmute(find(rw, b"MFCreateSinkWriterFromURL\0")?),
            })
        }
    }

    fn err(what: &str, e: impl std::fmt::Display) -> String { format!("{what}: {e}") }

    /// Whether this computer can use Still's own recorder, and if not, why.
    pub fn available() -> Result<(), String> {
        load_mf()?;
        // WinRT needs an apartment on the asking thread; a short-lived one keeps the caller's untouched.
        std::thread::spawn(|| unsafe {
            let _ = RoInitialize(RO_INIT_MULTITHREADED);
            match GraphicsCaptureSession::IsSupported() {
                Ok(true) => Ok(()),
                Ok(false) => Err("Windows screen capture isn’t supported on this computer.".to_string()),
                Err(e) => Err(err("Windows screen capture isn’t available", e)),
            }
        }).join().unwrap_or_else(|_| Err("Couldn’t check Windows screen capture.".into()))
    }

    /// Starts recording on a thread of its own and returns once the first frame is on its way, or with the reason it
    /// couldn't start.
    pub fn start(options: Options) -> Result<Handle, String> {
        let mf = load_mf()?;
        // A missing microphone or speaker is no reason not to record the screen: say so and go on without it.
        let mut warnings = Vec::new();
        let mut sources = Vec::new();
        for (wanted, loopback) in [(options.system_audio, true), (options.microphone, false)] {
            if !wanted { continue; }
            match Source::open(loopback) { Ok(source) => sources.push(source), Err(e) => warnings.push(e) }
        }
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
        std::thread::Builder::new().name("still-recorder".into()).spawn(move || {
            unsafe { let _ = RoInitialize(RO_INIT_MULTITHREADED); }
            if let Err(e) = unsafe { (mf.startup)(MF_VERSION, MFSTARTUP_FULL) }.ok() { let _ = ready_tx.send(Err(err("Media Foundation didn’t start", e))); return; }
            let outcome = run(&mf, options, Sound::new(sources), rx, &ready_tx);
            if let Err(e) = outcome { let _ = ready_tx.send(Err(e)); }
            unsafe { let _ = (mf.shutdown)(); }
        }).map_err(|e| err("The recorder couldn’t start", e))?;
        ready_rx.recv_timeout(Duration::from_secs(10)).map_err(|_| "The recorder didn’t start in time.".to_string())??;
        Ok(Handle { tx: std::sync::Mutex::new(tx), warnings })
    }

    /// The screen, as Windows.Graphics.Capture delivers it.
    struct Capture {
        context: ID3D11DeviceContext,
        device: ID3D11Device,
        winrt_device: IDirect3DDevice,
        pool: Direct3D11CaptureFramePool,
        session: GraphicsCaptureSession,
        size: windows::Graphics::SizeInt32,
        staging: ID3D11Texture2D,
        crop: (u32, u32, u32, u32),
    }

    fn device(kind: D3D_DRIVER_TYPE) -> windows::core::Result<(ID3D11Device, ID3D11DeviceContext)> {
        let mut device = None;
        let mut context = None;
        unsafe {
            D3D11CreateDevice(None, kind, HMODULE::default(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, None, D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut context))?;
        }
        Ok((device.ok_or_else(windows::core::Error::empty)?, context.ok_or_else(windows::core::Error::empty)?))
    }

    impl Capture {
        fn open(options: &Options) -> Result<Self, String> {
            // A real graphics card first; WARP (Windows' software renderer) on virtual machines and remote sessions.
            let (device, context) = device(D3D_DRIVER_TYPE_HARDWARE).or_else(|_| device(D3D_DRIVER_TYPE_WARP)).map_err(|e| err("No Direct3D device", e))?;
            let winrt_device: IDirect3DDevice = unsafe {
                let dxgi: IDXGIDevice = device.cast().map_err(|e| err("No DXGI device", e))?;
                CreateDirect3D11DeviceFromDXGIDevice(&dxgi).and_then(|d| d.cast()).map_err(|e| err("No capture device", e))?
            };
            let monitor = unsafe { MonitorFromPoint(POINT { x: options.monitor.0, y: options.monitor.1 }, MONITOR_DEFAULTTONEAREST) };
            let item: GraphicsCaptureItem = unsafe {
                let interop = factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(|e| err("Screen capture is unavailable", e))?;
                interop.CreateForMonitor(monitor).map_err(|e| err("This display can’t be captured", e))?
            };
            let size = item.Size().map_err(|e| err("The display’s size is unknown", e))?;
            let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&winrt_device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size).map_err(|e| err("No capture frames", e))?;
            let session = pool.CreateCaptureSession(&item).map_err(|e| err("No capture session", e))?;
            // Both are newer than capture itself; where they don't exist the cursor stays in and the border shows.
            let _ = session.SetIsCursorCaptureEnabled(options.cursor);
            let _ = session.SetIsBorderRequired(false);
            let (x, y, w, h) = options.crop;
            let crop = (x.min(size.Width as u32 - 2), y.min(size.Height as u32 - 2), w.min(size.Width as u32 - x.min(size.Width as u32 - 2)) / 2 * 2, h.min(size.Height as u32 - y.min(size.Height as u32 - 2)) / 2 * 2);
            let staging = staging_texture(&device, crop.2, crop.3)?;
            session.StartCapture().map_err(|e| err("Screen capture didn’t start", e))?;
            Ok(Capture { context, device, winrt_device, pool, session, size, staging, crop })
        }

        /// The newest frame since the last call, cropped and copied into `buffer`; false when the screen hasn't changed.
        fn next(&mut self, buffer: &mut Vec<u8>) -> Result<bool, String> {
            let mut newest = None;
            while let Ok(frame) = self.pool.TryGetNextFrame() { newest = Some(frame); }
            let Some(frame) = newest else { return Ok(false) };
            let content = frame.ContentSize().map_err(|e| err("Capture frame", e))?;
            if content.Width != self.size.Width || content.Height != self.size.Height {
                // The display changed resolution: carry on at the new size, keeping the area inside it.
                self.size = content;
                let _ = self.pool.Recreate(&self.winrt_device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, content);
                return Ok(false);
            }
            let texture: ID3D11Texture2D = unsafe {
                let surface = frame.Surface().map_err(|e| err("Capture surface", e))?;
                let access: IDirect3DDxgiInterfaceAccess = surface.cast().map_err(|e| err("Capture surface", e))?;
                access.GetInterface().map_err(|e| err("Capture texture", e))?
            };
            let (x, y, w, h) = self.crop;
            let region = D3D11_BOX { left: x, top: y, front: 0, right: x + w, bottom: y + h, back: 1 };
            unsafe {
                self.context.CopySubresourceRegion(&self.staging, 0, 0, 0, 0, &texture, 0, Some(&region));
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                self.context.Map(&self.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map_err(|e| err("Reading the frame", e))?;
                let row = w as usize * 4;
                buffer.resize(row * h as usize, 0);
                for line in 0..h as usize {
                    let source = (mapped.pData as *const u8).add(line * mapped.RowPitch as usize);
                    std::ptr::copy_nonoverlapping(source, buffer.as_mut_ptr().add(line * row), row);
                }
                self.context.Unmap(&self.staging, 0);
            }
            Ok(true)
        }
    }

    impl Drop for Capture {
        fn drop(&mut self) { let _ = self.session.Close(); let _ = self.pool.Close(); let _ = &self.device; }
    }

    fn staging_texture(device: &ID3D11Device, width: u32, height: u32) -> Result<ID3D11Texture2D, String> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width, Height: height, MipLevels: 1, ArraySize: 1, Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 }, Usage: D3D11_USAGE_STAGING,
            BindFlags: 0, CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32, MiscFlags: 0,
        };
        let mut texture = None;
        unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture)) }.map_err(|e| err("No frame buffer", e))?;
        texture.ok_or_else(|| "No frame buffer.".to_string())
    }

    /// The MP4 being written.
    struct Writer { sink: IMFSinkWriter, stream: u32, audio: Option<u32>, hardware: bool }

    impl Writer {
        fn create(mf: &Mf, options: &Options, width: u32, height: u32, hardware: bool, audio: bool) -> Result<Self, String> {
            unsafe {
                let mut raw = std::ptr::null_mut();
                (mf.create_attributes)(&mut raw, 2).ok().map_err(|e| err("Encoder settings", e))?;
                let attributes = IMFAttributes::from_raw(raw);
                attributes.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, hardware as u32).map_err(|e| err("Encoder settings", e))?;
                let path = HSTRING::from(options.path.as_os_str());
                let mut raw = std::ptr::null_mut();
                (mf.create_sink_writer_from_url)(PCWSTR(path.as_ptr()), std::ptr::null_mut(), attributes.as_raw(), &mut raw).ok().map_err(|e| err("The video file couldn’t be created", e))?;
                let sink = IMFSinkWriter::from_raw(raw);
                let frame_size = ((width as u64) << 32) | height as u64;
                let frame_rate = ((options.fps as u64) << 32) | 1;
                let output = media_type(mf)?;
                output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(|e| err("Encoder output", e))?;
                output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(|e| err("Encoder output", e))?;
                output.SetUINT32(&MF_MT_AVG_BITRATE, bitrate(width, height, options.fps, &options.quality)).map_err(|e| err("Encoder output", e))?;
                output.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(|e| err("Encoder output", e))?;
                output.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High.0 as u32).map_err(|e| err("Encoder output", e))?;
                output.SetUINT64(&MF_MT_FRAME_SIZE, frame_size).map_err(|e| err("Encoder output", e))?;
                output.SetUINT64(&MF_MT_FRAME_RATE, frame_rate).map_err(|e| err("Encoder output", e))?;
                output.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1).map_err(|e| err("Encoder output", e))?;
                let stream = sink.AddStream(&output).map_err(|e| err("This size can’t be encoded", e))?;
                let input = media_type(mf)?;
                input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video).map_err(|e| err("Encoder input", e))?;
                input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32).map_err(|e| err("Encoder input", e))?;
                input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32).map_err(|e| err("Encoder input", e))?;
                input.SetUINT32(&MF_MT_DEFAULT_STRIDE, width * 4).map_err(|e| err("Encoder input", e))?; // Rows run top to bottom.
                input.SetUINT64(&MF_MT_FRAME_SIZE, frame_size).map_err(|e| err("Encoder input", e))?;
                input.SetUINT64(&MF_MT_FRAME_RATE, frame_rate).map_err(|e| err("Encoder input", e))?;
                input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1).map_err(|e| err("Encoder input", e))?;
                sink.SetInputMediaType(stream, &input, None).map_err(|e| err("The encoder can’t take screen frames", e))?;
                let audio = if audio { Some(Self::add_audio(mf, &sink)?) } else { None };
                sink.BeginWriting().map_err(|e| err("The encoder didn’t start", e))?;
                Ok(Writer { sink, stream, audio, hardware })
            }
        }

        /// An AAC track fed with 16-bit stereo PCM at `RATE`.
        unsafe fn add_audio(mf: &Mf, sink: &IMFSinkWriter) -> Result<u32, String> {
            let e = |e| err("The sound encoder", e);
            let output = media_type(mf)?;
            output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio).map_err(e)?;
            output.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC).map_err(e)?;
            output.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16).map_err(e)?;
            output.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, RATE).map_err(e)?;
            output.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2).map_err(e)?;
            output.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24_000).map_err(e)?; // 192 kbit/s, the encoder's highest.
            output.SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0).map_err(e)?;
            let stream = sink.AddStream(&output).map_err(e)?;
            let input = media_type(mf)?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio).map_err(e)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM).map_err(e)?;
            input.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16).map_err(e)?;
            input.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, RATE).map_err(e)?;
            input.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2).map_err(e)?;
            input.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 4).map_err(e)?;
            input.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, RATE * 4).map_err(e)?;
            sink.SetInputMediaType(stream, &input, None).map_err(e)?;
            Ok(stream)
        }

        fn write(&self, mf: &Mf, pixels: &[u8], time: i64, duration: i64) -> Result<(), String> {
            self.write_to(mf, self.stream, pixels, time, duration).map_err(|e| err("Encoding a frame", e))
        }

        /// Sound starting at stereo frame `at`.
        fn write_audio(&self, mf: &Mf, samples: &[i16], at: u64) -> Result<(), String> {
            let Some(stream) = self.audio else { return Ok(()) };
            let bytes = unsafe { std::slice::from_raw_parts(samples.as_ptr() as *const u8, samples.len() * 2) };
            let hns = |frames: u64| (frames as i128 * 10_000_000 / RATE as i128) as i64;
            let frames = samples.len() as u64 / 2;
            self.write_to(mf, stream, bytes, hns(at), hns(at + frames) - hns(at)).map_err(|e| err("Encoding sound", e))
        }

        fn write_to(&self, mf: &Mf, stream: u32, bytes: &[u8], time: i64, duration: i64) -> Result<(), String> {
            unsafe {
                let mut raw = std::ptr::null_mut();
                (mf.create_memory_buffer)(bytes.len() as u32, &mut raw).ok().map_err(|e| err("Memory", e))?;
                let buffer = IMFMediaBuffer::from_raw(raw);
                let mut data = std::ptr::null_mut();
                buffer.Lock(&mut data, None, None).map_err(|e| err("Memory", e))?;
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
                buffer.Unlock().map_err(|e| err("Memory", e))?;
                buffer.SetCurrentLength(bytes.len() as u32).map_err(|e| err("Memory", e))?;
                let mut raw = std::ptr::null_mut();
                (mf.create_sample)(&mut raw).ok().map_err(|e| err("Sample", e))?;
                let sample = IMFSample::from_raw(raw);
                sample.AddBuffer(&buffer).map_err(|e| err("Sample", e))?;
                sample.SetSampleTime(time).map_err(|e| err("Sample", e))?;
                sample.SetSampleDuration(duration).map_err(|e| err("Sample", e))?;
                self.sink.WriteSample(stream, &sample).map_err(|e| e.to_string())
            }
        }

        fn finish(self) -> Result<(), String> { unsafe { self.sink.Finalize() }.map_err(|e| err("Finishing the video file", e)) }
    }

    fn media_type(mf: &Mf) -> Result<IMFMediaType, String> {
        let mut raw = std::ptr::null_mut();
        unsafe { (mf.create_media_type)(&mut raw).ok().map_err(|e| err("Media type", e))?; Ok(IMFMediaType::from_raw(raw)) }
    }

    /// A writer with the hardware encoder if it takes the first frame, or Windows' software encoder.
    fn open_writer(mf: &Mf, options: &Options, width: u32, height: u32, first: &[u8], frame: i64, audio: bool) -> Result<Writer, String> {
        let _ = std::fs::remove_file(&options.path);
        if let Ok(writer) = Writer::create(mf, options, width, height, true, audio) {
            if writer.write(mf, first, 0, frame).is_ok() { return Ok(writer); }
            drop(writer);
            let _ = std::fs::remove_file(&options.path);
        }
        let writer = Writer::create(mf, options, width, height, false, audio)?;
        writer.write(mf, first, 0, frame)?;
        Ok(writer)
    }

    /// What the computer plays, or the microphone, captured on a thread of its own into a queue.
    struct Source { queue: Queue, stop: Arc<AtomicBool>, thread: Option<std::thread::JoinHandle<()>> }

    impl Source {
        fn open(loopback: bool) -> Result<Self, String> {
            let queue: Queue = Arc::new(Mutex::new(VecDeque::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
            let (into, stopped) = (queue.clone(), stop.clone());
            let thread = std::thread::Builder::new().name(if loopback { "still-sound" } else { "still-microphone" }.into()).spawn(move || unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                let (client, capture, silence) = match open_endpoint(loopback) {
                    Ok(opened) => { let _ = ready_tx.send(Ok(())); opened }
                    Err(e) => { let _ = ready_tx.send(Err(e)); return; }
                };
                while !stopped.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(10));
                    if let Some(silence) = &silence { silence.feed(); }
                    while capture.GetNextPacketSize().unwrap_or(0) > 0 {
                        let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0u32, 0u32);
                        if capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None).is_err() { break; }
                        let count = frames as usize * 2;
                        if let Ok(mut queue) = into.lock() {
                            if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || data.is_null() { queue.extend(std::iter::repeat_n(0i16, count)); }
                            else { queue.extend(std::slice::from_raw_parts(data as *const i16, count)); }
                            // Nobody is taking it (paused, say): keep the newest few seconds only.
                            let over = queue.len().saturating_sub(RATE as usize * 2 * 4);
                            queue.drain(..over / 2 * 2);
                        }
                        let _ = capture.ReleaseBuffer(frames);
                    }
                }
                let _ = client.Stop();
                if let Some(silence) = &silence { let _ = silence.client.Stop(); }
            }).map_err(|e| err("Sound capture couldn’t start", e))?;
            match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(())) => Ok(Source { queue, stop, thread: Some(thread) }),
                Ok(Err(e)) => Err(e),
                Err(_) => { stop.store(true, Ordering::Relaxed); Err(if loopback { "The computer’s sound didn’t start in time." } else { "The microphone didn’t start in time." }.into()) }
            }
        }
    }

    impl Drop for Source {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(thread) = self.thread.take() { let _ = thread.join(); }
        }
    }

    /// Opens the default speakers (to record what they play) or microphone, asking Windows to convert to 16-bit
    /// stereo at `RATE` whatever the device's own format.
    unsafe fn open_endpoint(loopback: bool) -> Result<(IAudioClient, IAudioCaptureClient, Option<Silence>), String> {
        let what = if loopback { "The computer’s sound can’t be recorded" } else { "The microphone can’t be used" };
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).map_err(|e| err(what, e))?;
        let device = devices.GetDefaultAudioEndpoint(if loopback { eRender } else { eCapture }, eConsole)
            .map_err(|e| err(if loopback { "There are no speakers or headphones to record from" } else { "There is no microphone" }, e))?;
        // Windows only hands over loopback sound while something plays; playing silence keeps it flowing, so quiet
        // stretches are in the recording as silence instead of being left out. Without it, sound may drift.
        let silence = Silence::start(&device).ok();
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(|e| err(what, e))?;
        let format = WAVEFORMATEX { wFormatTag: WAVE_FORMAT_PCM as u16, nChannels: 2, nSamplesPerSec: RATE, nAvgBytesPerSec: RATE * 4, nBlockAlign: 4, wBitsPerSample: 16, cbSize: 0 };
        let flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY | if loopback { AUDCLNT_STREAMFLAGS_LOOPBACK } else { 0 };
        client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2_000_000, 0, &format, None).map_err(|e| err(what, e))?;
        let capture: IAudioCaptureClient = client.GetService().map_err(|e| err(what, e))?;
        client.Start().map_err(|e| err(what, e))?;
        Ok((client, capture, if loopback { silence } else { None }))
    }

    /// Silence played to the speakers for the length of the recording.
    struct Silence { client: IAudioClient, render: IAudioRenderClient, size: u32 }

    impl Silence {
        unsafe fn start(device: &IMMDevice) -> windows::core::Result<Self> {
            let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
            let format = client.GetMixFormat()?;
            let started = client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2_000_000, 0, format, None);
            CoTaskMemFree(Some(format as *const _));
            started?;
            let silence = Silence { size: client.GetBufferSize()?, render: client.GetService()?, client };
            silence.feed();
            silence.client.Start()?;
            Ok(silence)
        }

        fn feed(&self) {
            unsafe {
                let free = self.size.saturating_sub(self.client.GetCurrentPadding().unwrap_or(self.size));
                if free > 0 && self.render.GetBuffer(free).is_ok() { let _ = self.render.ReleaseBuffer(free, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32); }
            }
        }
    }

    /// The recording's sound: every source, mixed and written a little behind the clock, because captured sound
    /// arrives in bursts and writing right up to "now" would leave gaps that the next burst can't fill.
    struct Sound { sources: Vec<Source>, written: u64 }

    /// How far the sound trails the clock, and how far ahead of the others a source may get, in stereo frames.
    const LAG: u64 = RATE as u64 / 10;
    const SLACK: usize = RATE as usize / 5;

    impl Sound {
        fn new(sources: Vec<Source>) -> Self { Sound { sources, written: 0 } }
        fn wanted(&self) -> bool { !self.sources.is_empty() }

        /// Forgets what was captured: when writing begins or begins again, and while paused.
        fn clear(&mut self) {
            for source in &self.sources { if let Ok(mut q) = source.queue.lock() { q.clear(); } }
        }

        /// Writes the sound up to `until` (100-ns units of recording time), less the lag unless `all`.
        fn write(&mut self, mf: &Mf, writer: &Writer, until: i64, all: bool) -> Result<(), String> {
            if !self.wanted() { return Ok(()); }
            let end = (until.max(0) as i128 * RATE as i128 / 10_000_000) as u64;
            let end = if all { end } else { end.saturating_sub(LAG) };
            if end <= self.written { return Ok(()); }
            let frames = (end - self.written) as usize;
            let mut queues: Vec<VecDeque<i16>> = self.sources.iter().map(|s| s.queue.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default()).collect();
            let mixed = mix(&mut queues, frames, SLACK);
            // What wasn't needed yet goes back in front of anything captured meanwhile.
            for (source, mut rest) in self.sources.iter().zip(queues) {
                if let Ok(mut q) = source.queue.lock() { rest.extend(q.drain(..)); *q = rest; }
            }
            writer.write_audio(mf, &mixed, self.written)?;
            self.written = end;
            Ok(())
        }
    }

    fn run(mf: &Mf, options: Options, mut sound: Sound, commands: mpsc::Receiver<Cmd>, ready: &mpsc::Sender<Result<(), String>>) -> Result<(), String> {
        let mut capture = Capture::open(&options)?;
        let (_, _, width, height) = capture.crop;
        let fps = options.fps.clamp(1, 60);
        let frame = 10_000_000 / fps as i64;
        // Windows sends a frame as soon as capture starts; wait briefly for it so the video doesn't begin black.
        let mut pixels = Vec::new();
        let waited = Instant::now();
        while !capture.next(&mut pixels)? {
            if waited.elapsed() > Duration::from_secs(2) { pixels = vec![0; width as usize * height as usize * 4]; break; }
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut writer = Some(open_writer(mf, &options, width, height, &pixels, frame, sound.wanted())?);
        sound.clear();
        let mut timeline = Timeline::new();
        let (mut frames, mut dropped, mut written_until) = (1u64, 0u64, frame);
        let _ = ready.send(Ok(()));
        let mut next_tick = Instant::now() + Duration::from_nanos(1_000_000_000 / fps as u64);
        loop {
            match commands.try_recv() {
                Ok(Cmd::Pause(on)) => {
                    // The sound up to the pause is already captured: write it all now, so none of it is lost and
                    // the sound after resuming lines up with the picture again.
                    if on && !timeline.paused() { if let Some(w) = &writer { sound.write(mf, w, timeline.now_hns(), true)?; } }
                    timeline.pause(on);
                }
                Ok(Cmd::Restart) => {
                    drop(writer.take());
                    writer = Some(open_writer(mf, &options, width, height, &pixels, frame, sound.wanted())?);
                    sound.clear(); sound.written = 0;
                    timeline = Timeline::new(); frames = 1; dropped = 0; written_until = frame;
                }
                Ok(Cmd::Stop(reply)) => {
                    let hardware = writer.as_ref().map(|w| w.hardware).unwrap_or(false);
                    let audio = writer.as_ref().is_some_and(|w| w.audio.is_some());
                    let mut result = Ok(());
                    if let Some(w) = &writer { result = sound.write(mf, w, written_until, true); }
                    let finished = writer.take().map(Writer::finish).unwrap_or(Ok(()));
                    let result = result.and(finished);
                    let _ = reply.send(result.map(|_| Finished { path: options.path.clone(), duration: written_until as f64 / 10_000_000.0, frames, dropped, hardware, lit: lit_share(&pixels), audio }));
                    return Ok(());
                }
                Ok(Cmd::Cancel) | Err(mpsc::TryRecvError::Disconnected) => {
                    drop(writer.take());
                    let _ = std::fs::remove_file(&options.path);
                    return Ok(());
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
            // Keep the pool drained while paused too, so resuming shows the screen as it is then.
            let changed = capture.next(&mut pixels)?;
            let _ = changed;
            if timeline.paused() { sound.clear(); }
            else if let Some(w) = &writer { sound.write(mf, w, timeline.now_hns(), false)?; }
            if !timeline.paused() {
                let time = timeline.now_hns();
                // Constant frame rate: one frame per tick, repeating the last picture when the screen is still.
                if time >= written_until {
                    if let Some(w) = &writer {
                        match w.write(mf, &pixels, written_until, frame) {
                            Ok(()) => { frames += 1; written_until += frame; }
                            Err(e) => return Err(e),
                        }
                        // Fell more than a frame behind: skip ahead instead of writing a burst of stale frames.
                        let behind = (timeline.now_hns() - written_until) / frame;
                        if behind > 0 { dropped += behind as u64; written_until += behind * frame; }
                    }
                }
            }
            let now = Instant::now();
            if next_tick > now { std::thread::sleep(next_tick - now); }
            next_tick += Duration::from_nanos(1_000_000_000 / fps as u64);
            if next_tick < Instant::now() { next_tick = Instant::now(); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crops_are_even_and_stay_on_the_display() {
        assert_eq!(even_crop(10.4, 20.6, 401.0, 301.0, 1920, 1080), (10, 21, 400, 300));
        assert_eq!(even_crop(-5.0, -5.0, 3000.0, 3000.0, 1920, 1080), (0, 0, 1920, 1080));
        assert_eq!(even_crop(1919.0, 1079.0, 50.0, 50.0, 1920, 1080), (1918, 1078, 2, 2));
        assert_eq!(even_crop(0.0, 0.0, 1.0, 1.0, 1920, 1080), (0, 0, 2, 2));
    }

    #[test]
    fn bitrate_matches_the_mac_and_stays_in_bounds() {
        assert_eq!(bitrate(1920, 1080, 30, "high"), 11_197_440);
        assert_eq!(bitrate(1920, 1080, 30, "balanced"), 5_598_720);
        assert_eq!(bitrate(1920, 1080, 30, "compact"), 2_799_360);
        assert_eq!(bitrate(1920, 1080, 30, "anything else"), 11_197_440);
        assert_eq!(bitrate(10, 10, 1, "high"), 400_000);
        assert_eq!(bitrate(1920, 1080, 30, "bitrate:8000000"), 8_000_000);
        assert_eq!(bitrate(1920, 1080, 30, "bitrate:500"), 1_000_000);
        assert_eq!(bitrate(1920, 1080, 30, "bitrate:x"), 11_197_440);
        assert_eq!(bitrate(7680, 4320, 60, "high"), 100_000_000);
    }

    #[test]
    fn an_empty_capture_reads_as_unlit() {
        assert_eq!(lit_share(&[]), 0.0);
        assert_eq!(lit_share(&[0, 0, 0, 255, 3, 2, 1, 255]), 0.0);
        assert_eq!(lit_share(&[0, 0, 0, 255, 200, 120, 40, 255]), 0.5);
    }

    #[test]
    fn sources_are_mixed_padded_and_kept_in_step() {
        use std::collections::VecDeque;
        // Two sources add up, and clip instead of wrapping around.
        let mut queues = vec![VecDeque::from(vec![100, -100, 30000, 30000]), VecDeque::from(vec![1, 2, 30000, 30000])];
        assert_eq!(mix(&mut queues, 2, 10), vec![101, -98, 32767, 32767]);
        // A source that is short is padded with silence; nothing is left half a frame.
        let mut queues = vec![VecDeque::from(vec![5, 6, 7])];
        assert_eq!(mix(&mut queues, 2, 10), vec![5, 6, 0, 0]);
        assert_eq!(queues[0].len(), 1);
        // A source far ahead loses its oldest sound, down to the slack.
        let mut queues = vec![VecDeque::from((0..20).collect::<Vec<i16>>())];
        assert_eq!(mix(&mut queues, 2, 3), vec![10, 11, 12, 13]);
        assert_eq!(queues[0].len(), 6);
    }

    #[test]
    fn pauses_do_not_count_as_recorded_time() {
        let mut t = Timeline::new();
        std::thread::sleep(std::time::Duration::from_millis(30));
        t.pause(true);
        let at_pause = t.now_hns();
        std::thread::sleep(std::time::Duration::from_millis(60));
        assert_eq!(t.now_hns(), at_pause);
        t.pause(false);
        std::thread::sleep(std::time::Duration::from_millis(20));
        let after = t.now_hns();
        assert!(after >= at_pause + 150_000 && after < at_pause + 500_000, "{at_pause} then {after}");
    }
}
