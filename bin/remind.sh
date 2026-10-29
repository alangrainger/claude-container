#!/usr/bin/env bash
#
# remind - one-shot reminders that the forge poller delivers at a set minute.
#
# Usage: remind <repo> '<YYYY-MM-DD HH:MM>' '<prompt>'   add; prints the id
#        remind list                                     show all reminders
#        remind cancel <id>                              remove one
#
# The prompt is one line and must not start with '-'. A backslash in it is
# delivered as '\\'. Times are read and shown in this container's TZ.
#
# Reminders live in $REMINDERS_FILE (default ~/.claude/reminders.json), a JSON array
# of {id, repo, at, prompt}; `at` is a unix time. The poller (mention-poller.sh,
# ENABLE_REMINDERS=1) types the prompt into the repo's session once the time has
# passed and the session is idle, and removes the reminder only after that, so a
# failed delivery retries on the next tick.
set -euo pipefail

FILE="${REMINDERS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/reminders.json}"
die() { printf 'remind: %s\n' "$1" >&2; exit "${2:-1}"; }

# Serialise every write with the poller (flock on a sidecar file).
lock() { exec 9>"$FILE.lock"; flock 9; }

# Atomic write of the array on stdin.
save() {
  local tmp; tmp="$(mktemp "$FILE.XXXXXX")"
  cat > "$tmp" && mv "$tmp" "$FILE"
}

[ -s "$FILE" ] || printf '[]\n' > "$FILE"

case "${1:-}" in
  list)
    jq -r '.[] | [.id, (.at | strflocaltime("%Y-%m-%d %H:%M")), .repo, .prompt] | @tsv' "$FILE" \
      | awk -F'\t' 'BEGIN{n=0}{printf "%s  %s  %-20s %s\n",$1,$2,$3,$4; n++}END{if(!n)print "no reminders"}'
    ;;
  cancel)
    id="${2:?usage: remind cancel <id>}"
    lock
    jq -e --arg id "$id" 'map(select(.id == $id)) | length > 0' "$FILE" >/dev/null || die "no reminder $id"
    jq --arg id "$id" 'map(select(.id != $id))' "$FILE" | save
    echo "cancelled $id"
    ;;
  ''|-h|--help)
    sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0
    ;;
  *)
    repo="$1"; when="${2:?usage: remind <repo> '<YYYY-MM-DD HH:MM>' '<prompt>'}"
    prompt="${3:?usage: remind <repo> '<YYYY-MM-DD HH:MM>' '<prompt>'}"
    case "$repo" in *[!A-Za-z0-9._-]*|''|.|..) die "bad repo name '$repo'" 2 ;; esac
    case "$prompt" in -*) die "prompt must not start with '-'" 2 ;; *$'\n'*) die "prompt must be one line" 2 ;; esac
    at="$(date -d "$when" +%s 2>/dev/null)" || die "bad time '$when' (use 'YYYY-MM-DD HH:MM')" 2
    [ "$at" -gt "$(date +%s)" ] || die "time '$when' is in the past" 2
    id="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    lock
    jq --arg id "$id" --arg repo "$repo" --argjson at "$at" --arg p "$prompt" \
       '. + [{id:$id, repo:$repo, at:$at, prompt:$p}]' "$FILE" | save
    printf 'reminder %s set for %s in %s\n' "$id" "$(date -d "@$at" '+%Y-%m-%d %H:%M %Z')" "$repo"
    ;;
esac
