//! The headset's tracking cameras: the frames they send over USB.
//!
//! Layout found on the hardware (firmware 07000102) with Monado's list of camera
//! modes as the guide (BSL-1.0; see THIRD-PARTY.md). A frame is one bulk transfer: a 256-byte
//! header, then 8-bit pixels. The cameras expose 60 times a second; the header's time is on the
//! headset's own clock, the one SLAM and IMU records carry.
//!
//! - Mode 1: the two bottom cameras side by side, 1280 × 640, normal exposure (kind 0).
//! - Mode 3: two transfers per exposure with the same time and counter: kind 0, the bottom pair
//!   as in mode 1, and kind 3, the two top cameras side by side, 640 × 640 each, normal exposure,
//!   60 exposures a second. The top two look up and outwards, one to each side, and hardly
//!   overlap: not a stereo pair.
//! - Mode 4, for controller tracking: short exposures, two transfers per exposure with the same
//!   time and counter, kinds 4 and 5, each two 512 × 508 fisheye pictures one above the other.
//!   The exposure is so short that only lamps and LEDs show (mean 2 to 4 of 255), over each
//!   camera's whole fisheye picture: what the cameras see, where modes 1 and 3 send a rectified
//!   crop of about 82° (not used yet: it needs each fisheye's lens model).
//! - Mode 0x10: one 1 040 640-byte transfer per exposure, kind 11, normal exposure: the two
//!   bottom cameras' raw fisheye pictures, BC4-compressed (8 bytes per 4 × 4 block), 1024 wide and
//!   1016 high each, one above the other (about 1000 × 1000 of each is picture, the rest padding
//!   on the right). Unrectified, and the two cameras look apart, one out to each side: together
//!   far wider than mode 1's pair. Most likely what the PS5's see-through shows (not
//!   used yet). Monado's list calls mode 1 `BOTTOM_SBS_CROPPED`.

use super::protocol::ParseError;

pub const HEADER_SIZE: usize = 256;
const MAGIC: [u8; 4] = [b'V', b'I', 0x00, 0x02];

/// What a frame's header says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    /// The whole transfer's size, header included.
    pub size: u32,
    /// When the cameras exposed, in microseconds on the headset's clock (it wraps).
    pub vts_us: u32,
    /// Goes up by one per exposure.
    pub counter: u32,
    /// Which picture of the mode this is (0 in mode 1; 0 and 3 in mode 3; 4 and 5 in mode 4).
    pub kind: u16,
    /// The picture as sent: `width` × `height` pixels after the header.
    pub width: usize,
    pub height: usize,
}

impl FrameHeader {
    pub fn parse(frame: &[u8]) -> Result<FrameHeader, ParseError> {
        if frame.len() < HEADER_SIZE {
            return Err(ParseError::TooShort {
                need: HEADER_SIZE,
                got: frame.len(),
            });
        }
        if frame[..4] != MAGIC {
            return Err(ParseError::BadSignature);
        }
        let u16_at = |i: usize| u16::from_le_bytes([frame[i], frame[i + 1]]);
        let u32_at =
            |i: usize| u32::from_le_bytes([frame[i], frame[i + 1], frame[i + 2], frame[i + 3]]);
        let size = u32_at(4);
        // The pictures of a transfer sit side by side or one above the other; either way the
        // pixels are one block of `size - 256` bytes, `width` across.
        let (row, across) = (usize::from(u16_at(22)), usize::from(u16_at(24)));
        let width = row * across.max(1);
        let pixels = (size as usize).saturating_sub(HEADER_SIZE);
        if width == 0 || pixels % width != 0 {
            return Err(ParseError::BadSignature);
        }
        Ok(FrameHeader {
            size,
            vts_us: u32_at(8),
            counter: u32_at(12),
            kind: u16_at(16),
            width,
            height: pixels / width,
        })
    }
}

/// A frame's pixels (everything after the header), if the transfer is whole.
pub fn pixels<'a>(header: &FrameHeader, frame: &'a [u8]) -> Option<&'a [u8]> {
    frame.get(HEADER_SIZE..HEADER_SIZE + header.width * header.height)
}

/// Mode 0x10's picture: 1024 pixels wide, two cameras of 1016 rows one above the other.
pub const BC4_WIDTH: usize = 1024;
pub const BC4_HEIGHT: usize = 2032;
/// The columns of each that are picture (the rest is padding).
pub const BC4_PICTURE_WIDTH: usize = 1000;

