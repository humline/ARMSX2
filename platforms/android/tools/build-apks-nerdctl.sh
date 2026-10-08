#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$ANDROID_DIR/../.." && pwd)"
# shellcheck source=lib/android-build-defaults.sh
source "$SCRIPT_DIR/lib/android-build-defaults.sh"
OUTPUT_DIR="${1:-$ANDROID_DIR/build/nerdctl-apks}"

NERDCTL="${NERDCTL:-nerdctl}"
BUILDER_IMAGE="${ARMSX2_ANDROID_BUILDER_IMAGE:-armsx2-android-builder:local}"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
GRADLE_CACHE="$ANDROID_DIR/build/nerdctl-gradle-home"
BUILD_DEFAULTS="$ANDROID_DIR/android-build.properties"

DEFAULT_VERSION_CODE="$(android_build_default "$BUILD_DEFAULTS" versionCode)"
DEFAULT_VERSION_NAME="$(android_build_default "$BUILD_DEFAULTS" versionName)"
NDK_VERSION="$(android_build_default "$BUILD_DEFAULTS" ndkVersion)"
CMAKE_VERSION="$(android_build_default "$BUILD_DEFAULTS" cmakeVersion)"
COMPILE_SDK="$(android_build_default "$BUILD_DEFAULTS" compileSdk)"
GITHUB_APPLICATION_ID="$(android_build_default "$BUILD_DEFAULTS" githubApplicationId)"
VERSION_CODE="${VC:-$DEFAULT_VERSION_CODE}"
VERSION_NAME="${VN:-$DEFAULT_VERSION_NAME}"
APK_NAME_PATTERN="ARMSX2-__FLAVOR__-__PAGE__-vc${VERSION_CODE}-${VERSION_NAME}.apk"
ANDROID_SDK_TMPFS_SIZE="${ANDROID_SDK_TMPFS_SIZE:-2g}"

artifact_name() {
	local name="$APK_NAME_PATTERN"
	name="${name//__FLAVOR__/$1}"
	name="${name//__PAGE__/$2}"
	printf '%s' "$name"
}

PLAY_APPLICATION_ID="${PKG:-$(android_build_default "$BUILD_DEFAULTS" playApplicationId)}"

