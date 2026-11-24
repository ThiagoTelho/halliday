//! A headset session: owns the data source (USB headset or a replayed recording), the reader
//! threads and the head tracker, and answers pose queries from any thread.
//!
//! USB sessions reconnect by themselves: a supervisor thread opens the headset when it appears,
//! runs the status and SLAM readers, and goes back to waiting when the link drops. On a full-speed
//! (USB 2) link it tries one re-enumeration, as GAV does, then reports [`LinkState::FullSpeedLink`].

use std::fs::File;
use std::io::BufReader;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::psvr2::protocol::{DistortionCalibration, FirmwareInfo, SlamRecord, StatusReport};
use crate::recording::{Reader, RecordingError, Stream};
use crate::time::host_time_ns;
use crate::tracking::blobs::Blob;
use crate::tracking::{HeadPose, HeadTracker, HeadsetStatus, TrackerConfig};

/// The bright spots one tracking camera saw at its newest exposure (the controllers' LEDs, and
/// whatever else is bright). Views: a frame holds two cameras' pictures, left then right or top
/// then bottom; in camera mode 4 the two kinds of frame give views 0, 1 and 2, 3.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CameraView {
    /// When the cameras exposed, on the host's clock (0 until the headset's clock is known).
    pub exposure_host_ns: i64,
    /// The frame's counter (one per exposure) and how many frames this view has had.
    pub counter: u32,
    pub frames: u32,
    /// The picture's size in pixels.
    pub width: u16,
    pub height: u16,
    pub spots: Vec<Blob>,
}

pub const CAMERA_VIEWS: usize = 4;

/// Connection state, as reported to the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum LinkState {
    /// No headset found yet (or it was unplugged); still looking.
    Searching = 0,
    /// Headset open, streams running.
    Connected = 1,
    /// Headset on a USB 2 path: no IMU. The user must move it to a USB 3 port.
    FullSpeedLink = 2,
    /// Driven by a recording.
    Replaying = 3,
    /// Replay reached the end (non-looping).
    Ended = 4,
    /// The headset is there but could not be opened (another app holds it?).
    Error = 5,
}

impl LinkState {
    fn from_i32(v: i32) -> LinkState {
        match v {
            1 => LinkState::Connected,
            2 => LinkState::FullSpeedLink,
            3 => LinkState::Replaying,
            4 => LinkState::Ended,
            5 => LinkState::Error,
            _ => LinkState::Searching,
        }
    }
}

struct Shared {
    tracker: Mutex<HeadTracker>,
    link: AtomicI32,
    running: AtomicBool,
    calibration: Mutex<Option<DistortionCalibration>>,
    firmware: Mutex<Option<FirmwareInfo>>,
    last_error: Mutex<Option<String>>,
    /// The camera mode asked for (0: off) and the spots' threshold.
    camera_mode: AtomicU32,
    camera_threshold: AtomicU32,
    camera: Mutex<[CameraView; CAMERA_VIEWS]>,
    /// Passthrough: while set, the newest picture of the bottom pair is kept (in memory only).
    camera_keep: AtomicBool,
    camera_image: Mutex<CameraImage>,
    #[cfg(feature = "usb")]
    headset: Mutex<Option<Arc<crate::psvr2::usb::Headset>>>,
}

/// The newest picture of the two bottom cameras, side by side, 8 bits a pixel, kept while
/// passthrough is on. It shows the user's room: it lives here, is handed to the renderer, and
/// is dropped when passthrough goes off. Never written anywhere.
/// In camera mode 0x10 it is the two raw fisheye pictures one above the other, BC4-compressed
/// as sent (`bc4`): the renderer reads that format as it is.
#[derive(Default)]
struct CameraImage {
    exposure_host_ns: i64,
    counter: u32,
    width: u32,
    height: u32,
    bc4: bool,
    pixels: Vec<u8>,
}

/// What `Session::camera_image` says of the picture it copied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CameraImageInfo {
    pub exposure_host_ns: i64,
    pub counter: u32,
    pub width: u32,
    pub height: u32,
    /// The pixels are BC4 blocks (mode 0x10's fisheyes), not 8 bits each.
    pub bc4: bool,
}

