//! `halliday-probe`: PS VR2 diagnostics.
//!
//! ```text
//! halliday-probe list                       PS VR2 headsets on USB and their link speed
//! halliday-probe info                       firmware and lens calibration
//! halliday-probe stream [-s SECONDS] [-r FILE] [-n NOTE]
//!                                           live status + pose, optionally recorded to FILE
//! halliday-probe replay FILE                statistics of a recording
//! halliday-probe track FILE                 head-tracker prediction error over a recording
//! halliday-probe imu FILE                   the headset's IMU samples as CSV (its vibration)
//! halliday-probe synth FILE [-s SECONDS]    write a synthetic recording (looking left and right)
//! halliday-probe game-sim [-s SECONDS]      act as a VR game on Halliday's OpenVR bridge
//! halliday-probe game-host [-s SECONDS] [--eye WxH] [--hz HZ]
//!                                           act as Halliday for a game (a still head, two
//!                                           controllers), to test the runtime without the app
//! halliday-probe game-peek FILE.ppm [--overlay N | --skybox]
//!                                           save the running game's newest frame (or an
//!                                           overlay's picture, its skybox; and list its overlays)
//! ```
//!
//! The headset's interfaces are claimed exclusively: close other PS VR2 apps (GAV, Halliday) first.

use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use halliday_core::psvr2::protocol::{self, SlamRecord, StatusReport};
use halliday_core::psvr2::usb::{self, Headset};
use halliday_core::recording::{self, Stream};
use halliday_core::summary;
use halliday_core::tracking::replay as track_replay;

type Error = Box<dyn std::error::Error>;
type Recorder = Arc<Mutex<recording::Writer<BufWriter<File>>>>;

const USAGE: &str = "usage:
  halliday-probe list
  halliday-probe info
  halliday-probe stream [-s SECONDS] [-r FILE] [-n NOTE]
  halliday-probe camera PREFIX [--mode N] [-n FRAMES]
  halliday-probe blobs FILE.pgm [--threshold N]
  halliday-probe apk AndroidManifest.xml [--xml]
  halliday-probe hands DUMP.txt [--lag MS] [--fit] [--focal PX] [--mount] [--bottom-only] [--leds FILE] [--list]
  halliday-probe replay FILE
  halliday-probe track FILE
  halliday-probe imu FILE          the headset's IMU samples as CSV
  halliday-probe reset
  halliday-probe fisheye-pairs PREFIX [-n ROUNDS]
  halliday-probe synth FILE [-s SECONDS]
  halliday-probe game-sim [-s SECONDS]
  halliday-probe game-host [-s SECONDS] [--eye WxH] [--hz HZ]
  halliday-probe game-peek FILE.ppm [--overlay N | --skybox]";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("list") => list(),
        Some("info") => info(),
        Some("stream") => stream(&args[1..]),
        Some("replay") => match args.get(1) {
            Some(path) => replay(path),
            None => Err("replay needs a FILE".into()),
        },
        Some("fisheye-pairs") => match args.get(1) {
            Some(prefix) => fisheye_pairs(prefix, &args[2..]),
            None => Err("fisheye-pairs needs a PREFIX for the pictures it saves".into()),
        },
        Some("camera") => match args.get(1) {
            Some(prefix) => camera(prefix, &args[2..]),
            None => Err("camera needs a PREFIX for the pictures it saves".into()),
        },
        Some("blobs") => match args.get(1) {
            Some(path) => blobs(path, &args[2..]),
            None => Err("blobs needs a FILE.pgm saved by `camera`".into()),
        },
        Some("apk") => match args.get(1) {
            Some(path) => apk(path, args.iter().any(|a| a == "--xml")),
            None => Err("apk needs the AndroidManifest.xml taken out of an APK".into()),
        },
        Some("hands") => match args.get(1) {
            Some(path) => hands(path, &args[2..]),
            None => Err("hands needs a file written by Halliday's --camera-dump".into()),
        },
        Some("reset") => reset(),
        Some("imu") => match args.get(1) {
            Some(path) => imu(path),
            None => Err("imu needs a FILE".into()),
        },
        Some("axes") => match args.get(1) {
            Some(path) => axes(
                path,
                args.get(2).and_then(|s| s.parse().ok()).unwrap_or(15.0),
            ),
            None => Err("axes needs a FILE".into()),
        },
        Some("track") => match args.get(1) {
            Some(path) => track(path),
            None => Err("track needs a FILE".into()),
        },
        Some("synth") => synth(&args[1..]),
        Some("game-sim") => game_sim(&args[1..]),
        Some("game-peek") => game_peek(&args[1..]),
        Some("game-host") => game_host(&args[1..]),
        Some("-h" | "--help" | "help") => {
            println!("{USAGE}");
            Ok(())
        }
        _ => Err(USAGE.into()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("halliday-probe: {e}");
            ExitCode::FAILURE
        }
    }
}

fn list() -> Result<(), Error> {
    let headsets = usb::find_headsets()?;
    if headsets.is_empty() {
        println!("No PS VR2 headset on USB.");
    }
    for h in headsets {
        let note = match h.speed {
            usb::Speed::Low | usb::Speed::Full => "  <- USB 2 link: the IMU stream will be missing",
            _ => "",
        };
        println!(
            "PS VR2 on bus {} address {}: {:?} speed{note}",
            h.bus, h.address, h.speed
        );
    }
    Ok(())
}

fn info() -> Result<(), Error> {
    let headset = Headset::open()?;
    println!("Link speed: {:?}", headset.speed());
    let fw = headset.firmware_info()?;
    println!(
        "Firmware: {:08x} (recovery {:08x})",
        fw.version, fw.recovery_version
    );
    println!("Build:    {}", fw.commit_hash);
    println!("PCB id:   {}", fw.pcb_id);
    let cal = headset.distortion_calibration()?;
    println!("Distortion calibration (block version {}):", cal.version);
    println!(
        "  left  offset ({:+.6}, {:+.6})  rot (cos {:.6}, sin {:+.6})",
        cal.params[0], cal.params[1], cal.params[4], cal.params[5]
    );
    println!(
        "  right offset ({:+.6}, {:+.6})  rot (cos {:.6}, sin {:+.6})",
        cal.params[2], cal.params[3], cal.params[6], cal.params[7]
    );
    Ok(())
}

#[derive(Default)]
struct Live {
    status: Option<StatusReport>,
    slam: Option<SlamRecord>,
    status_packets: u64,
    imu_samples: u64,
    slam_records: u64,
    error: Option<String>,
}

