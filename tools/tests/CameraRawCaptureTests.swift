import Foundation

@main struct CameraRawCaptureTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/halliday-raw-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        precondition(CameraRawCapture(arguments: [], report: { _ in }) == nil)
        precondition(CameraRawCapture(arguments: ["--camera-raw-dump", "/Users/example/Documents/unsafe"], report: { _ in }) == nil)
        precondition(CameraRawCapture(arguments: ["--camera-raw-dump",root.path,"--camera-raw-trigger","/etc/passwd"],report:{_ in}) == nil)
        precondition(CameraRawCapture.payloadSize(width: 4, height: 8, bc4: true) == 16)
        precondition(CameraRawCapture.payloadSize(width: 3, height: 8, bc4: true) == nil)
        precondition(CameraRawCapture.payloadSize(width: 4096, height: 4096, bc4: false) == nil)
        let trigger = root.appendingPathComponent("trigger"), output = root.appendingPathComponent("frames")
        let capture = CameraRawCapture(arguments:["--camera-raw-dump",output.path,"--camera-raw-trigger",trigger.path],report:{_ in})!
        precondition(!capture.wantsImages(at: .nan))
        precondition(!capture.wantsImages(at: 100) && !capture.retainsImages && !fm.fileExists(atPath: output.path))
        try Data().write(to: trigger)
        precondition(capture.wantsImages(at: 100.2) && capture.retainsImages)
        // Two known constant BC4 blocks: top camera4x4=220, bottom camera4x4=180.
        let bc4:[UInt8] = [220,220,0,0,0,0,0,0,180,180,0,0,0,0,0,0]
        func record(_ counter: Int, _ time: Double) {
            capture.record(counter: counter, exposureNs: 123_456 + Int64(counter), width:4,height:8,
                bc4:true,bytes:bc4,mode:16,threshold:200,phases:["left":6,"right":5],now:time)
        }
        record(7,100.2);capture.waitForWrites()
        record(8,100.3) // Between sample deadlines: cannot exceed5Hz.
        record(7,100.41) // Repeated camera counter: never duplicate its file.
        record(9,100.61);capture.waitForWrites()
        precondition(!capture.wantsImages(at:107.2) && capture.finished && !capture.retainsImages)
        capture.waitForWrites()
        let manifestData = try Data(contentsOf:output.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(CameraRawCapture.Manifest.self,from:manifestData)
        precondition(manifest.frames.map(\.counter)==[7,9] && manifest.errors.isEmpty && manifest.reason=="duration")
        precondition(manifest.frames[0].exposure_host_ns==123_463 && manifest.frames[0].left_led_phase==6)
        for frame in manifest.frames {
            precondition(frame.width==4 && frame.height==8 && frame.bc4 && frame.byte_count==16)
            let payload = try Data(contentsOf:output.appendingPathComponent(frame.file))
            precondition(payload==Data(bc4))
        }
        try fm.removeItem(at:trigger);try Data().write(to:trigger)
        precondition(!capture.wantsImages(at:110),"One-shot capture must not rearm")
        // A pre-existing destination must survive a failed staged payload write.
        let collision = root.appendingPathComponent("collision")
        try fm.createDirectory(at:collision,withIntermediateDirectories:true)
        let existing = collision.appendingPathComponent("frame-1.bc4")
        try Data([99]).write(to:existing)
        let failed = CameraRawCapture(arguments:["--camera-raw-dump",collision.path],report:{_ in})!
        precondition(failed.wantsImages(at:0))
        failed.record(counter:1,exposureNs:1,width:4,height:8,bc4:true,bytes:bc4,mode:16,threshold:200,phases:[:],now:0)
        failed.waitForWrites();precondition(!failed.wantsImages(at:1));failed.waitForWrites()
        let preserved = try Data(contentsOf:existing)
        let files = try fm.contentsOfDirectory(atPath:collision.path)
        precondition(preserved==Data([99]))
        precondition(files.allSatisfy{!$0.hasSuffix(".partial")})
        let bad = try JSONDecoder().decode(CameraRawCapture.Manifest.self,from:Data(contentsOf:collision.appendingPathComponent("manifest.json")))
        precondition(bad.frames.isEmpty && bad.errors.count==1)
        // An armed camera with no image must release retention promptly.
        let absent = CameraRawCapture(arguments:["--camera-raw-dump",root.appendingPathComponent("absent").path],report:{_ in})!
        precondition(absent.wantsImages(at:10))
        precondition(!absent.wantsImages(at:12) && absent.finished && !absent.retainsImages)
        absent.waitForWrites()
        let reset = CameraRawCapture(arguments:["--camera-raw-dump",root.appendingPathComponent("clock").path],report:{_ in})!
        precondition(reset.wantsImages(at:10))
        precondition(!reset.wantsImages(at:1) && reset.finished && !reset.retainsImages)
        reset.waitForWrites()
        // Reject a trigger resolving outside private/tmp before any recording.
        let link = root.appendingPathComponent("outside")
        try fm.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:"/etc"))
        precondition(CameraRawCapture(arguments:["--camera-raw-dump",output.path,"--camera-raw-trigger",link.appendingPathComponent("passwd").path],report:{_ in})==nil)
        print("PASS: offdefault/privateTmp-only, triggergate,5Hz7s, exact BC4 payload+metadata, duplicatecounter, one-shot, sizebounds, writecollision cleanup+preservation")
    }
}
