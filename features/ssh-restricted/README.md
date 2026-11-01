# Restricted SSH agent (ssh-restricted)

Containers get the SSH keys in `~/.ssh/restricted` and nothing else.

There is actually [no way](https://github.com/microsoft/vscode-remote-release/issues/9466) to reliably prevent VS Code
from forwarding `SSH_AUTH_SOCK` into containers. So actually most of the work of this feature is in a host-side agent
that you have to install yourself. The devcontainer feature itself is only a failsafe, which kicks and screams if your
real keychain has found its way into the container.

## Example Usage

```json
"features": {
    "ghcr.io/laverdet/devcontainer/features/ssh-restricted:1": {}
}
```

## Setup

macOS only, but patches are welcome.

The host side is a launchd job that puts a read-only proxy in front of your ssh-agent. The proxy takes over
`SSH_AUTH_SOCK` and the agent itself becomes `SSH_UNFILTERED_AUTH_SOCK`. The proxy is
[ssh-agent-filter](https://git.tiwe.de/ssh-agent-filter.git), which passes sign requests through for the keys it was
started with and refuses everything else. Install it from [everpeace's
tap](https://github.com/everpeace/homebrew-ssh-agent-filter):

```sh
brew tap everpeace/ssh-agent-filter
brew trust --formula everpeace/ssh-agent-filter/ssh-agent-filter
brew install ssh-agent-filter
```

Then the agent (`--keys DIR` for a key directory other than `~/.ssh/restricted`):

```sh
curl -fsSL https://github.com/laverdet/devcontainer/releases/latest/download/ssh-agent-install.sh | sh -s -- add

# to uninstall:
# curl -fsSL https://github.com/laverdet/devcontainer/releases/latest/download/ssh-agent-install.sh | sh -s -- remove
```

---

From then on launchd sets two variables in every login session before any app starts:

- `SSH_AUTH_SOCK`: The proxy. This is what VS Code forwards into containers.
- `SSH_UNFILTERED_AUTH_SOCK`: Your agent, with your own keys.

You can enable the feature for every devcontainer in VS Code by adding it to your user `settings.json`:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/laverdet/devcontainer/features/ssh-restricted:1": {}
}
```

---

In `~/.ssh/config`, you can ensure that commands which run locally use the unfiltered agent:

```
Host *
    IdentityAgent $SSH_UNFILTERED_AUTH_SOCK
```

## Your shell

You may consider setting `SSH_AUTH_SOCK` in your local terminal environment. If you do this you should take care to
prevent VS Code from seeing it. VS Code resolves its environment with an interactive shell, so anything in your rc files
might make it into that environment. So consider something like this in `~/.profile` instead (or just skip this step).

```sh
[ -n "$VSCODE_RESOLVING_ENVIRONMENT" ] || export SSH_AUTH_SOCK=$SSH_UNFILTERED_AUTH_SOCK
```

## Keys

Put private keys in `~/.ssh/restricted`, each with its public key next to it (example: `id_rsa` and `id_rsa.pub`), and
restart the proxy; it loads the directory into your agent and passes exactly those keys:

```sh
launchctl kickstart -k gui/$(id -u)/com.laverdet.devcontainer-ssh-agent.restricted
```

A key with a passphrase needs it in the keychain. Add the key once by hand, then restart:

```sh
ssh-add --apple-use-keychain ~/.ssh/restricted/KEY
```

The log is `~/Library/Logs/devcontainer-ssh-agent.log`.
