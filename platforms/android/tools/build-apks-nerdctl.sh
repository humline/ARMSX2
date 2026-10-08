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
GRADLE_CACHE="${GRADLE_CACHE:-$HOME/.gradle}"
VERSION_CODE="${VC:-1088}"
VERSION_NAME="${VN:-2.6.1}"

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
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || {
	echo "error: VC must be an integer" >&2
	exit 1
}
[[ "$VERSION_NAME" =~ ^[A-Za-z0-9._+-]+$ ]] || {
	echo "error: VN contains unsupported characters" >&2
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
	--volume "$BUILD_CONTEXT/source:/workspace:rw" \
	--volume "$ANDROID_SDK:/android-sdk:rw" \
	--volume "$GRADLE_CACHE:/gradle:rw" \
	--volume "$OUTPUT_DIR:/output:rw" \
	--workdir /workspace/platforms/android \
	"$BUILDER_IMAGE" \
	bash -euc '
		mkdir -p "$HOME"
		for flavor in Github Play; do
			flavor_lower="$(printf "%s" "$flavor" | tr "[:upper:]" "[:lower:]")"
			if [[ "$flavor" == Play ]]; then
				application_id=come.nanodata.armsx2
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
				unzip -l "$apk" "lib/arm64-v8a/lib${library_name}.so" >/dev/null || {
					echo "error: expected native library missing from $apk" >&2
					exit 1
				}
				cp "$apk" "/output/ARMSX2-${flavor_lower}-${page_name}-vc${VC}-${VN}.apk"
			done
		done
	'

echo "Built APKs:"
for apk in "$OUTPUT_DIR"/*.apk; do
	[[ -f "$apk" ]] || continue
	sha256sum "$apk"
done
