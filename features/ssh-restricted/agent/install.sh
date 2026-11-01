#!/bin/sh
# Installs the host side of the ssh-restricted Dev Container Feature: a launchd agent of the login
# session that puts ssh-agent-filter in front of Apple's ssh-agent at the SSH_AUTH_SOCK path every app
# got at login, and moves the agent itself to SSH_UNFILTERED_AUTH_SOCK, a socket launchd makes for the
# job and publishes the way Apple's own ssh-agent does, so that every app has the variable from the
# moment it starts. The release workflow fills in @AGENT_RELEASE@; everything else is decided here, on
# the machine being installed. macOS only.
#
#   curl -fsSL https://github.com/laverdet/devcontainer/releases/latest/download/ssh-agent-install.sh | sh -s -- add
#
# Usage: install.sh [--local SCRIPT] [--keys DIR] {add|remove}
#   --local SCRIPT   use the devcontainer-ssh-agent script at SCRIPT instead of downloading this
#                    release's and verifying it against the release's SHA256SUMS
#   --keys DIR       directory of private keys containers may use (default $HOME/.ssh/restricted)
#
# Environment: PREFIX (install prefix, default $HOME/.local), AGENT_RELEASE (the v* release tag to
# fetch, default @AGENT_RELEASE@), AGENT_BASE_URL (where the release assets are, default that release
# on GitHub).
set -eu

NAME=devcontainer-ssh-agent
LABEL=com.laverdet.devcontainer-ssh-agent.restricted
REPO=laverdet/devcontainer
DEFAULT_RELEASE='@AGENT_RELEASE@'
RELEASE=${AGENT_RELEASE:-$DEFAULT_RELEASE}
PREFIX=${PREFIX:-$HOME/.local}
PUBLISH_DIR=$HOME/.local/share/devcontainer-ssh-agent # what containers bind-mount
KEYDIR=$HOME/.ssh/restricted
LAUNCH_AGENTS=$HOME/Library/LaunchAgents
LOG=$HOME/Library/Logs/$NAME.log
if [ "$RELEASE" = latest ]; then
	DEFAULT_BASE_URL=https://github.com/$REPO/releases/latest/download
else
	DEFAULT_BASE_URL=https://github.com/$REPO/releases/download/$RELEASE
fi
BASE_URL=${AGENT_BASE_URL:-$DEFAULT_BASE_URL}

usage() {
	echo "usage: install.sh [--local SCRIPT] [--keys DIR] {add|remove}"
}
say() {
	printf '%s\n' "$*"
}
die() {
	printf 'install.sh: %s\n' "$*" >&2
	exit 1
}

mode=
local_bin=
while [ $# -gt 0 ]; do
	case $1 in
		--local)
			[ $# -ge 2 ] || die "--local needs a path"
			local_bin=$2
			shift
			;;
		--keys)
			[ $# -ge 2 ] || die "--keys needs a path"
			KEYDIR=$2
			shift
			;;
		add | remove) mode=$1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 2
			;;
	esac
	shift
done
if [ -z "$mode" ]; then
	usage >&2
	exit 2
fi
[ "$(uname -s)" = Darwin ] || die "only macOS is supported for now"

