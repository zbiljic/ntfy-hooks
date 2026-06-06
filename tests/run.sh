#!/bin/sh
# Offline test suite for ntfy-hooks.
#
# - ntfy.sh is exercised with a fake `curl` on PATH that records the request,
#   so nothing hits the network.
# - install.sh is run against a throwaway HOME with --no-test, then checked for
#   idempotency and a clean uninstall.
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() {
  # check <description> <needle> <file>
  if grep -Fq "$2" "$3"; then pass "$1"; else
    fail "$1"
    printf '       expected to find: %s\n' "$2"
    printf '       in:\n'; sed 's/^/         /' "$3"
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Fake curl that records the request -------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
CURL_LOG="$WORK/curl.log"
cat >"$BIN/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CURL_LOG"
exit 0
EOF
chmod +x "$BIN/curl"

run_hook_stdin() { : >"$CURL_LOG"; printf '%s' "$1" | env PATH="$BIN:$PATH" NTFY_TOPIC=testtopic NTFY_HOOKS_CONFIG=/dev/null sh "$ROOT/ntfy.sh"; }
echo "ntfy.sh — Claude Code (stdin)"
run_hook_stdin '{"hook_event_name":"Stop","cwd":"/home/u/myproj"}'
check "Stop: title carries project"      "Title: Claude Code (myproj)" "$CURL_LOG"
check "Stop: finished message"           "Finished responding"          "$CURL_LOG"
check "Stop: topic in url"               "testtopic"                    "$CURL_LOG"

run_hook_stdin '{"hook_event_name":"Notification","cwd":"/home/u/myproj","message":"Need your input","notification_type":"permission_prompt"}'
check "Notification: custom message"     "Need your input"              "$CURL_LOG"
check "Notification: high priority"      "Priority: high"               "$CURL_LOG"

run_hook_stdin '{"hook_event_name":"PermissionRequest","cwd":"/home/u/myproj","tool_name":"Bash"}'
check "PermissionRequest: names tool"    "Needs permission: Bash"       "$CURL_LOG"
check "PermissionRequest: lock tag"      "Tags: lock"                   "$CURL_LOG"

echo "ntfy.sh — Codex lifecycle hooks (stdin)"
run_hook_stdin '{"hook_event_name":"Stop","model":"gpt-5","cwd":"/home/u/codexproj","last_assistant_message":"Lifecycle done"}'
check "Codex hook Stop: title carries project" "Title: Codex (codexproj)" "$CURL_LOG"
check "Codex hook Stop: message"               "Lifecycle done"           "$CURL_LOG"

run_hook_stdin '{"hook_event_name":"PermissionRequest","model":"gpt-5","cwd":"/home/u/codexproj","tool_name":"Bash","tool_input":{"description":"network access"}}'
check "Codex hook PermissionRequest: approval" "Needs approval: Bash - network access" "$CURL_LOG"
check "Codex hook PermissionRequest: high"     "Priority: high"                        "$CURL_LOG"

echo "ntfy.sh — opt out + missing topic"
: >"$CURL_LOG"
printf '%s' '{"hook_event_name":"Stop"}' | env PATH="$BIN:$PATH" NTFY_TOPIC=testtopic NTFY_QUIET=1 NTFY_HOOKS_CONFIG=/dev/null sh "$ROOT/ntfy.sh"
if [ -s "$CURL_LOG" ]; then fail "NTFY_QUIET suppresses send"; else pass "NTFY_QUIET suppresses send"; fi
: >"$CURL_LOG"
printf '%s' '{"hook_event_name":"Stop"}' | env PATH="$BIN:$PATH" NTFY_TOPIC= NTFY_HOOKS_CONFIG=/dev/null sh "$ROOT/ntfy.sh"
if [ -s "$CURL_LOG" ]; then fail "no topic → no send"; else pass "no topic → no send"; fi

# --- wget fallback (no curl on PATH) ----------------------------------------
# Build a curated PATH with a fake wget but no curl, symlinking only the real
# tools the hook needs at runtime so curl genuinely can't be found.
echo "ntfy.sh — wget fallback (no curl)"
WGBIN="$WORK/wgbin"
mkdir -p "$WGBIN"
WGET_LOG="$WORK/wget.log"
cat >"$WGBIN/wget" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WGET_LOG"
exit 0
EOF
chmod +x "$WGBIN/wget"
for t in sh cat jq basename; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$WGBIN/$t"
done
: >"$WGET_LOG"
printf '%s' '{"hook_event_name":"Stop","cwd":"/home/u/myproj"}' \
  | env PATH="$WGBIN" NTFY_TOPIC=testtopic NTFY_HOOKS_CONFIG=/dev/null sh "$ROOT/ntfy.sh"
check "wget: posts body"        "Finished responding"          "$WGET_LOG"
check "wget: header translated" "header=Title: Claude Code (myproj)" "$WGET_LOG"
check "wget: topic in url"      "testtopic"                    "$WGET_LOG"

# --- install.sh against a throwaway environment -----------------------------
echo "install.sh — wire / idempotency / uninstall"
H="$WORK/home"
mkdir -p "$H/.claude" "$H/.codex"
printf '{"model":"opusplan","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/existing/other.sh"}]}]}}\n' >"$H/.claude/settings.json"
printf '# my codex config\nnotify = ["%s"]\nmodel = "gpt-5"\n' "$H/.config/ntfy-hooks/ntfy.sh" >"$H/.codex/config.toml"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/existing/session.sh"}]}]}}\n' >"$H/.codex/hooks.json"

env HOME="$H" XDG_CONFIG_HOME="$H/.config" \
  CLAUDE_SETTINGS="$H/.claude/settings.json" CODEX_CONFIG="$H/.codex/config.toml" \
  CODEX_HOOKS="$H/.codex/hooks.json" \
  sh "$ROOT/install.sh" --topic instopic --claude --codex --no-test >/dev/null

HOOK="$H/.config/ntfy-hooks/ntfy.sh"
if [ -x "$HOOK" ]; then pass "hook installed + executable"; else fail "hook installed + executable"; fi
check "config has topic"                 'NTFY_TOPIC="instopic"'        "$H/.config/ntfy-hooks/config"
check "claude: preserved existing hook"  "/existing/other.sh"           "$H/.claude/settings.json"
check "claude: wired our hook"           "$HOOK"                         "$H/.claude/settings.json"
check "codex: preserved existing hook"   "/existing/session.sh"          "$H/.codex/hooks.json"
check "codex: hooks wired"               "$HOOK"                         "$H/.codex/hooks.json"
check "codex: permission matcher"        '"matcher": "*"'                "$H/.codex/hooks.json"
check "codex: preserved existing key"    'model = "gpt-5"'              "$H/.codex/config.toml"
if grep -Fq 'notify = ' "$H/.codex/config.toml"; then fail "codex: old notify removed"; else pass "codex: old notify removed"; fi

printf 'notify = ["/other/wrapper", "--previous-notify", "[\\"%s\\"]"]\nmodel = "gpt-5"\n' "$HOOK" >"$H/.codex/config.toml"
env HOME="$H" XDG_CONFIG_HOME="$H/.config" \
  CLAUDE_SETTINGS="$H/.claude/settings.json" CODEX_CONFIG="$H/.codex/config.toml" \
  CODEX_HOOKS="$H/.codex/hooks.json" \
  sh "$ROOT/install.sh" --topic instopic --no-claude --codex --no-test >/dev/null
check "codex: preserves wrapper notify chain" '/other/wrapper'          "$H/.codex/config.toml"

# Run again — must not duplicate.
env HOME="$H" XDG_CONFIG_HOME="$H/.config" \
  CLAUDE_SETTINGS="$H/.claude/settings.json" CODEX_CONFIG="$H/.codex/config.toml" \
  CODEX_HOOKS="$H/.codex/hooks.json" \
  sh "$ROOT/install.sh" --topic instopic --claude --codex --no-test >/dev/null

COUNT=$(grep -Fc "$HOOK" "$H/.claude/settings.json" || true)
if [ "$COUNT" = "3" ]; then pass "claude: idempotent (3 events, no dupes)"; else fail "claude: idempotent (got $COUNT occurrences, want 3)"; fi
NCOUNT=$(grep -Fc "$HOOK" "$H/.codex/hooks.json" || true)
if [ "$NCOUNT" = "2" ]; then pass "codex: idempotent (2 events, no dupes)"; else fail "codex: idempotent (got $NCOUNT occurrences, want 2)"; fi

# Uninstall.
env HOME="$H" XDG_CONFIG_HOME="$H/.config" \
  CLAUDE_SETTINGS="$H/.claude/settings.json" CODEX_CONFIG="$H/.codex/config.toml" \
  CODEX_HOOKS="$H/.codex/hooks.json" \
  sh "$ROOT/install.sh" --uninstall >/dev/null

if [ -e "$HOOK" ]; then fail "uninstall removes hook"; else pass "uninstall removes hook"; fi
if grep -Fq "$HOOK" "$H/.claude/settings.json"; then fail "uninstall cleans claude"; else pass "uninstall cleans claude"; fi
check "uninstall keeps other claude hook" "/existing/other.sh"          "$H/.claude/settings.json"
if grep -Fq "$HOOK" "$H/.codex/hooks.json"; then fail "uninstall cleans codex"; else pass "uninstall cleans codex"; fi
check "uninstall keeps other codex hook" "/existing/session.sh"         "$H/.codex/hooks.json"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
