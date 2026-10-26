#!/bin/sh
# timezone Feature: container entrypoint hook.
#
# The devcontainer CLI runs this at every container start, before the
# container's own command, as the container user (normally root):
#
#     entrypoint '<host TZ variable>'
#
# The argument is filled in by the CLI from ${localEnv:TZ} and is usually empty.
#
# Two things from the host are bind-mounted read-only:
#
#   /mnt/host/devcontainer-timezone: the directory the host agent (agent/ next
#   to this file) publishes into. 'localtime' is a copy of the zone data the
#   host's /etc/localtime resolves to and 'zone' is its IANA name; the agent
#   replaces both atomically whenever the host's zone changes.
#
#   /mnt/host/etc/localtime: the host's /etc/localtime itself, for hosts without
#   the agent. Docker resolves the host's symlink, so this is the zone file
#   pinned at container creation. On macOS it sits in a versioned directory the
#   OS replaces in place during updates, which is why it serves only to work out
#   the zone at start and never as the container's /etc/localtime.
#
# What happens, first match wins:
#   1. the 'timezone' Feature option: /etc/localtime links to that zone
#   2. the host's TZ variable, when it is an IANA zone name: the same
#   3. the agent's copy is present: /etc/localtime links to it, so every program
#      started from now on reads the host's current zone, with no process in
#      the container; /etc/timezone gets the name when the agent knows it
#   4. a name from the resolved host path of the mounted file (field 4 of
#      /proc/self/mountinfo, which ends in zoneinfo/<Zone> on macOS, Linux,
#      NixOS and WSL), or from a zone in this image's /usr/share/zoneinfo with
#      byte-identical contents: /etc/localtime links to the image's own copy
#   5. no name: the host's file is copied to /etc/localtime so the clock is right
# The script never exits non-zero: a problem here must not keep the container
# from starting.

HOST_DIR=/mnt/host/devcontainer-timezone
HOST_LOCALTIME=/mnt/host/etc/localtime
CONFIG=/usr/local/share/devcontainer-timezone/config
ZONEINFO=/usr/share/zoneinfo

log() {
	printf '[timezone] %s\n' "$*" >&2
}

valid_zone_name() {
	case $1 in
		'' | /* | */ | *//* | *..* | .* | *[!A-Za-z0-9_+./-]*) return 1 ;;
	esac
	return 0
}

# /proc/self/mountinfo octal-escapes whitespace (\040 for a space); undo that.
unescape() {
	printf '%b\n' "$1"
}

is_mountpoint() {
	awk '{ print $5 }' /proc/self/mountinfo | while IFS= read -r raw; do
		unescape "$raw"
	done | grep -qxF -- "$1"
}

# Zone name from a path such as /var/db/timezone/zoneinfo/Europe/Berlin.
zone_from_path() {
	case $1 in
		*/zoneinfo/*) zone=${1##*/zoneinfo/} ;;
		*) return 1 ;;
	esac
	zone=${zone#posix/}
	valid_zone_name "$zone" || return 1
	printf '%s\n' "$zone"
}

# Zone name from the resolved host path of the mounted file.
detect_from_mountinfo() {
	root=$(awk -v mp="$HOST_LOCALTIME" '$5 == mp { print $4; exit }' /proc/self/mountinfo)
	zone_from_path "$(unescape "$root")"
}

same_file() {
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$1" "$2"
	else
		[ "$(md5sum <"$1")" = "$(md5sum <"$2")" ]
	fi
}

