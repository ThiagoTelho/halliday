//! VR video format detection: projection (360°, 180°, fisheye, flat screen) and stereo layout
//! (mono, side by side, top/bottom) from the file name, container metadata and frame shape.
//!
//! Rules ported from GAV PSVR2 Player for macOS (`PlaybackConfig.detect`, `Detection.apply`,
//! `flatAspect` in player/main.swift; MIT, Andrey Gerasimov; see THIRD-PARTY.md). They follow the
//! naming conventions of VR video sites (DeoVR-style tags such as `_180_LR`, `_3DH`, `MKX200`).

/// How the picture maps onto the sphere or screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Projection {
    Equirect360 = 0,
    Equirect180 = 1,
    Fisheye = 2,
    /// An ordinary 2D/3D movie on a virtual screen.
    Flat = 3,
}

/// How the two eyes are packed in a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Stereo {
    Mono = 0,
    SideBySide = 1,
    TopBottom = 2,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoFormat {
    pub projection: Projection,
    pub stereo: Stereo,
    /// Lens field of view for fisheye video, degrees (60..=240).
    pub fisheye_fov_deg: f32,
}

impl Default for VideoFormat {
    fn default() -> Self {
        // An untagged VR file is most often 180° side by side.
        VideoFormat {
            projection: Projection::Equirect180,
            stereo: Stereo::SideBySide,
            fisheye_fov_deg: 190.0,
        }
    }
}

/// A format guess, and which parts the file name actually named (the rest may be overridden by
/// container metadata once the track is loaded).
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Detection {
    pub format: VideoFormat,
    pub projection_from_name: bool,
    pub stereo_from_name: bool,
}

/// Fisheye lens names used in file names → field of view in degrees.
const FISHEYE_LENSES: [(&str, f32); 4] = [
    ("MKX200", 200.0),
    ("MKX220", 220.0),
    ("VRCA220", 220.0),
    ("RF52", 190.0),
];

/// Guesses the format from a file name (with or without extension). Short tags (`_LR`, `_TB`,
/// `_3DH`…) only count as whole tokens; 180 and 360 must not be part of a longer number
/// (3600x1800, 1360…) nor followed by `P` (1080p).
pub fn detect(file_name: &str) -> Detection {
    let stem = match file_name.rfind('.') {
        Some(i) if i > 0 && file_name.len() - i <= 5 => &file_name[..i],
        _ => file_name,
    };
    let n = stem.to_uppercase();
    let tokens: Vec<&str> = n
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();
    let has_token = |list: &[&str]| list.iter().any(|t| tokens.contains(t));

    let mut d = Detection::default();
    if let Some(&(_, fov)) = FISHEYE_LENSES
        .iter()
        .find(|(name, _)| tokens.contains(name))
    {
        d.format.projection = Projection::Fisheye;
        d.format.fisheye_fov_deg = fov;
        d.projection_from_name = true;
    } else if n.contains("FISHEYE") || n.contains("VR180FISH") {
        d.format.projection = Projection::Fisheye;
        if let Some(fov) = fisheye_degrees(&n) {
            d.format.fisheye_fov_deg = fov.clamp(60.0, 240.0);
        }
        d.projection_from_name = true;
    } else if standalone_number(&n, "360") {
        d.format.projection = Projection::Equirect360;
        d.projection_from_name = true;
    } else if standalone_number(&n, "180") {
        d.format.projection = Projection::Equirect180;
        d.projection_from_name = true;
    }

    if has_token(&["TB", "OU", "3DV", "HTB", "HOU", "FTB", "FOU"])
        || n.contains("OVERUNDER")
        || n.contains("TOPBOTTOM")
    {
        d.format.stereo = Stereo::TopBottom;
        d.stereo_from_name = true;
    } else if has_token(&["LR", "3DH"]) || n.contains("SBS") || n.contains("SIDEBYSIDE") {
        d.format.stereo = Stereo::SideBySide;
        d.stereo_from_name = true;
    } else if has_token(&["MONO"]) {
        d.format.stereo = Stereo::Mono;
        d.stereo_from_name = true;
    } else if d.format.projection == Projection::Equirect360 {
        // An untagged full sphere is almost always mono; untagged 180 and fisheye are SBS.
        d.format.stereo = Stereo::Mono;
    }
    d
}

/// `FISHEYE190` → 190.
fn fisheye_degrees(n: &str) -> Option<f32> {
    let i = n.find("FISHEYE")? + "FISHEYE".len();
    let digits: String = n[i..].chars().take_while(|c| c.is_ascii_digit()).collect();
    (digits.len() == 3).then(|| digits.parse().ok()).flatten()
}