fn stream(args: &[String]) -> Result<(), Error> {
    let mut seconds: Option<f64> = None;
    let mut record_path: Option<String> = None;
    let mut note: Option<String> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut value = || {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{a} needs a value"))
        };
        match a.as_str() {
            "-s" | "--seconds" => seconds = Some(value()?.parse()?),
            "-r" | "--record" => record_path = Some(value()?),
            "-n" | "--note" => note = Some(value()?),
            other => return Err(format!("unknown option {other}\n{USAGE}").into()),
        }
    }

    let headset = Arc::new(Headset::open()?);
    let start = Instant::now();
    let t_ns = move || start.elapsed().as_nanos() as u64;

    let recorder: Option<Recorder> = match &record_path {
        Some(path) => {
            let unix_ns = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() as u64;
            let mut w = recording::Writer::new(BufWriter::new(File::create(path)?), unix_ns)?;
            if let Some(n) = &note {
                w.write(Stream::Note, 0, n.as_bytes())?;
            }
            let fw = headset.get_report(
                protocol::report::GET_FIRMWARE_INFO,
                protocol::FIRMWARE_INFO_SIZE,
            )?;
            w.write(Stream::FirmwareInfo, t_ns(), &fw)?;
            let cal = headset.get_report(
                protocol::report::GET_DISTORTION_CALIBRATION,
                protocol::DISTORTION_BLOCK_SIZE,
            )?;
            w.write(Stream::DistortionCalibration, t_ns(), &cal)?;
            eprintln!("Recording to {path}");
            Some(Arc::new(Mutex::new(w)))
        }
        None => None,
    };

    let live = Arc::new(Mutex::new(Live::default()));
    let running = Arc::new(AtomicBool::new(true));
    let readers = [Stream::Status, Stream::Slam].map(|kind| {
        let (headset, live, running, recorder) = (
            headset.clone(),
            live.clone(),
            running.clone(),
            recorder.clone(),
        );
        thread::spawn(move || read_loop(kind, &headset, &live, &running, recorder.as_ref(), t_ns))
    });

    eprintln!(
        "Streaming{}. Ctrl-C to stop.",
        seconds.map(|s| format!(" for {s} s")).unwrap_or_default()
    );
    let mut last = (0u64, 0u64, Instant::now());
    while seconds.is_none_or(|s| start.elapsed().as_secs_f64() < s) {
        thread::sleep(Duration::from_millis(250));
        let l = live.lock().unwrap();
        if let Some(e) = &l.error {
            eprintln!("\nStream stopped: {e}");
            break;
        }
        let dt = last.2.elapsed().as_secs_f64();
        let imu_hz = (l.imu_samples - last.0) as f64 / dt;
        let slam_hz = (l.slam_records - last.1) as f64 / dt;
        last = (l.imu_samples, l.slam_records, Instant::now());
        let status = l.status.as_ref().map_or("no status yet".into(), |s| {
            format!(
                "worn {} fn {} ipd {}mm dp {}",
                u8::from(s.worn),
                u8::from(s.function_button),
                s.ipd_mm,
                s.dprx_status
            )
        });
        let pose = l.slam.map_or("no pose yet".into(), |s| {
            let p = s.tracking_position();
            let q = s.tracking_orientation();
            format!(
                "pos ({:+.3} {:+.3} {:+.3}) m  quat ({:+.3} {:+.3} {:+.3} {:+.3})",
                p[0], p[1], p[2], q.w, q.x, q.y, q.z
            )
        });
        eprint!("\r{status} | imu {imu_hz:5.0} Hz slam {slam_hz:3.0} Hz | {pose}   ");
    }

    running.store(false, Ordering::Relaxed);
    for r in readers {
        let _ = r.join();
    }
    let l = live.lock().unwrap();
    eprintln!(
        "\n{} status packets, {} IMU samples, {} SLAM records in {:.1} s",
        l.status_packets,
        l.imu_samples,
        l.slam_records,
        start.elapsed().as_secs_f64()
    );
    if let Some(rec) = recorder {
        rec.lock().unwrap().flush()?;
    }
    Ok(())
}

fn read_loop(
    kind: Stream,
    headset: &Headset,
    live: &Mutex<Live>,
    running: &AtomicBool,
    recorder: Option<&Recorder>,
    t_ns: impl Fn() -> u64,
) {
    let mut buf = vec![0u8; protocol::READ_BUFFER_SIZE];
    let timeout = Duration::from_millis(500);
    while running.load(Ordering::Relaxed) {
        let read = match kind {
            Stream::Status => headset.read_status(&mut buf, timeout),
            _ => headset.read_slam(&mut buf, timeout),
        };
        let n = match read {
            Ok(Some(n)) => n,
            Ok(None) => continue,
            Err(e) => {
                live.lock().unwrap().error = Some(e.to_string());
                return;
            }
        };
        let data = &buf[..n];
        if let Some(rec) = recorder {
            if let Err(e) = rec.lock().unwrap().write(kind, t_ns(), data) {
                live.lock().unwrap().error = Some(format!("recording failed: {e}"));
                return;
            }
        }
        let mut l = live.lock().unwrap();
        match kind {
            Stream::Status => {
                if let Ok(s) = StatusReport::parse(data) {
                    l.status_packets += 1;
                    l.imu_samples += s.imu.len() as u64;
                    l.status = Some(s);
                }
            }
            _ => {
                if let Ok(s) = SlamRecord::parse(data) {
                    l.slam_records += 1;
                    l.slam = Some(s);
                }
            }
        }
    }
}

fn replay(path: &str) -> Result<(), Error> {
    let reader = recording::Reader::new(BufReader::new(File::open(path)?))?;
    let s = summary::summarize(reader)?;
    for n in &s.notes {
        println!("Note: {n}");
    }
    if let Some(fw) = &s.firmware {
        println!("Firmware: {:08x}, PCB id {}", fw.version, fw.pcb_id);
    }
    println!("Duration: {:.2} s", s.duration_s);
    println!(
        "Status:   {} packets, {} IMU samples ({:.0} Hz)",
        s.status_packets,
        s.imu_samples,
        s.imu_rate_hz()
    );
    println!(
        "SLAM:     {} records ({:.1} Hz)",
        s.slam_records,
        s.slam_rate_hz()
    );
    println!(
        "Worn:     {:.0}% of status packets, IPD {:?} mm",
        s.worn_fraction * 100.0,
        s.ipd_mm
    );
    if let (Some(a), Some(b)) = (s.first_position, s.last_position) {
        println!(
            "Position: first ({:+.3} {:+.3} {:+.3}) last ({:+.3} {:+.3} {:+.3}) m",
            a[0], a[1], a[2], b[0], b[1], b[2]
        );
    }
    if s.imu_vts_regressions > 0 {
        println!(
            "Warning:  {} IMU timestamps went backwards",
            s.imu_vts_regressions
        );
    }
    for (stream, n) in &s.parse_errors {
        println!("Warning:  {n} {stream} packets failed to parse");
    }
    Ok(())
}