domain=gui/$(id -u)
bin=$PREFIX/bin/$NAME
if [ -n "$local_bin" ]; then
	case $local_bin in
		/*) ;;
		*) local_bin=$(cd "$(dirname "$local_bin")" && pwd)/$(basename "$local_bin") ;;
	esac
	bin=$local_bin
fi

fetch() { # URL: body on stdout
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "$1"
	else
		die "need curl or wget to download $1"
	fi
}

sha256() { # FILE: hex digest on stdout
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

loaded() { # LABEL
	launchctl print "$domain/$1" >/dev/null 2>&1
}

# ssh-add -l exits 2 only when nothing answers at the socket.
alive() { # SOCKET
	SSH_AUTH_SOCK=$1 ssh-add -l >/dev/null 2>&1 || [ $? -ne 2 ]
}

# The socket launchd made for Apple's agent: the SSH_AUTH_SOCK of every app in the session.
session_sock() {
	launchctl getenv SSH_AUTH_SOCK
}

inode() { # FILE
	stat -f %i "$1" 2>/dev/null
}

# bootout returns before the service is gone, and a bootstrap fails until it is.
bootout() { # LABEL
	loaded "$1" || return 0
	launchctl bootout "$domain/$1" 2>/dev/null || true
	tries=0
	while loaded "$1"; do
		tries=$((tries + 1))
		[ "$tries" -le 100 ] || die "$1 did not stop"
		sleep 0.1
	done
}

bootstrap() { # PLIST
	launchctl bootstrap "$domain" "$1" || die "could not bootstrap $1"
}

remove_file() { # FILE
	if [ -e "$1" ]; then
		rm -f "$1" && say "removed $1"
	fi
}

# The script is the program itself, not an argument to sh, so that System Settings' Login Items shows
# its name.
write_plist() { # SCRIPT FILTER
	mkdir -p "$(dirname "$LOG")"
	cat >"$LAUNCH_AGENTS/$LABEL.plist" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$1</string>
		<string>-o</string>
		<string>$PUBLISH_DIR</string>
		<string>-k</string>
		<string>$KEYDIR</string>
		<string>-f</string>
		<string>$2</string>
	</array>
	<key>Sockets</key>
	<dict>
		<key>Listeners</key>
		<dict>
			<key>SecureSocketWithKey</key>
			<string>SSH_UNFILTERED_AUTH_SOCK</string>
		</dict>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOT
	say "wrote $LAUNCH_AGENTS/$LABEL.plist"
}

install_script() {
	if [ -n "$local_bin" ]; then
		[ -x "$bin" ] || die "$bin is not an executable file"
		return 0
	fi
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	say "downloading $BASE_URL/$NAME"
	fetch "$BASE_URL/$NAME" >"$tmp/$NAME"
	fetch "$BASE_URL/SHA256SUMS" >"$tmp/SHA256SUMS"
	expected=$(awk -v a="$NAME" '$2 == a || $2 == "*" a { print $1 }' "$tmp/SHA256SUMS")
	[ -n "$expected" ] || die "$NAME is not listed in SHA256SUMS"
	actual=$(sha256 "$tmp/$NAME")
	[ "$actual" = "$expected" ] || die "checksum mismatch for $NAME: expected $expected, got $actual"
	mkdir -p "$PREFIX/bin"
	install -m 0755 "$tmp/$NAME" "$bin"
	say "installed $bin"
}

# Whether the proxy has taken the SSH_AUTH_SOCK path: then it is the same file as agent.sock.
swapped() {
	[ -n "$(inode "$1")" ] && [ "$(inode "$1")" = "$(inode "$PUBLISH_DIR/agent.sock")" ]
}

# Give the SSH_AUTH_SOCK path back to your agent before the job, and with it the second name, goes.
restore() {
	sock=$(session_sock)
	unfiltered=$(launchctl getenv SSH_UNFILTERED_AUTH_SOCK)
	if [ -n "$sock" ] && [ -n "$unfiltered" ] && swapped "$sock"; then
		mv -f "$unfiltered" "$sock"
	fi
}

add() {
	# launchd's PATH has no Homebrew, so the job gets the path resolved here.
	filter=$(command -v ssh-agent-filter || true)
	if [ -z "$filter" ] && command -v brew >/dev/null 2>&1; then
		filter=$(brew --prefix ssh-agent-filter 2>/dev/null)/bin/ssh-agent-filter
	fi
	[ -x "$filter" ] || die "ssh-agent-filter is not installed; see the README for the Homebrew tap"
	[ -n "$(session_sock)" ] || die "no SSH_AUTH_SOCK in the session; log in again and retry"
	install_script
	mkdir -p "$PUBLISH_DIR"
	if [ ! -d "$KEYDIR" ]; then
		mkdir -p "$KEYDIR"
		chmod 0700 "$KEYDIR"
		say "created $KEYDIR; put the private keys containers may use there"
	fi
	restore
	bootout "$LABEL"
	write_plist "$bin" "$filter"
	bootstrap "$LAUNCH_AGENTS/$LABEL.plist"
	# Up once the SSH_AUTH_SOCK path is the proxy's socket and it answers.
	sock=$(session_sock)
	tries=0
	while ! swapped "$sock" || ! alive "$sock"; do
		tries=$((tries + 1))
		[ "$tries" -le 100 ] || die "the restricted agent did not come up; see $LOG"
		sleep 0.1
	done
	keys=$(SSH_AUTH_SOCK=$sock ssh-add -l 2>/dev/null | grep -c '^[0-9]' || true)
	say "restricted agent: SSH_AUTH_SOCK=$sock ($keys key(s) from $KEYDIR, log: $LOG)"
	say "your agent:       SSH_UNFILTERED_AUTH_SOCK=$(launchctl getenv SSH_UNFILTERED_AUTH_SOCK); select it in your shell and in ~/.ssh/config, see the README"
	say "after changing the keys in $KEYDIR, restart it: launchctl kickstart -k $domain/$LABEL"
	say "restart VS Code so it forwards this agent"
}

remove() {
	restore
	bootout "$LABEL"
	remove_file "$LAUNCH_AGENTS/$LABEL.plist"
	[ -n "$local_bin" ] || remove_file "$bin"
	launchctl unsetenv SSH_UNFILTERED_AUTH_SOCK
	say "SSH_AUTH_SOCK is your agent again; SSH_UNFILTERED_AUTH_SOCK is gone, change your shell and ~/.ssh/config back"
}

mkdir -p "$LAUNCH_AGENTS"
"$mode"
