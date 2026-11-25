import Foundation
import simd

// Only the immutable headset optical constants are substituted. The real
// Settings→gameImageSettingsGeometry→GameViewGeometry path is compiled intact.
enum Eye { case left, right }
struct Fov { let left: Float, right: Float, up: Float, down: Float }
enum Optics {
    static func fov(_ eye: Eye) -> Fov {
        let outward: Float = 61.5 * .pi / 180, inward: Float = 43.5 * .pi / 180
        let vertical: Float = 53 * .pi / 180
        return Fov(left: eye == .left ? -outward : -inward, right: eye == .left ? inward : outward,
                   up: vertical, down: -vertical)
    }
}

@main struct CropSettingsTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ why: String) {
            checks += 1
            if !value() { print("FAIL:", why); exit(1) }
        }
        let suite = "app.halliday.tests.crop.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(75, forKey: "gameRenderPercent")
        d.set("auto", forKey: "gameHalfFrameRateMode")
        d.set(120, forKey: "headsetRefreshHz")
        let before = d.persistentDomain(forName: suite)!
        let s = Settings(defaults: d)
        check(!s.gameCropEnabled && s.gameCropHorizontal == 0.85 && s.gameCropVertical == 0.90, "legacy crop defaults retained, default remains off")
        check(NSDictionary(dictionary: before).isEqual(to: d.persistentDomain(forName: suite)!), "reading new settings writes no migration")
        s.gameCropHorizontal = 0.63; s.gameCropVertical = 0.97; s.gameCropEnabled = true
        let reload = Settings(defaults: d)
        check(reload.gameCropEnabled && reload.gameCropHorizontal == 0.63 && reload.gameCropVertical == 0.97, "independent values persist")
        let requested = gameImageSettingsGeometry(reload)
        check(requested.isCropped, "real settings geometry helper applies crop")
        check(s.gameRenderPercent == 75 && s.gameHalfFrameRateMode == .auto && s.headsetRefreshHz == 120, "crop does not lower render scale/change cadence or refresh")
        var crop = 0, general = 0
        s.onChange = { general += 1 }; s.onGameCropChange = { crop += 1 }
        s.gameCropEnabled = false; s.gameCropHorizontal = 0.72; s.gameCropVertical = 0.93
        check(crop == 3 && general == 0, "slider and toggle use crop-only notification, no general reanchor")
        s.reduceMotion.toggle()
        check(general == 1 && crop == 3, "unrelated settings notification unchanged")
        s.onGameCropChange = nil; s.gameCropHorizontal = 0.85
        check(general == 2, "standalone general callback fallback")
        s.onChange = nil
        for (value, h, v): (Float, Float, Float) in [(-5,0.5,0.5),(9,1,1),(.nan,0.85,0.90),(.infinity,0.85,0.90)] {
            s.gameCropHorizontal = value; s.gameCropVertical = value
            check(s.gameCropHorizontal == h && s.gameCropVertical == v, "setter finite bounds/defaults")
            check(Settings(defaults: d).gameCropHorizontal == h && Settings(defaults: d).gameCropVertical == v, "persist only finite sanitized values")
        }
        d.set(-0.8, forKey: "gameCropHorizontal"); d.set(1.8, forKey: "gameCropVertical")
        let bounded = Settings(defaults: d)
        check(bounded.gameCropHorizontal == 0.5 && bounded.gameCropVertical == 1, "stored doubles clamped")
        d.set("bad", forKey: "gameCropHorizontal"); d.set("bad", forKey: "gameCropVertical")
        check(Settings(defaults: d).gameCropHorizontal == 0.85 && Settings(defaults: d).gameCropVertical == 0.90, "malformed saved values fallback")

        for percent in [50,55,65,75,85,95,100] {
            s.gameRenderPercent = percent; s.gameCropEnabled = false
            let full = gameImageSettingsGeometry(s)
            for h: Float in [0.5,0.61,0.74,0.85,0.93,1] {
                for v: Float in [0.5,0.67,0.90,0.99,1] {
                    s.gameCropHorizontal = h; s.gameCropVertical = v; s.gameCropEnabled = true
                    let g = gameImageSettingsGeometry(s)
                    check(g.renderSize.width % 32 == 0 && g.renderSize.height % 32 == 0, "runtime render budget aligned")
                    check(g.imageTarget.width % 32 == 0 && g.imageTarget.height % 32 == 0, "reconstruction budget aligned")
                    for eye in [0,1] {
                        let a = eye == 0 ? full.leftTangents : full.rightTangents
                        let b = eye == 0 ? g.leftTangents : g.rightTangents
                        let sx = Double(a.y-a.x), sy = Double(a.z-a.w)
                        let cx = Double(b.y-b.x), cy = Double(b.z-b.w)
                        check(abs(sx/Double(full.renderSize.width)-cx/Double(g.renderSize.width)) < 2e-8, "input horizontal ray density preserved")
                        check(abs(sy/Double(full.renderSize.height)-cy/Double(g.renderSize.height)) < 2e-8, "input vertical ray density preserved")
                        check(Double(g.imageTarget.width)/cx+0.0001 >= Double(full.imageTarget.width)/sx, "FSR output horizontal density never drops")
                        check(Double(g.imageTarget.height)/cy+0.0001 >= Double(full.imageTarget.height)/sy, "FSR output vertical density never drops")
                        check((eye == 0 ? a.y.bitPattern == b.y.bitPattern : a.x.bitPattern == b.x.bitPattern), "inner eye edge unchanged")
                        for uv: Float in [0,0.25,0.5,0.75,1] {
                            let sourceU = (Float(eye == 0 ? g.removedColumns : 0)+uv*Float(g.renderSize.width))/Float(full.renderSize.width)
                            let expected = a.x+(a.y-a.x)*sourceU
                            let actual = b.x+(b.y-b.x)*uv
                            check(abs(expected-actual) < 1e-6, "retained ray is not zoomed")
                        }
                    }
                    if h == 1 { check(g.removedColumns == 0, "vertical slider leaves horizontal FOV alone") }
                    if v == 1 { check(g.removedRows == 0, "horizontal slider leaves vertical FOV alone") }
                }
            }
        }
        s.gameRenderPercent = 100; s.gameCropHorizontal = 0.85; s.gameCropVertical = 0.90
        let legacy = gameImageSettingsGeometry(s)
        check(legacy.renderSize == .init(width: 1728,height: 1856) && legacy.imageTarget == legacy.renderSize, "original fixed crop remains same geometry")
        s.gameCropEnabled = false
        let off = gameImageSettingsGeometry(s)
        check(off.renderSize == .init(width: 2016,height: 2048) && off.imageTarget == off.renderSize, "disabled retains full original pixel budget")
        print("PASS: \(checks) independent crop persistence, notification, geometry and input/output pixel-density checks")
    }
}
