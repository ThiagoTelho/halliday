//! Additional Sense Bluetooth output and feedback. Wire layout from Monado's
//! BSL-1.0 pssense_protocol.h / pssense_driver.c at
//! 27a1999f6d7fb4972570d63a06e437c93a61e49f (THIRD-PARTY.md).
//! Independent packet composition; no HID calls or Sony SDK/driver material.

use crate::sense::{Hand, InputReport, REPORT_ID_BLUETOOTH};

#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct OutputFeedback {
    pub sequence: u32,
    pub device_ticks: u32,
    /// Echo of a host output timestamp, modulo 2^32 microseconds. Not an LED-latch acknowledgement.
    pub echoed_host_us: u32,
    pub crc_failures: u8,
    pub bluetooth: u8,
    pub reserved: [u8; 2],
}

pub fn feedback(product_id: u16, bytes: &[u8]) -> Option<OutputFeedback> {
    let hand = Hand::from_product_id(product_id)?;
    let parsed = InputReport::parse(hand, bytes).ok()?;
    let bluetooth = bytes.first() == Some(&REPORT_ID_BLUETOOTH);
    let common = if bluetooth {
        &bytes[2..65]
    } else {
        &bytes[1..64]
    };
    Some(OutputFeedback {
        sequence: parsed.sequence,
        device_ticks: parsed.device_ticks,
        echoed_host_us: u32::from_le_bytes(common[43..47].try_into().ok()?),
        crc_failures: if bluetooth { bytes[66] } else { 0 },
        bluetooth: u8::from(bluetooth),
        reserved: [0; 2],
    })
}

#[cfg(test)]
fn crc32(seed: &[u8], data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for byte in seed.iter().chain(data) {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn feedback_checks_full_input_and_handles_both_transport_offsets() {
        for bluetooth in [false, true] {
            let mut report = vec![0; if bluetooth { 78 } else { 64 }];
            report[0] = if bluetooth { 0x31 } else { 1 };
            let at = if bluetooth { 2 } else { 1 };
            report[at + 11..at + 15].copy_from_slice(&0xffff_fffdu32.to_le_bytes());
            report[at + 43..at + 47].copy_from_slice(&0xffff_fff0u32.to_le_bytes());
            report[at + 47..at + 51].copy_from_slice(&123u32.to_le_bytes());
            if bluetooth {
                report[66] = 7;
                let sum = crc32(&[0xa1], &report[..74]);
                report[74..78].copy_from_slice(&sum.to_le_bytes());
            }
            let value = feedback(crate::sense::PRODUCT_ID_LEFT, &report).unwrap();
            assert_eq!(value.sequence, 0xffff_fffd);
            assert_eq!(value.echoed_host_us, 0xffff_fff0);
            assert_eq!(value.device_ticks, 123);
            assert_eq!(value.crc_failures, if bluetooth { 7 } else { 0 });
            if bluetooth {
                report[20] ^= 1;
                assert!(feedback(crate::sense::PRODUCT_ID_RIGHT, &report).is_none());
            }
        }
        assert!(feedback(0, &[0; 78]).is_none());
        assert!(feedback(crate::sense::PRODUCT_ID_LEFT, &[0x31; 77]).is_none());
        assert_eq!(std::mem::size_of::<OutputFeedback>(), 16);
    }
}
