#!/usr/bin/env bash

android_build_default() {
	local properties_file="$1" key="$2" value
	value="$(awk -F= -v key="$key" '
		$1 == key {
			value = substr($0, index($0, "=") + 1)
			sub(/\r$/, "", value)
			sub(/^[[:space:]]+/, "", value)
			sub(/[[:space:]]+$/, "", value)
			print value
			exit
		}
	' "$properties_file")"
	[[ -n "$value" ]] || { echo "error: missing $key in $properties_file" >&2; return 1; }
	printf '%s' "$value"
}
