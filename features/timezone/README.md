# Host time zone (timezone)

Keep a devcontainer's timezone in sync with the host machine.

## Example Usage

Note that there is an agent which must be installed. See: [Setup](#setup).

```json
"features": {
    "ghcr.io/laverdet/devcontainer/features/timezone:1": {}
}
```

## Setup

This feature requires a smaller watcher agent to communicate the timezone to the agent. Only macOS and Linux are
supported but if you feel like adding Windows support you can send a PR.

```sh
# install the agent
curl -fsSL https://github.com/laverdet/devcontainer/releases/latest/download/timezone-agent-install.sh | sh
```

You can enable the feature for every devcontainer in VS Code by adding it to your user `settings.json`:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/laverdet/devcontainer/features/timezone:1": {}
}
```

## Why not just mount `/etc/localtime`?

Docker resolves the symlink at container creation time. So it won't update with your host machine's timezone.
Additionally, the timezone database may be updated when the host updates it's operating system version. For example
`/etc/localtime` might resolve to `/private/var/db/timezone/tz/2026c.1.0/zoneinfo/America/Chicago`. Then at some point
in the future `2026c.1.0` could be removed and your container will now fail to start.

## Why is an agent needed?

devcontainers don't provide any way to run code on the host before running a container. So there's no practical way to
watch for updates to `/etc/localtime` locally.
