#!/bin/sh
# `apply` is run on "create" instead of "install" because VS Code's own remote connection handling
# cannot merge settings. So if we were write VS Code settings then VS Code would either clobber
# them, or fail to inject its own required settings.
SHARE=/usr/local/share/devcontainer-settings

log() {
	printf '[settings] %s\n' "$*" >&2
}

# True when PATH is on the container's own filesystem or a named volume. A bind mount from the host
# is left alone: writing through it would change the host's file. The innermost mount wins;
# /proc/self/mountinfo octal-escapes whitespace.
on_container_fs() {
	best='' best_root=''
	while read -r _ _ _ root mp _; do
		mp=$(printf '%b' "$mp")
		case $1 in
			"$mp" | "${mp%/}"/*)
				if [ "${#mp}" -ge "${#best}" ]; then
					best=$mp
					best_root=$(printf '%b' "$root")
				fi
				;;
		esac
	done </proc/self/mountinfo
	[ "$best" = / ] && return 0
	case $best_root in
		*/volumes/*/_data | */volumes/*/_data/*) return 0 ;;
	esac
	return 1
}

# merge FILE JSON: deep-merge JSON into FILE, creating it when missing.
merge() {
	if [ -s "$1" ]; then
		if ! jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
			log "$1 is not a JSON object; leaving it alone"
			return 1
		fi
		if jq -e --argjson add "$2" '. == (. * $add)' "$1" >/dev/null 2>&1; then
			return 0
		fi
		merged=$(jq --argjson add "$2" '. * $add' "$1")
	else
		merged=$2
	fi
	if mkdir -p "$(dirname "$1")" && printf '%s\n' "$merged" >"$1.settings-tmp" && mv -f "$1.settings-tmp" "$1"; then
		log "updated $1"
	else
		log "cannot write $1"
		return 1
	fi
}

apply() {
	if on_container_fs "$1"; then
		merge "$1" "$2"
	else
		log "$1 is mounted from the host; leaving it alone"
	fi
}

apply_vscode() {
	found=
	for target in "$HOME"/.vscode-server*/data/Machine/settings.json; do
		[ -f "$target" ] || continue
		found=1
		apply "$target" "$1"
	done
	[ -n "$found" ] || log "no VS Code server data under $HOME; VS Code has not connected to this container, skipping its settings"
}

apply_claude() {
	apply "$HOME/.claude/settings.json" "$1"
}

[ -f "$SHARE/vscode.json" ] && apply_vscode "$(cat "$SHARE/vscode.json")"
[ -f "$SHARE/claude.json" ] && apply_claude "$(cat "$SHARE/claude.json")"
exit 0
