# AGENTS.md

Guidance for coding agents (and people) working in this repository. User-facing docs are in
[README.md](README.md).

## Commands

| Task | Command |
|---|---|
| Fetch the bundled AirPlay sender (once) | [`scripts/fetch-airplay-cli.sh`](scripts/fetch-airplay-cli.sh) |
| Unit tests | [`scripts/test.sh`](scripts/test.sh) (pass `--filter <name>` to narrow) |
| Build the app | [`scripts/bundle.sh`](scripts/bundle.sh), output `build/Roomfill.app` |
| Hardware checks without the app | `swift run rfprobe` (prints subcommands) |

Plain `swift test` fails with "no such module 'Testing'" when only the Command Line Tools are
installed; [`scripts/test.sh`](scripts/test.sh) adds the framework search paths. Always use it.

`vendor/` (airplay-cli binary and its license files) and `build/` are git-ignored. Never commit
binaries.

## Layout

| Path | What lives there |
|---|---|
| [`Sources/RoomfillCore/Engine.swift`](Sources/RoomfillCore/Engine.swift) | muted process tap, private aggregate device, IO callback fan-out to the Bluetooth speaker and the AirPlay ring |
| [`Sources/RoomfillCore/SoundbarFeed.swift`](Sources/RoomfillCore/SoundbarFeed.swift) | writer thread: ring, resampler, 16-bit PCM to airplay-cli; idle release; takeover watch |
| [`Sources/RoomfillCore/AirPlaySender.swift`](Sources/RoomfillCore/AirPlaySender.swift), [`AirPlayStatus.swift`](Sources/RoomfillCore/AirPlayStatus.swift) | airplay-cli process, command fifo, `[STATUS]` parsing, session state |
| [`Sources/RoomfillCore/SyncTest.swift`](Sources/RoomfillCore/SyncTest.swift), [`SyncMath.swift`](Sources/RoomfillCore/SyncMath.swift) | microphone sync test (GCC-PHAT) |
| [`Sources/RoomfillCore/SoundbarScale.swift`](Sources/RoomfillCore/SoundbarScale.swift) | per-model volume scales |
| [`Sources/Roomfill`](Sources/Roomfill) | SwiftUI menu bar app; `AppModel` owns the engine and feed |
| [`Sources/rfprobe`](Sources/rfprobe/main.swift) | diagnostics: devices, clock rate, discovery, test tones, headless engine, sync test |
| [`Tests/RoomfillCoreTests`](Tests/RoomfillCoreTests) | swift-testing unit tests, one file per area |

## Audio path

```
selected apps --(Core Audio process tap, muted)--> private aggregate device (Bluetooth speaker = clock)
   IO callback --> delay line --> Bluetooth speaker output
               --> delay line --> lock-free ring --> writer thread --> resampler --> s16le
                                                     --> airplay-cli stdin (AirPlay 2, PTP, ALAC) --> AirPlay speaker
```

## Rules

- **Realtime thread.** `Engine.render` runs on the Core Audio IO thread: no allocation, locks, I/O,
  logging or Swift string work there. Hand data off through `SPSCFloatRing`.
- **Test first.** Logic that can run without hardware gets a failing swift-testing test before the
  code. Hardware behaviour gets an `rfprobe` subcommand and a measured result instead.
- **Measure, don't assume.** Audio claims (sync, distortion, lag) are checked with the microphone
  through `rfprobe`, not by listening or reasoning alone.
- **Docstrings state the caller contract.** No history or "used by" notes in comments.
- **Settings stay loadable.** New `AppSettings` fields are decoded with `decodeIfPresent` and a
  default, so older saved settings keep working (there is a test for this).

## Facts learned the hard way

Breaking any of these brings back a bug that was already fixed:

- **16-bit only.** The tested soundbar plays 24-bit ALAC with heavy distortion. `SenderConfig` defaults
  to 16-bit with TPDF dither.
- **PTP timing is required** for Samsung soundbars; senders using NTP connect but play silence.
- **airplay-cli reads stdin faster than real time**, so writes do not pace anything. Drift is steered
  from airplay-cli's queue depth (frames written minus `elapsed_ms`), not from our ring fill.
- **Keep airplay-cli's input continuous.** If the engine stalls (rebuilds), `GapFiller` writes
  silence; otherwise airplay-cli pauses its timeline and the AirPlay speaker ends up later for good.
- **"Playing" only after the clock locks** (`SessionStatus`); before PTP lock the speaker renders late.
- **Sample-rate changes are asynchronous.** Use `setNominalRate` (waits for the device) before
  building the aggregate; the aggregate rebuilds itself if its rate changes later.
- **`TapAutoStart = false`** so IO runs while the selected apps are silent (keeps the feed and idle
  timer going).
- **Retarget the tap, don't rebuild it**, when only the selected apps' processes change; a rebuild
  unmutes them on the Mac for a moment and drops audio.
- **The sync test measures one speaker at a time.** Rhythmic music produces correlation peaks one beat
  away from the real one; measuring both speakers together mistook those for a speaker.
- **Another sender's session** shows as bit `0x800` in the speaker's `/info` `statusFlags`; the
  takeover watch only reconnects after two idle polls.
- **Ad-hoc signing changes the app identity on every build**, so macOS asks for permissions again and
  the first capture blocks behind the prompt. Sign with a stable identity (see the README).
- **Alerts can bypass the app.** macOS has a separate sound-effects output device; if it points at
  one of the speakers, notification sounds play there directly. The app warns about it.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes (`feat:`, `fix:`,
`chore:`, `docs:`) with an imperative summary.
