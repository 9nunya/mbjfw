# Development and verification

## Requirements

- macOS 15 or newer
- Apple Silicon (the runtime image is ARM64)
- Swift 6 and the Xcode command-line tools
- `sips`, `iconutil`, `codesign`, `pkgbuild`, and `ditto` for packaging

The Android SDK, Java runtime, and Android image are downloaded into the user's Application Support directory at runtime; they are not Swift package dependencies.

## Build and test

```sh
swift test
swift build -c release
./scripts/package-app.sh --no-open
```

`package-app.sh` builds the release executable and frame bridge, embeds the appliance resources and app icon, signs the local app bundle ad hoc by default, and verifies the signature. Omit `--no-open` to launch the app after packaging. Set `MBJFW_APP_SIGNING_IDENTITY` to use a Developer ID Application signing identity.

Create the installer package with:

```sh
./scripts/build-pkg.sh
```

The build output defaults to `dist/MBJFW-1.0.0-macos-arm64.pkg`. Set `MBJFW_PKG_OUTPUT` to write elsewhere. To sign a distributable package, set `MBJFW_APP_SIGNING_IDENTITY` and `MBJFW_INSTALLER_SIGNING_IDENTITY`; see [Distribution](DISTRIBUTION.md) for notarization.

## Source map

| Area | Source |
| --- | --- |
| App entry, windows, menu commands | `Sources/MBJFW/MBJFWApp.swift` |
| Profile, APK, and runtime coordination | `Sources/MBJFW/GameLibrary.swift`, `AccountStore.swift`, `AndroidRuntimeManager.swift` |
| Emulator process and Android lifecycle | `Sources/MBJFW/AndroidEmulatorSession.swift`, `AndroidSDKInstaller.swift`, `ProfileDevice.swift` |
| Profile UI and per-profile settings | `Sources/MBJFW/AccountsView.swift`, `SettingsView.swift` |
| Native window and input | `NativeGameHost/FrameBridge/NativeWindow.mm`, `UHIDTransport.mm` |
| Native shared-memory API | `NativeGameHost/FrameBridge/include/NativeSession.h`, `NativeSession.mm` |
| Guest appliance policy | `Guest/Appliance/`, `Sources/MBJFW/AndroidAppliancePolicy.swift` |

## Verification boundaries

`swift test` currently covers APK manifest parsing, download progress parsing, concurrent process-output isolation, profile data/settings coding, the native shared-memory notice round-trip, and backup recovery/tamper rejection. It does not boot multiple emulators, prove Android settings apply to a live profile, test sleep/wake, or measure gameplay latency. Those require a live Mac/Android guest run.

Before a release, verify on the intended reference Mac:

1. Build and open the `.pkg` on a clean user account; accept Android package terms and wait for the runtime manifest to become ready.
2. Import two supported APK builds, assign distinct builds to at least two profiles, and run the guests concurrently.
3. Confirm each profile retains its own worlds, sign-in, resolution, GPU/software choice, memory, cores, density, audio preference, and logs after restart.
4. Check native-window keyboard/mouse capture, Escape release, modifiers, pointer capture, focus switching, in-game notice hit testing, resize, fullscreen, and close behavior.
5. Run a 30-minute session, then sleep/wake the Mac and reopen both profiles. Confirm all worlds and profile settings persist.
6. Validate package signature, Gatekeeper launch, and notarization ticket for a public distribution build.

The prior live-session evidence and outstanding runtime risks are recorded in the project research notes. Do not treat a passing compile or a successful single-profile launch as completion of this matrix.
