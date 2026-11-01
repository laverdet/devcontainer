#!/bin/sh
set -eu

FEATURE_DIR=$(cd "$(dirname "$0")" && pwd)
SHARE=/usr/local/share/devcontainer-ssh-agent

INSTALLOPENSSHCLIENT=${INSTALLOPENSSHCLIENT:-true}
case $INSTALLOPENSSHCLIENT in
	true | false) ;;
	*)
		echo "ssh-agent: option 'installOpenSSHClient' must be true or false, got '$INSTALLOPENSSHCLIENT'" >&2
		exit 1
		;;
esac

install_ssh() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		# Drop the package lists afterwards only if this script had to fetch them.
		had_lists=$(find /var/lib/apt/lists -maxdepth 1 -type f ! -name lock | head -n 1)
		apt-get update -y
		apt-get install -y --no-install-recommends openssh-client
		[ -n "$had_lists" ] || rm -rf /var/lib/apt/lists/*
	elif command -v apk >/dev/null 2>&1; then
		apk add --no-cache openssh-client
	elif command -v pacman >/dev/null 2>&1; then
		# Same rule: the sync databases and the package cache stay only if they were there.
		had_sync=$(find /var/lib/pacman/sync -maxdepth 1 -name '*.db' 2>/dev/null | head -n 1)
		had_pkgs=$(find /var/cache/pacman/pkg -maxdepth 1 -type f 2>/dev/null | head -n 1)
		pacman -Sy --noconfirm openssh
		[ -n "$had_pkgs" ] || rm -rf /var/cache/pacman/pkg/*
		[ -n "$had_sync" ] || rm -rf /var/lib/pacman/sync/*
	else
		echo "ssh-agent: no known package manager, not installing the OpenSSH client" >&2
	fi
}

if [ "$INSTALLOPENSSHCLIENT" = true ] && ! command -v ssh >/dev/null 2>&1; then
	echo "ssh-agent: installing the OpenSSH client"
	install_ssh || echo "ssh-agent: warning: installing the OpenSSH client failed; continuing without it" >&2
fi

mkdir -p "$SHARE"
cp "$FEATURE_DIR/check.sh" "$SHARE/check"
chmod 0755 "$SHARE/check"

echo "ssh-agent: installed"
