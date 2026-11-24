//! Submitted camera geometry, independent of texture readback and render-pose tags.
use super::{compose, from_bridge, xr};
use halliday_bridge as bridge;
use halliday_core::game_bridge::Config;

pub(super) fn view(base: xr::Posef, source: &xr::CompositionLayerProjectionView) -> bridge::projection::View {
    let world = compose(base, source.pose);
    let fov = source.fov;
    // The .14 pixel handoff already applies each legal reversed-FOV flip.
    // Store canonical bounds matching those pixels, never flip them twice.
    bridge::projection::View {
        position: [world.position.x, world.position.y, world.position.z],
        orientation: [world.orientation.x, world.orientation.y, world.orientation.z, world.orientation.w],
        tangents: [fov.angle_left.min(fov.angle_right).tan(), fov.angle_left.max(fov.angle_right).tan(),
                   fov.angle_up.max(fov.angle_down).tan(), fov.angle_up.min(fov.angle_down).tan()],
    }
}

fn near(a: f32, b: f32) -> bool { (a-b).abs() <= 1e-5 * a.abs().max(b.abs()).max(1.0) }

/// What the legacy bridge can express: one rendered head, calibrated eye
/// separation, parallel cameras and the headset's calibrated FOV. Compare with
/// the actual derived rendered head, not a newer tracking sample.
pub(super) fn legacy_compatible(views: &[bridge::projection::View; 2], head: bridge::Pose, config: &Config) -> bool {
    let head = from_bridge(&head);
    for (eye, source) in views.iter().enumerate() {
        let mut offset = super::IDENTITY;
        offset.position.x = if eye == 0 { -config.ipd * 0.5 } else { config.ipd * 0.5 };
        let expected = compose(head, offset);
        if !source.position.iter().zip([expected.position.x,expected.position.y,expected.position.z]).all(|(&a,b)|near(a,b)) {
            return false;
        }
        let q=[expected.orientation.x,expected.orientation.y,expected.orientation.z,expected.orientation.w];
        let same=source.orientation.iter().zip(q).all(|(&a,b)|near(a,b));
        let opposite=source.orientation.iter().zip(q).all(|(&a,b)|near(a,-b));
        if !same && !opposite { return false; }
        if !source.tangents.iter().zip(config.tangents[eye]).all(|(&a,b)|near(a,b)) { return false; }
    }
    true
}
