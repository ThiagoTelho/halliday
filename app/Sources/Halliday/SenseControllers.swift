import Foundation
@preconcurrency import IOKit.hid
import simd
import CHallidayCore

/// The PS VR2 Sense controllers, paired with the Mac over Bluetooth (or plugged in over USB).
///
/// macOS shows them as HID devices. This reads their input reports on a thread of its own and
/// hands the bytes to the core (`halliday_sense_*`: the parser and the orientation are in Rust,
/// `core/halliday-core/src/sense.rs`); the app reads each hand's `state` whenever it likes.
/// Reading a game controller needs no permission from the user.
///
/// A controller has an orientation but, until the headset's cameras track it, no position, and no
/// compass: `recenter` says which way it points now.
final class SenseControllers: @unchecked Sendable {
    enum Hand: Int, CaseIterable, Sendable {
        case left, right
        var name: String { self == .left ? "left" : "right" }
        var productID: Int { self == .left ? 0x0E45 : 0x0E46 }
    }

    struct Buttons: OptionSet, Sendable {
        let rawValue: UInt32
        static let trigger = Buttons(rawValue: 1 << 0)
        static let grip = Buttons(rawValue: 1 << 1)
        static let stick = Buttons(rawValue: 1 << 2)
        static let ps = Buttons(rawValue: 1 << 3)
        /// Create on the left controller, Options on the right.
        static let menu = Buttons(rawValue: 1 << 4)
        /// Square on the left controller, cross on the right.
        static let lower = Buttons(rawValue: 1 << 5)
        /// Triangle on the left controller, circle on the right.
        static let upper = Buttons(rawValue: 1 << 6)
        static let triggerTouch = Buttons(rawValue: 1 << 8)
        static let gripTouch = Buttons(rawValue: 1 << 9)
        static let stickTouch = Buttons(rawValue: 1 << 10)
        static let lowerTouch = Buttons(rawValue: 1 << 11)
        static let upperTouch = Buttons(rawValue: 1 << 12)
    }

    struct State: Sendable {
        /// The controller's axes (x right, y up, −z forward) in the tracking space.
        var orientation: simd_quatf
        var angularVelocity: SIMD3<Float>
        var stick: SIMD2<Float>
        var trigger: Float
        var triggerProximity: Float
        var gripProximity: Float
        var buttons: Buttons
        var reports: Int
        var missed: Int
        /// Seconds since the newest report arrived.
        var age: Float
        /// The controller's clock at its newest report, in thirds of a microsecond.
        var deviceTicks: UInt32
        var batteryPercent: Int
        var charging: Bool
        /// False until the orientation has found "up".
        var settled: Bool
    }

    /// One connected controller: the core's handle and the buffer macOS writes reports into.
    private final class Device {
        let hand: Hand
        let device: IOHIDDevice
        let core: OpaquePointer
        let buffer: UnsafeMutablePointer<UInt8>
        static let bufferSize = 128
        weak var owner: SenseControllers?

        init?(hand: Hand, device: IOHIDDevice) {
            guard let core = halliday_sense_open(UInt16(hand.productID)) else { return nil }
            self.hand = hand
            self.device = device
            self.core = core
            buffer = .allocate(capacity: Self.bufferSize)
        }

        deinit {
            halliday_sense_close(core)
            buffer.deallocate()
        }
    }

    private let lock = NSLock()
    private var devices: [Hand: Device] = [:]
    private var manager: IOHIDManager?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// Starts looking for controllers; they come and go as they wake, sleep and reconnect.
    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "halliday.sense"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    /// The newest state of a hand's controller; nil while it isn't connected or has sent nothing.
    func state(_ hand: Hand) -> State? {
        lock.lock()
        let core = devices[hand]?.core
        var s = HallidaySenseState()
        let ok = core.map { halliday_sense_state($0, &s) } ?? false
        lock.unlock()
        guard ok else { return nil }
        return State(
            orientation: simd_quatf(ix: s.orientation.0, iy: s.orientation.1, iz: s.orientation.2, r: s.orientation.3),
            angularVelocity: SIMD3(s.angular_velocity.0, s.angular_velocity.1, s.angular_velocity.2),
            stick: SIMD2(s.stick.0, s.stick.1), trigger: s.trigger,
            triggerProximity: s.trigger_proximity, gripProximity: s.grip_proximity,
            buttons: Buttons(rawValue: s.buttons), reports: Int(s.reports), missed: Int(s.missed), age: s.age, deviceTicks: s.device_ticks,
            batteryPercent: Int(s.battery_percent), charging: s.charging != 0, settled: s.settled != 0)
    }

    var connected: [Hand] { lock.lock(); defer { lock.unlock() }; return Hand.allCases.filter { devices[$0] != nil } }

