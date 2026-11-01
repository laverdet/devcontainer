#!/bin/sh
# Runs on devcontainer attach. This is the failsafe which prevents your real SSH_AUTH_SOCKET from
# silently living in the devcontainer.
AGENT=/var/run/devcontainer-ssh-agent/agent.sock

# Private key of all 0's. Armor is in `takes_keys` to avoid triggering a hit from secret scanners.
JUNK='b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACA7aie8zrakLWKjqNAqbw1zZTIVdx3iQ6Y6wEihi1naKQAAAIgAAAAAAAAA
AAAAAAtzc2gtZWQyNTUxOQAAACA7aie8zrakLWKjqNAqbw1zZTIVdx3iQ6Y6wEihi1naKQ
AAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADtqJ7zOtqQtYqOo0CpvDXNl
MhV3HeJDpjrASKGLWdopAAAABGp1bmsB'

log() {
	printf '[ssh-agent] %s\n' "$*" >&2
}

# ssh-add -l exits 2 only when nothing answers at the socket.
answers() {
	SSH_AUTH_SOCK=$1 ssh-add -l >/dev/null 2>&1 || [ $? -ne 2 ]
}

takes_keys() {
	printf -- '-----%s OPENSSH %s KEY-----\n%s\n-----%s OPENSSH %s KEY-----\n' BEGIN PRIVATE "$JUNK" END PRIVATE \
		| SSH_AUTH_SOCK=$1 ssh-add -t 1 - >/dev/null 2>&1
}

alarm() { # SOCKET
	log "!!! $1 took a key: it is NOT the restricted agent. The host is forwarding your real agent, and everything in this container can use your keys."
	log "!!! Install this Feature's agents on the host, https://github.com/laverdet/devcontainer/tree/main/features/ssh-restricted, and restart VS Code. Taking this container down."
	# A PID 1 with a signal handler, such as the Dev Containers default, stops the container; one
	# without ignores signals from inside, root or not. Then everything of this user's goes.
	kill -TERM 1 2>/dev/null || sudo -n kill -TERM 1 2>/dev/null
	kill -KILL -1 2>/dev/null
	exit 1
}

command -v ssh-add >/dev/null 2>&1 || exit 0
answers "$AGENT" || log "nothing answers at $AGENT; is the restricted agent running on the host?"
for sock in "$AGENT" "${TMPDIR:-/tmp}"/vscode-ssh-auth-*.sock; do
	if [ -S "$sock" ] && answers "$sock" && takes_keys "$sock"; then
		alarm "$sock"
	fi
done
exit 0
