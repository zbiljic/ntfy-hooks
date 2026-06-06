#!/bin/sh
# ntfy-hooks installer.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/zbiljic/ntfy-hooks/main/install.sh | sh
#
# From a checkout:
#   ./install.sh [flags]
#
# It installs the universal ntfy.sh hook, writes a config file with your topic,
# and wires the hook into every supported coding agent it finds (Claude Code,
# Codex). Re-running is safe - it never duplicates existing wiring.
set -eu

APP="ntfy-hooks"
REPO="zbiljic/ntfy-hooks"
REPO_RAW="https://raw.githubusercontent.com/${REPO}/main"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ntfy-hooks"
HOOK_PATH="${NTFY_HOOK_PATH:-$CONFIG_DIR/ntfy.sh}"
CONFIG_FILE="$CONFIG_DIR/config"

CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
CODEX_HOOKS="${CODEX_HOOKS:-$HOME/.codex/hooks.json}"

# Defaults overridable by env or flags.
NTFY_SERVER="${NTFY_URL:-https://ntfy.sh}"
TOPIC="${NTFY_TOPIC:-}"
TOKEN="${NTFY_TOKEN:-}"
ENV_NTFY_URL="${NTFY_URL+x}"
ENV_NTFY_TOPIC="${NTFY_TOPIC+x}"
ENV_NTFY_TOKEN="${NTFY_TOKEN+x}"

ACTION="install"
DO_CLAUDE="auto"
DO_CODEX="auto"
DO_TEST="auto"
ASSUME_YES=0

# --- Output helpers ---------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$(printf '\033[0m')
  C_DIM=$(printf '\033[2m')
  C_BLUE=$(printf '\033[34m')
  C_GREEN=$(printf '\033[32m')
  C_YELLOW=$(printf '\033[33m')
else
  C_RESET=""
  C_DIM=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf 'error: %s\n' "$*" >&2; }
die() {
  err "$*"
  exit 1
}

usage() {
  cat <<EOF
${APP} - wire ntfy.sh push notifications into coding-agent hooks.

Usage:
  install.sh [flags]
  curl -fsSL ${REPO_RAW}/install.sh | sh -s -- [flags]

Flags:
  --topic <name>     ntfy topic to publish to (default: \$NTFY_TOPIC,
                     existing config, or random)
  --server <url>     ntfy server (default: ${NTFY_SERVER})
  --token <token>    bearer token for protected/self-hosted servers
  --claude           force-enable Claude Code wiring
  --no-claude        skip Claude Code wiring
  --codex            force-enable Codex wiring
  --no-codex         skip Codex wiring
  --no-test          do not send a test notification
  --hook-path <p>    where to install ntfy.sh (default: ${HOOK_PATH})
  --uninstall        remove wiring and the installed hook
  -y, --yes          non-interactive; never prompt
  -h, --help         show this help

Environment:
  NTFY_TOPIC, NTFY_URL, NTFY_TOKEN   pre-seed configuration
  CLAUDE_SETTINGS, CODEX_CONFIG,
  CODEX_HOOKS                        override config paths (testing)
EOF
}

load_existing_config() {
  [ -f "$CONFIG_FILE" ] || return 0

  cfg_url=""
  cfg_topic=""
  cfg_token=""
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  cfg_url="${NTFY_URL:-}"
  cfg_topic="${NTFY_TOPIC:-}"
  cfg_token="${NTFY_TOKEN:-}"

  if [ -z "$ENV_NTFY_URL" ] && [ -n "$cfg_url" ]; then NTFY_SERVER="$cfg_url"; fi
  if [ -z "$ENV_NTFY_TOPIC" ] && [ -n "$cfg_topic" ]; then TOPIC="$cfg_topic"; fi
  if [ -z "$ENV_NTFY_TOKEN" ] && [ -n "$cfg_token" ]; then TOKEN="$cfg_token"; fi
}

load_existing_config

# --- Argument parsing -------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --topic)
      TOPIC="${2:?--topic needs a value}"
      shift 2
      ;;
    --server)
      NTFY_SERVER="${2:?--server needs a value}"
      shift 2
      ;;
    --token)
      TOKEN="${2:?--token needs a value}"
      shift 2
      ;;
    --hook-path)
      HOOK_PATH="${2:?--hook-path needs a value}"
      shift 2
      ;;
    --claude)
      DO_CLAUDE="yes"
      shift
      ;;
    --no-claude)
      DO_CLAUDE="no"
      shift
      ;;
    --codex)
      DO_CODEX="yes"
      shift
      ;;
    --no-codex)
      DO_CODEX="no"
      shift
      ;;
    --no-test)
      DO_TEST="no"
      shift
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    -y | --yes)
      ASSUME_YES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

