#!/bin/sh
# ntfy-hooks - universal notification hook for coding agents.
#
# Sends an ntfy.sh push notification when a coding agent needs your attention
# or finishes a turn. It understands the two payload conventions in the wild:
#
#   * Claude Code  - hook JSON arrives on STDIN.
#   * Codex        - hook JSON is the LAST command-line argument (the `notify`
#                    program is called as: notify '<json>').
#
# Any other tool that delivers a JSON event on stdin or as the final argument
# works too. Configuration is read from (first wins):
#
#   1. Environment variables (NTFY_TOPIC, NTFY_URL, ...).
#   2. $NTFY_HOOKS_CONFIG, else $XDG_CONFIG_HOME/ntfy-hooks/config
#      (~/.config/ntfy-hooks/config).
#
# This script never fails the calling agent: every path exits 0.

# Be strict, but stay POSIX. (No pipefail - not portable to /bin/sh.)
set -u

# --- Load configuration -----------------------------------------------------

CONFIG_FILE="${NTFY_HOOKS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ntfy-hooks/config}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NTFY_PRIORITY="${NTFY_PRIORITY:-}"
NTFY_CLICK="${NTFY_CLICK:-}"
NTFY_QUIET="${NTFY_QUIET:-}"

# Opt-out switch.
case "$NTFY_QUIET" in
  1 | true | yes | on) exit 0 ;;
esac

# --- Read the event payload -------------------------------------------------
# Codex passes the JSON as the last positional argument; Claude Code (and
# friends) pipe it on stdin.

INPUT=""
if [ "$#" -gt 0 ]; then
  for INPUT in "$@"; do :; done # INPUT ends up as the last argument
else
  INPUT="$(cat 2>/dev/null || true)"
fi

# --- Helpers ----------------------------------------------------------------

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

have_curl=0
command -v curl >/dev/null 2>&1 && have_curl=1
have_wget=0
command -v wget >/dev/null 2>&1 && have_wget=1

# json <filter> - extract a value from the payload, empty string on any error.
json() {
  [ "$have_jq" -eq 1 ] || return 0
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || true
}

# http_post <url> <body> [header...] - POST via curl or wget (whichever exists).
# Each header is a literal "Key: Value" string. Returns nonzero if no HTTP
# client is available or the request fails.
http_post() {
  url="$1"
  body="$2"
  shift 2
  hcount="$#" # remaining args are headers
  if [ "$have_curl" -eq 1 ]; then
    while [ "$hcount" -gt 0 ]; do
      h="$1"
      shift
      set -- "$@" -H "$h"
      hcount=$((hcount - 1))
    done
    curl -fsS -m 10 "$@" -d "$body" "$url" >/dev/null 2>&1
  elif [ "$have_wget" -eq 1 ]; then
    while [ "$hcount" -gt 0 ]; do
      h="$1"
      shift
      set -- "$@" --header="$h"
      hcount=$((hcount - 1))
    done
    wget -q -O /dev/null --timeout=10 --tries=1 "$@" --post-data="$body" "$url" >/dev/null 2>&1
  else
    return 127
  fi
}

# desktop_fallback <message> - best-effort local desktop notification.
# Supports macOS (osascript) and Linux/BSD desktops (notify-send); a no-op
# elsewhere (e.g. headless servers).
desktop_fallback() {
  if command -v osascript >/dev/null 2>&1; then
    # Escape backslashes then double quotes for the AppleScript string literal.
    msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "display notification \"$msg\" with title \"ntfy-hooks\"" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "ntfy-hooks" "$1" 2>/dev/null || true
  fi
}

# --- Derive notification fields ---------------------------------------------

EVENT="$(json '.hook_event_name')" # Claude Code
TYPE="$(json '.type')"             # Codex
CWD="$(json '.cwd')"
HOOK_TITLE="$(json '.title')" # explicit override, if a caller sets it
EXPLICIT_MSG="$(json '.message')"

PROJECT=""
if [ -n "$CWD" ]; then
  PROJECT="$(basename "$CWD" 2>/dev/null || true)"
fi

