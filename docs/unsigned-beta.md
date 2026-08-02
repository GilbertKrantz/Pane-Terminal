# Pane 0.2 unsigned beta

Pane 0.2 is distributed as an unsigned, non-notarized direct-download beta.
It requires macOS 14 or newer and has no automatic update channel.

## Build a beta archive

Run this from a clean checkout on a Mac with the required Xcode toolchain:

```sh
Scripts/Release/build-unsigned-beta.sh
```

The script runs the standard SwiftPM suite, both native Xcode test targets,
builds a universal Release app, validates bundle metadata, and creates an
artifact directory under `Artifacts/Release/<commit>/` containing:

- `Pane-0.2-unsigned.zip`
- `Pane-0.2-unsigned.zip.sha256`
- `release-manifest.json`
- Xcode result bundles and sanitized test/build logs

The builder refuses to overwrite an existing artifact directory. Its bundle
validator requires the `com.gilbertkrantz.Pane` identifier, version `0.2`, build
`3`, macOS 14.0 minimum, `AppIcons.icns`, and both `arm64` and `x86_64` slices.

## Install and update

1. Download and unzip `Pane-0.2-unsigned.zip`.
2. Move `Pane.app` to Applications if desired.
3. In Finder, Control-click `Pane.app`, choose **Open**, then confirm **Open**.
   macOS may instead offer **Open Anyway** in System Settings > Privacy &
   Security because the beta is unsigned and not notarized.
4. To update, quit Pane, replace `Pane.app` with a newer archive, and repeat
   the Finder confirmation when macOS asks.

Do not treat this beta as App Store, Developer ID, or notarized distribution.
No automatic updater is present.

## Evidence boundaries

The app-backed soak driver exercises Pane's workspace, sessions, PTYs, shell
integration, and metrics through `PaneSoakRunnerTests`. It is automated runtime
evidence, not visual or manual TUI evidence. A beta release record still needs
the 2-hour and 8-hour artifacts, Instruments review, and the manual supported
workflow in [P2 release validation](p2-release-validation.md).

Docker, tmux, fzf, Neovim, OpenCode, Codex, htop, and btop are **unverified**
unless a dated Pane manual run is attached. They must never be reported as beta
compatibility passes solely from fixture output.

## Future signed distribution

When a Developer ID becomes available, add Developer ID signing, notarization,
stapling, Gatekeeper assessment, and a signed DMG or ZIP to this same release
flow. Pane's non-sandboxed terminal architecture remains unchanged.
