import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import SaberCore

/// Music + sound effect playback.
///
/// Game audio is routed to a chosen output device (by default the Mac's built-in speakers)
/// so the AirPods, which are in the player's hands, keep streaming motion while the
/// music plays with low latency through the speakers.
final class GameAudio {
    let engine = AVAudioEngine()
    private let music = AVAudioPlayerNode()
    private let sfxMixer = AVAudioMixerNode()
    private var sfxPlayers: [AVAudioPlayerNode] = []
    private var sfxBuffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var musicBuffer: AVAudioPCMBuffer?
    private var nextSfx = 0
    private let sfxLock = NSLock()
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    /// Keeps the AirPods' Bluetooth link active (silent stream) so motion data keeps flowing.
    private var keepAlive: AVAudioEngine?

    private(set) var isMusicPlaying = false
    private(set) var currentOutputName: String = "System Default"
    /// Extra user offset in seconds (positive = notes later).
    var userOffset: Double = 0

    var onConfigurationChange: (() -> Void)?

    init() {
        engine.attach(music)
        engine.attach(sfxMixer)
        engine.connect(music, to: engine.mainMixerNode, format: format)
        engine.connect(sfxMixer, to: engine.mainMixerNode, format: format)
        for _ in 0..<12 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: sfxMixer, format: format)
            sfxPlayers.append(p)
        }
        for effect in SoundEffect.allCases {
            sfxBuffers[effect] = makeBuffer(SoundEffectSynth.render(effect, sampleRate: format.sampleRate))
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func makeBuffer(_ a: StereoAudio) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(a.frameCount)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(a.frameCount)
        a.left.withUnsafeBufferPointer { src in ch[0].update(from: src.baseAddress!, count: a.frameCount) }
        a.right.withUnsafeBufferPointer { src in ch[1].update(from: src.baseAddress!, count: a.frameCount) }
        return buf
    }

    func setMusic(_ a: StereoAudio) {
        musicBuffer = makeBuffer(a)
    }

    // MARK: Output routing

    /// `choice`: "auto" (built-in speakers if present), "system" (system default), or a device UID.
    func applyOutput(choice: String) {
        var target: AudioOutputDevice?
        switch choice {
        case "auto": target = AudioDevices.builtInSpeakers()
        case "system": target = nil
        default: target = AudioDevices.device(uid: choice) ?? AudioDevices.builtInSpeakers()
        }
        let wasPlaying = isMusicPlaying
        if wasPlaying { music.pause() }
        engine.stop()
        let deviceID = target?.id ?? AudioDevices.defaultOutputDevice()
        if var dev = deviceID, let unit = engine.outputNode.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { NSLog("SwiftSaber: could not select output device (\(status))") }
        }
        currentOutputName = target?.name ?? "System Default"
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        start()
        if wasPlaying { music.play() }
    }

    func start() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("SwiftSaber: audio engine failed to start: \(error)")
        }
    }

    /// Plays silence to the AirPods so they stay awake and keep reporting motion.
    func setKeepAirPodsAwake(_ on: Bool) {
        if !on {
            keepAlive?.stop()
            keepAlive = nil
            return
        }
        guard keepAlive == nil, let pods = AudioDevices.airPods() else { return }
        let e = AVAudioEngine()
        let silent = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for b in abl {
                if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
            }
            return noErr
        }
        e.attach(silent)
        var dev = pods.id
        if let unit = e.outputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        e.connect(silent, to: e.mainMixerNode, format: format)
        e.connect(e.mainMixerNode, to: e.outputNode, format: nil)
        e.mainMixerNode.outputVolume = 0
        do {
            e.prepare()
            try e.start()
            keepAlive = e
        } catch {
            NSLog("SwiftSaber: keep-alive stream failed: \(error)")
        }
    }

    // MARK: Volumes

    func setVolumes(music m: Double, sfx s: Double) {
        music.volume = Float(m)
        sfxMixer.outputVolume = Float(s)
    }

    // MARK: Music transport

    func playMusicFromStart() {
        guard let buf = musicBuffer else { return }
        start()
        music.stop()
        music.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        music.play()
        isMusicPlaying = true
    }

    func pauseMusic() {
        guard isMusicPlaying else { return }
        music.pause()
        isMusicPlaying = false
    }

    func resumeMusic() {
        start()
        music.play()
        isMusicPlaying = true
    }

    func stopMusic() {
        music.stop()
        isMusicPlaying = false
    }

    /// Short fade then stop (used when failing a level).
    func fadeOutMusic(duration: Double = 0.8) {
        let startVolume = music.volume
        let steps = 16
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) { [weak self] in
                guard let self else { return }
                self.music.volume = startVolume * Float(1 - Double(i) / Double(steps))
                if i == steps {
                    self.stopMusic()
                    self.music.volume = startVolume
                }
            }
        }
    }

    /// Current position of the song in seconds, as heard by the player (nil if unknown).
    func songTime() -> Double? {
        guard let nodeTime = music.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = music.playerTime(forNodeTime: nodeTime) else { return nil }
        var t = Double(playerTime.sampleTime) / playerTime.sampleRate
        if isMusicPlaying && nodeTime.isHostTimeValid {
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let rendered = AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
            t += max(0, min(0.1, now - rendered))
        }
        let latency = engine.outputNode.presentationLatency
        return t - latency - userOffset
    }

    // MARK: Effects

    func play(_ effect: SoundEffect, pan: Float = 0, volume: Float = 1) {
        guard let buf = sfxBuffers[effect], engine.isRunning else { return }
        sfxLock.lock()
        let p = sfxPlayers[nextSfx]
        nextSfx = (nextSfx + 1) % sfxPlayers.count
        sfxLock.unlock()
        p.pan = pan
        p.volume = volume
        p.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }
    }
}
