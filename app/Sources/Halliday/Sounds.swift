// Interface sounds (ROADMAP W12 C.8): short, quiet tones for the pointer landing on a control, a
// press and its release, panels opening and closing, notices and problems. They are made here from
// sine waves (no audio files), played on the Mac's sound output, and follow the "Sounds" setting
// (0 turns them off). In the headset they will come from where the control is (W9).

import AVFoundation

@MainActor
enum Sounds {
    enum Sound: CaseIterable {
        case hover, press, release, open, close, notice, problem, key, chime
    }

    /// 0 (off) … 1, from Settings.
    static var volume: Float = 0.5
    /// Silent runs: `--mute`, and the scripted snapshot modes.
    private static let muted = ["--mute", "--keys-snapshot", "--picker-snapshot", "--snapshot", "--probe"].contains { CommandLine.arguments.contains($0) }

    private static var engine: AVAudioEngine?
    private static var players: [AVAudioPlayerNode] = []
    private static var next = 0
    private static var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private static var failed = false
    private static var lastHover = 0.0
    private static var observer: NSObjectProtocol?

    static func play(_ sound: Sound) {
        guard !muted, !failed, volume > 0.01 else { return }
        if sound == .hover {
            // The pointer sweeping over a row of buttons ticks, it doesn't buzz.
            let now = CACurrentMediaTime()
            guard now - lastHover > 0.07 else { return }
            lastHover = now
        }
        guard start(), let buffer = buffers[sound] else { return }
        let player = players[next]
        next = (next + 1) % players.count
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private static func start() -> Bool {
        if let engine, engine.isRunning { return true }
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else { return false }
        players = (0..<4).map { _ in AVAudioPlayerNode() }
        for p in players {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
        }
        do {
            try engine.start()
        } catch {
            log("[sound] no interface sounds: \(error.localizedDescription)")
            failed = true
            return false
        }
        self.engine = engine
        if buffers.isEmpty { for s in Sound.allCases { buffers[s] = make(s, format: format) } }
        // The output device changed (headphones, a display): the engine stops; start again on the next sound.
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { Sounds.engine = nil }
        }
        return true
    }

    /// One tone of a sound: from `from` Hz gliding to `to`, starting at `at` seconds, fading out
    /// with time constant `decay`.
    private struct Tone {
        var from: Double, to: Double, at: Double, length: Double, decay: Double, gain: Double
    }

    private static func tones(_ sound: Sound) -> [Tone] {
        switch sound {
        case .hover: [Tone(from: 1800, to: 1800, at: 0, length: 0.020, decay: 0.006, gain: 0.05)]
        case .press: [Tone(from: 540, to: 400, at: 0, length: 0.045, decay: 0.014, gain: 0.22)]
        case .release: [Tone(from: 760, to: 960, at: 0, length: 0.055, decay: 0.018, gain: 0.16)]
        case .key: [Tone(from: 1150, to: 900, at: 0, length: 0.028, decay: 0.008, gain: 0.14)]
        case .open: [Tone(from: 440, to: 440, at: 0, length: 0.16, decay: 0.05, gain: 0.10), Tone(from: 660, to: 660, at: 0.06, length: 0.20, decay: 0.06, gain: 0.10)]
        case .close: [Tone(from: 660, to: 660, at: 0, length: 0.14, decay: 0.045, gain: 0.09), Tone(from: 440, to: 440, at: 0.05, length: 0.18, decay: 0.055, gain: 0.09)]
        case .notice: [Tone(from: 880, to: 880, at: 0, length: 0.22, decay: 0.07, gain: 0.12), Tone(from: 1320, to: 1320, at: 0.09, length: 0.30, decay: 0.09, gain: 0.10)]
        case .chime: [Tone(from: 784, to: 784, at: 0, length: 0.6, decay: 0.25, gain: 0.16), Tone(from: 988, to: 988, at: 0.18, length: 0.6, decay: 0.25, gain: 0.14),
                      Tone(from: 1175, to: 1175, at: 0.36, length: 0.9, decay: 0.35, gain: 0.13)]
        case .problem: [Tone(from: 520, to: 520, at: 0, length: 0.20, decay: 0.07, gain: 0.13), Tone(from: 390, to: 390, at: 0.11, length: 0.28, decay: 0.09, gain: 0.13)]
        }
    }

    private static func make(_ sound: Sound, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let tones = tones(sound), rate = format.sampleRate
        let length = tones.map { $0.at + $0.length }.max() ?? 0.05
        let frames = AVAudioFrameCount(length * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var v = 0.0
            for tone in tones where t >= tone.at && t < tone.at + tone.length {
                let x = t - tone.at, k = x / tone.length
                // Phase of a tone gliding linearly from `from` to `to`.
                let phase = 2 * Double.pi * (tone.from * x + (tone.to - tone.from) * x * k / 2)
                let attack = min(1, x / 0.003), tail = min(1, (tone.length - x) / 0.004)
                v += sin(phase) * exp(-x / tone.decay) * attack * tail * tone.gain
            }
            for c in 0..<Int(format.channelCount) { channels[c][i] = Float(v) }
        }
        return buffer
    }
}
