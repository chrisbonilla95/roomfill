import CoreAudio
import Foundation

public struct SyncTestResult: Sendable {
    /// Lags in the order [soundbar, Bose] when both were heard.
    public var measurement: SyncMeasurement?
    public var offsetMs: Double?
    public var message: String
}

/// The built-in microphone, else the default input device.
public func syncTestMicrophone() -> AudioDevice? {
    let inputs = allDevices().filter { channelCount($0.id, kAudioObjectPropertyScopeInput) > 0 }
    if let builtIn = inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) { return builtIn }
    let def = getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                       initial: AudioObjectID(0)) ?? 0
    return inputs.first { $0.id == def }
}

@MainActor
private func capture(_ engine: Engine, seconds: Double) async -> (reference: [Float], mic: [Float]) {
    let capacity = Int((seconds + 0.5) * engine.sampleRate)
    let ref = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    engine.captureReference = ref
    engine.captureMic = micBuf
    engine.captureCapacity = capacity
    engine.captureCount = 0
    engine.captureActive = true
    try? await Task.sleep(for: .seconds(seconds))
    engine.captureActive = false
    try? await Task.sleep(for: .milliseconds(100))
    let count = engine.captureCount
    let result = (Array(UnsafeBufferPointer(start: ref, count: count)), Array(UnsafeBufferPointer(start: micBuf, count: count)))
    engine.captureReference = nil
    engine.captureMic = nil
    ref.deallocate()
    micBuf.deallocate()
    return result
}

/// Measures each speaker on its own: the Bose is silenced while the microphone times the soundbar,
/// then the soundbar is silenced while it times the Bose. With `apply`, the engine uses the offset that
/// lines them up; otherwise the previous offset is restored. Takes about 13 s; each speaker drops out
/// for about 6 s in turn.
@MainActor
public func runSyncTest(engine: Engine, apply: Bool, settleSeconds: Double = 1.5, captureSeconds: Double = 5,
                        manageMicrophone: Bool = true) async -> SyncTestResult {
    guard let mic = syncTestMicrophone() else {
        return SyncTestResult(measurement: nil, offsetMs: nil, message: "No microphone found")
    }
    let previous = engine.config.offset
    if manageMicrophone {
        do { try engine.setMicrophone(mic) } catch {
            return SyncTestResult(measurement: nil, offsetMs: nil, message: "Could not add the microphone: \(error)")
        }
    }
    engine.setOffset(SyncOffset(ms: 0))

    engine.muteBose = true
    try? await Task.sleep(for: .seconds(settleSeconds))
    let soundbarCapture = await capture(engine, seconds: captureSeconds)
    engine.muteBose = false
    engine.muteSoundbar = true
    try? await Task.sleep(for: .seconds(settleSeconds))
    let boseCapture = await capture(engine, seconds: captureSeconds)
    engine.muteSoundbar = false

    engine.setOffset(previous)
    if manageMicrophone { try? engine.setMicrophone(nil) }

    let rate = engine.sampleRate
    let sb = measureLags(reference: soundbarCapture.reference, mic: soundbarCapture.mic, sampleRate: rate)
    let bo = measureLags(reference: boseCapture.reference, mic: boseCapture.mic, sampleRate: rate)
    switch (sb, bo) {
    case (.failure(.referenceSilent), _), (_, .failure(.referenceSilent)):
        return SyncTestResult(measurement: nil, offsetMs: nil, message: "Nothing playing; start music in a selected app")
    case (.failure(.micSilent), _), (_, .failure(.micSilent)):
        return SyncTestResult(measurement: nil, offsetMs: nil, message: "Microphone heard nothing (permission?)")
    case (.failure(let e), _), (_, .failure(let e)):
        return SyncTestResult(measurement: nil, offsetMs: nil, message: "Sync test failed: \(e)")
    case (.success(let sm), .success(let bm)):
        guard let soundbarLag = strongestLagMs(sm) else {
            return SyncTestResult(measurement: nil, offsetMs: nil,
                                  message: "Couldn't hear the soundbar clearly; turn it up or move the Mac closer")
        }
        guard let boseLag = strongestLagMs(bm) else {
            return SyncTestResult(measurement: nil, offsetMs: nil,
                                  message: "Couldn't hear the Bose clearly; turn it up or move the Mac closer")
        }
        let offset = offsetMs(soundbarLagMs: soundbarLag, boseLagMs: boseLag)
        let measurement = SyncMeasurement(lagsMs: [soundbarLag, boseLag],
                                          confidence: [sm.confidence.max() ?? 0, bm.confidence.max() ?? 0],
                                          noiseConfidence: max(sm.noiseConfidence, bm.noiseConfidence))
        if apply { engine.setOffset(SyncOffset(ms: offset)) }
        let who = offset >= 0 ? "Bose held back" : "Soundbar held back"
        return SyncTestResult(measurement: measurement, offsetMs: offset,
                              message: String(format: "Synced: %@ by %.0f ms", who, abs(offset)))
    }
}
