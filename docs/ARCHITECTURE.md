# Architecture

MBJFW keeps the Android SDK and system image shared, but gives every profile a separate emulator process, AVD registry, writable device disks, Minecraft package assignment, settings record, log directory, and native display session.

## Host app

The SwiftUI executable owns the APK catalog, account/profile catalog, launcher and settings surfaces, install consent, and process lifecycle. `GameLibrary` is the profile coordinator. It creates one `AndroidRuntimeManager` per profile ID; each manager owns one `AndroidEmulatorSession` and one native shared-memory session name. The managers share immutable SDK tools and image files under `~/Library/Application Support/MBJFW/android-runtime/`.

`AccountStore` persists the profile list as a JSON blob through `CatalogStore`. New fields are decoded with defaults so old profile records continue to load. The previous global APK selection migrates to the initially selected profile; legacy profile records seed their settings from the old global renderer/resource preferences. New profiles start with the standard defaults. Every profile then stores its own selected APK and `ProfileSettings`.

## Runtime start

1. The runtime manager resolves the profile's selected content-addressed APK and private Android data directory.
2. First-run SDK setup is serialized and shared. Each caller waits on the same in-progress install task; only the initial setup requires license consent.
3. `ProfileDevice` writes the profile's `config.ini` and AVD registry so QEMU sees profile-specific storage and hardware limits.
4. A process-local port lease assigns a distinct ADB emulator serial to each concurrently launched profile.
5. The emulator starts with the selected host/software renderer and resource limits, a unique `MBJFW_NATIVE_SESSION` shared-memory name, and the profile's AVD home.
6. The app provisions the minimal appliance policy, connects the native HID path, verifies the guest boot, installs or verifies the assigned Minecraft APK, and launches its resolved activity.
7. `NativeGameHost` attaches inside that QEMU process, binds the guest renderer to its AppKit window, and forwards host keyboard/mouse input through the UHID bridge. Gameplay frames do not travel through the SwiftUI process.

Stopping a profile terminates only its emulator and native display. Other profiles remain alive. The emulator writes world and sign-in data to that profile's private virtual disks.

## In-game notices

Runtime events use the same versioned POSIX shared-memory object that carries display and input state. A bounded, sequence-protected UTF-8 notice record is polled by the native host and shown in a material panel inside the display window. The panel returns `nil` from hit testing, so it never blocks game input. Notice categories use standard system symbols and colors. The notification path is independent of screenshots, ADB polling, or a local network service.

## Data ownership

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/MBJFW/apks/<sha256>.apk` | Imported APK objects shared by profiles |
| `~/Library/Application Support/MBJFW/accounts/<uuid>/` | Profile catalog data and backups |
| `.../accounts/<uuid>/android-avd/` | Profile's Android AVD registry and writable guest disks |
| `.../accounts/<uuid>/logs/` | Emulator and runtime logs for that profile |
| `~/Library/Application Support/MBJFW/android-runtime/` | Shared SDK, emulator, system image, downloads, and setup logs |

Profile archives are not deleted when a profile is archived. Removing an APK is rejected while any running or starting profile uses it.

## Known scope boundaries

- Profiles are isolated Android devices, not separate macOS users. Microsoft account login remains Minecraft's responsibility.
- Concurrent Android guests consume their configured RAM independently. MBJFW does not promise that an arbitrary number of instances fit on the host.
- The native bridge C ABI is internal and versioned; it is not a supported third-party extension API.
- The packaged app downloads the emulator and system image at first run. Those large vendor artifacts are not embedded in the installer.
- A successful source build does not prove gameplay, sleep/wake, or long-session performance. See [Development and verification](DEVELOPMENT.md).
