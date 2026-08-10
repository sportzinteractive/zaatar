// zaatarcap - native audio capture for Zaatar
// Records default input mic + SYSTEM AUDIO (Core Audio process tap, macOS 14.2+)
// mixed -> 16kHz mono s16 WAV until SIGINT/SIGTERM.
// System audio means remote meeting participants come from the digital stream,
// immune to mic input-volume resets (Meet/Chrome AGC) that caused Whisper
// hallucination loops on quiet remote speech.
// Falls back to mic-only if the tap cannot be created (permission denied etc).
// Writes running peak level (dBFS) to <output>.level every 5s for rec's
// silence watchdog.
// Built as ~/Applications/ZaatarCap.app so the bundle holds its own mic +
// audio-capture TCC grants (launchd-spawned recording works).

import AVFoundation
import CoreAudio
import Foundation

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func warn(_ msg: String) {
    FileHandle.standardError.write(("WARN: " + msg + "\n").data(using: .utf8)!)
}

guard CommandLine.arguments.count == 2 else {
    die("usage: zaatarcap <output.wav>", 2)
}
let outPath = CommandLine.arguments[1]
let outURL = URL(fileURLWithPath: outPath)
let levelURL = URL(fileURLWithPath: outPath + ".level")

// Mic permission: blocks for the user prompt on first run.
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
    sem.wait()
    if !granted { die("ERROR: microphone access denied by user", 3) }
default:
    die("ERROR: microphone access denied (System Settings > Privacy > Microphone > ZaatarCap)", 3)
}

// ---------------------------------------------------------------------------
// Core Audio helpers
// ---------------------------------------------------------------------------

func defaultInputDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return (st == noErr && dev != kAudioObjectUnknown) ? dev : nil
}

func deviceUID(_ dev: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ptr)
    }
    return st == noErr ? uid as String? : nil
}

func inputChannelCount(_ dev: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// ---------------------------------------------------------------------------
// System-audio tap + aggregate device (mic + tap, drift-corrected)
// ---------------------------------------------------------------------------

var tapID = AudioObjectID(kAudioObjectUnknown)
var aggID = AudioDeviceID(kAudioObjectUnknown)
var micChannels = 0  // first N channels of the capture format belong to the mic

func setupSystemAudioCapture() -> AudioDeviceID? {
    guard let micDev = defaultInputDeviceID(), let micUID = deviceUID(micDev) else {
        warn("no default input device UID; falling back to mic-only")
        return nil
    }
    let micCh = inputChannelCount(micDev)
    guard micCh > 0 else {
        warn("mic reports 0 input channels; falling back to mic-only")
        return nil
    }

    // Global tap: all system audio, no exclusions. Triggers the one-time
    // "System Audio Recording" permission prompt (NSAudioCaptureUsageDescription).
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    tapDesc.name = "Zaatar System Tap"
    tapDesc.isPrivate = true
    tapDesc.muteBehavior = .unmuted

    var newTap = AudioObjectID(kAudioObjectUnknown)
    var st = AudioHardwareCreateProcessTap(tapDesc, &newTap)
    guard st == noErr, newTap != kAudioObjectUnknown else {
        warn("system-audio tap creation failed (status \(st)); falling back to mic-only. Check System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only.")
        return nil
    }
    tapID = newTap

    let aggUID = UUID().uuidString
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "Zaatar Capture",
        kAudioAggregateDeviceUIDKey as String: aggUID,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceIsStackedKey as String: false,
        kAudioAggregateDeviceMainSubDeviceKey as String: micUID,
        kAudioAggregateDeviceSubDeviceListKey as String: [
            [
                kAudioSubDeviceUIDKey as String: micUID,
                kAudioSubDeviceDriftCompensationKey as String: 1,
            ]
        ],
        kAudioAggregateDeviceTapListKey as String: [
            [
                kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: 1,
            ]
        ],
    ]
    var newAgg = AudioDeviceID(kAudioObjectUnknown)
    st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAgg)
    guard st == noErr, newAgg != kAudioObjectUnknown else {
        warn("aggregate device creation failed (status \(st)); falling back to mic-only")
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        return nil
    }
    aggID = newAgg
    micChannels = micCh
    return newAgg
}