/// True if `number` appears in `n` not preceded by a digit and not followed by a digit or `P`.
fn standalone_number(n: &str, number: &str) -> bool {
    let bytes = n.as_bytes();
    n.match_indices(number).any(|(i, _)| {
        let before = i.checked_sub(1).map(|j| bytes[j]);
        let after = bytes.get(i + number.len()).copied();
        !before.is_some_and(|b| b.is_ascii_digit())
            && !after.is_some_and(|b| b.is_ascii_digit() || b == b'P')
    })
}

/// Container metadata about the track, when present.
#[derive(Debug, Clone, Copy, Default)]
pub struct TrackInfo<'a> {
    /// `ProjectionKind` format-description extension: "Equirectangular", "HalfEquirectangular",
    /// "Rectilinear"…
    pub projection_kind: Option<&'a str>,
    /// `ViewPackingKind`: "SideBySide", "OverUnder".
    pub view_packing: Option<&'a str>,
    /// MV-HEVC with separate eye layers (only the base layer is decoded: one eye per frame).
    pub multiview: bool,
    pub width: u32,
    pub height: u32,
}

impl Detection {
    /// Fills in what the file name left open from container metadata and the frame shape.
    /// Returns true if the format changed.
    pub fn refine(&mut self, track: &TrackInfo) -> bool {
        let before = self.format;
        let aspect = if track.height > 0 {
            track.width as f64 / track.height as f64
        } else {
            2.0
        };
        if !self.projection_from_name {
            match track.projection_kind {
                Some("Equirectangular") => self.format.projection = Projection::Equirect360,
                Some("HalfEquirectangular") => self.format.projection = Projection::Equirect180,
                Some("Rectilinear") => self.format.projection = Projection::Flat, // iPhone / Vision Pro spatial video
                None => {
                    // VR frames are 2:1 (180° SBS, 360° mono), 1:1 (360° TB, 180° mono) or rarely
                    // 1:2 / 4:1; anything else (16:9, scope, 4:3, full SBS 32:9) is a movie.
                    let vr = [0.5, 1.0, 2.0, 4.0]
                        .iter()
                        .any(|r| (aspect / r - 1.0).abs() < 0.03);
                    if !vr {
                        self.format.projection = Projection::Flat;
                    }
                }
                Some(_) => {} // unknown kind: keep the guess
            }
        }
        if !self.stereo_from_name {
            match track.view_packing {
                Some("SideBySide") => self.format.stereo = Stereo::SideBySide,
                Some("OverUnder") => self.format.stereo = Stereo::TopBottom,
                _ => {
                    if track.multiview || track.projection_kind == Some("Equirectangular") {
                        self.format.stereo = Stereo::Mono;
                    } else if self.format.projection == Projection::Flat {
                        // Untagged movie: mono, unless two full-size pictures sit side by side or stacked.
                        self.format.stereo = if aspect > 3.2 {
                            Stereo::SideBySide
                        } else if aspect > 0.8 && aspect < 0.95 {
                            Stereo::TopBottom
                        } else {
                            Stereo::Mono
                        };
                    }
                }
            }
        }
        self.format != before
    }
}

