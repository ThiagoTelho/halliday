//! USB transport for the PS VR2 headset, over libusb (rusb).
//!
//! Follows the sequence GAV PSVR2 Player uses on macOS (MIT; see THIRD-PARTY.md): check that the
//! link is not full-speed, claim the status interface and select alt setting 1, claim the SLAM
//! interface, then read both streams with blocking transfers from their own threads. No kernel
//! extension or root is needed on macOS.
//!
//! [`Headset`] is `Sync`: one thread can block in [`Headset::read_slam`] while another blocks in
//! [`Headset::read_status`]. Control requests can be issued from any thread, but keep them on one
//! (as GAV does) to avoid interleaving commands.

use std::time::Duration;

pub use rusb::Speed;
use rusb::{Context, DeviceHandle, Direction, Recipient, RequestType, UsbContext};
use thiserror::Error;

use super::protocol::{self, DistortionCalibration, FirmwareInfo, ParseError, report};
use super::{USB_PRODUCT_ID, USB_VENDOR_ID};

/// Timeout for control requests.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Debug, Error)]
pub enum UsbError {
    #[error("no PS VR2 headset found on USB (is Sony's PC adapter connected and powered?)")]
    NotFound,
    #[error(
        "the headset is on a full-speed (12 Mbit/s) USB link, so its IMU stream is missing; \
         connect the adapter's USB cable to a USB 3 port, without USB 2 hubs or cables"
    )]
    FullSpeedLink,
    #[error("USB error while trying to {step}: {source}")]
    Usb {
        step: &'static str,
        source: rusb::Error,
    },
    #[error("bad reply from the headset: {0}")]
    Protocol(#[from] ParseError),
}

fn usb(step: &'static str) -> impl FnOnce(rusb::Error) -> UsbError {
    move |source| UsbError::Usb { step, source }
}

/// A PS VR2 headset found on USB, with its basic descriptor facts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadsetInfo {
    pub bus: u8,
    pub address: u8,
    pub speed: Speed,
}

/// Lists PS VR2 headsets currently on USB, without opening them.
pub fn find_headsets() -> Result<Vec<HeadsetInfo>, UsbError> {
    let ctx = Context::new().map_err(usb("create a libusb context"))?;
    let devices = ctx.devices().map_err(usb("list USB devices"))?;
    let mut found = Vec::new();
    for dev in devices.iter() {
        let Ok(desc) = dev.device_descriptor() else {
            continue;
        };
        if super::is_headset(desc.vendor_id(), desc.product_id()) {
            found.push(HeadsetInfo {
                bus: dev.bus_number(),
                address: dev.address(),
                speed: dev.speed(),
            });
        }
    }
    Ok(found)
}

/// An open PS VR2 headset with the status and SLAM interfaces claimed.
pub struct Headset {
    handle: DeviceHandle<Context>,
    speed: Speed,
}

impl Headset {
    /// Opens the first PS VR2 headset and claims the status and SLAM interfaces.
    ///
    /// Fails with [`UsbError::FullSpeedLink`] when the headset enumerated at full speed: the
    /// status interface then lacks alt setting 1, which carries the IMU. GAV found that a bad
    /// plug-in can look the same and that one re-enumeration cures it; that retry is left to the
    /// caller (see [`Headset::reset`]).
    /// Asks the headset to re-enumerate without claiming anything first: what brings it back when
    /// it has stopped answering (it then refuses its interfaces, and `open` fails). libusb may
    /// block about 10 s.
    pub fn reset_device() -> Result<(), UsbError> {
        let ctx = Context::new().map_err(usb("create a libusb context"))?;
        let handle = ctx
            .open_device_with_vid_pid(USB_VENDOR_ID, USB_PRODUCT_ID)
            .ok_or(UsbError::NotFound)?;
        handle.reset().map_err(usb("reset the device"))
    }

    pub fn open() -> Result<Headset, UsbError> {
        let ctx = Context::new().map_err(usb("create a libusb context"))?;
        let handle = ctx
            .open_device_with_vid_pid(USB_VENDOR_ID, USB_PRODUCT_ID)
            .ok_or(UsbError::NotFound)?;
        let device = handle.device();
        let speed = device.speed();

        if !status_alt_setting_present(&handle)? {
            return Err(UsbError::FullSpeedLink);
        }

        handle
            .claim_interface(protocol::STATUS_INTERFACE)
            .map_err(usb("claim the status interface"))?;
        handle
            .set_alternate_setting(protocol::STATUS_INTERFACE, protocol::STATUS_ALT_SETTING)
            .map_err(usb("select the status interface's alt setting 1"))?;
        handle
            .claim_interface(protocol::SLAM_INTERFACE)
            .map_err(usb("claim the SLAM interface"))?;

        Ok(Headset { handle, speed })
    }

    /// Link speed the headset enumerated at.
    pub fn speed(&self) -> Speed {
        self.speed
    }

    /// Asks the headset to re-enumerate. Consumes the handle: open it again afterwards.
    /// libusb can block for about 10 s here while the device comes back as a new one.
    pub fn reset(self) -> Result<(), UsbError> {
        self.handle.reset().map_err(usb("reset the device"))
    }

