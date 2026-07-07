<div align="center">
    <h1>📦 Stockpile</h1>
    <p><b>Your disk, explained — not just displayed.</b></p>
</div>

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)
![License](https://img.shields.io/github/license/kennykankush/stockpile?style=flat-square)
![Status](https://img.shields.io/badge/status-pre--release-orange?style=flat-square)

Stockpile is a storage transparency app for macOS. Every gig gets a name in
plain words, a reason it exists, and a verdict on whether it's safe to let go.
No treemaps. No scare tactics. No "247 issues found!". It informs — you decide.

It shows **both truths about your disk**: physical bytes on disk, and effective
space after purgeable — because a meter that silently switches between the two
is exactly how this app got born.

## Install

**Homebrew** (the repo is its own tap):

```sh
brew tap kennykankush/stockpile https://github.com/kennykankush/stockpile
brew trust kennykankush/stockpile   # newer Homebrew requires this for third-party taps
brew install --cask stockpile
```

**Installer script:**

```sh
curl -fsSL https://raw.githubusercontent.com/kennykankush/stockpile/main/scripts/install.sh | sh
```

**Manual:** grab `Stockpile-x.y.z.zip` from the
[latest release](https://github.com/kennykankush/stockpile/releases/latest),
unzip, drop into Applications. Signed with Developer ID and notarized by
Apple — it opens with no warnings.

> [!NOTE]
> No treemaps. No scare tactics. It informs — you decide.

## Features

### Overview — the honest numbers
- [x] Physical **and** effective usage, side by side, always
- [x] Purgeable space measured and explained, not hidden
- [x] Disk snapshot recorded each launch (your storage gets a history)

### Descend — the inward granulizer
- [x] Click a folder and it becomes the canvas — descend, don't squint
- [x] Every recognized directory annotated in plain words with a safety tier:
      🟢 cache (regenerates itself) · 🟡 regenerable (costs a rebuild) · 🔴 your data (never suggested)
- [x] Session-cached sizing — revisits are instant, refresh on demand
- [ ] Persistent scan cache across launches
- [ ] Clear-to-Trash actions, recorded in the Ledger

### Apps — the totality, by source
- [x] Every app censused and classified: **App Store · Brew Cask · Brew CLI · Direct**
- [x] Sizes stream in live; last-used dates surface the forgotten
- [x] Homebrew read straight from disk (Caskroom/Cellar) — no subprocess, instant
- [ ] One-click uninstall via the *correct* path per source, with leftover sweep

### Startup — what actually runs at login
- [x] Login items, LaunchAgents, LaunchDaemons — each showing *what it runs*, in plain words
- [x] Live PIDs, keep-alive flags, disabled-state detection
- [x] Reversible controls for user-domain items (bootout + `.DISABLED` rename — never delete)
- [ ] Privileged helper for root-owned items

### Ledger — storage with a memory
- [x] Append-only record of every snapshot and every action
- [ ] Diffs between scans ("Spotify's cache regrew 2.1 GB this week")

### Widget
- [ ] The anti-gaslight disk widget: honest numbers + reclaimable estimate

## The safety model

The rules registry is **allowlist-only**: Stockpile can only suggest clearing
paths a versioned rule explicitly recognizes — with guards like *`node_modules`
only counts beside a `package.json`*. Anything unrecognized is your data and is
untouchable, no matter how large. Nothing is ever `rm`'d: Trash only, every
action recorded, everything reversible.

## Requirements

macOS 26 (Tahoe) or later. Native SwiftUI — no Electron, no runtime, no
background daemons. An anti-bloat app must not be bloat.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/kennykankush/stockpile && cd stockpile
xcodegen generate && open Stockpile.xcodeproj
```

Core logic lives in `Core/` as a headless, tested Swift package
(`swift test` from `Core/`): `RulesKit` (the allowlist), `ScannerKit`
(dual accounting + honest sizing), `InventoryKit` (app census, startup
catalog), `LedgerKit` (the memory).

## FAQ

**Why does Finder say I have way more free space than `df` does?**
Purgeable space. macOS promises it can auto-delete certain caches when space
runs low, and Finder counts that promise as free space. Stockpile shows both
numbers so you're never lied to. This exact confusion is the app's origin
story.

**Is it safe?**
Sizing never follows symlinks and never reads file contents (iCloud dataless
files stay in the cloud). Deleting — when it ships — is Trash-only and
ledger-recorded. The tier system is enforced in code and covered by tests.

**Are the sizes exact?**
Allocated bytes on disk — honest for sparse files, and measured once then
cached until the mtime changes or you refresh (each view shows *when* it was
measured). One blind spot we share with every scanner including Finder: APFS
clone files share storage under the hood but each reports its full size, so
sums can slightly exceed true usage. macOS exposes no API to see clone
sharing — anyone claiming clone-exact numbers is guessing.

**Why no treemap?**
Treemaps show you bytes. Stockpile shows you *meaning*. If you want rectangles,
GrandPerspective is excellent.

## License

[MIT](LICENSE) — © 2026 Hadi Mulia
