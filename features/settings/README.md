# Settings (settings)

Inject your own settings into the per-user configuration files inside a devcontainer. This provides
a means to, for example, turn down Claude security settings only for containerized environments.
There are two providers:

| Option   | File in the container                        | Scope                                  |
| -------- | -------------------------------------------- | -------------------------------------- |
| `vscode` | `~/.vscode-server/data/Machine/settings.json` | VS Code "Remote [Dev Container]" settings |
| `claude` | `~/.claude/settings.json`                    | Claude Code user settings              |

## Example Usage

```json
"features": {
    "ghcr.io/laverdet/devcontainer/features/settings:1": {
        "vscode": "\"'{\"claudeCode.allowDangerouslySkipPermissions\": true, \"claudeCode.environmentVariables\": [{\"name\": \"IS_SANDBOX\", \"value\": \"1\"}]}'\"",
        "claude": "\"'{\"permissions\": {\"defaultMode\": \"auto\"}}'\""
    }
}
```

Each option is a JSON object wrapped in `"'{...}'"`. devcontainers has improperly implemented shell
escaping so the outer quotes are a workaround for that. If you have a plain single-quote `'` in the
JSON it should be escaped as `'\\''`. See: ([devcontainers/cli#1324](https://github.com/devcontainers/cli/issues/1324)).

You can enable the feature for every devcontainer in VS Code by adding it to your user `settings.json`:

```json
"dev.containers.defaultFeatures": {
  "ghcr.io/laverdet/devcontainer/features/settings:1": {
    // [...]
  }
}
```