# Zone in this image's zoneinfo with the same bytes as the host's file. Same
# bytes means the same rules, so any match is a correct answer; canonical names
# from zone1970.tab and zone.tab are preferred over aliases.
detect_by_content() {
	[ -s "$HOST_LOCALTIME" ] && [ -d "$ZONEINFO" ] || return 1
	size=$(wc -c <"$HOST_LOCALTIME" | tr -d ' ')
	same_size=$(cd "$ZONEINFO" && find . -type f -size "${size}c" \
		! -path './posix/*' ! -path './right/*' ! -name '*.tab' ! -name '*.zi' \
		! -name leapseconds ! -name posixrules ! -name localtime ! -name Factory ! -name '+VERSION' \
		2>/dev/null | sed 's#^\./##' | sort)
	[ -n "$same_size" ] || return 1
	preferred=$(for tab in zone1970.tab zone.tab; do
		[ -r "$ZONEINFO/$tab" ] && awk '!/^#/ && NF >= 3 { print $3 }' "$ZONEINFO/$tab"
	done)
	ordered=$(printf '%s\n%s\n' "$preferred" "$same_size" | awk 'NF && !seen[$0]++')
	while IFS= read -r zone; do
		[ -n "$zone" ] || continue
		printf '%s\n' "$same_size" | grep -qxF -- "$zone" || continue
		if same_file "$ZONEINFO/$zone" "$HOST_LOCALTIME"; then
			printf '%s\n' "$zone"
			return 0
		fi
	done <<EOM
$ordered
EOM
	return 1
}

# Replace a path with a copy of the host's file, without a window where it is missing.
copy_host_file_to() {
	[ -s "$HOST_LOCALTIME" ] || return 1
	mkdir -p "$(dirname "$1")" && cp "$HOST_LOCALTIME" "$1.timezone-tmp" && mv -f "$1.timezone-tmp" "$1"
}

# apply_zone ZONE ORIGIN [HOST_FILE_IS_ZONE]: point /etc/localtime and
# /etc/timezone at ZONE, creating the zone file from the host's copy when the
# image lacks it and the host's file is known to be that zone.
apply_zone() {
	file=$ZONEINFO/$1
	if [ ! -f "$file" ]; then
		if [ -n "${3:-}" ] && copy_host_file_to "$file"; then
			log "created $file from the host's /etc/localtime"
		else
			log "no $file in this image; enable the installTzdata option or choose a zone the image has"
			return 1
		fi
	fi
	ln -sfn "$file" /etc/localtime || { log "cannot replace /etc/localtime"; return 1; }
	printf '%s\n' "$1" >/etc/timezone || log "cannot write /etc/timezone"
	log "time zone set to $1 (from $2)"
}

# Link /etc/localtime to the agent's copy; fails when there is none.
follow_agent() {
	[ "$(head -c 4 "$HOST_DIR/localtime" 2>/dev/null)" = TZif ] || return 1
	ln -sfn "$HOST_DIR/localtime" /etc/localtime || { log "cannot replace /etc/localtime"; return 1; }
	zone=$(head -n 1 "$HOST_DIR/zone" 2>/dev/null)
	if valid_zone_name "$zone"; then
		printf '%s\n' "$zone" >/etc/timezone || log "cannot write /etc/timezone"
	else
		zone='(name unknown)'
		rm -f /etc/timezone
	fi
	log "following the host's time zone through $HOST_DIR, currently $zone"
}

main() {
	HOST_TZ=${1:-}
	TIMEZONE=
	if [ -r "$CONFIG" ]; then
		# shellcheck disable=SC1090
		. "$CONFIG"
	fi

	if [ "$(id -u)" != 0 ]; then
		log "not running as root (container user is $(id -un)); cannot set the time zone"
		return 0
	fi
	if is_mountpoint /etc/localtime; then
		log "/etc/localtime is a mount point (from devcontainer.json?); leaving it alone"
		return 0
	fi

	if [ -n "$TIMEZONE" ]; then
		apply_zone "$TIMEZONE" "the 'timezone' option"
	elif valid_zone_name "$HOST_TZ"; then
		apply_zone "$HOST_TZ" "the host's TZ variable"
	elif follow_agent; then
		:
	elif zone=$(detect_from_mountinfo); then
		apply_zone "$zone" "the host's /etc/localtime link" 1
	elif zone=$(detect_by_content); then
		apply_zone "$zone" "matching the host's /etc/localtime against $ZONEINFO" 1
	elif copy_host_file_to /etc/localtime; then
		rm -f /etc/timezone
		log "could not determine the host's time zone name; copied the host's /etc/localtime instead (clock is right, zone name unknown)"
	else
		log "could not determine the host's time zone and cannot read $HOST_LOCALTIME; leaving /etc/localtime as is"
	fi
	return 0
}

main "$@" || log "unexpected error (exit status $?)"
exit 0