/// Switches the headset's tracking cameras on in `--mode N` (4, the controller-tracking mode, by
/// default), reads `-n` frames (12), says what each is and saves the pictures as
/// `PREFIX-<n>.pgm`, then switches the cameras off. For seeing what the cameras see (the
/// controllers' LEDs, ROADMAP W11 E.2): nothing is kept beyond the files asked for.
fn camera(prefix: &str, args: &[String]) -> Result<(), Error> {
    let mut mode = 4u32;
    let mut frames = 12usize;
    let mut i = 0;
    while i < args.len() {
        match (args[i].as_str(), args.get(i + 1)) {
            ("--mode", Some(v)) => {
                mode = u32::from_str_radix(
                    v.trim_start_matches("0x"),
                    if v.starts_with("0x") { 16 } else { 10 },
                )?
            }
            ("-n", Some(v)) => frames = v.parse()?,
            _ => return Err(USAGE.into()),
        }
        i += 2;
    }
    let headset = usb::Headset::open()?;
    headset.set_camera_mode(mode)?;
    println!("camera mode {mode}: reading {frames} frames");
    let mut buf = vec![0u8; 2 * 1024 * 1024];
    let started = Instant::now();
    let mut got = 0;
    let mut empty = 0;
    let mut result = Ok(());
    while got < frames && started.elapsed() < Duration::from_secs(10) {
        let n = match headset.read_camera(&mut buf, Duration::from_millis(500)) {
            // Empty transfers come while the cameras start: not frames.
            Ok(Some(0)) => {
                empty += 1;
                thread::sleep(Duration::from_millis(1));
                continue;
            }
            Ok(Some(n)) => n,
            Ok(None) => continue,
            Err(e) => {
                result = Err(e.into());
                break;
            }
        };
        got += 1;
        // Known sizes: a 256-byte header, then 8-bit pixels.
        let shape = match n {
            520_448 => Some((512usize, 1016usize)),
            819_456 => Some((1280, 640)),
            409_856 => Some((640, 640)),
            260_352 => Some((256, 1016)),
            80_256 => Some((400, 200)),
            _ => None,
        };
        let header: Vec<String> = buf[..n.min(32)]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let pixels = &buf[n.min(256)..n];
        let brightest = pixels.iter().copied().max().unwrap_or(0);
        let bright = pixels.iter().filter(|&&p| p >= 200).count();
        let mean =
            pixels.iter().map(|&p| u64::from(p)).sum::<u64>() as f64 / pixels.len().max(1) as f64;
        println!(
            "frame {got}: {n} bytes at {:.3} s, {} · mean {mean:.1}, brightest {brightest}, {bright} pixels over 200 · header {}",
            started.elapsed().as_secs_f64(),
            shape.map_or("unknown shape".into(), |(w, h)| format!("{w}×{h}")),
            header.join(" ")
        );
        let path = match shape {
            Some((w, h)) if pixels.len() >= w * h => {
                let path = format!("{prefix}-{got}.pgm");
                let mut file = BufWriter::new(File::create(&path)?);
                write!(file, "P5\n{w} {h}\n255\n")?;
                file.write_all(&pixels[..w * h])?;
                path
            }
            _ => {
                let path = format!("{prefix}-{got}.bin");
                File::create(&path)?.write_all(&buf[..n])?;
                path
            }
        };
        println!("  saved {path}");
    }
    // Always off again: the cameras are not left running.
    headset.set_camera_mode(0)?;
    println!("{got} frames, {empty} empty transfers");
    if got == 0 && result.is_ok() {
        return Err("no camera frame arrived in 10 s".into());
    }
    result
}

/// Pictures of the same still scene in camera mode 1 (the bottom pair rectified, 1280 × 640) and
/// mode 0x10 (the same two cameras' raw fisheye pictures, BC4, 1024 × 2032 decoded), modes taken
/// in turn `-n` times (3 by default): PREFIX-1-N.pgm and PREFIX-16-N.pgm. For fitting the
/// fisheyes' lens model: the same sensors, so one picture is the other turned and undistorted.
/// The headset must not move: each round's pictures can be compared with the first's.
fn fisheye_pairs(prefix: &str, args: &[String]) -> Result<(), Error> {
    use halliday_core::psvr2::camera::{BC4_HEIGHT, BC4_WIDTH, decode_bc4};
    let rounds: usize = match (args.first().map(String::as_str), args.get(1)) {
        (Some("-n"), Some(v)) => v.parse()?,
        (None, _) => 3,
        _ => return Err(USAGE.into()),
    };
    let headset = usb::Headset::open()?;
    let mut buf = vec![0u8; 2 * 1024 * 1024];
    let save = |path: &str, w: usize, h: usize, px: &[u8]| -> Result<(), Error> {
        let mut file = BufWriter::new(File::create(path)?);
        write!(file, "P5\n{w} {h}\n255\n")?;
        file.write_all(&px[..w * h])?;
        Ok(())
    };
    let mut result = Ok(());
    'rounds: for round in 1..=rounds {
        for (mode, size) in [(1u32, 819_456usize), (0x10, 1_040_640)] {
            headset.set_camera_mode(mode)?;
            // Frames of the mode before come first (its size tells them apart), and the first
            // few of the new one while the cameras settle: the fourth of the new size is kept.
            let started = Instant::now();
            let mut seen = 0;
            while seen < 4 {
                if started.elapsed() > Duration::from_secs(10) {
                    result = Err(format!("mode {mode}: no frames in 10 s").into());
                    break 'rounds;
                }
                match headset.read_camera(&mut buf, Duration::from_millis(500)) {
                    Ok(Some(n)) if n == size => seen += 1,
                    Ok(_) => continue,
                    Err(e) => {
                        result = Err(e.into());
                        break 'rounds;
                    }
                }
            }
            let pixels = &buf[256..size];
            let path = format!("{prefix}-{mode}-{round}.pgm");
            if mode == 1 {
                save(&path, 1280, 640, pixels)?;
            } else {
                let px = decode_bc4(pixels, BC4_WIDTH, BC4_HEIGHT).ok_or("short BC4 picture")?;
                save(&path, BC4_WIDTH, BC4_HEIGHT, &px)?;
            }
            let mean = pixels.iter().map(|&p| u64::from(p)).sum::<u64>() / pixels.len() as u64;
            println!("round {round}, mode {mode}: {path} (raw mean {mean})");
        }
    }
    headset.set_camera_mode(0)?;
    result
}

