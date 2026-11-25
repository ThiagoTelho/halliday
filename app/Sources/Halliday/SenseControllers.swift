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
        /// Sensor sample on the camera/frame host clock, including transport mapping.
        var sampleHostNs: Int64
        /// The controller's clock at its newest report, in thirds of a microsecond.
        var deviceTicks: UInt32
        var batteryPercent: Int
        var charging: Bool
        /// False until the orientation has found "up".
        var settled: Bool
    }

    /// One connected controller: the core's handle and the buffer macOS writes reports into.
    private final class Device: @unchecked Sendable {
        let hand: Hand
        let device: IOHIDDevice
        let core: OpaquePointer
        let generation: UInt64
        let bluetooth: Bool
        let buffer: UnsafeMutablePointer<UInt8>
        static let bufferSize = 128
        weak var owner: SenseControllers?
        /// Owned by outputQueue, independently of the LED/vibration transport counter.
        var ledProgramming = SenseLEDProgramming()
        var ledSynchronizer = SenseLEDSynchronizer() // outputQueue only
        // lock-protected mailboxes, at most one pending closure per connection.
        var pendingFeedback: SenseLEDSynchronizer.Feedback?
        var feedbackQueued = false
        var pendingCamera: (counter: Int64, exposure: Int64, period: Double, offset: Int64)?
        var cameraQueued = false

        init?(hand: Hand, device: IOHIDDevice, generation: UInt64, transport: String) {
            guard let core = halliday_sense_open(UInt16(hand.productID)) else { return nil }
            self.hand = hand
            self.device = device
            self.core = core
            self.generation = generation
            bluetooth = transport.caseInsensitiveCompare("Bluetooth") == .orderedSame
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
    private var nextGeneration: UInt64 = 0
    private var acceptingOutput = true
    // All output, including the existing LED controls, shares one ordering and
    // per-connection report sequence. HID writes never run on the main actor.
    private let outputQueue = DispatchQueue(label: "halliday.sense.output")
    private var hapticScheduler = SenseHapticScheduler()
    private var activeHapticTokens: [Int: UInt64] = [:] // outputQueue only
    private var outputPolicy = SenseOutputPolicy() // protected by lock
    private var ledFeedbackEnabled = true // conservative phase1 path; fixed-sync API remains available
    private var outputTimer: DispatchSourceTimer?
    // Feature reads can block during wake-up; keep them off the input run loop,
    // main actor and LED/haptic output queue.
    private let calibrationQueue = DispatchQueue(label: "halliday.sense.calibration")
    private final class CalibrationJob: @unchecked Sendable {
        // Accessed only on calibrationQueue.
        var collector = SenseCalibrationCollector()
        var plan = SenseCalibrationRetryPlan()
    }

    /// Starts looking for controllers; they come and go as they wake, sleep and reconnect.
    func start() {
        guard thread == nil else { return }
        lock.lock(); acceptingOutput = true; lock.unlock()
        let t = Thread { [weak self] in self?.run() }
        t.name = "halliday.sense"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        acceptingOutput = false
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
        thread = nil
    }

    /// Queues a vibration for the current Bluetooth connection. True means
    /// accepted for asynchronous output, not proof that a controller took it.
    @discardableResult
    func vibrate(_ hand: Hand, amplitude: Float, frequencyHz: Float, durationNanoseconds: UInt64) -> Bool {
        guard SenseHapticScheduler.valid(amplitude: amplitude, frequencyHz: frequencyHz,
                                        durationNanoseconds: durationNanoseconds) else { return false }
        if amplitude == 0 || durationNanoseconds == 0 { stopVibration(hand); return true }
        lock.lock()
        let target = acceptingOutput && outputPolicy.focused ? devices[hand] : nil
        let policyGeneration = outputPolicy.token(hand: hand.rawValue)
        lock.unlock()
        guard let target, target.bluetooth else { return false }
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        outputQueue.async { [weak self] in
            guard let self, self.current(target, accepting: true),
                  self.hapticRequestCurrent(policyGeneration, hand: hand.rawValue) else { return }
            let commands = self.hapticScheduler.play(hand: hand.rawValue, generation: target.generation,
                amplitude: amplitude, frequencyHz: frequencyHz, durationNanoseconds: durationNanoseconds,
                requestedAt: requestedAt, now: DispatchTime.now().uptimeNanoseconds)
            if !commands.isEmpty {
                self.activeHapticTokens[hand.rawValue] = policyGeneration
            }
            self.sendVibration(commands)
            self.scheduleOutputTimer()
        }
        return true
    }

    func stopVibration(_ hand: Hand) {
        lock.lock(); let target = devices[hand]
        outputPolicy.cancel(hand: hand.rawValue)
        lock.unlock()
        guard let target else { return }
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.sendVibration(self.hapticScheduler.stop(hand: hand.rawValue, generation: target.generation, force: true))
            self.scheduleOutputTimer()
        }
    }

    func stopAllVibration() {
        lock.lock(); outputPolicy.cancelAll()
        lock.unlock()
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.sendVibration(self.hapticScheduler.stopAll(force: true))
            self.scheduleOutputTimer()
        }
    }

    /// UI/dashboard/session ownership can stop classic haptics without touching LED sync.
    func setHapticsFocused(_ focused: Bool) {
        lock.lock()
        guard outputPolicy.setFocused(focused) else { lock.unlock(); return }
        lock.unlock()
        if !focused { stopAllVibration() }
    }

    func setLEDFeedbackEnabled(_ enabled: Bool) {
        lock.lock()
        guard ledFeedbackEnabled != enabled else { lock.unlock(); return }
        ledFeedbackEnabled = enabled
        let targets = Array(devices.values)
        for device in targets { device.pendingCamera = nil; device.pendingFeedback = nil }
        lock.unlock()
        outputQueue.async { for target in targets { target.ledSynchronizer.reset() } }
    }

    private func current(_ expected: Device, accepting: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (!accepting || acceptingOutput) && devices[expected.hand]?.generation == expected.generation
    }
    private var hapticIsFocused: Bool { lock.lock(); defer { lock.unlock() }; return outputPolicy.focused }
    private func hapticRequestCurrent(_ generation: UInt64, hand: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptingOutput && outputPolicy.accepts(hand: hand, token: generation)
    }

    /// Allocate from the same per-connection transport sequence as classic haptics.
    private func ledReportID(_ target: Device) -> (sequence: UInt8, counter: UInt8)? {
        dispatchPrecondition(condition: .onQueue(outputQueue))
        return hapticScheduler.nextReport(hand: target.hand.rawValue, generation: target.generation)
    }

    // The following three methods run only on outputQueue. A task holds the
    // old Device strongly, and revalidates generation before each HID write.
    private func sendVibration(_ commands: [SenseHapticScheduler.Output]) {
        dispatchPrecondition(condition: .onQueue(outputQueue))
        for command in commands {
            guard let hand = Hand(rawValue: command.hand) else { continue }
            if command.amplitude > 0 {
                guard let token = activeHapticTokens[command.hand], hapticRequestCurrent(token, hand: command.hand) else { continue }
            }
            lock.lock(); let target = devices[hand]; lock.unlock()
            guard let target, target.bluetooth, target.generation == command.generation,
                  let reportID = hapticScheduler.nextReport(hand: command.hand, generation: command.generation) else { continue }
            guard let report = target.ledProgramming.vibrationReport(
                transportSequence: reportID.sequence, transportCounter: reportID.counter,
                amplitude: command.amplitude, frequencyHz: command.frequencyHz,
                hostMicroseconds: UInt32(truncatingIfNeeded: halliday_host_time_ns() / 1000)) else {
                log("[sense] \(target.hand.name) vibration report rejected invalid retained LED settings")
                continue
            }
            writeOutput(target, report: report, purpose: "vibration")
        }
    }

    private func writeOutput(_ target: Device, report: [UInt8], purpose: String) {
        dispatchPrecondition(condition: .onQueue(outputQueue))
        lock.lock()
        let cleanup = purpose != "LED" && report[5] == 0
        let allowed = devices[target.hand]?.generation == target.generation && (acceptingOutput || cleanup)
        lock.unlock()
        guard allowed else { return }
        if purpose != "LED", !hapticIsFocused, report[5] != 0 { return }
        let result = IOHIDDeviceSetReport(target.device, kIOHIDReportTypeOutput, 0x31, report, report.count)
        if result != kIOReturnSuccess {
            log(String(format: "[sense] %@ %@ report failed (0x%08x)", target.hand.name, purpose, result))
            // Do not retain old effects on a failed link.
            _ = hapticScheduler.stop(hand: target.hand.rawValue, generation: target.generation)
        }
        else {
            let word: (Int) -> UInt32 = { start in (0..<4).reduce(UInt32(0)) { $0 | UInt32(report[start+$1]) << (8*$1) } }
            target.ledSynchronizer.outputSent(hostUs: word(18), atNs: halliday_host_time_ns(),
                settings: .init(phase: report[22], pulse: report[24], position: word(25), cycle: word(29)))
        }
    }

    private func receiveOutputFeedback(_ target: Device, report: UnsafeMutablePointer<UInt8>, length: Int) {
        var raw = HallidaySenseOutputFeedback()
        guard halliday_sense_output_feedback(UInt16(target.hand.productID), report, length, &raw) else { return }
        let value = SenseLEDSynchronizer.Feedback(sequence: raw.sequence, ticks: raw.device_ticks,
            echoedHostUs: raw.echoed_host_us, crcFailures: raw.crc_failures, receivedNs: halliday_host_time_ns())
        lock.lock()
        guard acceptingOutput, ledFeedbackEnabled, devices[target.hand]?.generation == target.generation else { lock.unlock(); return }
        target.pendingFeedback = value
        guard !target.feedbackQueued else { lock.unlock(); return }
        target.feedbackQueued = true; lock.unlock()
        outputQueue.async { [weak self, target] in
            guard let self else { return }
            self.lock.lock(); let value = target.pendingFeedback
            target.pendingFeedback = nil; target.feedbackQueued = false
            let valid = self.acceptingOutput && self.ledFeedbackEnabled && self.devices[target.hand]?.generation == target.generation
            self.lock.unlock()
            if valid, let value { target.ledSynchronizer.receive(value) }
        }
    }

    /// New exposure-driven entry point. The adapter supplies its existing calibrated
    /// pulse-centre offset; this helper never estimates visibility from a missing hand.
    func synchronizeLEDs(counter: Int64, exposureHostNs: Int64, periodNs: Double, centreOffsetNs: Int64,
                         excluding: Set<Hand> = []) {
        lock.lock()
        let targets = acceptingOutput && ledFeedbackEnabled ? devices.values.filter { $0.bluetooth && !excluding.contains($0.hand) } : []
        for target in targets {
            target.pendingCamera = (counter, exposureHostNs, periodNs, centreOffsetNs)
            guard !target.cameraQueued else { continue }
            target.cameraQueued = true
            outputQueue.async { [weak self, target] in
                guard let self else { return }
                self.lock.lock(); let sample = target.pendingCamera
                target.pendingCamera = nil; target.cameraQueued = false
                let valid = self.acceptingOutput && self.ledFeedbackEnabled && self.devices[target.hand]?.generation == target.generation
                self.lock.unlock()
                guard valid, let sample,
                    let command = target.ledSynchronizer.camera(counter: sample.counter, exposureNs: sample.exposure,
                        periodNs: sample.period, centreOffsetNs: sample.offset, nowNs: halliday_host_time_ns()),
                    let id = self.ledReportID(target) else { return }
                let report = target.ledProgramming.report(transportSequence: id.sequence, transportCounter: id.counter,
                    phase: command.phase, pulse: command.pulse, position: command.position, cycle: command.cycle,
                    hostMicroseconds: UInt32(truncatingIfNeeded: halliday_host_time_ns()/1000))
                self.writeOutput(target, report: report, purpose: "LED")
            }
        }
        lock.unlock()
    }

    func confirmLEDVisibility(_ hand: Hand, counter: Int64, exposureHostNs: Int64) {
        lock.lock(); let target = acceptingOutput ? devices[hand] : nil; lock.unlock()
        guard let target else { return }
        outputQueue.async { [weak self, target] in
            guard let self, self.current(target, accepting: true) else { return }
            target.ledSynchronizer.optical(counter: counter, exposureNs: exposureHostNs, visible: true)
        }
    }

    private func scheduleOutputTimer() {
        dispatchPrecondition(condition: .onQueue(outputQueue))
        guard let deadline = hapticScheduler.nextDeadline else {
            outputTimer?.setEventHandler {}; outputTimer?.cancel(); outputTimer = nil
            return
        }
        if outputTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: outputQueue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let commands = self.hapticScheduler.advance(now: DispatchTime.now().uptimeNanoseconds)
                self.sendVibration(commands)
                self.scheduleOutputTimer()
            }
            outputTimer = timer
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .microseconds(250))
            timer.resume()
        } else {
            outputTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .microseconds(250))
        }
    }

    /// The newest state of a hand's controller; nil while it isn't connected or has sent nothing.
    func state(_ hand: Hand) -> State? {
        lock.lock()
        let core = devices[hand]?.core
        var s = HallidaySenseState()
        var sampleHostNs: Int64 = 0
        let ok = core.map { halliday_sense_state_timed($0, &s, &sampleHostNs) } ?? false
        lock.unlock()
        guard ok else { return nil }
        return State(
            orientation: simd_quatf(ix: s.orientation.0, iy: s.orientation.1, iz: s.orientation.2, r: s.orientation.3),
            angularVelocity: SIMD3(s.angular_velocity.0, s.angular_velocity.1, s.angular_velocity.2),
            stick: SIMD2(s.stick.0, s.stick.1), trigger: s.trigger,
            triggerProximity: s.trigger_proximity, gripProximity: s.grip_proximity,
            buttons: Buttons(rawValue: s.buttons), reports: Int(s.reports), missed: Int(s.missed), age: s.age, sampleHostNs: sampleHostNs, deviceTicks: s.device_ticks,
            batteryPercent: Int(s.battery_percent), charging: s.charging != 0, settled: s.settled != 0)
    }

    var connected: [Hand] { lock.lock(); defer { lock.unlock() }; return Hand.allCases.filter { devices[$0] != nil } }

    /// A cached, bracketed sensor orientation for this exact camera exposure.
    /// No HID request, forward prediction or stale latest-state fallback.
    func orientation(_ hand: Hand, atHostNs exposure: Int64) -> simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        guard let core = devices[hand]?.core else { return nil }
        var q = [Float](repeating: 0, count: 4)
        guard halliday_sense_orientation_at(core, exposure, &q) else { return nil }
        return simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
    }

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

    /// Forget only camera-derived fusion when tracking-camera geometry changes.
    /// The controller's IMU/mount calibration and physical output are untouched.
    func clearOpticalPlace(_ hand: Hand) {
        lock.lock(); defer { lock.unlock() }
        guard let core = devices[hand]?.core else { return }
        halliday_sense_place_fix(core, 0, nil)
        halliday_sense_room_yaw(core, 0)
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
    /// how many current connections accepted an asynchronous report request.
    @discardableResult
    func setLEDs(phase: UInt8, pulse: UInt8 = 42, cycle: Double = 1.0 / 60, hand: Hand? = nil) -> Int {
        guard cycle.isFinite, cycle > 0, cycle * 3e9 <= Double(UInt32.max) else { return 0 }
        lock.lock()
        let targets = acceptingOutput ? devices.values.filter { hand == nil || $0.hand == hand } : []
        lock.unlock()
        for target in targets {
            outputQueue.async { [weak self] in
                guard let self, self.current(target),
                      let reportID = self.ledReportID(target) else { return }
                var state = HallidaySenseState()
                guard halliday_sense_state(target.core, &state) else { return }
                let position = state.device_ticks &+ UInt32(cycle * 3_000_000)
                let report = target.ledProgramming.report(transportSequence: reportID.sequence, transportCounter: reportID.counter,
                    phase: phase, pulse: pulse, position: position, cycle: UInt32(cycle * 3e9),
                    hostMicroseconds: UInt32(truncatingIfNeeded: halliday_host_time_ns() / 1000))
                self.writeOutput(target, report: report, purpose: "LED")
            }
        }
        return targets.count
    }

    /// One controller's LEDs put in step: a pulse of `pulse` × 50 µs whose middle is at
    /// `position` on the controller's own clock (thirds of a microsecond, as `deviceTicks`),
    /// then every `cycleNs`. Sent from a queue of its own: a Bluetooth write can take
    /// milliseconds, and this is asked for several times a second.
    func syncLEDs(_ hand: Hand, position: UInt32, cycleNs: Double, pulse: UInt8 = 42) {
        guard cycleNs.isFinite, cycleNs > 0, cycleNs * 3 <= Double(UInt32.max) else { return }
        lock.lock(); let target = acceptingOutput ? devices[hand] : nil; lock.unlock()
        guard let target else { return }
        outputQueue.async { [weak self] in
            guard let self, self.current(target),
                  let reportID = self.ledReportID(target) else { return }
            let report = target.ledProgramming.report(transportSequence: reportID.sequence, transportCounter: reportID.counter,
                phase: 1, pulse: pulse, position: position, cycle: UInt32(cycleNs * 3),
                hostMicroseconds: UInt32(truncatingIfNeeded: halliday_host_time_ns() / 1000))
            self.writeOutput(target, report: report, purpose: "LED")
        }
    }

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
        // Drain on the reader thread, never the main actor. Stop live Bluetooth
        // actuators before closing HID; queued requests are already disabled.
        outputQueue.sync {
            sendVibration(hapticScheduler.stopAll(force: true))
            scheduleOutputTimer()
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        devices = [:]
        self.manager = nil
        runLoop = nil
        lock.unlock()
    }

    private func attach(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
        lock.lock(); nextGeneration &+= 1; let generation = nextGeneration; lock.unlock()
        guard let hand = Hand.allCases.first(where: { $0.productID == product }),
              let d = Device(hand: hand, device: device, generation: generation, transport: transport) else { return }
        d.owner = self
        IOHIDDeviceRegisterInputReportCallback(device, d.buffer, Device.bufferSize, { context, _, _, _, _, report, length in
            let d = Unmanaged<Device>.fromOpaque(context!).takeUnretainedValue()
            if halliday_sense_report(d.core, report, length) { d.owner?.receiveOutputFeedback(d, report: report, length: length) }
        }, Unmanaged.passUnretained(d).toOpaque())
        lock.lock()
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.hapticScheduler.connect(hand: hand.rawValue, generation: generation, bluetooth: d.bluetooth)
            self.scheduleOutputTimer()
        }
        devices[hand] = d
        lock.unlock()
        log("[sense] \(hand.name) controller connected (\(transport)), IMU calibration pending")
        let job = CalibrationJob()
        calibrationQueue.async { [weak self, d] in self?.calibrate(d, job: job) }
    }

    private func calibrate(_ target: Device, job: CalibrationJob) {
        dispatchPrecondition(condition: .onQueue(calibrationQueue))
        guard job.plan.beginAttempt(isCurrent: current(target, accepting: true)) else { return }
        // Reading feature 05 also asks Sense to leave compatibility mode. Do not
        // give up permanently when the first request races Bluetooth wake-up.
        var calibratedNow = false
        defer {
            if (job.plan.attempts == 1 || calibratedNow), current(target, accepting: true) {
                var faster = [UInt8](repeating: 0, count: 48)
                halliday_sense_polling_report(&faster)
                let result = IOHIDDeviceSetReport(target.device, kIOHIDReportTypeFeature, 0x08, faster, faster.count)
                if result != kIOReturnSuccess {
                    log(String(format: "[sense] %@ faster polling failed (0x%08x)", target.hand.name, result))
                }
            }
        }
        for _ in 0..<2 {
            guard current(target, accepting: true) else { job.plan.complete(); return }
            var bytes = [UInt8](repeating: 0, count: 64)
            bytes[0] = 0x05
            var length = bytes.count
            // No app lock is held over the blocking HID operation.
            let result = bytes.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(target.device, kIOHIDReportTypeFeature, 0x05, $0.baseAddress!, &length)
            }
            guard current(target, accepting: true) else { job.plan.complete(); return }
            guard let pair = job.collector.consume(status: result, length: length, bytes: bytes) else { continue }
            // Generation and stop state cannot change between validation and
            // applying the calibration to the retained core handle.
            lock.lock()
            let active = acceptingOutput && devices[target.hand]?.generation == target.generation
            let calibrated = active && halliday_sense_calibrate(target.core, pair.first, pair.second, 64)
            lock.unlock()
            guard active else { job.plan.complete(); return }
            if calibrated {
                calibratedNow = true
                job.plan.complete()
                log("[sense] \(target.hand.name) IMU calibration read (attempt \(job.plan.attempts))")
                return
            }
            job.collector.rejectPair()
        }
        let next = job.plan.retryDelay
        log("[sense] \(target.hand.name) IMU calibration attempt \(job.plan.attempts): \(job.collector.issue)\(next == nil ? "; keeping defaults" : "; retry scheduled")")
        if let next {
            calibrationQueue.asyncAfter(deadline: .now() + next) { [weak self, target, job] in
                self?.calibrate(target, job: job)
            }
        }
    }

    private func detach(_ device: IOHIDDevice) {
        lock.lock()
        let hand = devices.first { $0.value.device === device }?.key
        // The callback's context points at the Device: unregister before letting it go.
        if let hand, let d = devices[hand] {
            IOHIDDeviceRegisterInputReportCallback(device, d.buffer, Device.bufferSize, nil, nil)
            devices[hand] = nil
            let generation = d.generation
            outputQueue.async { [weak self] in
                guard let self else { return }
                self.hapticScheduler.disconnect(hand: hand.rawValue, generation: generation)
                self.scheduleOutputTimer()
            }
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
                if taken != ledsTaken { ledsTaken = taken; log("[sense] LED phase \(ledPhase): report queued for \(taken) controller(s)") }
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