func teardownSystemAudioCapture() {
    if aggID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(aggID)
        aggID = AudioDeviceID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

let captureDevice = setupSystemAudioCapture()
let systemAudioActive = captureDevice != nil

// ---------------------------------------------------------------------------
// Engine setup
// ---------------------------------------------------------------------------

let engine = AVAudioEngine()
let input = engine.inputNode

// Point the engine's input at the aggregate device (mic + tap).
if let agg = captureDevice {
    var dev = agg
    guard let au = input.audioUnit,
          AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &dev,
                               UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    else {
        die("ERROR: cannot bind engine input to aggregate device", 4)
    }
}

let inFormat = input.outputFormat(forBus: 0)
guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
    die("ERROR: no usable input device", 4)
}
if !systemAudioActive { micChannels = Int(inFormat.channelCount) }

guard let outFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
) else { die("ERROR: cannot build output format", 4) }

// Intermediate mono float format at the native rate (we downmix manually so
// mic and tap channels are SUMMED, not averaged away).
guard let monoFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false
) else { die("ERROR: cannot build mixdown format", 4) }

guard let converter = AVAudioConverter(from: monoFormat, to: outFormat) else {
    die("ERROR: cannot convert \(inFormat.sampleRate)Hz to 16kHz mono", 4)
}

let file: AVAudioFile
do {
    file = try AVAudioFile(
        forWriting: outURL,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ],
        commonFormat: .pcmFormatInt16,
        interleaved: true
    )
} catch {
    die("ERROR: cannot open \(outPath) for writing: \(error.localizedDescription)", 4)
}

// Peak tracking for the silence watchdog
let peakLock = NSLock()
var peakAbs: Int16 = 0

input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
    let frames = Int(buffer.frameLength)
    guard frames > 0, let chans = buffer.floatChannelData else { return }
    let nCh = Int(buffer.format.channelCount)
    let micCh = min(micChannels, nCh)
    let tapCh = nCh - micCh

    // Downmix: average mic channels + average tap channels, then sum.
    guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
          let monoData = mono.floatChannelData?[0] else { return }
    mono.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        var mic: Float = 0
        for c in 0..<micCh { mic += chans[c][i] }
        if micCh > 0 { mic /= Float(micCh) }
        var tap: Float = 0
        if tapCh > 0 {
            for c in micCh..<nCh { tap += chans[c][i] }
            tap /= Float(tapCh)
        }
        monoData[i] = max(-1.0, min(1.0, mic + tap))
    }

    let ratio = outFormat.sampleRate / monoFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
    var fed = false
    var convErr: NSError?
    converter.convert(to: outBuf, error: &convErr) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return mono
    }
    guard outBuf.frameLength > 0, let samples = outBuf.int16ChannelData?[0] else { return }
    var localPeak: Int16 = 0
    for i in 0..<Int(outBuf.frameLength) {
        let v = samples[i] == Int16.min ? Int16.max : abs(samples[i])
        if v > localPeak { localPeak = v }
    }
    peakLock.lock()
    if localPeak > peakAbs { peakAbs = localPeak }
    peakLock.unlock()
    do { try file.write(from: outBuf) } catch {
        FileHandle.standardError.write("WARN: write failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}

func shutdown() {
    engine.stop()
    input.removeTap(onBus: 0)
    file.close() // finalizes WAV header
    teardownSystemAudioCapture()
    try? FileManager.default.removeItem(at: levelURL)
    exit(0)
}

// Signal handling via dispatch sources (safe, runs on main queue)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler { shutdown() }
sigterm.setEventHandler { shutdown() }
sigint.resume()
sigterm.resume()

// Level file writer (every 5s): running peak in dBFS
let levelTimer = DispatchSource.makeTimerSource(queue: .main)
levelTimer.schedule(deadline: .now() + 5, repeating: 5)
levelTimer.setEventHandler {
    peakLock.lock()
    let p = peakAbs
    peakLock.unlock()
    let db = p == 0 ? -91.0 : 20.0 * log10(Double(p) / 32767.0)
    try? String(format: "%.1f\n", db).write(to: levelURL, atomically: true, encoding: .utf8)
}
levelTimer.resume()

do {
    try engine.start()
} catch {
    teardownSystemAudioCapture()
    die("ERROR: audio engine failed to start: \(error.localizedDescription)", 4)
}

let mode = systemAudioActive ? "mic+system" : "mic-only"
FileHandle.standardError.write("zaatarcap: recording [\(mode)] \(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch -> 16kHz mono \(outPath)\n".data(using: .utf8)!)
dispatchMain()
