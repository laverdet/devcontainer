#!/bin/sh
set -eu

FEATURE_DIR=$(cd "$(dirname "$0")" && pwd)
SHARE=/usr/local/share/devcontainer-settings

VSCODE=${VSCODE:-}
CLAUDE=${CLAUDE:-}

install_jq() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		# Drop the package lists afterwards only if this script had to fetch them.
		had_lists=$(find /var/lib/apt/lists -maxdepth 1 -type f ! -name lock | head -n 1)
		apt-get update -y
		apt-get install -y --no-install-recommends jq
		[ -n "$had_lists" ] || rm -rf /var/lib/apt/lists/*
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-cache jq
	elif command -v pacman >/dev/null 2>&1; then
		# Same rule: the sync databases and the package cache stay only if they were there.
		had_sync=$(find /var/lib/pacman/sync -maxdepth 1 -name '*.db' 2>/dev/null | head -n 1)
		had_pkgs=$(find /var/cache/pacman/pkg -maxdepth 1 -type f 2>/dev/null | head -n 1)
		pacman -Sy --noconfirm jq
		[ -n "$had_pkgs" ] || rm -rf /var/cache/pacman/pkg/*
		[ -n "$had_sync" ] || rm -rf /var/lib/pacman/sync/*
	else
		echo "settings: jq is required and no known package manager was found; install jq in the image" >&2
		exit 1
	fi
}

if ! command -v jq >/dev/null 2>&1; then
	echo "settings: installing jq"
	install_jq
fi

mkdir -p "$SHARE"
cp "$FEATURE_DIR/apply.sh" "$SHARE/apply"
chmod 0755 "$SHARE/apply"

record() {
	[ -n "$2" ] || return 0
	if ! printf '%s\n' "$2" | jq -e 'type == "object"' >/dev/null 2>&1; then
		echo "settings: option '$1' must be a JSON object (see the README for how to quote it), got: $2" >&2
		exit 1
	fi
	printf '%s\n' "$2" | jq . >"$SHARE/$1.json"
	chmod 0644 "$SHARE/$1.json"
	recorded="$recorded $1"
}
recorded=
record vscode "$VSCODE"
record claude "$CLAUDE"

echo "settings: installed${recorded:+ (providers:$recorded)}"