/// The bright spots of a picture saved by `camera`, for each camera in it (a frame holds two:
/// side by side when it is wider than tall, one above the other otherwise).
fn blobs(path: &str, args: &[String]) -> Result<(), Error> {
    use halliday_core::tracking::blobs::{BlobOptions, find};
    let mut options = BlobOptions::default();
    if let [flag, value] = args
        && flag == "--threshold"
    {
        options.threshold = value.parse()?;
    }
    let file = std::fs::read(path)?;
    // "P5\n<width> <height>\n255\n", as `camera` writes it.
    let text = String::from_utf8_lossy(&file[..file.len().min(32)]).into_owned();
    let mut fields = text.split_whitespace();
    let (Some("P5"), Some(w), Some(h)) = (fields.next(), fields.next(), fields.next()) else {
        return Err("not a PGM picture saved by `camera`".into());
    };
    let (width, height): (usize, usize) = (w.parse()?, h.parse()?);
    let pixels = file
        .get(file.len() - width * height..)
        .ok_or("the picture is cut short")?;
    let views = if width > height {
        [
            ("left", (0, 0, width / 2, height)),
            ("right", (width / 2, 0, width, height)),
        ]
    } else {
        [
            ("top", (0, 0, width, height / 2)),
            ("bottom", (0, height / 2, width, height)),
        ]
    };
    for (name, view) in views {
        let found = find(pixels, width, view, options);
        println!(
            "{name}: {} spots at or above {}",
            found.len(),
            options.threshold
        );
        for b in found.iter().take(24) {
            println!(
                "  ({:6.1}, {:6.1})  {:3} px, {}×{}, peak {}, fill {:.2}",
                b.x,
                b.y,
                b.area,
                b.width(),
                b.height(),
                b.peak,
                b.fill()
            );
        }
    }
    Ok(())
}

/// What an Android package says of itself: its binary manifest read (`unzip -p APP.apk
/// AndroidManifest.xml > FILE`), or with `--xml` written out as text.
fn apk(path: &str, xml: bool) -> Result<(), Error> {
    use halliday_core::apk::Manifest;
    let manifest = Manifest::parse(&std::fs::read(path)?)
        .map_err(|e| format!("not a manifest Halliday can read: {e:?}"))?;
    if xml {
        print!("{}", manifest.to_xml());
        return Ok(());
    }
    println!(
        "{} {} (code {}), for Android SDK {} and up",
        manifest.package, manifest.version_name, manifest.version_code, manifest.min_sdk
    );
    for a in &manifest.activities {
        println!(
            "  activity {}{}{}{}",
            a.name,
            if a.launcher {
                " · what a launcher starts"
            } else {
                ""
            },
            if a.vr { " · VR" } else { "" },
            a.native_library
                .as_ref()
                .map_or(String::new(), |lib| format!(" · native: lib{lib}.so"))
        );
    }
    println!("  {} permissions", manifest.permissions.len());
    Ok(())
}

