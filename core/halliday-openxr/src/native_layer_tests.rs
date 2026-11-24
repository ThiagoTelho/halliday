use super::*;

fn view() -> xr::CompositionLayerProjectionView {
    xr::CompositionLayerProjectionView {
        ty: xr::CompositionLayerProjectionView::TYPE,
        next: std::ptr::null(), pose: IDENTITY,
        fov: xr::Fovf { angle_left: -0.9, angle_right: 1.1, angle_up: 1.05, angle_down: -0.95 },
        sub_image: unsafe { std::mem::zeroed() },
    }
}

#[test]
fn projection_view_checks_type_pose_and_exclusive_fov_bounds_but_accepts_legal_flips() {
    let original = view();
    for horizontal in [false, true] { for vertical in [false, true] {
        let mut v = view();
        if horizontal { std::mem::swap(&mut v.fov.angle_left, &mut v.fov.angle_right); }
        if vertical { std::mem::swap(&mut v.fov.angle_down, &mut v.fov.angle_up); }
        assert_eq!(validate_projection_view(&v), Ok(()));
    }}
    for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY,
                std::f32::consts::FRAC_PI_2, -std::f32::consts::FRAC_PI_2, 2.0, -2.0] {
        for field in 0..4 {
            let mut v = view();
            match field { 0 => v.fov.angle_left=bad, 1 => v.fov.angle_right=bad,
                          2 => v.fov.angle_up=bad, _ => v.fov.angle_down=bad }
            assert_eq!(validate_projection_view(&v), Err(xr::Result::ERROR_VALIDATION_FAILURE));
        }
    }
    let mut v = view();v.ty=xr::StructureType::COMPOSITION_LAYER_QUAD;
    assert_eq!(validate_projection_view(&v), Err(xr::Result::ERROR_VALIDATION_FAILURE));
    let mut v = original;v.pose.orientation.w=2.0;
    assert_eq!(validate_projection_view(&v), Err(xr::Result::ERROR_POSE_INVALID));
}

#[test]
fn projection_pixel_flip_matches_coordinate_oracle_for_odd_even_and_single_pixel_sizes() {
    for width in [1u32,2,3,8] { for height in [1u32,2,5,8] {
        let source: Vec<u8>=(0..width*height*4).map(|n| (n*17+3) as u8).collect();
        for horizontal in [false,true] { for vertical in [false,true] {
            let mut result=source.clone();
            flip_projection_pixels(&mut result,width,height,horizontal,vertical);
            for y in 0..height { for x in 0..width { for channel in 0..4 {
                let sx=if horizontal {width-1-x} else {x};
                let sy=if vertical {height-1-y} else {y};
                assert_eq!(result[((y*width+x)*4+channel) as usize],source[((sy*width+sx)*4+channel) as usize]);
            }}}
            flip_projection_pixels(&mut result,width,height,horizontal,vertical);
            assert_eq!(result,source,"flipping twice must preserve every byte");
        }}
    }}
}
