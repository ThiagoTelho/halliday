import CHallidayCore

/// One physical controller's LED settings latch. The owner calls this only on its output
/// queue when programming LEDs. Other output packets do not consume this sequence: reusing
/// the transport counter can repeat the last LED latch after intervening haptic packets.
struct SenseLEDProgramming {
    private var settingsSequence: UInt8 = 0
    private var programmed: [UInt8]?

    mutating func report(transportSequence: UInt8, transportCounter: UInt8, phase: UInt8,
                         pulse: UInt8, position: UInt32, cycle: UInt32, hostMicroseconds: UInt32) -> [UInt8] {
        settingsSequence &+= 1
        var report = [UInt8](repeating: 0, count: 78)
        halliday_sense_led_report(transportSequence, transportCounter, phase, settingsSequence,
                                 pulse, position, cycle, hostMicroseconds, &report)
        programmed = report
        return report
    }

    /// Every output carries the same connection's current LED settings. Haptic
    /// start, refresh, stop and cancellation do not consume the LED latch.
    func vibrationReport(transportSequence: UInt8, transportCounter: UInt8,
                         amplitude: Float, frequencyHz: Float, hostMicroseconds: UInt32) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: 78)
        let valid: Bool
        if let programmed {
            valid = programmed.withUnsafeBufferPointer {
                halliday_sense_vibration_report_with_led(transportSequence, transportCounter, amplitude,
                    frequencyHz, hostMicroseconds, $0.baseAddress, &report)
            }
        } else {
            valid = halliday_sense_vibration_report_with_led(transportSequence, transportCounter, amplitude,
                frequencyHz, hostMicroseconds, nil, &report)
        }
        return valid ? report : nil
    }
}