/// The controllers' places through a capture of the bottom cameras' spots (Halliday's
/// `--camera-dump FILE`), with the cameras' built-in numbers; `--fit` fits those numbers to the
/// capture first, `--list` prints every fix.
fn hands(path: &str, args: &[String]) -> Result<(), Error> {
    use halliday_core::sense::Hand;
    use halliday_core::tracking::hands::{HandTracker, calibrate, parse_dump};
    use halliday_core::tracking::stereo::PSVR2_BOTTOM;
    let mut frames = parse_dump(&std::fs::read_to_string(path)?);
    // `--lag MS`: each controller's orientation taken at the exposure's time, its reports
    // arriving MS after the motion they tell of (dumps that hold the reports' times).
    if let Some(i) = args.iter().position(|a| a == "--lag") {
        let ms: f64 = args.get(i + 1).ok_or("--lag needs milliseconds")?.parse()?;
        halliday_core::tracking::hands::at_exposure(&mut frames, (ms * 1e6) as i64);
    }
    let (Some(first), Some(last)) = (frames.first(), frames.last()) else {
        return Err("no exposure with both bottom pictures in that file".into());
    };
    let seconds = |t_ns: u64| (t_ns - first.t_ns) as f64 * 1e-9;
    println!(
        "{} exposures over {:.1} s",
        frames.len(),
        seconds(last.t_ns)
    );
    let mut pair = PSVR2_BOTTOM;
    if args.iter().any(|a| a == "--fit") {
        let found = calibrate(&frames, &pair)
            .ok_or("too few exposures show a controller well enough to fit the cameras")?;
        let p = found.pair;
        println!(
            "Fitted on {} + {} exposures (left + right controller), {} LED sightings, {:.2} px left over:",
            found.fixes[0], found.fixes[1], found.sightings, found.rms
        );
        println!(
            "  focal length {:.1} px ({:.1} degrees across 640), centre {:.1} / {:.1} (left / right picture), {:.1} down",
            p.focal,
            2.0 * (320.0 / p.focal).atan().to_degrees(),
            p.cx_left,
            p.cx_right,
            p.cy
        );
        println!(
            "  cameras {:.2} mm apart; pitch {:.3} rad (the mean of the two below)",
            p.baseline * 1000.0,
            p.pitch
        );
        for (name, tilt) in ["left", "right"].iter().zip(found.tilt) {
            if let Some([pitch, roll]) = tilt {
                println!(
                    "  by the {name} controller the pair looks {:.2} degrees below the head's forward, rolled {:.2}",
                    pitch.to_degrees(),
                    roll.to_degrees()
                );
            }
        }
        for (n, ring) in found.rings.iter().enumerate() {
            println!(
                "  {:3} px from the centre and on: {:6} sightings, {:.2} px left over, {:+.2} outward",
                n * 80,
                ring.sightings,
                ring.rms,
                ring.outward
            );
        }
        pair = p;
    }
    // `--focal PX`: another focal length than the built-in one (after `--fit`, than the fitted).
    if let Some(i) = args.iter().position(|a| a == "--focal") {
        pair.focal = args.get(i + 1).ok_or("--focal needs pixels")?.parse()?;
    }
    let list = args.iter().any(|a| a == "--list");
    let bottom_only = args.iter().any(|a| a == "--bottom-only");
    // `--leds FILE`: for every fix, where each of the controller's LEDs is in the bottom pair's
    // camera frame and how it faces (for working out what the other cameras should see).
    let mut leds_out = match args.iter().position(|a| a == "--leds") {
        Some(i) => Some(std::io::BufWriter::new(File::create(
            args.get(i + 1).ok_or("--leds needs a FILE")?,
        )?)),
        None => None,
    };
    for (h, hand) in [Hand::Left, Hand::Right].into_iter().enumerate() {
        let mut tracker = HandTracker::new(hand);
        // (exposure, seconds, fix)
        let mut fixes = Vec::new();
        let mut with_pose = 0;
        // For `--mount`: the head's pose with each fix.
        let mut seen_from = Vec::new();
        for (n, frame) in frames.iter().enumerate() {
            let (Some(orientation), Some(head)) = (frame.hands[h], frame.head) else {
                continue;
            };
            with_pose += 1;
            let world = pair.camera_from_world(head);
            // The top cameras' pictures too, when the capture has them (`--bottom-only`: not).
            let top = halliday_core::tracking::stereo::PSVR2_TOP;
            let others: Vec<_> = if bottom_only {
                Vec::new()
            } else {
                vec![
                    (top[0], frame.top[0].as_slice()),
                    (top[1], frame.top[1].as_slice()),
                ]
            };
            if let Some(fix) = tracker.update_with(
                &pair,
                &others,
                &world,
                orientation,
                &frame.left,
                &frame.right,
            ) {
                if list {
                    println!(
                        "{hand:?} {:7.3} s  at {:+.4} {:+.4} {:+.4} m  heading {:+6.1}  lean {:+5.1} {:+5.1}  {:2} sightings  {:.2} px",
                        seconds(frame.t_ns),
                        fix.position[0],
                        fix.position[1],
                        fix.position[2],
                        fix.heading.to_degrees(),
                        fix.tilt[0].to_degrees(),
                        fix.tilt[1].to_degrees(),
                        fix.sightings,
                        fix.rms
                    );
                }
                if let Some(at) = frame.head_position {
                    seen_from.push((head, at, fix.position));
                }
                if let Some(out) = leds_out.as_mut() {
                    use halliday_core::tracking::stereo::{
                        apply, from_quat, from_rotation_vector, mul, turn_y,
                    };
                    use std::io::Write;
                    let lean =
                        from_rotation_vector([f64::from(fix.tilt[0]), 0.0, f64::from(fix.tilt[1])]);
                    let rotation = mul(
                        &mul(&mul(&world, &lean), &turn_y(f64::from(fix.heading))),
                        &from_quat(orientation),
                    );
                    write!(
                        out,
                        "{hand:?} {} {} {}",
                        frame.counter, fix.sightings, fix.rms
                    )?;
                    for led in halliday_core::tracking::leds::sense_leds(hand) {
                        let p = apply(&rotation, led.position);
                        let n = apply(&rotation, led.normal);
                        write!(
                            out,
                            " {:.5},{:.5},{:.5},{:.4},{:.4},{:.4}",
                            p[0] + f64::from(fix.position[0]),
                            p[1] + f64::from(fix.position[1]),
                            p[2] + f64::from(fix.position[2]),
                            n[0],
                            n[1],
                            n[2]
                        )?;
                    }
                    writeln!(out)?;
                }
                fixes.push((n, seconds(frame.t_ns), fix));
            }
        }
        if fixes.is_empty() {
            println!("{hand:?} controller: not found in {with_pose} exposures");
            continue;
        }
        let median = |mut v: Vec<f32>| {
            v.sort_by(f32::total_cmp);
            v[v.len() / 2]
        };
        // How far a fix is from the middle of its two neighbours, over three exposures in a row:
        // what the fit's noise looks like on a hand that moves smoothly.
        let jitter: Vec<f32> = fixes
            .windows(3)
            .filter(|w| w[2].0 - w[0].0 == 2)
            .map(|w| {
                let d: [f32; 3] = std::array::from_fn(|k| {
                    w[1].2.position[k] - (w[0].2.position[k] + w[2].2.position[k]) * 0.5
                });
                (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt() * 1000.0
            })
            .collect();
        println!(
            "{hand:?} controller: found in {} of {with_pose} exposures; {} LED sightings and {:.2} px left over (medians){}",
            fixes.len(),
            median(fixes.iter().map(|f| f.2.sightings as f32).collect()),
            median(fixes.iter().map(|f| f.2.rms).collect()),
            if jitter.is_empty() {
                String::new()
            } else {
                format!("; {:.2} mm from frame to frame", median(jitter))
            }
        );
        for k in 0..3 {
            let (lo, hi) = fixes.iter().fold((f32::MAX, f32::MIN), |(lo, hi), f| {
                (lo.min(f.2.position[k]), hi.max(f.2.position[k]))
            });
            print!(
                "{}{} {:+.2} to {:+.2} m",
                if k == 0 {
                    "  from the left camera: "
                } else {
                    ", "
                },
                ["right", "down", "ahead"][k],
                lo,
                hi
            );
        }
        println!();
        // `--mount`: the capture is of a controller lying still while the head moved.
        if args.iter().any(|a| a == "--mount") {
            match halliday_core::tracking::hands::camera_place(&pair, &seen_from) {
                Some((camera, room, off, kept)) => println!(
                    "  if it lay still: the left camera is {:+.1} mm right, {:+.1} up, {:+.1} back of the head's point; the controller at {:+.3} {:+.3} {:+.3} m; {} of {} fixes agree to {:.1} mm",
                    camera[0] * 1000.0,
                    camera[1] * 1000.0,
                    camera[2] * 1000.0,
                    room[0],
                    room[1],
                    room[2],
                    kept,
                    seen_from.len(),
                    off * 1000.0
                ),
                None => println!("  too few fixes to place the cameras"),
            }
        }
        // The heading correction through the capture, a figure for every three seconds.
        let mut line = String::from("  heading correction, degrees:");
        let mut from = 0.0;
        while from <= fixes.last().map_or(0.0, |f| f.1) {
            let part: Vec<f32> = fixes
                .iter()
                .filter(|f| f.1 >= from && f.1 < from + 3.0)
                .map(|f| f.2.heading.to_degrees())
                .collect();
            if !part.is_empty() {
                line += &format!(
                    " {:.0} s {:+.1} ({})",
                    from,
                    median(part.clone()),
                    part.len()
                );
            }
            from += 3.0;
        }
        println!("{line}");
    }
    Ok(())
}

/// Which reading of the SLAM position's axes fits a head turning about the neck: for every signed
/// permutation S of the raw position p, the best fit of `S p = c + Q l` (c a still point, l a
/// lever turned by the orientation Q) over the last `seconds` of a recording, sorted by what is
/// left over. With the head only turning, the right axes leave almost nothing.
/// Asks the headset to re-enumerate, as Halliday's session does when it stops answering (a
/// control read it never replied to left it refusing its interfaces until then).
fn reset() -> Result<(), Error> {
    usb::Headset::reset_device()?;
    println!("Reset; the headset comes back as a new device in a few seconds.");
    Ok(())
}

/// The headset's IMU samples as CSV (host ms, the IMU's own µs clock, gyro in rad/s and
/// acceleration in m/s², tracking axes): for looking at a recording's vibration.
fn imu(path: &str) -> Result<(), Error> {
    use halliday_core::psvr2::protocol::StatusReport;
    use halliday_core::recording::Stream;
    let reader = recording::Reader::new(BufReader::new(File::open(path)?))?;
    println!("host_ms,imu_us,gx,gy,gz,ax,ay,az");
    for record in reader {
        let r = record?;
        if r.stream == Stream::Status
            && let Ok(s) = StatusReport::parse(&r.data)
        {
            for i in &s.imu {
                let (g, a) = (i.gyro_rad_s(), i.accel_m_s2());
                println!(
                    "{:.3},{},{:.5},{:.5},{:.5},{:.4},{:.4},{:.4}",
                    r.t_ns as f64 * 1e-6,
                    i.imu_ts_us,
                    g[0],
                    g[1],
                    g[2],
                    a[0],
                    a[1],
                    a[2]
                );
            }
        }
    }
    Ok(())
}

#[allow(clippy::needless_range_loop)] // a 6×7 elimination reads better with indices
fn axes(path: &str, seconds: f64) -> Result<(), Error> {
    use halliday_core::psvr2::protocol::SlamRecord;
    use halliday_core::recording::Stream;
    use halliday_core::tracking::head::SLAM_CORRECTION;
    let reader = recording::Reader::new(BufReader::new(File::open(path)?))?;
    let mut samples = Vec::new();
    for record in reader {
        let r = record?;
        if r.stream == Stream::Slam
            && let Ok(s) = SlamRecord::parse(&r.data)
        {
            let q = (SLAM_CORRECTION * s.tracking_orientation()).normalized();
            samples.push((r.t_ns as f64 * 1e-9, s.position, q));
        }
    }
    let end = samples.last().map_or(0.0, |s| s.0);
    samples.retain(|s| s.0 >= end - seconds);
    println!("{} poses over the last {seconds} s", samples.len());
    let mut results = Vec::new();
    for perm in [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ] {
        for signs in 0..8 {
            let sign = [0, 1, 2].map(|k| if signs >> k & 1 == 1 { -1.0f64 } else { 1.0 });
            let mut ata = [[0.0f64; 7]; 6];
            let rows = |q: halliday_core::math::Quat, p: [f32; 3]| {
                let cols = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]].map(|e| q.rotate(e));
                [0, 1, 2].map(|k| {
                    let mut a = [0.0f64; 7];
                    a[k] = 1.0;
                    for j in 0..3 {
                        a[3 + j] = f64::from(cols[j][k]);
                    }
                    a[6] = sign[k] * f64::from(p[perm[k]]);
                    a
                })
            };
            for (_, p, q) in &samples {
                for a in rows(*q, *p) {
                    for i in 0..6 {
                        for j in 0..7 {
                            ata[i][j] += a[i] * a[j];
                        }
                    }
                }
            }
            for i in 0..6 {
                let pivot = (i..6)
                    .max_by(|a, b| ata[*a][i].abs().total_cmp(&ata[*b][i].abs()))
                    .unwrap();
                ata.swap(i, pivot);
                for r in 0..6 {
                    if r != i && ata[i][i].abs() > 1e-12 {
                        let f = ata[r][i] / ata[i][i];
                        for j in 0..7 {
                            ata[r][j] -= f * ata[i][j];
                        }
                    }
                }
            }
            let x: Vec<f64> = (0..6).map(|i| ata[i][6] / ata[i][i]).collect();
            let mut sum = 0.0;
            for (_, p, q) in &samples {
                for a in rows(*q, *p) {
                    let e = (0..6).map(|i| a[i] * x[i]).sum::<f64>() - a[6];
                    sum += e * e;
                }
            }
            let rms = (sum / samples.len().max(1) as f64).sqrt() * 1000.0;
            results.push((rms, perm, sign, [x[3], x[4], x[5]]));
        }
    }
    results.sort_by(|a, b| a.0.total_cmp(&b.0));
    for (rms, perm, sign, l) in results.iter().take(8) {
        let name = |k: usize| format!("{}p{}", if sign[k] < 0.0 { '-' } else { '+' }, perm[k]);
        println!(
            "[{} {} {}]  left over {rms:6.2} mm   lever ({:+.3} {:+.3} {:+.3}) m",
            name(0),
            name(1),
            name(2),
            l[0],
            l[1],
            l[2]
        );
    }
    println!("in use: [+p2 +p1 -p0]");
    Ok(())
}