impl Shared {
    fn new(link: LinkState) -> Shared {
        Shared {
            tracker: Mutex::new(HeadTracker::new(TrackerConfig::default())),
            link: AtomicI32::new(link as i32),
            running: AtomicBool::new(true),
            calibration: Mutex::new(None),
            firmware: Mutex::new(None),
            last_error: Mutex::new(None),
            camera_mode: AtomicU32::new(0),
            camera_threshold: AtomicU32::new(200),
            camera: Mutex::new(Default::default()),
            camera_keep: AtomicBool::new(false),
            camera_image: Mutex::new(CameraImage::default()),
            #[cfg(feature = "usb")]
            headset: Mutex::new(None),
        }
    }

    fn set_link(&self, s: LinkState) {
        self.link.store(s as i32, Ordering::Release);
    }

    fn running(&self) -> bool {
        self.running.load(Ordering::Acquire)
    }

    fn tracker(&self) -> MutexGuard<'_, HeadTracker> {
        self.tracker.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn ingest(&self, stream: Stream, data: &[u8], host_ns: i64) {
        match stream {
            Stream::Status => {
                if let Ok(s) = StatusReport::parse(data) {
                    self.tracker().ingest_status(&s, host_ns);
                }
            }
            Stream::Slam => {
                if let Ok(s) = SlamRecord::parse(data) {
                    self.tracker().ingest_slam(&s, host_ns);
                }
            }
            Stream::FirmwareInfo => {
                if let Ok(f) = FirmwareInfo::parse(data) {
                    *self.firmware.lock().unwrap() = Some(f);
                }
            }
            Stream::DistortionCalibration => {
                if let Ok(c) = DistortionCalibration::parse(data) {
                    *self.calibration.lock().unwrap() = Some(c);
                }
            }
            Stream::Note => {}
        }
    }
}

pub struct Session {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl Session {
    /// Starts looking for a USB headset; connects (and reconnects) in the background.
    #[cfg(feature = "usb")]
    pub fn usb() -> Session {
        let shared = Arc::new(Shared::new(LinkState::Searching));
        let s = shared.clone();
        let thread = thread::Builder::new()
            .name("halliday-usb".into())
            .spawn(move || usb::supervise(&s))
            .expect("spawn USB thread");
        Session {
            shared,
            thread: Some(thread),
        }
    }

    /// Plays a recording in real time, re-timed to start now. With `looping`, starts over at the
    /// end (the tracker is reset each time, as after a reconnect).
    pub fn replay(path: impl Into<PathBuf>, looping: bool) -> Result<Session, RecordingError> {
        let path = path.into();
        // Open once up front so a bad path or file fails here, not in the thread.
        Reader::new(BufReader::new(File::open(&path)?))?;
        let shared = Arc::new(Shared::new(LinkState::Replaying));
        let s = shared.clone();
        let thread = thread::Builder::new()
            .name("halliday-replay".into())
            .spawn(move || replay(&s, &path, looping))
            .expect("spawn replay thread");
        Ok(Session {
            shared,
            thread: Some(thread),
        })
    }

    pub fn link_state(&self) -> LinkState {
        LinkState::from_i32(self.shared.link.load(Ordering::Acquire))
    }

    /// Head pose predicted for host time `at_host_ns` (see [`crate::time::host_time_ns`]).
    pub fn predict(&self, at_host_ns: i64) -> Option<HeadPose> {
        self.shared.tracker().predict(at_host_ns)
    }

    pub fn status(&self) -> HeadsetStatus {
        self.shared.tracker().status()
    }

    pub fn recenter(&self, full: bool) {
        let now = host_time_ns();
        let mut t = self.shared.tracker();
        if full {
            t.recenter_full(now)
        } else {
            t.recenter_yaw(now)
        }
    }

    /// The headset's lens calibration, or the fallback before one was read.
    pub fn calibration(&self) -> [f32; 8] {
        self.shared
            .calibration
            .lock()
            .unwrap()
            .map_or(DistortionCalibration::FALLBACK, |c| c.params)
    }

    pub fn firmware(&self) -> Option<FirmwareInfo> {
        self.shared.firmware.lock().unwrap().clone()
    }

    /// Cached PCB identity for per-headset camera calibration. No USB request is made here.
    /// Do not return the previous device's identity while reconnecting or replaying.
    pub fn headset_identity(&self) -> Option<String> {
        if self.link_state() != LinkState::Connected {
            return None;
        }
        let id = self.firmware()?.pcb_id;
        if self.link_state() != LinkState::Connected
            || id.is_empty()
            || id.len() > 16
            || !id.bytes().all(|b| b.is_ascii_graphic())
        {
            return None;
        }
        Some(id)
    }

    pub fn last_error(&self) -> Option<String> {
        self.shared.last_error.lock().unwrap().clone()
    }