AGENT=""
MESSAGE=""
TAGS=""
PRIORITY=""

if [ -n "$EVENT" ]; then
  # ---- Claude Code -----------------------------------------------------
  AGENT="Claude Code"
  case "$EVENT" in
    Notification)
      MESSAGE="${EXPLICIT_MSG:-Waiting for your input}"
      case "$(json '.notification_type')" in
        permission*)
          TAGS="lock"
          PRIORITY="high"
          ;;
        idle*) TAGS="zzz" ;;
        *) TAGS="bell" ;;
      esac
      ;;
    Stop | SubagentStop)
      MESSAGE="${EXPLICIT_MSG:-Finished responding}"
      TAGS="white_check_mark"
      ;;
    PermissionRequest)
      tool="$(json '.tool_name')"
      MESSAGE="Needs permission${tool:+: $tool}"
      TAGS="lock"
      PRIORITY="high"
      ;;
    PreCompact)
      MESSAGE="Compacting context"
      TAGS="compression"
      ;;
    SessionEnd)
      MESSAGE="${EXPLICIT_MSG:-Session ended}"
      TAGS="checkered_flag"
      ;;
    *)
      MESSAGE="${EXPLICIT_MSG:-$EVENT}"
      TAGS="bell"
      ;;
  esac
elif [ -n "$TYPE" ]; then
  # ---- Codex -----------------------------------------------------------
  AGENT="Codex"
  case "$TYPE" in
    agent-turn-complete)
      MESSAGE="$(json '.["last-assistant-message"]')"
      [ -n "$MESSAGE" ] || MESSAGE="Turn complete"
      TAGS="white_check_mark"
      ;;
    approval-requested)
      MESSAGE="Needs approval"
      TAGS="lock"
      PRIORITY="high"
      ;;
    plan-mode-prompt)
      MESSAGE="Plan ready for review"
      TAGS="memo"
      ;;
    *)
      MESSAGE="$TYPE"
      TAGS="bell"
      ;;
  esac
else
  # ---- Unknown / jq-less fallback --------------------------------------
  AGENT=""
  MESSAGE="${EXPLICIT_MSG:-Agent needs your attention}"
  TAGS="bell"
fi

# Allow config/env to force a priority.
[ -n "$NTFY_PRIORITY" ] && PRIORITY="$NTFY_PRIORITY"

# Build the title.
if [ -n "$HOOK_TITLE" ]; then
  TITLE="$HOOK_TITLE"
elif [ -n "$AGENT" ] && [ -n "$PROJECT" ]; then
  TITLE="$AGENT ($PROJECT)"
elif [ -n "$AGENT" ]; then
  TITLE="$AGENT"
elif [ -n "$PROJECT" ]; then
  TITLE="$PROJECT"
else
  TITLE="ntfy-hooks"
fi

# Keep the body to a sane length for a push notification.
if [ "${#MESSAGE}" -gt 2000 ]; then
  MESSAGE="$(printf '%.2000s' "$MESSAGE")…"
fi

# --- Require a topic --------------------------------------------------------

if [ -z "$NTFY_TOPIC" ]; then
  desktop_fallback "NTFY_TOPIC is not set - run the ntfy-hooks installer"
  exit 0
fi

# --- Send -------------------------------------------------------------------

# Collect headers as literal "Key: Value" strings; http_post adapts them to the
# available client (curl or wget).
set -- "Title: $TITLE"
[ -n "$TAGS" ] && set -- "$@" "Tags: $TAGS"
[ -n "$PRIORITY" ] && set -- "$@" "Priority: $PRIORITY"
[ -n "$NTFY_CLICK" ] && set -- "$@" "Click: $NTFY_CLICK"
[ -n "$NTFY_TOKEN" ] && set -- "$@" "Authorization: Bearer $NTFY_TOKEN"

# If the push can't be delivered (no client or network failure), make a
# best-effort local notification so the event isn't silently lost.
http_post "${NTFY_URL%/}/$NTFY_TOPIC" "$MESSAGE" "$@" || desktop_fallback "$MESSAGE"

exit 0
