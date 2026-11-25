import simd

@MainActor
func gameImageSettingsGeometry(_ settings: Settings) -> GameViewGeometry {
    let size = GameImagePlan.renderSize(percent: settings.gameRenderPercent)
    func tangents(_ eye: Eye) -> SIMD4<Float> {
        let f = Optics.fov(eye)
        return SIMD4(tan(f.left), tan(f.right), tan(f.up), tan(f.down))
    }
    return GameViewGeometry(renderSize: .init(width: size.width, height: size.height),
        imageTarget: .init(width: GameImagePlan.targetWidth, height: GameImagePlan.targetHeight),
        leftTangents: tangents(.left), rightTangents: tangents(.right),
        crop: GameCropSettings(enabled: settings.gameCropEnabled,
                               horizontal: settings.gameCropHorizontal, vertical: settings.gameCropVertical))
}