fn track(path: &str) -> Result<(), Error> {
    let reader = recording::Reader::new(BufReader::new(File::open(path)?))?;
    let e = track_replay::evaluate(reader)?;
    let held = track_replay::evaluate_with(
        recording::Reader::new(BufReader::new(File::open(path)?))?,
        halliday_core::tracking::TrackerConfig {
            predict_position: false,
            ..Default::default()
        },
    )?;
    println!(
        "SLAM poses:        {} ({} evaluated)",
        e.slam_poses, e.evaluated
    );
    println!(
        "Prediction error:  mean {:.3} deg, p95 {:.3} deg, max {:.3} deg",
        e.mean_error_deg, e.p95_error_deg, e.max_error_deg
    );
    println!(
        "Without prediction: mean {:.3} deg between poses",
        e.mean_motion_deg
    );
    println!(
        "Eye position error: mean {:.2} mm, p95 {:.2} mm (held, not predicted: mean {:.2} mm, p95 {:.2} mm)",
        e.mean_position_error_mm,
        e.p95_position_error_mm,
        held.mean_position_error_mm,
        held.p95_position_error_mm
    );
    // What reaches the eyes: frames shown `shown` ms after they start, predicted `ahead` ms.
    for window_ms in [0i64, 3, 6, 10, 16, 24] {
        let h = track_replay::evaluate_horizon(
            recording::Reader::new(BufReader::new(File::open(path)?))?,
            halliday_core::tracking::TrackerConfig {
                extrapolation_window_ns: window_ms * 1_000_000,
                ..Default::default()
            },
            34_000_000,
            34_000_000,
        )?;
        println!(
            "Gyro mean over {window_ms} ms, 34 ms ahead: {:.3} deg (p95 {:.3}), {:.2} mm (p95 {:.2}); shake while still ({} frames): {:.2}' (p95 {:.2}'), {:.3} mm (p95 {:.3}); over all: {:.2}', {:.3} mm",
            h.mean_error_deg,
            h.p95_error_deg,
            h.mean_position_error_mm,
            h.p95_position_error_mm,
            h.still_frames,
            h.still_shake_arcmin,
            h.still_shake_p95_arcmin,
            h.still_shake_mm,
            h.still_shake_p95_mm,
            h.shake_arcmin,
            h.shake_mm
        );
    }
    // The view's steadiness: SLAM corrections taken over `smooth` ms, the position's velocity
    // carried forward less below `still` m/s. What each costs in error, what it takes off the shake.
    for (smooth_ms, still, window_ms, turn_deg) in [
        (0i64, 0.0f32, 0i64, 0.0f32),
        (60, 0.0, 0, 0.0),
        (60, 0.05, 0, 0.0),
        (60, 0.1, 0, 0.0),
        (100, 0.1, 0, 0.0),
        (60, 0.05, 24, 10.0),
        (60, 0.05, 24, 20.0),
        (60, 0.05, 40, 20.0),
        (60, 0.05, 40, 40.0),
        (60, 0.05, 60, 30.0),
    ] {
        let h = track_replay::evaluate_horizon(
            recording::Reader::new(BufReader::new(File::open(path)?))?,
            halliday_core::tracking::TrackerConfig {
                correction_smoothing_ns: smooth_ms * 1_000_000,
                still_speed: still,
                still_window_ns: window_ms * 1_000_000,
                still_turn: turn_deg.to_radians(),
                extrapolation_window_ns: 0,
                predict_position: true,
                ..Default::default()
            },
            34_000_000,
            34_000_000,
        )?;
        println!(
            "Corrections over {smooth_ms} ms, still below {still} m/s, gyro mean {window_ms} ms under {turn_deg}°/s: {:.3} deg (p95 {:.3}), {:.2} mm (p95 {:.2}); shake while still: {:.2}' (p95 {:.2}'), {:.3} mm (p95 {:.3}); over all: {:.2}', {:.3} mm",
            h.mean_error_deg,
            h.p95_error_deg,
            h.mean_position_error_mm,
            h.p95_position_error_mm,
            h.still_shake_arcmin,
            h.still_shake_p95_arcmin,
            h.still_shake_mm,
            h.still_shake_p95_mm,
            h.shake_arcmin,
            h.shake_mm
        );
    }
    for span_ms in [0i64, 4, 6, 8, 12, 16, 24] {
        for ahead in [24i64, 34] {
            let h = track_replay::evaluate_horizon(
                recording::Reader::new(BufReader::new(File::open(path)?))?,
                halliday_core::tracking::TrackerConfig {
                    acceleration_window_ns: span_ms * 1_000_000,
                    ..Default::default()
                },
                ahead * 1_000_000,
                ahead * 1_000_000,
            )?;
            println!(
                "Turning's change over {span_ms} ms, {ahead} ms ahead: {:.3} deg (p95 {:.3}); shake while still: {:.2}' (p95 {:.2}'); over all: {:.2}'",
                h.mean_error_deg,
                h.p95_error_deg,
                h.still_shake_arcmin,
                h.still_shake_p95_arcmin,
                h.shake_arcmin,
            );
        }
    }
    for (ahead, shown) in [(12, 12), (12, 29), (20, 29), (29, 29), (40, 40)] {
        for position in [true, false] {
            let h = track_replay::evaluate_horizon(
                recording::Reader::new(BufReader::new(File::open(path)?))?,
                halliday_core::tracking::TrackerConfig {
                    predict_position: position,
                    ..Default::default()
                },
                ahead * 1_000_000,
                shown * 1_000_000,
            )?;
            println!(
                "Predicted {ahead} ms, shown {shown} ms after ({}): {:.3} deg (p95 {:.3}), {:.2} mm (p95 {:.2})",
                if position {
                    "position predicted"
                } else {
                    "position held"
                },
                h.mean_error_deg,
                h.p95_error_deg,
                h.mean_position_error_mm,
                h.p95_position_error_mm
            );
        }
    }
    if let Some(o) = e.clock_offset_ms {
        println!("Clock offset:      {o:.3} ms (host - headset)");
    }
    Ok(())
}

