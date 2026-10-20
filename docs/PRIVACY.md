# Runtime downloads, local data, and privacy

## Runtime downloads

The first-run installer downloads a host-matched Temurin Java 21 runtime from Adoptium, Android command-line tools and emulator/platform tools from Google, and an Android 15 Google APIs system image from the Android SDK repository. Apple Silicon uses the ARM64 image; Intel uses x86_64 and checks for Android's ARM64 app translation library because the Minecraft APK is ARM64. Download URLs, verification logic, and package names are defined in `Sources/MBJFW/RuntimeArchitecture.swift` and `Sources/MBJFW/AndroidSDKInstaller.swift`. MBJFW presents Android SDK license acceptance before package installation. It does not bundle the Android system image or the Minecraft game.

## Game APKs

Users import their own Bedrock APK files. MBJFW inspects the Android manifest, hashes and stores each APK locally, and installs the selected build into a profile using local ADB. MBJFW does not download Minecraft, access the Play Store, or make a claim about the user's license rights. Users are responsible for obtaining game files they are entitled to use.

## Local profile and application data

App support data is stored under `~/Library/Application Support/MBJFW/`:

- Imported APKs are content-addressed under `apks/`.
- Each profile UUID has a separate account folder with its Android virtual-device disks, Minecraft data, backups, selected build, and profile settings.
- Emulator and launch logs for a profile live under that profile's `logs/` directory.
- Shared Android tooling, the Java runtime, SDK downloads, and the system image live under `android-runtime/` on Apple Silicon and `android-runtime-x86_64/` on Intel.

MBJFW does not upload profile data, game worlds, APKs, or sign-in credentials. Minecraft's Microsoft/Xbox authentication is entered in the game itself and is not read by MBJFW. The app does not include analytics or an MBJFW account service.

## Network and local processes

Network use includes documented Java/Android runtime downloads, a GitHub check for the latest published MBJFW release on launch, and—only after the user accepts—downloading the matching macOS installer and its SHA-256 file. Minecraft and the Android image may initiate their own connections. MBJFW starts local Android Emulator and ADB processes. The native game display uses a POSIX shared-memory channel between the launcher and emulator process; it does not stream frames through a web server or take screenshots for presentation.

## Backups

Profile backups contain Android profile data and Minecraft worlds. Store and share them with the same care as the original profile. Restoring a backup stops the target profile and preserves a recoverable copy of the previous data when possible.
