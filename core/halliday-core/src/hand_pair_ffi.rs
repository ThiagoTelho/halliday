//! One paired optical solve, without HID/camera ownership or controller pose offsets.
use crate::ffi::{HallidayCameraSpot, HallidayHandFix};
use crate::math::Quat;
use crate::tracking::hands::{Frame, PairedHandTracker, Spot};
use crate::tracking::stereo::{PSVR2_BOTTOM, PSVR2_BOTTOM_PLACE};
use std::sync::Mutex;

pub struct HallidayHandPair(Mutex<PairedHandTracker>);

#[unsafe(no_mangle)]
pub extern "C" fn halliday_hand_pair_open() -> *mut HallidayHandPair {
    Box::into_raw(Box::new(HallidayHandPair(Mutex::new(
        PairedHandTracker::new(),
    ))))
}
/// # Safety
/// Null or an owned handle from open, never used after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_pair_close(handle: *mut HallidayHandPair) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
/// # Safety
/// Null or a live handle. This resets both optical tracks on a geometry change.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_pair_set_fisheyes(
    handle: *const HallidayHandPair,
    on: bool,
) {
    if let Some(handle) = unsafe { handle.as_ref() } {
        handle
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .set_bottom_fisheyes(on);
    }
}
/// # Safety
/// Null or live handle; rotation is null or3 readable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_pair_set_fisheye_alignment(
    handle: *const HallidayHandPair,
    rotation: *const f32,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    if rotation.is_null() {
        return false;
    }
    let rotation = unsafe { [*rotation, *rotation.add(1), *rotation.add(2)] };
    handle
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .set_bottom_fisheye_alignment(rotation.map(f64::from))
}

/// # Safety
/// All non-null pointers address the declared complete arrays. Out has2 fixes,
/// head4 floats, head_position3, controllers8(leftXYZW,rightXYZW). Spot arrays
/// have count entries. This function only consumes these immutable snapshots.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_pair_update(
    handle: *const HallidayHandPair,
    exposure_ns: u64,
    head: *const f32,
    head_position: *const f32,
    controllers: *const f32,
    controller_mask: u32,
    left: *const HallidayCameraSpot,
    left_count: u32,
    right: *const HallidayCameraSpot,
    right_count: u32,
    top_left: *const HallidayCameraSpot,
    top_left_count: u32,
    top_right: *const HallidayCameraSpot,
    top_right_count: u32,
    out: *mut HallidayHandFix,
) -> u32 {
    if out.is_null() {
        return 0;
    }
    unsafe {
        out.write(HallidayHandFix::default());
        out.add(1).write(HallidayHandFix::default());
    }
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if exposure_ns == 0 || head.is_null() || head_position.is_null() || controllers.is_null() {
        return 0;
    }
    let quat = |p: *const f32| -> Option<Quat> {
        let v = unsafe { [*p, *p.add(1), *p.add(2), *p.add(3)] };
        let norm = v.iter().map(|v| v * v).sum::<f32>();
        if !v.iter().all(|v| v.is_finite()) || !norm.is_finite() || norm < 1e-8 {
            return None;
        }
        Some(
            Quat {
                x: v[0],
                y: v[1],
                z: v[2],
                w: v[3],
            }
            .normalized(),
        )
    };
    let Some(head) = quat(head) else { return 0 };
    let head_position = unsafe { [*head_position, *head_position.add(1), *head_position.add(2)] };
    if !head_position.iter().all(|x| x.is_finite()) {
        return 0;
    }
    let spots = |p: *const HallidayCameraSpot, n: u32| -> Option<Vec<Spot>> {
        if n > 4096 || (n > 0 && p.is_null()) {
            return None;
        }
        if n == 0 {
            return Some(Vec::new());
        }
        Some(
            unsafe { std::slice::from_raw_parts(p, n as usize) }
                .iter()
                .filter(|s| s.x.is_finite() && s.y.is_finite())
                .map(|s| Spot {
                    x: s.x,
                    y: s.y,
                    area: s.area,
                })
                .collect(),
        )
    };
    let (Some(left), Some(right), Some(top_left), Some(top_right)) = (
        spots(left, left_count),
        spots(right, right_count),
        spots(top_left, top_left_count),
        spots(top_right, top_right_count),
    ) else {
        return 0;
    };
    let frame = Frame {
        counter: exposure_ns,
        t_ns: exposure_ns,
        left,
        right,
        top: [top_left, top_right],
        hands: std::array::from_fn(|i| {
            if controller_mask & (1 << i) != 0 {
                quat(unsafe { controllers.add(i * 4) })
            } else {
                None
            }
        }),
        hands_at: [None; 2],
        head: Some(head),
        head_position: Some(head_position),
    };
    let fixes = handle
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .update_frame(&frame);
    let mut mask = 0;
    for (hand, fix) in fixes.into_iter().enumerate() {
        if let Some(fix) = fix {
            let at = PSVR2_BOTTOM.in_head(PSVR2_BOTTOM_PLACE, fix.position.map(f64::from));
            unsafe {
                out.add(hand).write(HallidayHandFix {
                    position: at.map(|v| v as f32),
                    heading: fix.heading,
                    sightings: fix.sightings,
                    rms: fix.rms,
                    tilt: fix.tilt,
                });
            }
            mask |= 1 << hand;
        }
    }
    mask
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paired_optical_ffi_geometry_nulls_and_missing_pose_are_safe() {
        let handle = halliday_hand_pair_open();
        let mut out = [HallidayHandFix::default(); 2];
        let q = [0., 0., 0., 1.];
        let qs = [0., 0., 0., 1., 0., 0., 0., 1.];
        let p = [0.; 3];
        unsafe {
            assert!(!halliday_hand_pair_set_fisheye_alignment(
                std::ptr::null(),
                p.as_ptr()
            ));
            assert!(!halliday_hand_pair_set_fisheye_alignment(
                handle,
                std::ptr::null()
            ));
            assert!(!halliday_hand_pair_set_fisheye_alignment(
                handle,
                [0., f32::NAN, 0.].as_ptr()
            ));
            assert!(halliday_hand_pair_set_fisheye_alignment(handle, p.as_ptr()));
            halliday_hand_pair_set_fisheyes(handle, true);
            assert_eq!(
                halliday_hand_pair_update(
                    handle,
                    1,
                    q.as_ptr(),
                    p.as_ptr(),
                    qs.as_ptr(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    out.as_mut_ptr()
                ),
                0
            );
            assert!(out.iter().all(|f| f.sightings == 0));
            halliday_hand_pair_close(handle);
            halliday_hand_pair_close(std::ptr::null_mut());
        }
    }
}