    /// Vendor control read: returns the payload (the reply minus its 8-byte header).
    pub fn get_report(&self, report_id: u16, len: usize) -> Result<Vec<u8>, UsbError> {
        let request_type =
            rusb::request_type(Direction::In, RequestType::Vendor, Recipient::Endpoint);
        let mut buf = vec![0u8; protocol::CONTROL_HEADER_SIZE + len];
        let n = self
            .handle
            .read_control(
                request_type,
                protocol::CONTROL_GET_REQUEST,
                report_id,
                0,
                &mut buf,
                CONTROL_TIMEOUT,
            )
            .map_err(usb("read a control report"))?;
        if n < protocol::CONTROL_HEADER_SIZE {
            return Err(ParseError::TooShort {
                need: protocol::CONTROL_HEADER_SIZE,
                got: n,
            }
            .into());
        }
        buf.truncate(n);
        Ok(buf.split_off(protocol::CONTROL_HEADER_SIZE))
    }

    /// Vendor control write of a command packet.
    pub fn send_command(
        &self,
        report_id: u16,
        subcmd: u16,
        payload: &[u8],
    ) -> Result<(), UsbError> {
        let request_type =
            rusb::request_type(Direction::Out, RequestType::Vendor, Recipient::Endpoint);
        let pkt = protocol::encode_control(report_id, subcmd, payload)?;
        self.handle
            .write_control(
                request_type,
                protocol::CONTROL_SET_REQUEST,
                report_id,
                0,
                &pkt,
                CONTROL_TIMEOUT,
            )
            .map_err(usb("send a control command"))?;
        Ok(())
    }

    pub fn firmware_info(&self) -> Result<FirmwareInfo, UsbError> {
        let payload = self.get_report(report::GET_FIRMWARE_INFO, protocol::FIRMWARE_INFO_SIZE)?;
        Ok(FirmwareInfo::parse(&payload)?)
    }

    pub fn distortion_calibration(&self) -> Result<DistortionCalibration, UsbError> {
        let payload = self.get_report(
            report::GET_DISTORTION_CALIBRATION,
            protocol::DISTORTION_BLOCK_SIZE,
        )?;
        Ok(DistortionCalibration::parse(&payload)?)
    }

    /// Panel brightness, 0..=1.
    pub fn set_brightness(&self, brightness: f32) -> Result<(), UsbError> {
        self.send_command(
            report::SET_BRIGHTNESS,
            1,
            &protocol::brightness_payload(brightness),
        )
    }

    /// Blocks until a status packet arrives. Returns its length, or `None` on timeout.
    pub fn read_status(
        &self,
        buf: &mut [u8],
        timeout: Duration,
    ) -> Result<Option<usize>, UsbError> {
        timeout_is_none(
            self.handle
                .read_interrupt(protocol::STATUS_ENDPOINT, buf, timeout),
            "read the status stream",
        )
    }

    /// Starts the headset's tracking cameras in `mode` (Monado's `psvr2_camera_mode`: 1 is the
    /// two bottom cameras side by side, 640 × 640 each; 4 is the controller-tracking mode, short
    /// exposures as two 512 × 508 fisheye pictures, top and bottom pairs in turn; 0 is off).
    /// Claims the camera interface the first time.
    pub fn set_camera_mode(&self, mode: u32) -> Result<(), UsbError> {
        if mode != 0 {
            self.handle
                .claim_interface(protocol::CAMERA_INTERFACE)
                .map_err(usb("claim the camera interface"))?;
        }
        let mut payload = [0u8; 8];
        payload[..4].copy_from_slice(&1u32.to_le_bytes());
        payload[4..].copy_from_slice(&mode.to_le_bytes());
        self.send_command(report::SET_CAMERA_MODE, 1, &payload)
    }

    /// Blocks until a camera frame arrives (one bulk transfer: a 256-byte header, then the
    /// pixels). `buf` must hold the largest frame of the mode (1 MB is enough for all known).
    pub fn read_camera(
        &self,
        buf: &mut [u8],
        timeout: Duration,
    ) -> Result<Option<usize>, UsbError> {
        timeout_is_none(
            self.handle
                .read_bulk(protocol::CAMERA_ENDPOINT, buf, timeout),
            "read the camera stream",
        )
    }

    /// Blocks until a SLAM record arrives. Returns its length, or `None` on timeout.
    pub fn read_slam(&self, buf: &mut [u8], timeout: Duration) -> Result<Option<usize>, UsbError> {
        timeout_is_none(
            self.handle.read_bulk(protocol::SLAM_ENDPOINT, buf, timeout),
            "read the SLAM stream",
        )
    }
}

impl Drop for Headset {
    fn drop(&mut self) {
        let _ = self.handle.release_interface(protocol::CAMERA_INTERFACE);
        let _ = self.handle.release_interface(protocol::SLAM_INTERFACE);
        let _ = self.handle.release_interface(protocol::STATUS_INTERFACE);
    }
}

fn timeout_is_none(r: rusb::Result<usize>, step: &'static str) -> Result<Option<usize>, UsbError> {
    match r {
        Ok(n) => Ok(Some(n)),
        Err(rusb::Error::Timeout) => Ok(None),
        Err(source) => Err(UsbError::Usb { step, source }),
    }
}

/// True if the active configuration has the status interface's alt setting 1.
fn status_alt_setting_present(handle: &DeviceHandle<Context>) -> Result<bool, UsbError> {
    let config = handle
        .device()
        .active_config_descriptor()
        .map_err(usb("read the configuration descriptor"))?;
    Ok(config.interfaces().flat_map(|i| i.descriptors()).any(|d| {
        d.interface_number() == protocol::STATUS_INTERFACE
            && d.setting_number() == protocol::STATUS_ALT_SETTING
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_sync<T: Sync + Send>() {}

    #[test]
    fn headset_can_be_shared_between_reader_threads() {
        assert_sync::<Headset>();
    }
}
