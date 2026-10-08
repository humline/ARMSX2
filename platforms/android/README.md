# ARMSX2 
PlayStation 2 Emulator for Android based on the work of [PCSX2](https://github.com/PCSX2/pcsx2)

## App version

The Android app version and SDK toolchain defaults are configured in
`android-build.properties`:

```properties
versionCode=1088
versionName=2.6.1
```

Change `versionName` to the user-facing release version and increment the integer
`versionCode` for every published APK or AAB. Release scripts can still override
these defaults with `-Parmsx2.versionName=...` and `-Parmsx2.versionCode=...`.

## Android APK builds

Release/test APKs should be built with the universal page-size builder:

```bash
./tools/build-universal-page-apk.sh ~/Downloads/ARMSX2-Refresh-UniversalPage.apk
```

The script compiles both 4K and 16K ARM64 emucore variants, packages them into
one APK, signs it, and verifies 16K zip alignment. This keeps one distributable
APK working correctly on both older 4K-page devices and newer 16K-page devices.

To build per-page-size APKs for both the open-source and Play flavors in a
Linux/amd64 nerdctl/BuildKit environment, run:

```bash
ANDROID_HOME="$HOME/Android/Sdk" tools/build-apks-nerdctl.sh
```

The script builds a temporary Java/native build image with `nerdctl build`,
then creates GitHub and Play release-variant APKs for 4K and 16K page sizes
under `build/nerdctl-apks/`. It uses debug signing (not suitable for release
distribution), does not use PGO, and excludes local keystores/signing
properties from the temporary build context. `android-build.properties` is the
shared source for Gradle and shell build defaults; `VC` and `VN` override the
version, and `PKG` overrides the Play application ID. Set
`ANDROID_SDK_TMPFS_SIZE` (default `2g`) to adjust the writable SDK metadata
overlay size. Install the compile SDK,
build-tools, platform-tools, NDK, and CMake versions listed there, with SDK
licenses accepted. Host SDK packages are mounted read-only; a temporary
writable SDK metadata overlay keeps build-time SDK changes inside the
container. Set `TMPDIR` to a disk-backed filesystem with enough free space for
the temporary source copy and native build scratch files.
