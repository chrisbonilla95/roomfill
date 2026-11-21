import Foundation

/// What the soundbar's display and app show for the current audio.
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationSec: Int?
    public var positionSec: Int?
    public var itemID: String?
    public var artworkFile: String?

    public init(title: String, artist: String, album: String = "", durationSec: Int? = nil, positionSec: Int? = nil,
                itemID: String? = nil, artworkFile: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSec = durationSec
        self.positionSec = positionSec
        self.itemID = itemID
        self.artworkFile = artworkFile
    }
}

extension NowPlaying {
    /// Same track and display details; the playback position is ignored.
    public func sameTrack(as other: NowPlaying) -> Bool {
        var a = self, b = other
        a.positionSec = nil
        b.positionSec = nil
        return a == b
    }
}

/// airplay-cli command-pipe lines that push `info` to the receiver. Values are kept on one line.
public func metadataCommands(_ info: NowPlaying) -> [String] {
    func clean(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
    var lines = ["TITLE=\(clean(info.title))", "ARTIST=\(clean(info.artist))", "ALBUM=\(clean(info.album))"]
    if let d = info.durationSec { lines.append("DURATION=\(d)") }
    if let p = info.positionSec { lines.append("PROGRESS=\(p)") }
    lines.append("ITEMID=\(clean(info.itemID ?? info.title))")
    lines.append("ARTWORKFILE=\(clean(info.artworkFile ?? ""))")
    lines.append("ACTION=SENDMETA")
    return lines
}

/// Display text when the playing apps cannot describe their track: their names.
public func fallbackNowPlaying(playingAppNames: [String]) -> NowPlaying? {
    guard !playingAppNames.isEmpty else { return nil }
    return NowPlaying(title: playingAppNames.joined(separator: " + "), artist: "Roomfill")
}