command -v "$NERDCTL" >/dev/null 2>&1 || {
	echo "error: nerdctl is required (with its BuildKit builder configured)" >&2
	exit 1
}
[[ -n "$ANDROID_SDK" && -d "$ANDROID_SDK" ]] || {
	echo "error: set ANDROID_HOME or ANDROID_SDK_ROOT to an installed Android SDK" >&2
	exit 1
}
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
	echo "error: the nerdctl Android builder requires a Linux x86_64 host SDK/toolchain" >&2
	exit 1
}
[[ -d "$ANDROID_SDK/platforms" && -d "$ANDROID_SDK/ndk" &&
	-d "$ANDROID_SDK/platform-tools" && -d "$ANDROID_SDK/licenses" ]] || {
	echo "error: Android SDK platforms, NDK, platform-tools, and licenses must be installed under $ANDROID_SDK" >&2
	exit 1
}
[[ -d "$ANDROID_SDK/ndk/$NDK_VERSION" && -d "$ANDROID_SDK/cmake/$CMAKE_VERSION" ]] || {
	echo "error: install NDK $NDK_VERSION and CMake $CMAKE_VERSION in $ANDROID_SDK before building" >&2
	exit 1
}
[[ -x "$ANDROID_SDK/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" &&
	-x "$ANDROID_SDK/cmake/$CMAKE_VERSION/bin/cmake" ]] || {
	echo "error: the SDK must contain Linux x86_64 NDK and CMake host tools" >&2
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
[[ "$GITHUB_APPLICATION_ID" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]] || {
	echo "error: githubApplicationId must be a valid Android application ID" >&2
	exit 1
}
[[ "$ANDROID_SDK_TMPFS_SIZE" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || {
	echo "error: ANDROID_SDK_TMPFS_SIZE must be a positive size in bytes, k, m, or g" >&2
	exit 1
}

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
BUILD_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/armsx2-nerdctl.XXXXXX")"
trap 'rm -rf "$BUILD_CONTEXT"' EXIT
mkdir -p "$BUILD_CONTEXT/source" "$BUILD_CONTEXT/tmp" "$GRADLE_CACHE"

# Build from the current working tree, but do not copy VCS metadata or local
# signing material into the builder container.
tar -C "$REPO_DIR" \
	--exclude='.git' \
	--exclude='*/.git' \
	--exclude='./platforms/android/app/build' \
	--exclude='./platforms/android/build' \
	--exclude='./platforms/android/armsx2_keystore.properties' \
	--exclude='./platforms/android/local.properties' \
	--exclude='*.keystore' \
	--exclude='*.jks' \
	--exclude='*.p12' \
	--exclude='*.pfx' \
	--exclude='*.profdata' \
	--exclude='.gradle' \
	--exclude='*/.gradle' \
	-cf - . | tar -C "$BUILD_CONTEXT/source" -xf -

echo "Building Android toolchain image with nerdctl/BuildKit..."
"$NERDCTL" build \
	--platform linux/amd64 \
	--progress=plain \
	--file "$SCRIPT_DIR/nerdctl-android-builder.Dockerfile" \
	--tag "$BUILDER_IMAGE" \
	"$SCRIPT_DIR"

echo "Building GitHub (open-source) and Play release APKs..."
for flavor in github play; do
	for page in 4k 16k; do
		rm -f "$OUTPUT_DIR/$(artifact_name "$flavor" "$page")"
	done
done
# The inner build command is intentionally literal and expanded only in the container.
# shellcheck disable=SC2016
"$NERDCTL" run --rm \
	--platform linux/amd64 \
	--user "$(id -u):$(id -g)" \
	--security-opt no-new-privileges \
	--cap-drop ALL \
	--read-only \
	--tmpfs "/android-sdk:rw,nosuid,nodev,size=$ANDROID_SDK_TMPFS_SIZE" \
	--env ANDROID_HOME=/android-sdk \
	--env ANDROID_SDK_ROOT=/android-sdk \
	--env GRADLE_USER_HOME=/gradle \
	--env HOME=/tmp/build-home \
	--env VC="$VERSION_CODE" \
	--env VN="$VERSION_NAME" \
	--env PLAY_APPLICATION_ID="$PLAY_APPLICATION_ID" \
	--env GITHUB_APPLICATION_ID="$GITHUB_APPLICATION_ID" \
	--env APK_NAME_PATTERN="$APK_NAME_PATTERN" \
	--volume "$BUILD_CONTEXT/source:/workspace:rw" \
	--volume "$BUILD_CONTEXT/tmp:/tmp:rw" \
	--volume "$ANDROID_SDK:/android-sdk-base:ro" \
	--volume "$GRADLE_CACHE:/gradle:rw" \
	--volume "$OUTPUT_DIR:/output:rw" \
	--workdir /workspace/platforms/android \
	"$BUILDER_IMAGE" \
	bash -euc '
		mkdir -p "$HOME"
		# Keep installed SDK packages read-only, while giving AGP a writable
		# SDK root for temporary metadata and any required package installs.
		for entry in /android-sdk-base/*; do
			[[ -e "$entry" ]] || continue
			name="$(basename "$entry")"
			if [[ -d "$entry" ]]; then
				case "$name" in
					build-tools|cmake|cmdline-tools|emulator|extras|licenses|ndk|platform-tools|platforms|sources|system-images)
						mkdir -p "$ANDROID_HOME/$name"
						for package in "$entry"/*; do
							[[ -e "$package" ]] || continue
							ln -s "$package" "$ANDROID_HOME/$name/$(basename "$package")"
						done
						;;
					*)
						ln -s "$entry" "$ANDROID_HOME/$name"
						;;
				esac
			else
				cp "$entry" "$ANDROID_HOME/$name"
			fi
		done
		apksigner="$(
			for tools_dir in "$ANDROID_HOME"/build-tools/*; do
				[[ -x "$tools_dir/apksigner" ]] &&
					printf "%s\t%s\n" "$(basename "$tools_dir")" "$tools_dir/apksigner"
			done | sort -V -k1,1 | tail -n 1 | cut -f2-
		)"
		[[ -x "$apksigner" ]] || { echo "error: apksigner is missing from the Android SDK" >&2; exit 1; }
		for flavor in Github Play; do
			flavor_lower="$(printf "%s" "$flavor" | tr "[:upper:]" "[:lower:]")"
			if [[ "$flavor" == Play ]]; then
				application_id="$PLAY_APPLICATION_ID"
			else
				application_id="$GITHUB_APPLICATION_ID"
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
				apk_name="${APK_NAME_PATTERN//__FLAVOR__/$flavor_lower}"
				apk_name="${apk_name//__PAGE__/$page_name}"
				cp "$apk" "/output/$apk_name"
			done
		done
	'

echo "Built APKs:"
checksum_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1"
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1"
	else
		echo "error: sha256sum or shasum is required to verify APK outputs" >&2
		return 1
	fi
}
for flavor in github play; do
	for page in 4k 16k; do
		apk="$OUTPUT_DIR/$(artifact_name "$flavor" "$page")"
		[[ -s "$apk" ]] || { echo "error: expected APK was not produced: $apk" >&2; exit 1; }
		checksum_file "$apk"
	done
done