fn synth(args: &[String]) -> Result<(), Error> {
    let path = args.first().ok_or("synth needs a FILE")?;
    let mut motion = halliday_core::synthetic::LookAround::default();
    if let [_, flag, value] = args
        && (flag == "-s" || flag == "--seconds")
    {
        motion.seconds = value.parse()?;
    }
    std::fs::write(path, motion.record())?;
    println!(
        "Wrote {path}: {} s of looking left and right",
        motion.seconds
    );
    Ok(())
}

/// Acts as a VR game on the bridge Halliday.app opens (what halliday-vrclient does under Wine):
/// follows the head it publishes and submits a world-fixed test scene, rows bottom-up like OpenGL.
/// Sky above and ground below, one color per compass quarter (ahead red, right green, behind blue,
/// left yellow), lines every 10°, a white mark at the top left of the left eye and a magenta one
/// at the top right of the right eye.
fn game_sim(args: &[String]) -> Result<(), Error> {
    use halliday_core::game_bridge::GameSide;
    let mut seconds = 30.0f64;
    if let [flag, value] = args
        && (flag == "-s" || flag == "--seconds")
    {
        seconds = value.parse()?;
    }
    let home = std::env::var("HOME")?;
    let path = std::path::PathBuf::from(home)
        .join("Library/Application Support/Halliday/OpenVR/halliday-bridge.shm");
    let mut game = GameSide::open(&path)
        .map_err(|e| format!("{}: {e} (is Halliday running?)", path.display()))?;
    let c = game.config();
    println!(
        "Connected: {}x{} per eye at {} Hz; submitting for {seconds} s",
        c.eye_width, c.eye_height, c.display_hz
    );
    let start = Instant::now();
    let mut frames = 0u64;
    while start.elapsed().as_secs_f64() < seconds && game.halliday_alive() {
        let Some(state) = game.wait_frame(Duration::from_millis(40)) else {
            continue;
        };
        let pose = state.head;
        let (w, h) = (c.eye_width as usize, c.eye_height as usize);
        game.submit(pose, |eye, pixels| {
            paint_eye(pixels, w, h, c.tangents[eye], pose.orientation, eye)
        });
        frames += 1;
    }
    println!(
        "Submitted {frames} frames in {:.1} s",
        start.elapsed().as_secs_f64()
    );
    Ok(())
}

/// Halliday's side of the bridge without the app: the runtime and a game see a headset standing
/// still at 1.6 m and two still controllers, paced at `--hz`. Logs what the game does every 5 s.
fn game_host(args: &[String]) -> Result<(), Error> {
    use halliday_bridge::{Controller, Pose, State};
    use halliday_core::game_bridge::{Config, GameBridge};
    let (mut seconds, mut eye, mut hz) = (60.0f64, (1440u32, 1468u32), 90.0f32);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().ok_or("a flag needs a value")?;
        match flag.as_str() {
            "-s" | "--seconds" => seconds = value.parse()?,
            "--hz" => hz = value.parse()?,
            "--eye" => {
                let (w, h) = value.split_once('x').ok_or("--eye WxH")?;
                eye = (w.parse()?, h.parse()?);
            }
            _ => return Err(format!("unknown flag {flag}").into()),
        }
    }
    // `HALLIDAY_BRIDGE` names another file, as for the OpenXR runtime: a test beside a running Halliday.
    let path = match std::env::var_os("HALLIDAY_BRIDGE") {
        Some(path) => std::path::PathBuf::from(path),
        None => std::path::PathBuf::from(std::env::var("HOME")?)
            .join("Library/Application Support/Halliday/OpenVR/halliday-bridge.shm"),
    };
    let bridge = GameBridge::create(
        &path,
        Config {
            eye_width: eye.0,
            eye_height: eye.1,
            display_hz: hz,
            ipd: 0.063,
            tangents: [[-1.25, 1.05, 1.2, -1.25], [-1.05, 1.25, 1.2, -1.25]],
        },
    )?;
    let interval = Duration::from_secs_f64(1.0 / hz as f64);
    bridge.set_frame_interval(interval.as_nanos() as u64);
    let still = |position: [f32; 3]| Pose {
        position,
        valid: 1,
        orientation: [0.0, 0.0, 0.0, 1.0],
        ..Pose::default()
    };
    let hand = |x: f32| Controller {
        pose: still([x, 1.1, -0.3]),
        connected: 1,
        ..Controller::default()
    };
    let state = State {
        head: still([0.0, 1.6, 0.0]),
        controllers: [hand(-0.2), hand(0.2)],
    };
    println!(
        "Hosting {}: {}x{} per eye at {hz} Hz for {seconds} s",
        path.display(),
        eye.0,
        eye.1
    );
    let start = Instant::now();
    let mut next = start;
    let mut report = start;
    while start.elapsed().as_secs_f64() < seconds {
        bridge.publish(&state);
        let c = bridge.client();
        if report.elapsed() >= Duration::from_secs(5) {
            report = Instant::now();
            println!(
                "{:5.1} s: game pid {} initialized {} frames {} heartbeat {}",
                start.elapsed().as_secs_f64(),
                c.pid,
                c.initialized,
                c.frames,
                c.heartbeat
            );
        }
        next += interval;
        if let Some(wait) = next.checked_duration_since(Instant::now()) {
            thread::sleep(wait);
        } else {
            next = Instant::now();
        }
    }
    Ok(())
}

