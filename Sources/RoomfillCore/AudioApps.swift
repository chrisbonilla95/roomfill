import AppKit
import CoreAudio
import Foundation

public struct AudioProcessRecord: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var pid: pid_t
    public var bundleID: String
    public var isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public struct RunningAppInfo: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var name: String

    public init(pid: pid_t, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

/// A user-facing app and the Core Audio process objects that carry its sound.
public struct AudioApp: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var processObjectIDs: [AudioObjectID]
    public var isPlaying: Bool

    public init(id: String, name: String, processObjectIDs: [AudioObjectID], isPlaying: Bool) {
        self.id = id
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.isPlaying = isPlaying
    }
}

public let ownBundleID = "io.chrisbonilla.roomfill"

/// Groups audio processes under the running app that owns them: by parent process chain first,
/// then by the longest running-app bundle ID that prefixes the process's bundle ID. Processes with
/// no owning app, and this app itself, are left out. Sorted by app name.
public func groupIntoApps(_ records: [AudioProcessRecord], runningApps: [RunningAppInfo],
                          parentOf: (pid_t) -> pid_t?) -> [AudioApp] {
    let byPID = Dictionary(runningApps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    func owner(_ r: AudioProcessRecord) -> RunningAppInfo? {
        var pid: pid_t? = r.pid
        var hops = 0
        while let p = pid, p > 1, hops < 16 {
            if let app = byPID[p] { return app }
            pid = parentOf(p)
            hops += 1
        }
        return runningApps
            .filter { r.bundleID.hasPrefix($0.bundleID) }
            .max { $0.bundleID.count < $1.bundleID.count }
    }
    var apps: [String: AudioApp] = [:]
    for r in records where r.bundleID != ownBundleID {
        guard let app = owner(r), app.bundleID != ownBundleID else { continue }
        var entry = apps[app.bundleID] ?? AudioApp(id: app.bundleID, name: app.name, processObjectIDs: [], isPlaying: false)
        entry.processObjectIDs.append(r.objectID)
        entry.isPlaying = entry.isPlaying || r.isRunningOutput
        apps[app.bundleID] = entry
    }
    return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Parent process ID via sysctl; nil when the process is gone.
public func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Current Core Audio process objects as records.
public func currentAudioProcessRecords() -> [AudioProcessRecord] {
    getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { obj in
        AudioProcessRecord(objectID: obj,
                           pid: getValue(obj, kAudioProcessPropertyPID, initial: pid_t(0)) ?? 0,
                           bundleID: getString(obj, kAudioProcessPropertyBundleID) ?? "",
                           isRunningOutput: (getValue(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0)
    }
}

/// Apps that currently have audio processes, grouped as in `groupIntoApps`.
public func currentAudioApps() -> [AudioApp] {
    let running = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { app -> RunningAppInfo? in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningAppInfo(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id)
        }
    return groupIntoApps(currentAudioProcessRecords(), runningApps: running, parentOf: parentPID)
}
