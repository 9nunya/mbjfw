# Distribution, signing, and notarization

## Local package

On an Apple Silicon or Intel Mac with Xcode command-line tools:

```sh
./scripts/build-pkg.sh
```

This builds the native app for the current Mac, stages it under `/Applications/MBJFW.app`, and creates a host-specific package: `dist/MBJFW-1.0.0-macos-arm64.pkg` on Apple Silicon or `dist/MBJFW-1.0.0-macos-x86_64.pkg` on Intel. A matching SHA-256 file is created beside it. The package installs only the MBJFW app bundle. Android SDK downloads, profiles, APKs, saves, and logs live in the user's home directory and are not replaced or removed by an app update.

The default build is an unsigned, local-testing installer. It is not suitable for posting as a trusted public download. Users may see a Gatekeeper warning when installing an unsigned build.

## In-app update check

At launch, MBJFW checks GitHub's latest **published** release. If a newer release has a package and SHA-256 sidecar for the current Mac architecture, MBJFW asks before downloading. After the checksum matches, it opens the installer in macOS Installer; the user confirms installation there. Draft releases are not offered. The app currently checks again on each launch and has no background installation path.

## Developer ID release

Use identities present in the local keychain:

```sh
security find-identity -v -p codesigning
```

Then sign the application and installer package:

```sh
export MBJFW_APP_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export MBJFW_INSTALLER_SIGNING_IDENTITY='Developer ID Installer: Example (TEAMID)'
./scripts/build-pkg.sh
```

The app uses hardened runtime with narrowly specified entitlements in `scripts/MBJFW.entitlements` because its native graphics bridge is loaded into the emulator process. Keep that injection path under review when changing the signing model. The installer identity must be a **Developer ID Installer** certificate; the app identity must be a **Developer ID Application** certificate.

## Notarization

Store notarization credentials in the keychain with `xcrun notarytool store-credentials`. Then set:

```sh
export MBJFW_NOTARIZE=1
export MBJFW_NOTARY_PROFILE='your-keychain-profile-name'
export MBJFW_APP_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export MBJFW_INSTALLER_SIGNING_IDENTITY='Developer ID Installer: Example (TEAMID)'
./scripts/build-pkg.sh
```

The script submits the signed package, waits for Apple's result, and staples the ticket on success. Check the notary log if Apple rejects a build. Validate installation on a clean macOS account and a second Mac before publishing.

## Release checklist

- Run `swift test` and the live matrix in [Development](DEVELOPMENT.md).
- Confirm bundle identifier, version, minimum macOS version, icon, embedded resources, framework rpaths, and the expected host architecture (`arm64` or `x86_64`).
- Confirm the Intel runtime downloads the Google APIs x86_64 image and exposes ARM64 app translation before launching the ARM64 Minecraft APK.
- Verify the app and installer signatures, then confirm the package's notarization ticket is stapled.
- Install over an existing version and confirm Application Support data remains intact.
- Confirm first-run Android SDK license presentation and required download size/space messaging.
- Publish the package hash, version notes, supported macOS version, and known compatibility limits.
- Do not include a Minecraft APK, Android system image, Google account data, or profile virtual disks in the package.
