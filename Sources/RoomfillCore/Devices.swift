import CoreAudio
import Foundation

public struct AudioDevice: Equatable {
    public var id: AudioObjectID
    public var name: String
    public var uid: String
    public var transport: UInt32
    public var hasOutput: Bool

    public var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return fourCC(transport)
        }
    }
}

public func device(_ id: AudioObjectID) -> AudioDevice {
    AudioDevice(id: id,
                name: getString(id, kAudioObjectPropertyName) ?? "?",
                uid: getString(id, kAudioDevicePropertyDeviceUID) ?? "?",
                transport: getValue(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0,
                hasOutput: !getIDs(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty)
}

public func allDevices() -> [AudioDevice] {
    getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map(device)
}

public func defaultOutputDevice() -> AudioObjectID {
    getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
             initial: AudioObjectID(0)) ?? 0
}

/// Total output latency the device reports, in milliseconds.
public func outputLatencyMs(_ dev: AudioObjectID) -> Double {
    let out = kAudioObjectPropertyScopeOutput
    let lat = getValue(dev, kAudioDevicePropertyLatency, out, initial: UInt32(0)) ?? 0
    let safety = getValue(dev, kAudioDevicePropertySafetyOffset, out, initial: UInt32(0)) ?? 0
    let buffer = getValue(dev, kAudioDevicePropertyBufferFrameSize, out, initial: UInt32(0)) ?? 0
    var stream: UInt32 = 0
    if let s = getIDs(dev, kAudioDevicePropertyStreams, out).first {
        stream = getValue(s, kAudioStreamPropertyLatency, initial: UInt32(0)) ?? 0
    }
    let rate = getValue(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
    guard rate > 0 else { return 0 }
    return Double(lat + safety + buffer + stream) / rate * 1000
}

private func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioObjectPropertyScopeOutput, mElement: element)
}

private func hasVolume(_ dev: AudioObjectID, _ element: UInt32) -> Bool {
    var addr = volumeAddress(element)
    return AudioObjectHasProperty(dev, &addr)
}

/// Output volume as a 0...1 scalar: the main element, else the average of channels 1 and 2.
public func deviceVolume(_ dev: AudioObjectID) -> Float? {
    func read(_ element: UInt32) -> Float? {
        guard hasVolume(dev, element) else { return nil }
        var addr = volumeAddress(element)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }
    if let main = read(kAudioObjectPropertyElementMain) { return main }
    let channels = [read(1), read(2)].compactMap { $0 }
    return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
}

/// Sets output volume (0...1) on the main element, else channels 1 and 2. Returns false if unsupported.
@discardableResult
public func setDeviceVolume(_ dev: AudioObjectID, _ value: Float) -> Bool {
    var v = Float32(min(max(value, 0), 1))
    func write(_ element: UInt32) -> Bool {
        guard hasVolume(dev, element) else { return false }
        var addr = volumeAddress(element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }
    if write(kAudioObjectPropertyElementMain) { return true }
    let ok1 = write(1), ok2 = write(2)
    return ok1 || ok2
}

/// Sets a device's nominal sample rate and waits until the device reports it, because the change
/// completes asynchronously. Returns false if the rate was not reached within `timeout` seconds.
@discardableResult
public func setNominalRate(_ dev: AudioObjectID, _ rate: Double, timeout: TimeInterval = 1) -> Bool {
    func current() -> Double { getValue(dev, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0 }
    if current() == rate { return true }
    guard setValue(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(rate)) == noErr else {
        return false
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if current() == rate { return true }
        usleep(10_000)
    }
    return current() == rate
}

/// The device macOS plays alerts and sound effects on.
public func soundEffectsOutputDevice() -> AudioObjectID {
    getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
             initial: AudioObjectID(0)) ?? 0
}

@discardableResult
public func setSoundEffectsOutputDevice(_ id: AudioObjectID) -> Bool {
    setValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
             kAudioObjectPropertyScopeGlobal, id) == noErr
}

/// Whether a device name contains the chosen name; an empty choice matches nothing.
public func deviceNameMatches(_ name: String, wanted: String) -> Bool {
    !wanted.isEmpty && name.localizedCaseInsensitiveContains(wanted)
}
