# ntfy-hooks

**Push notifications from your coding agents to your phone, via
[ntfy](https://ntfy.sh) - set up in one line.**

`ntfy-hooks` is a tiny, portable shell hook that fires an [ntfy](https://ntfy.sh)
notification when a coding agent needs your attention (a permission/approval
prompt) or finishes a turn. One script understands **Claude Code** and **Codex**
hook events today, and anything else that can call a command with a JSON event
on stdin.

No daemon, no binary to build, no wrapper around your agent. Just a hook and a
config file.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/zbiljic/ntfy-hooks/main/install.sh | sh
```

The installer:

1. Drops the hook at `~/.config/ntfy-hooks/ntfy.sh`.
2. Asks for your ntfy server, topic, and optional token, then writes them to
   `~/.config/ntfy-hooks/config`.
3. Auto-detects and wires every supported agent it finds
   (`~/.claude`, `~/.codex`).
4. Sends a test notification so you can confirm it works.

Re-running is safe: it updates the installed hook, checks the agent wiring, and
never duplicates existing hooks. In interactive mode, existing config values are
shown as defaults; press Enter to keep them. In non-interactive mode (`-y`), the
existing config is reused automatically unless flags or environment variables
override it.

> **Then subscribe to your topic** in the ntfy [app](https://ntfy.sh/app)
> (iOS/Android) or at `https://ntfy.sh/<your-topic>`. The topic name is the only
> secret - anyone who knows it can read your notifications, so keep it private.

### From a checkout

```bash
git clone https://github.com/zbiljic/ntfy-hooks
cd ntfy-hooks
./install.sh                               # interactive
./install.sh --topic my-topic -y           # non-interactive
./install.sh --server https://ntfy.example # self-hosted server
```

### Flags

```
--topic <name>     ntfy topic
                   (default: $NTFY_TOPIC, existing config, or random)
--server <url>     ntfy server
                   (default: $NTFY_URL, existing config, or https://ntfy.sh)
--token <token>    ntfy token
                   (default: $NTFY_TOKEN or existing config)
--claude | --no-claude    force / skip Claude Code wiring
--codex  | --no-codex     force / skip Codex wiring
--no-test          don't send a test notification
--uninstall        remove wiring and the installed hook
-y, --yes          non-interactive
-h, --help         full help
```

## What you get notified about

| Agent           | Event                | Title                  | Priority |
| --------------- | -------------------- | ---------------------- | -------- |
| **Claude Code** | `Stop`               | finished responding    | default  |
|                 | `Notification`       | waiting / idle prompt  | high\*   |
|                 | `PermissionRequest`  | needs permission       | high     |
| **Codex**       | `Stop`               | turn complete          | default  |
|                 | `PermissionRequest`  | needs approval         | high     |

\* high when the notification is a permission prompt.

Titles include the project directory name, e.g. `Claude Code (my-repo)`.

## Configuration

At runtime, the hook reads `~/.config/ntfy-hooks/config` (a shell file), and
these environment variables can override it:

| Variable        | Default            | Meaning                                   |
| --------------- | ------------------ | ----------------------------------------- |
| `NTFY_TOPIC`    | - (required)       | the ntfy topic to publish to              |
| `NTFY_URL`      | `https://ntfy.sh`  | ntfy server                               |
| `NTFY_TOKEN`    | -                  | token for protected servers               |
| `NTFY_PRIORITY` | -                  | force a priority for every message        |
| `NTFY_CLICK`    | -                  | URL opened when the notification is tapped|
| `NTFY_QUIET`    | -                  | set to `1` to mute all notifications      |

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/zbiljic/ntfy-hooks/main/install.sh | sh -s -- --uninstall
```

This removes the hook and unwires the agents but leaves your `config` (so you
keep your topic). Delete `~/.config/ntfy-hooks/` to remove that too.

## How it works

The hook detects which agent called it by where the JSON event arrives:

- **Claude Code** pipes the event to the hook on **stdin**.
- **Codex** pipes lifecycle-hook events to the hook on **stdin** via
  `~/.codex/hooks.json`.

It then maps the event to a title/message/priority and `POST`s to ntfy with
`curl`. The hook is defensive by design: missing topic, missing `jq`, or a
network error never fails the calling agent (it always exits `0`).

## Requirements

- `curl` and `jq` (jq is used to parse the event payload; without it the hook
  still sends a generic notification).
- `bash`/`sh`, macOS or Linux.

## Development

This repo uses [mise](https://mise.jdx.dev) for tooling and tasks. Run
`mise install` once to get `shellcheck` and `shfmt`, then:

```bash
mise run shellcheck:lint   # shellcheck
mise run test              # offline test suite (fake curl, throwaway HOME)
mise run shfmt:fmt         # shfmt (optional)
mise run check             # shfmt:check + shellcheck:lint
mise run validate          # check + test
mise tasks                 # list all tasks
```

## License

MIT © Nemanja Zbiljić