# --- Preconditions ----------------------------------------------------------

have_curl=0
if command -v curl >/dev/null 2>&1; then have_curl=1; fi
have_wget=0
if command -v wget >/dev/null 2>&1; then have_wget=1; fi
[ "$have_curl" -eq 1 ] || [ "$have_wget" -eq 1 ] || die "curl or wget is required"
have_jq=0
if command -v jq >/dev/null 2>&1; then have_jq=1; fi

# Locate a local ntfy.sh next to this script (checkout install), else download.
SRC_DIR=""
case "$0" in
  */*) SRC_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" 2>/dev/null && pwd
  ) || SRC_DIR="" ;;
esac

# --- Generic helpers --------------------------------------------------------

backup() {
  # backup <file> - copy to file.bak.<timestamp> if it exists.
  [ -f "$1" ] || return 0
  cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
}

gen_topic() {
  rand=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 20 || true)
  [ -n "$rand" ] || die "could not generate a random topic; pass --topic"
  printf 'ntfy-hooks-%s' "$rand"
}

http_get() {
  # http_get <url> <dest> - download url to dest via curl or wget.
  if [ "$have_curl" -eq 1 ]; then
    curl -fsSL "$1" -o "$2"
  else
    wget -q -O "$2" "$1"
  fi
}

http_post() {
  # http_post <url> <body> [header...] - POST via curl or wget. Each header is
  # a literal "Key: Value" string. Returns nonzero on failure.
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
  else
    while [ "$hcount" -gt 0 ]; do
      h="$1"
      shift
      set -- "$@" --header="$h"
      hcount=$((hcount - 1))
    done
    wget -q -O /dev/null --timeout=10 --tries=1 "$@" --post-data="$body" "$url" >/dev/null 2>&1
  fi
}

# --- Claude Code ------------------------------------------------------------

# jq programs - single-quoted on purpose ($arr/$cmd are jq vars, not shell).
# shellcheck disable=SC2016
CLAUDE_ADD_FILTER='
def ensure($arr):
  if any($arr[]; (.hooks // []) | any(.[]; .command == $cmd))
  then $arr
  else $arr + [ { "hooks": [ { "type": "command", "command": $cmd, "async": true } ] } ]
  end;
.hooks = (.hooks // {})
| .hooks.Stop              = ensure(.hooks.Stop // [])
| .hooks.Notification      = ensure(.hooks.Notification // [])
| .hooks.PermissionRequest = ensure(.hooks.PermissionRequest // [])
'

# shellcheck disable=SC2016
CLAUDE_DEL_FILTER='
def clean($arr):
  ($arr // [])
  | map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
  | map(select((.hooks // []) | length > 0));
.hooks = (.hooks // {})
| .hooks.Stop              = clean(.hooks.Stop)
| .hooks.Notification      = clean(.hooks.Notification)
| .hooks.PermissionRequest = clean(.hooks.PermissionRequest)
| .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
'

wire_claude() {
  if [ "$have_jq" -eq 0 ]; then
    warn "jq not found - cannot edit $CLAUDE_SETTINGS automatically."
    warn "Add a Stop/Notification/PermissionRequest command hook pointing to:"
    warn "  $HOOK_PATH"
    return 0
  fi
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  [ -f "$CLAUDE_SETTINGS" ] || printf '{}\n' >"$CLAUDE_SETTINGS"
  jq empty "$CLAUDE_SETTINGS" 2>/dev/null || die "$CLAUDE_SETTINGS is not valid JSON; fix it and re-run"
  backup "$CLAUDE_SETTINGS"
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_PATH" "$CLAUDE_ADD_FILTER" "$CLAUDE_SETTINGS" >"$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
  ok "Claude Code wired (Stop, Notification, PermissionRequest) → $CLAUDE_SETTINGS"
}

unwire_claude() {
  [ -f "$CLAUDE_SETTINGS" ] || return 0
  [ "$have_jq" -eq 1 ] || {
    warn "jq not found - edit $CLAUDE_SETTINGS by hand"
    return 0
  }
  backup "$CLAUDE_SETTINGS"
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_PATH" "$CLAUDE_DEL_FILTER" "$CLAUDE_SETTINGS" >"$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
  ok "Removed ntfy-hooks wiring from $CLAUDE_SETTINGS"
}

# --- Codex ------------------------------------------------------------------

# jq programs - single-quoted on purpose ($arr/$cmd are jq vars, not shell).
# shellcheck disable=SC2016
CODEX_ADD_FILTER='
def entry($matcher):
  ((if $matcher == "" then {} else { "matcher": $matcher } end)
   + { "hooks": [ { "type": "command", "command": $cmd, "timeout": 10, "statusMessage": "Sending ntfy notification" } ] });
def ensure($arr; $matcher):
  if any(($arr // [])[]; (.hooks // []) | any(.command == $cmd))
  then ($arr // [])
  else ($arr // []) + [ entry($matcher) ]
  end;
.hooks = (.hooks // {})
| .hooks.Stop              = ensure(.hooks.Stop; "")
| .hooks.PermissionRequest = ensure(.hooks.PermissionRequest; "*")
'

# shellcheck disable=SC2016
CODEX_DEL_FILTER='
def clean($arr):
  ($arr // [])
  | map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
  | map(select((.hooks // []) | length > 0));
.hooks = (.hooks // {})
| .hooks.Stop              = clean(.hooks.Stop)
| .hooks.PermissionRequest = clean(.hooks.PermissionRequest)
| .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
'

remove_old_codex_notify() {
  [ -f "$CODEX_CONFIG" ] || return 0
  grep -Fq "$HOOK_PATH" "$CODEX_CONFIG" 2>/dev/null || return 0

  tmp=$(mktemp)
  awk -v hook="$HOOK_PATH" '
    {
      compact = $0
      gsub(/[[:space:]]/, "", compact)
      if (compact == "notify=[\"" hook "\"]") next
      print
    }
  ' "$CODEX_CONFIG" >"$tmp"

  if ! cmp -s "$tmp" "$CODEX_CONFIG"; then
    backup "$CODEX_CONFIG"
    mv "$tmp" "$CODEX_CONFIG"
    ok "Removed old Codex notify wiring from $CODEX_CONFIG"
    return 0
  fi
  rm -f "$tmp"

  warn "Codex config mentions this hook in another notify setting; left it unchanged."
}

wire_codex() {
  if [ "$have_jq" -eq 0 ]; then
    warn "jq not found - cannot edit $CODEX_HOOKS automatically."
    warn "Add Stop and PermissionRequest command hooks pointing to:"
    warn "  $HOOK_PATH"
    return 0
  fi
  mkdir -p "$(dirname "$CODEX_HOOKS")"
  [ -f "$CODEX_HOOKS" ] || printf '{}\n' >"$CODEX_HOOKS"
  jq empty "$CODEX_HOOKS" 2>/dev/null || die "$CODEX_HOOKS is not valid JSON; fix it and re-run"
  backup "$CODEX_HOOKS"
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_PATH" "$CODEX_ADD_FILTER" "$CODEX_HOOKS" >"$tmp" && mv "$tmp" "$CODEX_HOOKS"
  ok "Codex wired (Stop, PermissionRequest) → $CODEX_HOOKS"
  remove_old_codex_notify
}

unwire_codex() {
  [ -f "$CODEX_HOOKS" ] || return 0
  [ "$have_jq" -eq 1 ] || {
    warn "jq not found - edit $CODEX_HOOKS by hand"
    return 0
  }
  grep -Fq "$HOOK_PATH" "$CODEX_HOOKS" 2>/dev/null || return 0
  backup "$CODEX_HOOKS"
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_PATH" "$CODEX_DEL_FILTER" "$CODEX_HOOKS" >"$tmp" && mv "$tmp" "$CODEX_HOOKS"
  ok "Removed ntfy-hooks wiring from $CODEX_HOOKS"
}

# --- Agent detection --------------------------------------------------------

want_claude() {
  case "$DO_CLAUDE" in
    yes) return 0 ;;
    no) return 1 ;;
    *) [ -d "$HOME/.claude" ] || [ -f "$CLAUDE_SETTINGS" ] ;;
  esac
}

want_codex() {
  case "$DO_CODEX" in
    yes) return 0 ;;
    no) return 1 ;;
    *) [ -d "$HOME/.codex" ] || [ -f "$CODEX_CONFIG" ] ;;
  esac
}

# --- Actions ----------------------------------------------------------------

do_uninstall() {
  info "Uninstalling ${APP}"
  unwire_claude
  unwire_codex
  if [ -f "$HOOK_PATH" ]; then
    rm -f "$HOOK_PATH"
    ok "Removed $HOOK_PATH"
  fi
  if [ -f "$CONFIG_FILE" ]; then
    warn "Left your config in place: $CONFIG_FILE (delete it to remove the topic)"
  fi
  ok "Done."
}

install_hook() {
  mkdir -p "$CONFIG_DIR"
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/ntfy.sh" ]; then
    cp "$SRC_DIR/ntfy.sh" "$HOOK_PATH"
    info "Installed hook from $SRC_DIR/ntfy.sh"
  else
    info "Downloading ntfy.sh from $REPO_RAW"
    http_get "$REPO_RAW/ntfy.sh" "$HOOK_PATH" || die "failed to download ntfy.sh"
  fi
  chmod +x "$HOOK_PATH"
  ok "Hook installed → $HOOK_PATH"
}

resolve_topic() {
  if [ -n "$TOPIC" ]; then return 0; fi
  if [ "$ASSUME_YES" -eq 0 ] && [ -r /dev/tty ]; then
    printf 'ntfy topic [blank = generate a random, private one]: ' >/dev/tty
    read -r TOPIC </dev/tty || TOPIC=""
  fi
  if [ -z "$TOPIC" ]; then
    TOPIC=$(gen_topic)
    info "Generated a random topic: $TOPIC"
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  backup "$CONFIG_FILE"
  (
    umask 077
    {
      printf '# %s configuration - sourced by ntfy.sh. Treat the topic as a secret.\n' "$APP"
      printf 'NTFY_URL="%s"\n' "$NTFY_SERVER"
      printf 'NTFY_TOPIC="%s"\n' "$TOPIC"
      if [ -n "$TOKEN" ]; then printf 'NTFY_TOKEN="%s"\n' "$TOKEN"; fi
    } >"$CONFIG_FILE"
  )
  ok "Wrote config → $CONFIG_FILE"
}

send_test() {
  if [ "$DO_TEST" = "no" ]; then return 0; fi
  info "Sending a test notification…"
  set -- "Title: ntfy-hooks installed" "Tags: tada"
  [ -n "$TOKEN" ] && set -- "$@" "Authorization: Bearer $TOKEN"
  if http_post "${NTFY_SERVER%/}/$TOPIC" \
    "Notifications are wired up. You'll hear from your agents here." "$@"; then
    ok "Test notification sent."
  else
    warn "Test notification failed (check connectivity / topic / token)."
  fi
}

print_summary() {
  printf '\n'
  ok "${APP} is set up."
  printf '%sSubscribe to your topic to receive notifications:%s\n' "$C_DIM" "$C_RESET"
  printf '   • Web:   %s/%s\n' "${NTFY_SERVER%/}" "$TOPIC"
  printf '   • App:   ntfy (iOS/Android) → add subscription → topic %s\n' "$TOPIC"
  printf '   • CLI:   curl -s %s/%s/json\n' "${NTFY_SERVER%/}" "$TOPIC"
  printf '\n%sConfig:%s %s\n' "$C_DIM" "$C_RESET" "$CONFIG_FILE"
  printf '%sHook:%s   %s\n' "$C_DIM" "$C_RESET" "$HOOK_PATH"
  printf '%sUninstall:%s curl -fsSL %s/install.sh | sh -s -- --uninstall\n' "$C_DIM" "$C_RESET" "$REPO_RAW"
}

# --- Main -------------------------------------------------------------------

if [ "$ACTION" = "uninstall" ]; then
  do_uninstall
  exit 0
fi

info "Installing ${APP}"
install_hook
resolve_topic
write_config

wired_any=0
if want_claude; then
  wire_claude
  wired_any=1
fi
if want_codex; then
  wire_codex
  wired_any=1
fi
if [ "$wired_any" -eq 0 ]; then
  warn "No supported agent detected (looked for ~/.claude and ~/.codex)."
  warn "Re-run with --claude and/or --codex to force wiring."
fi

send_test
print_summary