    /// Switches the headset's tracking cameras to `mode` (0: off; 1: the two bottom cameras,
    /// normal exposure; 4: controller tracking) and sets what counts as a bright spot. The
    /// session's camera thread reads the frames and keeps each view's spots; nothing of the
    /// pictures themselves is kept. Does nothing for a replayed recording.
    pub fn set_camera(&self, mode: u32, threshold: u8) {
        self.shared
            .camera_threshold
            .store(u32::from(threshold), Ordering::Release);
        self.shared.camera_mode.store(mode, Ordering::Release);
    }

    /// The newest spots of a view (see [`CameraView`]); `None` for a view that has had no frame.
    /// Passthrough on or off: whether the bottom cameras' newest picture is kept for
    /// `camera_image`. Off drops the picture held.
    pub fn set_camera_keep(&self, on: bool) {
        self.shared.camera_keep.store(on, Ordering::Release);
        if !on {
            *self
                .shared
                .camera_image
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = CameraImage::default();
        }
    }

    /// Copies the bottom cameras' newest picture into `out` (left camera then right, side by
    /// side, 8 bits a pixel) if there is one other than `have` (a counter) and it fits.
    pub fn camera_image(&self, have: u32, out: &mut [u8]) -> Option<CameraImageInfo> {
        let image = self
            .shared
            .camera_image
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if image.pixels.is_empty() || image.counter == have || image.pixels.len() > out.len() {
            return None;
        }
        out[..image.pixels.len()].copy_from_slice(&image.pixels);
        Some(CameraImageInfo {
            exposure_host_ns: image.exposure_host_ns,
            counter: image.counter,
            width: image.width,
            height: image.height,
            bc4: image.bc4,
        })
    }

    pub fn camera_view(&self, view: usize) -> Option<CameraView> {
        let views = self.shared.camera.lock().unwrap_or_else(|e| e.into_inner());
        views.get(view).filter(|v| v.frames > 0).cloned()
    }