/// Decodes BC4 (one channel, 8 bytes per 4 × 4 block: two end values and sixteen 3-bit
/// indices) into 8-bit pixels, `width` × `height` (multiples of 4). `None` when `data` is short.
pub fn decode_bc4(data: &[u8], width: usize, height: usize) -> Option<Vec<u8>> {
    let (bw, bh) = (width / 4, height / 4);
    if data.len() < bw * bh * 8 || width % 4 != 0 || height % 4 != 0 {
        return None;
    }
    let mut out = vec![0u8; width * height];
    for by in 0..bh {
        for bx in 0..bw {
            let b = &data[(by * bw + bx) * 8..][..8];
            let (r0, r1) = (u32::from(b[0]), u32::from(b[1]));
            let mut palette = [0u8; 8];
            palette[0] = r0 as u8;
            palette[1] = r1 as u8;
            if r0 > r1 {
                for i in 1..7 {
                    palette[1 + i as usize] = (((7 - i) * r0 + i * r1 + 3) / 7) as u8;
                }
            } else {
                for i in 1..5 {
                    palette[1 + i as usize] = (((5 - i) * r0 + i * r1 + 2) / 5) as u8;
                }
                palette[6] = 0;
                palette[7] = 255;
            }
            let bits = b[2..8]
                .iter()
                .enumerate()
                .fold(0u64, |acc, (k, &v)| acc | (u64::from(v) << (8 * k)));
            for p in 0..16 {
                let index = ((bits >> (3 * p)) & 7) as usize;
                out[(by * 4 + p / 4) * width + bx * 4 + p % 4] = palette[index];
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn bc4_blocks_decode() {
        // One block: ends 200 and 100 (eight values), the first pixel index 0, the second 1,
        // the third 2 (the first in between), the rest 7.
        let mut bits: u64 = 0;
        for p in 0..16u64 {
            let index = match p {
                0 => 0,
                1 => 1,
                2 => 2,
                _ => 7,
            };
            bits |= index << (3 * p);
        }
        let mut block = vec![200u8, 100];
        block.extend_from_slice(&bits.to_le_bytes()[..6]);
        let px = super::decode_bc4(&block, 4, 4).unwrap();
        assert_eq!(&px[..3], &[200, 100, 186]);
        assert_eq!(px[15], 114);
        // Ends in the other order: six values, then 0 and 255.
        block[0] = 100;
        block[1] = 200;
        let px = super::decode_bc4(&block, 4, 4).unwrap();
        assert_eq!(&px[..3], &[100, 200, 120]);
        assert_eq!(px[15], 255);
        assert!(super::decode_bc4(&block[..7], 4, 4).is_none());
    }

    use super::*;

    fn header(hex: &str, size: usize) -> Vec<u8> {
        let mut frame: Vec<u8> = hex
            .split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect();
        frame.resize(size, 0);
        frame
    }

    /// Headers captured from a headset.
    const MODE_4: &str = "56 49 00 02 00 f1 07 00 83 71 dc 32 f4 c6 00 00 05 00 fc 01 fc 01 00 02 01 00 02 00 00 01 00 00";
    const MODE_1: &str = "56 49 00 02 00 81 0c 00 70 9c e1 32 08 c7 00 00 00 00 80 02 80 02 80 02 02 00 01 00 00 01 00 00";

    #[test]
    fn the_controller_tracking_frame_is_two_fisheye_pictures() {
        let frame = header(MODE_4, 520_448);
        let h = FrameHeader::parse(&frame).unwrap();
        assert_eq!((h.size, h.kind, h.counter), (520_448, 5, 0xc6f4));
        assert_eq!(h.vts_us, 0x32dc_7183);
        assert_eq!((h.width, h.height), (512, 1016));
        assert_eq!(pixels(&h, &frame).unwrap().len(), 512 * 1016);
    }

    #[test]
    fn the_bottom_cameras_frame_is_two_pictures_side_by_side() {
        let frame = header(MODE_1, 819_456);
        let h = FrameHeader::parse(&frame).unwrap();
        assert_eq!((h.kind, h.width, h.height), (0, 1280, 640));
        // Cut short, there are no pixels to give.
        assert!(pixels(&h, &frame[..1000]).is_none());
    }

    #[test]
    fn other_data_is_refused() {
        assert!(FrameHeader::parse(&[0u8; 300]).is_err());
        assert!(FrameHeader::parse(&[0x56, 0x49]).is_err());
    }
}
