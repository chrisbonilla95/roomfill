# Roomfill

A macOS menu bar app that plays the apps you choose on an AirPlay speaker and a Bluetooth speaker at
the same time, in sync, while everything else on your Mac keeps playing on its normal output.

Example: Spotify on a Wi-Fi soundbar and a portable Bluetooth speaker in the same room, while
notifications, calls and YouTube stay on the MacBook speakers or AirPods.

## What it does

- **Per-app routing.** Tick the apps that should go to the speakers. They are captured with a Core
  Audio process tap and muted on the Mac; every other app is untouched. Routing is per app (a browser
  sends all its tabs).
- **AirPlay speaker** gets lossless ALAC (16-bit / 44.1 kHz) through
  [airplay-cli](https://github.com/music-assistant/airplay-cli), an AirPlay 2 sender with PTP timing.
- **Bluetooth speaker** gets the same audio through macOS (AAC or SBC, whatever the Mac negotiates).
- **Sync.** Each speaker is held back so both play at the same moment. "Run sync test" uses the Mac's
  microphone: it silences one speaker at a time and times the other, then sets the offset. Fine-tune
  with +/- 10 ms.
- **Lower lag than macOS AirPlay.** Play/pause reaches the speakers in about 0.7 s (the Bluetooth
  speaker's own delay) instead of about 2 s.
- **Volume** per speaker, an overall slider that moves both by the same amount, and per-speaker mute.
- **Now playing.** The AirPlay speaker shows the Spotify track (title, artist, album) or the names
  of the playing apps.
- **Polite with other senders.** If an iPhone takes over the AirPlay speaker, the Bluetooth speaker
  keeps playing and Roomfill reconnects once the speaker reports it is free. After 5 minutes of
  silence it releases the AirPlay speaker so it can sleep or serve a TV.

## Requirements

- macOS 26 on Apple Silicon (Core Audio process taps need macOS 14.2 or later; older versions are
  untested).
- Swift 6 Command Line Tools (`xcode-select --install`). Xcode is not needed.
- [GitHub CLI](https://cli.github.com/) (`gh`) to download airplay-cli.
- An AirPlay 2 speaker that accepts PTP-timed streams (tested: Samsung HW-Q800D) and a Bluetooth
  speaker paired with the Mac.

## Build and run

```sh
scripts/fetch-airplay-cli.sh   # downloads airplay-cli v0.5.15 and checks its SHA-256
scripts/test.sh                # unit tests
scripts/bundle.sh              # builds build/Roomfill.app
open build/Roomfill.app
```

On first launch, open the menu bar icon, pick your AirPlay and Bluetooth speakers under Settings,
choose the apps to send, and switch it on.

### Signing

`bundle.sh` signs ad-hoc unless a code-signing identity named `Roomfill Local` exists in your
keychain. With ad-hoc signing macOS asks for the audio-recording permission again after every rebuild.
A self-signed certificate keeps permissions across builds:

```sh
# In Keychain Access: Certificate Assistant > Create a Certificate...
#   Name: Roomfill Local, Identity Type: Self Signed Root, Certificate Type: Code Signing
security find-identity -v -p codesigning   # should list "Roomfill Local"
```

To use an identity with another name, put its name in a `.codesign-identity` file at the repository
root (ignored by git).

### Permissions it asks for

| Permission | Why |
|---|---|
| System Audio Recording | capture the chosen apps |
| Local Network | find the AirPlay speaker and stream to it |
| Microphone | the sync test only |
| Automation (Spotify) | read the current track for the speaker's display |

## Volume scales

The AirPlay protocol carries volume as 0 to 100 (linear in dB from -30 to 0 dB). Many speakers show
a different number in their own app. Roomfill shows the speaker's own number when it knows the
model; otherwise it shows the AirPlay value. Known models live in `VolumeScale.forModel`
(`Sources/RoomfillCore/SoundbarScale.swift`). To add one, note the number the speaker's app shows at
AirPlay volumes 20, 40, 60, 80, 90 and 100 and open a pull request.

## Development

`swift run rfprobe` has subcommands for checking hardware without the app: list devices and audio
apps, find AirPlay receivers, play test tones to a receiver, run the engine headless, and run the
sync test (`swift run rfprobe` prints usage).

Layout:

- `Sources/RoomfillCore`: capture engine, AirPlay sender wrapper, resampling, sync measurement
- `Sources/Roomfill`: the menu bar app (SwiftUI)
- `Sources/rfprobe`: hardware diagnostics
- `Tests/RoomfillCoreTests`: unit tests

## Limitations

- Routing is per app, not per browser tab.
- Video in routed apps plays its sound a few hundred ms after the picture.
- The AirPlay speaker sometimes needs a few seconds after another sender leaves before it accepts a
  new session.
- One AirPlay speaker and one Bluetooth speaker.

## License and credits

Roomfill is licensed under the GNU General Public License v3.0 (see `LICENSE`).

The app bundles [airplay-cli](https://github.com/music-assistant/airplay-cli) v0.5.15 unmodified, run
as a separate process. airplay-cli is licensed under GPL-3.0; its license and third-party notices are
included in the app bundle (`Contents/Resources/airplay-cli/`), and its corresponding source is the
[v0.5.15 tag](https://github.com/music-assistant/airplay-cli/tree/v0.5.15). airplay-cli builds on
[OwnTone](https://github.com/owntone/owntone-server) and [libraop](https://github.com/philippe44/libraop).

AirPlay is a trademark of Apple Inc. This project is not affiliated with or endorsed by Apple,
Samsung or Bose.
