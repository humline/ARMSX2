#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ANDROID_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$ANDROID_DIR/build/nerdctl-apks}"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

NERDCTL="${NERDCTL:-nerdctl}"
BUILDER_IMAGE="${ARMSX2_ANDROID_BUILDER_IMAGE:-armsx2-android-builder:local}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
GRADLE_CACHE="$ANDROID_DIR/build/nerdctl-gradle-home"
APP_GRADLE="$ANDROID_DIR/app/build.gradle.kts"
DEFAULT_VERSION_CODE="$(sed -nE 's/.*[?]:[[:space:]]*([0-9]+)$/\1/p' "$APP_GRADLE")"
DEFAULT_VERSION_NAME="$(sed -nE 's/.*[?]:[[:space:]]*"([^"]+)".*/\1/p' "$APP_GRADLE")"
NDK_VERSION="$(sed -nE 's/.*armsx2NdkVersion = .*orElse\("([^"]+)"\).*/\1/p' "$APP_GRADLE")"
CMAKE_VERSION="$(sed -nE 's/.*version = "([0-9.]+)".*/\1/p' "$APP_GRADLE")"
COMPILE_SDK="$(sed -nE 's/^[[:space:]]*compileSdk = ([0-9]+)$/\1/p' "$APP_GRADLE")"
VERSION_CODE="${VC:-$DEFAULT_VERSION_CODE}"
VERSION_NAME="${VN:-$DEFAULT_VERSION_NAME}"
# Share the Play package default with tools/build-play-aab.sh.
DEFAULT_PLAY_APPLICATION_ID="$(sed -nE 's/^PKG="\$\{PKG:-([^}]+)\}"$/\1/p' "$ANDROID_DIR/tools/build-play-aab.sh")"
PLAY_APPLICATION_ID="${PKG:-$DEFAULT_PLAY_APPLICATION_ID}"

command -v "$NERDCTL" >/dev/null 2>&1 || {
	echo "error: nerdctl is required (with its BuildKit builder configured)" >&2
	exit 1
}
[[ -n "$ANDROID_SDK" && -d "$ANDROID_SDK" ]] || {
	echo "error: set ANDROID_HOME or ANDROID_SDK_ROOT to an installed Android SDK" >&2
	exit 1
}
[[ -d "$ANDROID_SDK/platforms" && -d "$ANDROID_SDK/ndk" ]] || {
	echo "error: Android SDK platforms and NDK must be installed under $ANDROID_SDK" >&2
	exit 1
}
[[ -n "$DEFAULT_VERSION_CODE" && -n "$DEFAULT_VERSION_NAME" && -n "$DEFAULT_PLAY_APPLICATION_ID" &&
	-n "$NDK_VERSION" && -n "$CMAKE_VERSION" && -n "$COMPILE_SDK" ]] || {
	echo "error: could not read Android build defaults from $APP_GRADLE" >&2
	exit 1
}
[[ -d "$ANDROID_SDK/ndk/$NDK_VERSION" && -d "$ANDROID_SDK/cmake/$CMAKE_VERSION" ]] || {
	echo "error: install NDK $NDK_VERSION and CMake $CMAKE_VERSION in $ANDROID_SDK before building" >&2
	exit 1
}
platform_found=false
for platform in "$ANDROID_SDK/platforms/android-$COMPILE_SDK" "$ANDROID_SDK"/platforms/android-"$COMPILE_SDK".*; do
	if [[ -d "$platform" ]]; then
		platform_found=true
		break
	fi
done
[[ "$platform_found" == true ]] || {
	echo "error: Android platform $COMPILE_SDK is missing from $ANDROID_SDK" >&2
	exit 1
}
build_tools_found=false
for build_tools in "$ANDROID_SDK"/build-tools/*; do
	if [[ -d "$build_tools" ]]; then
		build_tools_found=true
		break
	fi
done
[[ "$build_tools_found" == true ]] || {
	echo "error: Android build-tools must be installed in $ANDROID_SDK" >&2
	exit 1
}
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || {
	echo "error: VC must be an integer" >&2
	exit 1
}
[[ "$VERSION_NAME" =~ ^[A-Za-z0-9._+-]+$ ]] || {
	echo "error: VN contains unsupported characters" >&2
	exit 1
}
[[ "$PLAY_APPLICATION_ID" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]] || {
	echo "error: PKG must be a valid Android application ID" >&2
	exit 1
}

BUILD_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/armsx2-nerdctl.XXXXXX")"
trap 'rm -rf "$BUILD_CONTEXT"' EXIT
mkdir -p "$BUILD_CONTEXT/source" "$GRADLE_CACHE"

# Build from the current working tree, but do not copy VCS metadata or local
# signing material into the builder container.
tar -C "$REPO_DIR" \
	--exclude='./.git' \
	--exclude='./platforms/android/app/build' \
	--exclude='./platforms/android/build' \
	--exclude='./platforms/android/armsx2_keystore.properties' \
	--exclude='*.keystore' \
	--exclude='*.jks' \
	--exclude='*.p12' \
	--exclude='*.pfx' \
	--exclude='*.profdata' \
	--exclude='*/.gradle' \
	-cf - . | tar -C "$BUILD_CONTEXT/source" -xf -

echo "Building Android toolchain image with nerdctl/BuildKit..."
"$NERDCTL" build \
	--progress=plain \
	--file "$SCRIPT_DIR/nerdctl-android-builder.Dockerfile" \
	--tag "$BUILDER_IMAGE" \
	"$SCRIPT_DIR"

echo "Building GitHub (open-source) and Play release APKs..."
for flavor in github play; do
	for page in 4k 16k; do
		rm -f "$OUTPUT_DIR/ARMSX2-${flavor}-${page}-vc${VERSION_CODE}-${VERSION_NAME}.apk"
	done
done
# The inner build command is intentionally literal and expanded only in the container.
# shellcheck disable=SC2016
"$NERDCTL" run --rm \
	--user "$(id -u):$(id -g)" \
	--security-opt no-new-privileges \
	--cap-drop ALL \
	--read-only \
	--tmpfs /tmp:rw,nosuid,nodev,size=2g \
	--env ANDROID_HOME=/android-sdk \
	--env ANDROID_SDK_ROOT=/android-sdk \
	--env GRADLE_USER_HOME=/gradle \
	--env HOME=/tmp/build-home \
	--env VC="$VERSION_CODE" \
	--env VN="$VERSION_NAME" \
	--env PLAY_APPLICATION_ID="$PLAY_APPLICATION_ID" \
	--volume "$BUILD_CONTEXT/source:/workspace:rw" \
	--volume "$ANDROID_SDK:/android-sdk:ro" \
	--volume "$GRADLE_CACHE:/gradle:rw" \
	--volume "$OUTPUT_DIR:/output:rw" \
	--workdir /workspace/platforms/android \
	"$BUILDER_IMAGE" \
	bash -euc '
		mkdir -p "$HOME"
		apksigner="$(find "$ANDROID_HOME/build-tools" -type f -name apksigner | sort -V | tail -n 1)"
		[[ -x "$apksigner" ]] || { echo "error: apksigner is missing from the Android SDK" >&2; exit 1; }
		for flavor in Github Play; do
			flavor_lower="$(printf "%s" "$flavor" | tr "[:upper:]" "[:lower:]")"
			if [[ "$flavor" == Play ]]; then
				application_id="$PLAY_APPLICATION_ID"
			else
				application_id=com.armsx2
			fi
			for page_size in 0x1000 0x4000; do
				if [[ "$page_size" == 0x1000 ]]; then
					page_name=4k
				else
					page_name=16k
				fi
				library_name="emucore_${page_name}"
				echo "=== ${flavor} ${page_name} ==="
				./gradlew --no-daemon ":app:assemble${flavor}Release" \
					"-Parmsx2.applicationId=${application_id}" \
					"-Parmsx2.hostPageSize=${page_size}" \
					"-Parmsx2.nativeLibName=${library_name}" \
					-Parmsx2.pgo=none \
					"-Parmsx2.versionCode=${VC}" \
					"-Parmsx2.versionName=${VN}"

				apk="app/build/outputs/apk/${flavor_lower}/release/app-${flavor_lower}-release.apk"
				[[ -f "$apk" ]] || { echo "error: expected APK not produced: $apk" >&2; exit 1; }
				"$apksigner" verify "$apk"
				unzip -l "$apk" "lib/arm64-v8a/lib${library_name}.so" >/dev/null || {
					echo "error: expected native library missing from $apk" >&2
					exit 1
				}
				cp "$apk" "/output/ARMSX2-${flavor_lower}-${page_name}-vc${VC}-${VN}.apk"
			done
		done
	'

echo "Built APKs:"
for flavor in github play; do
	for page in 4k 16k; do
		apk="$OUTPUT_DIR/ARMSX2-${flavor}-${page}-vc${VERSION_CODE}-${VERSION_NAME}.apk"
		[[ -s "$apk" ]] || { echo "error: expected APK was not produced: $apk" >&2; exit 1; }
		sha256sum "$apk"
	done
done