/// Picture aspect of one eye on the flat screen. Half-SBS/half-TB squeeze each eye into half the
/// frame and are shown stretched back: an eye narrower than 1.25:1 or wider than 3:1 is taken as
/// squeezed.
pub fn flat_aspect(width: u32, height: u32, stereo: Stereo) -> f32 {
    if width == 0 || height == 0 {
        return 16.0 / 9.0;
    }
    let frame = width as f32 / height as f32;
    match stereo {
        Stereo::Mono => frame,
        Stereo::SideBySide => {
            if frame / 2.0 < 1.25 {
                frame
            } else {
                frame / 2.0
            }
        }
        Stereo::TopBottom => {
            if frame * 2.0 > 3.0 {
                frame
            } else {
                frame * 2.0
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fmt(name: &str) -> (Projection, Stereo) {
        let d = detect(name);
        (d.format.projection, d.format.stereo)
    }

    #[test]
    fn common_vr_names() {
        assert_eq!(
            fmt("beach_180_LR.mp4"),
            (Projection::Equirect180, Stereo::SideBySide)
        );
        assert_eq!(
            fmt("concert_360_TB.mov"),
            (Projection::Equirect360, Stereo::TopBottom)
        );
        assert_eq!(fmt("city_360.mp4"), (Projection::Equirect360, Stereo::Mono));
        assert_eq!(
            fmt("trip-180-3DH.mp4"),
            (Projection::Equirect180, Stereo::SideBySide)
        );
        assert_eq!(
            fmt("show_180x180_3dh_LR.mp4"),
            (Projection::Equirect180, Stereo::SideBySide)
        );
        assert_eq!(
            fmt("movie_SBS.mkv"),
            (Projection::Equirect180, Stereo::SideBySide)
        );
        assert_eq!(
            fmt("demo_MONO_360.mp4"),
            (Projection::Equirect360, Stereo::Mono)
        );
        assert_eq!(
            fmt("film.HOU.mp4"),
            (Projection::Equirect180, Stereo::TopBottom)
        );
    }

    #[test]
    fn numbers_inside_longer_numbers_or_resolutions_do_not_count() {
        let d = detect("clip_3600x1800.mp4");
        assert!(!d.projection_from_name);
        assert!(!detect("trailer_1080p.mp4").projection_from_name);
        assert!(!detect("cam_1360.mp4").projection_from_name);
        assert!(detect("x_360_y.mp4").projection_from_name);
    }

    #[test]
    fn short_tags_only_as_whole_tokens() {
        // "TB" inside a word is not a tag; "LR" inside "COLOR" neither.
        assert!(!detect("DATABASE_180.mp4").stereo_from_name);
        assert!(!detect("COLOR_180.mp4").stereo_from_name);
        assert!(detect("x_TB_180.mp4").stereo_from_name);
    }

    #[test]
    fn fisheye_lenses_and_explicit_fov() {
        let d = detect("scene_MKX200_LR.mp4");
        assert_eq!(d.format.projection, Projection::Fisheye);
        assert_eq!(d.format.fisheye_fov_deg, 200.0);
        let d = detect("scene_FISHEYE190_LR.mp4");
        assert_eq!(
            (d.format.projection, d.format.fisheye_fov_deg),
            (Projection::Fisheye, 190.0)
        );
        assert_eq!(
            detect("x_VR180FISH.mp4").format.projection,
            Projection::Fisheye
        );
    }

    #[test]
    fn metadata_and_shape_fill_in_the_rest() {
        // Untagged 16:9 file: a flat mono movie.
        let mut d = detect("holiday.mp4");
        assert!(d.refine(&TrackInfo {
            width: 1920,
            height: 1080,
            ..Default::default()
        }));
        assert_eq!(
            (d.format.projection, d.format.stereo),
            (Projection::Flat, Stereo::Mono)
        );
        // Untagged 2:1 file: keeps the 180° SBS guess.
        let mut d = detect("holiday.mp4");
        assert!(!d.refine(&TrackInfo {
            width: 5760,
            height: 2880,
            ..Default::default()
        }));
        // Full SBS 3D movie (two 16:9 pictures): flat SBS.
        let mut d = detect("movie.mp4");
        d.refine(&TrackInfo {
            width: 3840,
            height: 1080,
            ..Default::default()
        });
        assert_eq!(
            (d.format.projection, d.format.stereo),
            (Projection::Flat, Stereo::SideBySide)
        );
        // Metadata wins over shape when the name said nothing.
        let mut d = detect("capture.mov");
        d.refine(&TrackInfo {
            projection_kind: Some("Equirectangular"),
            width: 4096,
            height: 2048,
            ..Default::default()
        });
        assert_eq!(
            (d.format.projection, d.format.stereo),
            (Projection::Equirect360, Stereo::Mono)
        );
        // Spatial video (MV-HEVC, rectilinear): flat, one eye decoded.
        let mut d = detect("IMG_0001.MOV");
        d.refine(&TrackInfo {
            projection_kind: Some("Rectilinear"),
            multiview: true,
            width: 1920,
            height: 1080,
            ..Default::default()
        });
        assert_eq!(
            (d.format.projection, d.format.stereo),
            (Projection::Flat, Stereo::Mono)
        );
        // The name wins over metadata.
        let mut d = detect("x_360_TB.mp4");
        d.refine(&TrackInfo {
            projection_kind: Some("HalfEquirectangular"),
            view_packing: Some("SideBySide"),
            width: 4096,
            height: 4096,
            ..Default::default()
        });
        assert_eq!(
            (d.format.projection, d.format.stereo),
            (Projection::Equirect360, Stereo::TopBottom)
        );
    }

    #[test]
    fn flat_screen_aspect_unsqueezes_half_packed_movies() {
        assert!((flat_aspect(1920, 1080, Stereo::Mono) - 1.778).abs() < 0.01);
        assert!((flat_aspect(1920, 1080, Stereo::SideBySide) - 1.778).abs() < 0.01); // half-SBS
        assert!((flat_aspect(3840, 1080, Stereo::SideBySide) - 1.778).abs() < 0.01); // full SBS
        assert!((flat_aspect(1920, 1080, Stereo::TopBottom) - 1.778).abs() < 0.01); // half-TB
        assert!((flat_aspect(1920, 2160, Stereo::TopBottom) - 1.778).abs() < 0.01); // full TB
    }
}
