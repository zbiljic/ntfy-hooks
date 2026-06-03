# ntfy-hooks

**Push notifications from your coding agents to your phone, via [ntfy](https://ntfy.sh) - set up in one line.**

`ntfy-hooks` is a tiny, portable shell hook that fires an [ntfy](https://ntfy.sh)
notification when a coding agent needs your attention (a permission/approval
prompt) or finishes a turn. One script understands both major payload
conventions, so the same hook works for **Claude Code** and **Codex** today, and
anything else that can call a command on an event.

No daemon, no binary to build, no wrapper around your agent. Just a hook and a
config file.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/zbiljic/ntfy-hooks/main/install.sh | sh
```

The installer:

1. Drops the hook at `~/.config/ntfy-hooks/ntfy.sh`.
2. Asks for (or generates) a private ntfy **topic** and writes it to
   `~/.config/ntfy-hooks/config`.
3. Auto-detects and wires every supported agent it finds
   (`~/.claude`, `~/.codex`).
4. Sends a test notification so you can confirm it works.

Re-running is safe - it never duplicates existing wiring.

> **Then subscribe to your topic** in the ntfy [app](https://ntfy.sh/app)
> (iOS/Android) or at `https://ntfy.sh/<your-topic>`. The topic name is the only
> secret - anyone who knows it can read your notifications, so keep it private.

### From a checkout

```bash
git clone https://github.com/zbiljic/ntfy-hooks
cd ntfy-hooks
./install.sh                       # interactive
./install.sh --topic my-topic -y   # non-interactive
```

### Flags

```
--topic <name>     ntfy topic (default: $NTFY_TOPIC or a random private one)
--server <url>     ntfy server (default: https://ntfy.sh)
--token <token>    bearer token for protected / self-hosted servers
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
| **Codex**       | `agent-turn-complete`| turn complete          | default  |
|                 | `approval-requested` | needs approval         | high     |

\* high when the notification is a permission prompt.

Titles include the project directory name, e.g. `Claude Code (my-repo)`.

## Configuration

Everything is read from `~/.config/ntfy-hooks/config` (a shell file the hook
sources), and can be overridden by environment variables:

| Variable        | Default            | Meaning                                   |
| --------------- | ------------------ | ----------------------------------------- |
| `NTFY_TOPIC`    | - (required)       | the ntfy topic to publish to              |
| `NTFY_URL`      | `https://ntfy.sh`  | ntfy server                               |
| `NTFY_TOKEN`    | -                  | bearer token for protected servers        |
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
- **Codex** passes the event as the **last command-line argument** to the
  program named in its `notify` setting.

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