fn paint_eye(pixels: &mut [u8], w: usize, h: usize, t: [f32; 4], q: [f32; 4], eye: usize) {
    let rows_per = h.div_ceil(8);
    thread::scope(|scope| {
        for (band, chunk) in pixels.chunks_mut(rows_per * w * 4).enumerate() {
            scope.spawn(move || {
                for (i, px) in chunk.chunks_exact_mut(4).enumerate() {
                    let (x, row) = (i % w, band * rows_per + i / w);
                    // Row 0 is the bottom (OpenGL).
                    let (u, v) = ((x as f32 + 0.5) / w as f32, (row as f32 + 0.5) / h as f32);
                    let d = [t[0] + u * (t[1] - t[0]), t[3] + v * (t[2] - t[3]), -1.0];
                    let color = scene(rotate(q, d), u, v, eye);
                    px.copy_from_slice(&[color[0], color[1], color[2], 255]);
                }
            });
        }
    });
}

fn rotate(q: [f32; 4], v: [f32; 3]) -> [f32; 3] {
    let [x, y, z, w] = q;
    let u = [x, y, z];
    let cross = |a: [f32; 3], b: [f32; 3]| {
        [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ]
    };
    let t = cross(u, v).map(|c| 2.0 * c);
    let c2 = cross(u, t);
    [
        v[0] + w * t[0] + c2[0],
        v[1] + w * t[1] + c2[1],
        v[2] + w * t[2] + c2[2],
    ]
}

fn scene(d: [f32; 3], u: f32, v: f32, eye: usize) -> [u8; 3] {
    if v > 0.9 && ((eye == 0 && u < 0.1) || (eye == 1 && u > 0.9)) {
        return if eye == 0 {
            [255, 255, 255]
        } else {
            [255, 0, 255]
        };
    }
    let len = (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt();
    let (az, el) = (
        d[0].atan2(-d[2]).to_degrees(),
        (d[1] / len).asin().to_degrees(),
    );
    let base = if el > 0.0 {
        [70.0, 110.0, 170.0]
    } else {
        [40.0, 40.0, 45.0]
    };
    let tint = match az {
        a if a.abs() < 45.0 => [220.0, 60.0, 60.0],
        a if (45.0..135.0).contains(&a) => [60.0, 200.0, 80.0],
        a if a.abs() >= 135.0 => [60.0, 90.0, 230.0],
        _ => [230.0, 210.0, 60.0],
    };
    let mut c = [0.0f32; 3];
    for i in 0..3 {
        c[i] = base[i] * 0.6 + tint[i] * 0.4;
    }
    let near_line = |a: f32| (a - (a / 10.0).round() * 10.0).abs() < 0.15;
    if near_line(az) || near_line(el) {
        c = [235.0, 235.0, 235.0];
    }
    if el.abs() < 0.25 {
        c = [255.0, 255.0, 255.0];
    }
    c.map(|x| x as u8)
}

/// Saves the newest frame a game submitted to Halliday's bridge (as the game drew it: one image,
/// or both eyes side by side) as a binary PPM.
fn game_peek(args: &[String]) -> Result<(), Error> {
    use halliday_core::game_bridge::GameSide;
    let out = args.first().ok_or("game-peek needs a FILE.ppm")?;
    let path = match std::env::var_os("HALLIDAY_BRIDGE") {
        Some(path) => std::path::PathBuf::from(path),
        None => std::path::PathBuf::from(std::env::var("HOME")?)
            .join("Library/Application Support/Halliday/OpenVR/halliday-bridge.shm"),
    };
    let game = GameSide::view(&path)
        .map_err(|e| format!("{}: {e} (is Halliday running?)", path.display()))?;
    for (i, o) in game
        .overlays()
        .iter()
        .enumerate()
        .filter(|(_, o)| o.used != 0)
    {
        let key =
            String::from_utf8_lossy(&o.key[..o.key.iter().position(|&c| c == 0).unwrap_or(64)])
                .into_owned();
        println!(
            "overlay {i}: {key}, {}, {:.2} m wide, alpha {:.2}, {} at ({:.2}, {:.2}, {:.2})",
            if o.visible != 0 { "shown" } else { "hidden" },
            o.width_m,
            o.alpha,
            if o.relative != 0 {
                format!("relative to device {}", o.device)
            } else {
                "in the room".into()
            },
            o.transform[0][3],
            o.transform[1][3],
            o.transform[2][3]
        );
    }
    let which = match (args.get(1).map(String::as_str), args.get(2)) {
        (Some("--overlay"), Some(n)) => Some(Some(n.parse::<usize>()?)),
        (Some("--skybox"), _) => Some(None),
        _ => None,
    };
    let (w, h, left) = match which {
        None => {
            let (w, h, left, _) = game.peek().ok_or("no frame yet")?;
            (w, h, left)
        }
        Some(id) => game.peek_picture(id).ok_or("no picture there")?,
    };
    let mut ppm = format!("P6\n{w} {h}\n255\n").into_bytes();
    for px in left.chunks_exact(4) {
        ppm.extend_from_slice(&px[..3]);
    }
    std::fs::write(out, ppm)?;
    // The alpha the picture came with, which the file doesn't keep: how much of it is clear
    // (a frame whose alpha is meant shows the room there) and how much solid.
    let pixels = (left.len() / 4).max(1) as f64;
    let clear = left.chunks_exact(4).filter(|px| px[3] < 8).count() as f64;
    let solid = left.chunks_exact(4).filter(|px| px[3] > 247).count() as f64;
    println!(
        "Wrote {out}: {w}x{h} (alpha: {:.0} % clear, {:.0} % solid)",
        100.0 * clear / pixels,
        100.0 * solid / pixels
    );
    Ok(())
}
