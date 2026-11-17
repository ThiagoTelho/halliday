//! PlayStation VR2 headset.
//!
//! USB identifiers and protocol from Monado's `psvr2` driver (BSL-1.0, see THIRD-PARTY.md).

pub mod camera;
pub mod distortion;
mod distortion_lut;
pub mod protocol;
#[cfg(feature = "usb")]
pub mod usb;

/// Sony Interactive Entertainment USB vendor id.
pub const USB_VENDOR_ID: u16 = 0x054C;

/// PS VR2 headset USB product id (seen through Sony's PC adapter).
pub const USB_PRODUCT_ID: u16 = 0x0CDE;

/// Returns true if a USB vendor/product id pair is a PS VR2 headset.
pub fn is_headset(vendor_id: u16, product_id: u16) -> bool {
    vendor_id == USB_VENDOR_ID && product_id == USB_PRODUCT_ID
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_headset_ids() {
        assert!(is_headset(0x054C, 0x0CDE));
        assert!(!is_headset(0x054C, 0x0CE6)); // DualSense
        assert!(!is_headset(0x1234, 0x0CDE));
    }
}