    /// Panel brightness 0..=1. Returns false when no USB headset is connected.
    pub fn set_brightness(&self, brightness: f32) -> bool {
        #[cfg(feature = "usb")]
        if let Some(h) = self.shared.headset.lock().unwrap().as_ref() {
            return h.set_brightness(brightness).is_ok();
        }
        let _ = brightness;
        false
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shared.running.store(false, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Sleeps in short steps so shutdown stays responsive. Returns false if the session stopped.
fn sleep_while_running(shared: &Shared, total: Duration) -> bool {
    let step = Duration::from_millis(50);
    let mut left = total;
    while shared.running() && !left.is_zero() {
        let d = left.min(step);
        thread::sleep(d);
        left -= d;
    }
    shared.running()
}

fn replay(shared: &Shared, path: &PathBuf, looping: bool) {
    loop {
        let reader = match File::open(path)
            .map_err(RecordingError::from)
            .and_then(|f| Reader::new(BufReader::new(f)))
        {
            Ok(r) => r,
            Err(e) => {
                *shared.last_error.lock().unwrap() = Some(e.to_string());
                shared.set_link(LinkState::Error);
                return;
            }
        };
        *shared.tracker() = HeadTracker::new(TrackerConfig::default());
        let start = host_time_ns();
        let mut first_t: Option<u64> = None;
        for record in reader {
            let Ok(r) = record else { break };
            let base = *first_t.get_or_insert(r.t_ns);
            let due = start + r.t_ns.saturating_sub(base) as i64;
            let wait = due - host_time_ns();
            if wait > 0 && !sleep_while_running(shared, Duration::from_nanos(wait as u64)) {
                return;
            }
            if !shared.running() {
                return;
            }
            shared.ingest(r.stream, &r.data, due);
        }
        if !looping || !shared.running() {
            shared.set_link(LinkState::Ended);
            return;
        }
    }
}

#[cfg(feature = "usb")]
mod usb {
    use super::*;
    use crate::psvr2::protocol::READ_BUFFER_SIZE;
    use crate::psvr2::usb::{Headset, UsbError};

    const RETRY: Duration = Duration::from_secs(1);
    const READ_TIMEOUT: Duration = Duration::from_millis(500);

    /// Gone this long, the headset was unplugged (not re-enumerating after a reset), and a
    /// slow link when it comes back is worth one more reset.
    const UNPLUGGED: Duration = Duration::from_secs(15);

    pub(super) fn supervise(shared: &Shared) {
        let mut reset_tried = false;
        let mut gone_since: Option<std::time::Instant> = None;
        while shared.running() {
            match Headset::open() {
                Ok(h) => {
                    reset_tried = false;
                    gone_since = None;
                    run_connected(shared, Arc::new(h));
                    shared.set_link(LinkState::Searching);
                }
                Err(UsbError::NotFound) => {
                    // A reset makes the headset vanish for a moment: that must not count as a
                    // new plug-in, or a USB 2 path was reset every two seconds for good, with
                    // nothing to say why (the adapter plugged straight into a Mac's USB 2 port).
                    let since = *gone_since.get_or_insert_with(std::time::Instant::now);
                    if since.elapsed() > UNPLUGGED {
                        reset_tried = false;
                    }
                    if !reset_tried || since.elapsed() > UNPLUGGED {
                        shared.set_link(LinkState::Searching);
                    }
                }
                Err(UsbError::FullSpeedLink) => {
                    gone_since = None;
                    if !reset_tried {
                        // A bad plug-in looks like this and one re-enumeration cures it (GAV).
                        reset_tried = true;
                        reset_headset();
                    } else {
                        shared.set_link(LinkState::FullSpeedLink);
                    }
                }
                Err(e) => {
                    *shared.last_error.lock().unwrap() = Some(e.to_string());
                    shared.set_link(LinkState::Error);
                }
            }
            if !sleep_while_running(shared, RETRY) {
                break;
            }
        }
    }

    /// The tracking cameras: follows the mode asked for, reads frames and keeps their bright
    /// spots. A camera that fails only stops the cameras, not the head tracking.
    fn cameras(shared: &Shared, headset: &Headset, alive: &AtomicBool) {
        // Reading and looking for spots are two threads: camera mode 3 sends 120 pictures a
        // second, and with one thread doing both, four top pictures in ten were lost while the
        // spots of the one before were being found.
        let (to_worker, pictures) = std::sync::mpsc::sync_channel::<(Vec<u8>, usize)>(8);
        let (give_back, spare) = std::sync::mpsc::channel::<Vec<u8>>();
        thread::scope(|scope| {
            scope.spawn(move || {
                for (buf, n) in pictures {
                    camera_picture(shared, &buf[..n]);
                    let _ = give_back.send(buf);
                }
            });
            let mut mode = 0u32;
            *shared.camera.lock().unwrap_or_else(|e| e.into_inner()) = Default::default();
            while shared.running() && alive.load(Ordering::Acquire) {
                let wanted = shared.camera_mode.load(Ordering::Acquire);
                if wanted != mode {
                    if let Err(e) = headset.set_camera_mode(wanted) {
                        *shared.last_error.lock().unwrap() = Some(format!("cameras: {e}"));
                        shared.camera_mode.store(mode, Ordering::Release);
                    } else {
                        mode = wanted;
                        *shared.camera.lock().unwrap_or_else(|e| e.into_inner()) =
                            Default::default();
                    }
                }
                if mode == 0 {
                    thread::sleep(Duration::from_millis(50));
                    continue;
                }
                let mut buf = spare
                    .try_recv()
                    .unwrap_or_else(|_| vec![0u8; 2 * 1024 * 1024]);
                match headset.read_camera(&mut buf, Duration::from_millis(100)) {
                    Ok(Some(0)) => {
                        // Empty transfers come while the cameras start.
                        thread::sleep(Duration::from_millis(1));
                    }
                    // (A picture the worker has no room for is dropped.)
                    Ok(Some(n)) => {
                        let _ = to_worker.try_send((buf, n));
                    }
                    Ok(None) => {}
                    Err(e) => {
                        *shared.last_error.lock().unwrap() = Some(format!("cameras: {e}"));
                        shared.camera_mode.store(0, Ordering::Release);
                    }
                }
            }
            if mode != 0 {
                let _ = headset.set_camera_mode(0);
            }
            drop(to_worker);
        });
    }

    /// One picture from the cameras: its bright spots, kept for its two views.
    fn camera_picture(shared: &Shared, bytes: &[u8]) {
        use crate::psvr2::camera::{self, FrameHeader};
        use crate::tracking::blobs::{self, BlobOptions};
        let Ok(header) = FrameHeader::parse(bytes) else {
            return;
        };
        let Some(pixels) = camera::pixels(&header, bytes) else {
            return;
        };
        // Camera mode 0x10 (kind 11): the bottom cameras' raw fisheye pictures, BC4.
        let bc4 = header.kind == 11;
        let decoded;
        let (pixels, w, h) = if bc4 {
            let Some(p) = camera::decode_bc4(pixels, camera::BC4_WIDTH, camera::BC4_HEIGHT) else {
                return;
            };
            decoded = p;
            (decoded.as_slice(), camera::BC4_WIDTH, camera::BC4_HEIGHT)
        } else {
            (pixels, header.width, header.height)
        };
        let options = BlobOptions {
            threshold: shared.camera_threshold.load(Ordering::Acquire) as u8,
            ..Default::default()
        };
        let halves = if bc4 {
            // About 1000 of each picture's 1024 columns are picture; the rest is padding.
            let across = camera::BC4_PICTURE_WIDTH;
            [(0, 0, across, h / 2), (0, h / 2, across, h)]
        } else if w > h {
            [(0, 0, w / 2, h), (w / 2, 0, w, h)]
        } else {
            [(0, 0, w, h / 2), (0, h / 2, w, h)]
        };
        let exposure_host_ns = shared.tracker().clock_offset_ns().map_or(0, |offset| {
            // The header's clock is 32 bits of microseconds and the offset belongs to
            // the unwrapped one: of the times a wrap apart, the one nearest to now is
            // meant (a capture once came out 4 295 s in the past).
            const WRAP_NS: i64 = (1 << 32) * 1000;
            let t = i64::from(header.vts_us) * 1000 + offset;
            let now = crate::time::host_time_ns();
            t + (now - t + WRAP_NS / 2).div_euclid(WRAP_NS) * WRAP_NS
        });
        // The second picture of an exposure (mode 3's top cameras, kind 3; mode 4's kind 5) goes
        // to views 2 and 3.
        let first = if header.kind == 3 || header.kind == 5 {
            2
        } else {
            0
        };
        // Passthrough: the bottom pair's picture as it came (mode 1's and mode 3's kind 0; mode
        // 0x10's still compressed).
        if (header.kind == 0 || bc4) && shared.camera_keep.load(Ordering::Acquire) {
            let mut image = shared
                .camera_image
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            image.pixels.clear();
            image.pixels.extend_from_slice(if bc4 {
                camera::pixels(&header, bytes).unwrap_or_default()
            } else {
                pixels
            });
            image.exposure_host_ns = exposure_host_ns;
            image.counter = header.counter;
            image.width = w as u32;
            image.height = h as u32;
            image.bc4 = bc4;
        }
        for (i, half) in halves.into_iter().enumerate() {
            let spots = blobs::find(pixels, w, half, options);
            let mut views = shared.camera.lock().unwrap_or_else(|e| e.into_inner());
            let view = &mut views[first + i];
            *view = CameraView {
                exposure_host_ns,
                counter: header.counter,
                frames: view.frames.wrapping_add(1).max(1),
                width: (half.2 - half.0) as u16,
                height: (half.3 - half.1) as u16,
                spots,
            };
        }
    }

    fn reset_headset() {
        // Re-open without claiming, just to reset: libusb may block ~10 s, so do it on its own thread.
        thread::spawn(|| {
            if let Ok(ctx) = rusb::Context::new() {
                use rusb::UsbContext;
                if let Some(h) = ctx.open_device_with_vid_pid(
                    crate::psvr2::USB_VENDOR_ID,
                    crate::psvr2::USB_PRODUCT_ID,
                ) {
                    let _ = h.reset();
                }
            }
        });
    }

    fn run_connected(shared: &Shared, headset: Arc<Headset>) {
        *shared.tracker() = HeadTracker::new(TrackerConfig::default());
        // A failed read must not attach the previous headset's camera profile to a new device.
        *shared.firmware.lock().unwrap() = headset.firmware_info().ok();
        match headset.distortion_calibration() {
            Ok(c) => *shared.calibration.lock().unwrap() = Some(c),
            Err(e) => *shared.last_error.lock().unwrap() = Some(format!("calibration: {e}")),
        }
        *shared.headset.lock().unwrap() = Some(headset.clone());
        shared.set_link(LinkState::Connected);

        let alive = AtomicBool::new(true);
        thread::scope(|s| {
            {
                let (headset, alive) = (&headset, &alive);
                s.spawn(move || cameras(shared, headset, alive));
            }
            for stream in [Stream::Status, Stream::Slam] {
                let (headset, alive) = (&headset, &alive);
                s.spawn(move || {
                    let mut buf = vec![0u8; READ_BUFFER_SIZE];
                    while shared.running() && alive.load(Ordering::Acquire) {
                        let read = match stream {
                            Stream::Status => headset.read_status(&mut buf, READ_TIMEOUT),
                            _ => headset.read_slam(&mut buf, READ_TIMEOUT),
                        };
                        match read {
                            Ok(Some(n)) => shared.ingest(stream, &buf[..n], host_time_ns()),
                            Ok(None) => {}
                            Err(e) => {
                                *shared.last_error.lock().unwrap() = Some(e.to_string());
                                alive.store(false, Ordering::Release);
                            }
                        }
                    }
                });
            }
        });
        *shared.headset.lock().unwrap() = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::psvr2::protocol::{IMU_RECORD_SIZE, SLAM_RECORD_SIZE, STATUS_HEADER_SIZE};
    use crate::recording::Writer;

    #[test]
    fn camera_profile_identity_is_cached_and_connected_only() {
        let shared = Arc::new(Shared::new(LinkState::Connected));
        let session = Session { shared: shared.clone(), thread: None };
        assert_eq!(session.headset_identity(), None);
        let firmware = |id: &str| FirmwareInfo {
            version: 1, commit_hash: String::new(), pcb_id: id.into(), recovery_version: 1,
        };
        *shared.firmware.lock().unwrap() = Some(firmware("TEST-PCB-1234567"));
        assert_eq!(session.headset_identity().as_deref(), Some("TEST-PCB-1234567"));
        for link in [LinkState::Searching, LinkState::Replaying, LinkState::Error] {
            shared.set_link(link);
            assert_eq!(session.headset_identity(), None);
        }
        shared.set_link(LinkState::Connected);
        for id in ["", " ", "has space", "bad\0id", "bad\nid", "abcdefghijklmnopq", "nonasciié"] {
            *shared.firmware.lock().unwrap() = Some(firmware(id));
            assert_eq!(session.headset_identity(), None, "{id:?}");
        }
        *shared.firmware.lock().unwrap() = Some(firmware("OTHER-PCB"));
        assert_eq!(session.headset_identity().as_deref(), Some("OTHER-PCB"));
        *shared.firmware.lock().unwrap() = None;
        assert_eq!(session.headset_identity(), None);
    }

    fn recording(ms: u32) -> PathBuf {
        let mut w = Writer::new(Vec::new(), 0).unwrap();
        for i in 0..ms {
            let vts = i * 1000;
            let mut st = vec![0u8; STATUS_HEADER_SIZE];
            st[1] = 1;
            st[5] = 64;
            for _ in 0..2 {
                let mut rec = vec![0u8; IMU_RECORD_SIZE];
                rec[0..4].copy_from_slice(&vts.to_le_bytes());
                st.extend(rec);
            }
            w.write(Stream::Status, vts as u64 * 1000 + 1_000_000, &st)
                .unwrap();
            if i % 16 == 0 {
                let mut slam = vec![0u8; SLAM_RECORD_SIZE];
                slam[0..3].copy_from_slice(b"SLA");
                slam[8..12].copy_from_slice(&vts.to_le_bytes());
                slam[28..32].copy_from_slice(&1f32.to_le_bytes());
                w.write(Stream::Slam, vts as u64 * 1000 + 23_000_000, &slam)
                    .unwrap();
            }
        }
        let path =
            std::env::temp_dir().join(format!("halliday-session-{}-{ms}.hrec", std::process::id()));
        std::fs::write(&path, w.into_inner()).unwrap();
        path
    }

    #[test]
    fn replay_drives_the_tracker_and_ends() {
        let path = recording(150);
        let s = Session::replay(&path, false).unwrap();
        assert_eq!(s.link_state(), LinkState::Replaying);
        thread::sleep(Duration::from_millis(100));
        let pose = s.predict(host_time_ns()).expect("pose while replaying");
        assert!(pose.predicted);
        assert_eq!(s.status().ipd_mm, 64);
        assert_eq!(s.calibration(), DistortionCalibration::FALLBACK);
        thread::sleep(Duration::from_millis(250));
        assert_eq!(s.link_state(), LinkState::Ended);
        drop(s);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn looping_replay_stops_promptly_on_drop() {
        let path = recording(2000);
        let s = Session::replay(&path, true).unwrap();
        thread::sleep(Duration::from_millis(30));
        let t = std::time::Instant::now();
        drop(s);
        assert!(
            t.elapsed() < Duration::from_millis(200),
            "{:?}",
            t.elapsed()
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn replay_rejects_missing_files() {
        assert!(Session::replay("/nonexistent/x.hrec", false).is_err());
    }
}
