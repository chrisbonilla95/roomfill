# Third-party notices

Roomfill's own source code is licensed under the GNU General Public License v3.0 (see
[LICENSE](LICENSE)). This repository contains no third-party source code.

## Bundled in the built app

| Component | Version | License | Source |
|---|---|---|---|
| [airplay-cli](https://github.com/music-assistant/airplay-cli) | v0.5.15 (`cliairplay-macos-arm64`, unmodified) | GPL-3.0 | [tag v0.5.15](https://github.com/music-assistant/airplay-cli/tree/v0.5.15) |

airplay-cli is not stored in this repository.
[`scripts/fetch-airplay-cli.sh`](scripts/fetch-airplay-cli.sh) downloads the release binary at build
time and verifies its SHA-256, and [`scripts/bundle.sh`](scripts/bundle.sh) places it in the app
bundle next to its own license and third-party notices (`Contents/Resources/airplay-cli/LICENSE` and
`THIRD_PARTY_NOTICES.md`). Those notices cover the components linked into airplay-cli, including
libraop, the Apple ALAC codec, the ALAC decoder, AES-CTR and mDNS code; see airplay-cli's
[THIRD_PARTY_NOTICES.md](https://github.com/music-assistant/airplay-cli/blob/v0.5.15/THIRD_PARTY_NOTICES.md).

Roomfill runs airplay-cli as a separate process and talks to it over pipes.

## Other material

- **App icon** ([`scripts/make-icon.swift`](scripts/make-icon.swift), [`assets/icon.png`](assets/icon.png)):
  original work, part of this project under GPL-3.0.
- **System symbols** shown in the menu bar and popover are drawn at runtime through Apple's SF Symbols
  APIs; no symbol artwork is included in this repository or the app bundle.
- **Apple frameworks** (Core Audio, AudioToolbox, Accelerate, Network, SwiftUI, AppKit) are system
  components and are not redistributed.

AirPlay is a trademark of Apple Inc. Roomfill is not affiliated with or endorsed by Apple, Samsung or
Bose.