    /// Says a hand's controller points along `yaw` now (radians about y; 0 is straight ahead).
    func recenter(_ hand: Hand, yaw: Float) {
        lock.lock()
        if let core = devices[hand]?.core { halliday_sense_recenter(core, yaw) }
        lock.unlock()
    }
    // The controller's place: the cameras' fixes fused with its accelerometer in the core
    // (`tracking/place.rs`).

    private func core(_ hand: Hand) -> OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        return devices[hand]?.core
    }

    /// What the cameras add to the controller's own heading: with it the accelerometer is put
    /// in the room's frame.
    func setRoomYaw(_ hand: Hand, _ yaw: Float) {
        if let core = core(hand) { halliday_sense_room_yaw(core, yaw) }
    }

    /// The cameras saw the controller at `position` (the room's frame) at host time `ns`.
    func placeFix(_ hand: Hand, ns: Int64, _ position: SIMD3<Float>) {
        guard let core = core(hand) else { return }
        var p = [position.x, position.y, position.z]
        halliday_sense_place_fix(core, ns, &p)
    }

    /// Where the controller is at host time `ns`, and its velocity; nil when not seen lately.
    func place(_ hand: Hand, atNs ns: Int64) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)? {
        guard let core = core(hand) else { return nil }
        var p = [Float](repeating: 0, count: 3), v = [Float](repeating: 0, count: 3)
        guard halliday_sense_place(core, ns, &p, &v) else { return nil }
        return (SIMD3(p[0], p[1], p[2]), SIMD3(v[0], v[1], v[2]))
    }


    /// Sets every connected controller's tracking LEDs (the core's `led_phase`: 1 blinks, 5 is
    /// off): a pulse of `pulse` × 50 µs every `cycle` seconds, the first one a cycle from now on
    /// each controller's own clock. Not yet in step with the cameras (ROADMAP W11 E.2). Returns
    /// how many controllers took it.
    @discardableResult
    func setLEDs(phase: UInt8, pulse: UInt8 = 42, cycle: Double = 1.0 / 60) -> Int {
        lock.lock()
        let targets = devices.values.map { ($0.device, $0.core) }
        ledSequence &+= 1
        let sequence = ledSequence
        lock.unlock()
        var taken = 0
        for (device, core) in targets {
            var s = HallidaySenseState()
            guard halliday_sense_state(core, &s) else { continue }
            var report = [UInt8](repeating: 0, count: 78)
            let position = s.device_ticks &+ UInt32(cycle * 3_000_000)
            halliday_sense_led_report(sequence & 0x0F, sequence, phase, 1, pulse, position, UInt32(cycle * 3e9),
                                      UInt32(truncatingIfNeeded: halliday_host_time_ns() / 1000), &report)
            if IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x31, report, report.count) == kIOReturnSuccess { taken += 1 }
        }
        return taken
    }
    private var ledSequence: UInt8 = 0

    /// One controller's LEDs put in step: a pulse of `pulse` × 50 µs whose middle is at
    /// `position` on the controller's own clock (thirds of a microsecond, as `deviceTicks`),
    /// then every `cycleNs`. Sent from a queue of its own: a Bluetooth write can take
    /// milliseconds, and this is asked for several times a second.
    func syncLEDs(_ hand: Hand, position: UInt32, cycleNs: Double, pulse: UInt8 = 42) {
        lock.lock()
        let device = devices[hand]?.device
        ledSequence &+= 1
        let sequence = ledSequence
        lock.unlock()
        guard let device else { return }
        var report = [UInt8](repeating: 0, count: 78)
        halliday_sense_led_report(sequence & 0x0F, sequence, 1, sequence, pulse, position, UInt32(cycleNs * 3),
                                  UInt32(truncatingIfNeeded: halliday_host_time_ns() / 1000), &report)
        let bytes = report
        ledQueue.async { _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x31, bytes, bytes.count) }
    }
    private let ledQueue = DispatchQueue(label: "halliday.sense.leds")

    // --- The reading thread ---

    private func run() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = Hand.allCases.map { [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0.productID] as [String: Any] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<SenseControllers>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<SenseControllers>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        // Seized: while Halliday runs the controllers are its alone. Shared, macOS took the PS
        // button for itself and opened its Games app at every press.
        var opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if opened != kIOReturnSuccess {
            log(String(format: "[sense] couldn't take the controllers for Halliday alone (0x%08x): sharing them (the PS button also opens the Mac's Games app)", opened))
            opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if opened != kIOReturnSuccess { log(String(format: "[sense] couldn't open the HID manager (0x%08x)", opened)) }
        lock.lock()
        self.manager = manager
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()
        CFRunLoopRun()
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        devices = [:]
        self.manager = nil
        runLoop = nil
        lock.unlock()
    }

    private func attach(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard let hand = Hand.allCases.first(where: { $0.productID == product }), let d = Device(hand: hand, device: device) else { return }
        d.owner = self
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        // The IMU's calibration: one feature report, read twice for its two halves.
        var halves = [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 2)
        var read = true
        for i in 0..<2 {
            var length = 64
            read = read && IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, &halves[i], &length) == kIOReturnSuccess && length == 64
        }
        let calibrated = read && halliday_sense_calibrate(d.core, halves[0], halves[1], 64)
        // More reports a second (about 133, where it sends 60 by itself): less lag in the hand.
        var faster = [UInt8](repeating: 0, count: 48)
        halliday_sense_polling_report(&faster)
        let asked = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x08, faster, faster.count)
        if asked != kIOReturnSuccess { log(String(format: "[sense] %@ controller didn't take the faster report rate (0x%08x)", hand.name, asked)) }
        IOHIDDeviceRegisterInputReportCallback(device, d.buffer, Device.bufferSize, { context, _, _, _, _, report, length in
            let d = Unmanaged<Device>.fromOpaque(context!).takeUnretainedValue()
            _ = halliday_sense_report(d.core, report, length)
        }, Unmanaged.passUnretained(d).toOpaque())
        lock.lock()
        devices[hand] = d
        lock.unlock()
        log("[sense] \(hand.name) controller connected (\(transport)), IMU calibration \(calibrated ? "read" : "not read: defaults")")
    }

    private func detach(_ device: IOHIDDevice) {
        lock.lock()
        let hand = devices.first { $0.value.device === device }?.key
        // The callback's context points at the Device: unregister before letting it go.
        if let hand, let d = devices[hand] {
            IOHIDDeviceRegisterInputReportCallback(device, d.buffer, Device.bufferSize, nil, nil)
            devices[hand] = nil
        }
        lock.unlock()
        if let hand { log("[sense] \(hand.name) controller disconnected") }
    }

    // --- `halliday --sense-probe [SECONDS]` ---

    /// Prints what the controllers send, a line a second each, for `seconds`: no window.
    static func probe(seconds: Double, ledPhase: UInt8? = nil, ledCycle: Double = 1.0 / 60) {
        let sense = SenseControllers()
        sense.start()
        var ledsTaken = -1
        let names: [(Buttons, String)] = [(.trigger, "trigger"), (.grip, "grip"), (.stick, "stick"), (.ps, "PS"), (.menu, "menu"),
                                          (.lower, "lower"), (.upper, "upper"), (.triggerTouch, "trigger-touch"), (.gripTouch, "grip-touch"),
                                          (.stickTouch, "stick-touch"), (.lowerTouch, "lower-touch"), (.upperTouch, "upper-touch")]
        var seen: [Hand: Buttons] = [:]
        var last: [Hand: Int] = [:]
        let end = Date().addingTimeInterval(seconds)
        var nextLine = Date().addingTimeInterval(1)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.01)
            // `--leds PHASE`: the tracking LEDs, told once both controllers are there (telling
            // them again restarts the blink's timing).
            if let ledPhase, ledsTaken < 2, sense.connected.count == 2 || Date() > end.addingTimeInterval(2 - seconds) {
                let taken = sense.setLEDs(phase: ledPhase, cycle: ledCycle)
                if taken != ledsTaken { ledsTaken = taken; log("[sense] LED phase \(ledPhase): \(taken) controller(s) took the report") }
            }
            for hand in Hand.allCases {
                guard let s = sense.state(hand) else { continue }
                // Each button the first time it is seen pressed.
                let fresh = s.buttons.subtracting(seen[hand] ?? [])
                if !fresh.isEmpty {
                    seen[hand, default: []].formUnion(fresh)
                    log("[sense] \(hand.name): first " + names.filter { fresh.contains($0.0) }.map(\.1).joined(separator: ", "))
                }
            }
            guard Date() >= nextLine else { continue }
            nextLine = nextLine.addingTimeInterval(1)
            for hand in Hand.allCases {
                guard let s = sense.state(hand) else { continue }
                let forward = s.orientation.act(SIMD3<Float>(0, 0, -1))
                let yaw = atan2(-forward.x, -forward.z) * 180 / .pi, pitch = asin(max(-1, min(1, forward.y))) * 180 / .pi
                let up = s.orientation.act(SIMD3<Float>(0, 1, 0))
                let roll = atan2(s.orientation.act(SIMD3<Float>(1, 0, 0)).y, up.y) * 180 / .pi
                log(String(format: "[sense] %@: %d reports/s, %d lost · yaw %+.0f° pitch %+.0f° roll %+.0f° · stick %+.2f %+.2f trigger %.2f near %.2f grip near %.2f · battery %d%%%@",
                           hand.name, s.reports - (last[hand] ?? 0), s.missed, yaw, pitch, roll, s.stick.x, s.stick.y, s.trigger,
                           s.triggerProximity, s.gripProximity, s.batteryPercent, s.charging ? " charging" : ""))
                last[hand] = s.reports
            }
            if sense.connected.isEmpty { log("[sense] no controller connected (pair them in System Settings → Bluetooth: hold Create + PS, or Options + PS)") }
        }
        if ledPhase != nil { sense.setLEDs(phase: 5) }
        sense.stop()
    }
}
