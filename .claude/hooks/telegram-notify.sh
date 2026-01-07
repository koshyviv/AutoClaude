#!/usr/bin/env bash
set -euo pipefail

# ~/.claude/hooks/telegram-notify.sh
#
# Usage (from Claude hooks):
#   telegram-notify.sh question
#   telegram-notify.sh done
#
# Env required:
#   BOT_TOKEN, CHAT_ID
#
# Optional env:
#   TG_DISABLE_NOTIFICATION=true|false
#   TG_MESSAGE_THREAD_ID=<int>   (for forum topics / message threads)
#   TG_PARSE_MODE=HTML           (default HTML)
#   TG_MAX_INLINE=3500           (threshold to send as message vs document)
#   TG_LOG_FILE=~/.claude/hooks/telegram-notify.log

MODE="${1:-auto}"

#BOT_TOKEN="${BOT_TOKEN:-}"
#CHAT_ID="${CHAT_ID:-}"
BOT_TOKEN="8339956513:AAEKtFn_r7yQHYrwK-v8t9M_f-GvCUBax2A"
CHAT_ID="-1003289806131"


if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "Missing BOT_TOKEN or CHAT_ID" >&2
  exit 1
fi

TG_PARSE_MODE="${TG_PARSE_MODE:-HTML}"
TG_DISABLE_NOTIFICATION="${TG_DISABLE_NOTIFICATION:-false}"
TG_MESSAGE_THREAD_ID="${TG_MESSAGE_THREAD_ID:-}"
TG_MAX_INLINE="${TG_MAX_INLINE:-3500}"
TG_LOG_FILE="${TG_LOG_FILE:-$HOME/.claude/hooks/telegram-notify.log}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need_cmd jq
need_cmd curl
need_cmd tac

log() {
  local msg="$1"
  printf '%s %s\n' "$(date -Is)" "$msg" >> "$TG_LOG_FILE" 2>/dev/null || true
}

# Claude hooks provide JSON on stdin. If invoked manually without stdin, fall back to EVENT_DATA.
INPUT=""
if [[ -t 0 ]]; then
  INPUT="${EVENT_DATA:-{}}"
else
  # Avoid blocking on empty stdin (rare); read with a small timeout if available.
  # shellcheck disable=SC2002
  INPUT="$(cat || true)"
  if [[ -z "${INPUT//[$' \t\r\n']/}" ]]; then
    INPUT="${EVENT_DATA:-{}}"
  fi
fi
[[ -z "${INPUT//[$' \t\r\n']/}" ]] && INPUT="{}"

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // "unknown"')"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty')"
TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // empty')"
HOOK_EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // empty')"

# Machine identification
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
MACHINE_SHORT="${MACHINE_ID:0:7}"

PROJECT="claude"
[[ -n "$CWD" ]] && PROJECT="$(basename "$CWD")"

SHORT_ID="$(printf '%s' "$SESSION_ID" | cut -c1-8)"

# Session-topic mapping
SESSION_TOPIC_MAP="${HOME}/.claude/hooks/session-topics.json"
TOPIC_ID=""

# Strategy 1: Use CLAUDE_TOPIC_ID environment variable (most reliable!)
if [[ -n "${CLAUDE_TOPIC_ID:-}" ]]; then
    TOPIC_ID="$CLAUDE_TOPIC_ID"
    log "Found topic ID from environment: $TOPIC_ID"
fi

# Strategy 2: Try exact session ID match in mapping
if [[ -z "$TOPIC_ID" && -f "$SESSION_TOPIC_MAP" ]]; then
    TOPIC_ID=$(jq -r ".[] | select(.session == \"$SESSION_ID\") | .topic_id" "$SESSION_TOPIC_MAP" 2>/dev/null || echo "")
    [[ -n "$TOPIC_ID" ]] && log "Found topic ID from session mapping: $TOPIC_ID"
fi

# Strategy 3: Fuzzy match by CLAUDE_TMUX_SESSION if available
if [[ -z "$TOPIC_ID" && -n "${CLAUDE_TMUX_SESSION:-}" && -f "$SESSION_TOPIC_MAP" ]]; then
    TOPIC_ID=$(jq -r ".[] | select(.session == \"$CLAUDE_TMUX_SESSION\") | .topic_id" "$SESSION_TOPIC_MAP" 2>/dev/null || echo "")
    [[ -n "$TOPIC_ID" ]] && log "Found topic ID from tmux session name: $TOPIC_ID"
fi

# Strategy 4: Fuzzy match by project + recent time (last resort fallback)
if [[ -z "$TOPIC_ID" && -f "$SESSION_TOPIC_MAP" && -n "$PROJECT" && "$PROJECT" != "claude" ]]; then
    one_hour_ago=$(date -d '1 hour ago' -Iseconds 2>/dev/null || date -v-1H -Iseconds 2>/dev/null || echo "")
    if [[ -n "$one_hour_ago" ]]; then
        TOPIC_ID=$(jq -r --arg proj "$PROJECT" --arg since "$one_hour_ago" \
            '[.[] | select(.project == $proj and .created > $since)] | sort_by(.created) | reverse | .[0].topic_id // empty' \
            "$SESSION_TOPIC_MAP" 2>/dev/null || echo "")
        [[ -n "$TOPIC_ID" ]] && log "Found topic ID from fuzzy match: $TOPIC_ID"
    fi
fi

[[ -n "$TOPIC_ID" ]] && TG_MESSAGE_THREAD_ID="$TOPIC_ID"

TMUX_LABEL=""
if [[ -n "${TMUX:-}" ]]; then
  TMUX_LABEL="$(tmux display-message -p '#S:#I.#P' 2>/dev/null || true)"
fi

header_html() {
  local h="<b>[${MACHINE_SHORT}] ${PROJECT} [${SHORT_ID}]</b>"
  [[ -n "$TMUX_LABEL" ]] && h="${h} <i>${TMUX_LABEL}</i>"
  echo "$h"
}

html_escape() {
  # Escape &, <, > for Telegram HTML parse_mode
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

curl_common=(
  --silent --show-error
  --connect-timeout 5
  --max-time 15
  --retry 3
  --retry-delay 1
  --retry-connrefused
)

tg_send_message_html() {
  local html="$1"
  local url="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"

  # Build form params
  local -a form
  form+=( -d "chat_id=${CHAT_ID}" )
  form+=( -d "parse_mode=${TG_PARSE_MODE}" )
  form+=( -d "disable_web_page_preview=true" )
  form+=( -d "disable_notification=${TG_DISABLE_NOTIFICATION}" )
  [[ -n "$TG_MESSAGE_THREAD_ID" ]] && form+=( -d "message_thread_id=${TG_MESSAGE_THREAD_ID}" )

  local response
  response=$(curl "${curl_common[@]}" -X POST "$url" "${form[@]}" --data-urlencode "text=${html}" 2>&1)
  local status=$?
  if [[ $status -ne 0 ]] || ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    log "ERROR sending message: status=$status response=$response"
    return 1
  fi
  return 0
}

tg_send_document() {
  local caption="$1"
  local filepath="$2"
  local url="https://api.telegram.org/bot${BOT_TOKEN}/sendDocument"

  local -a form
  form+=( -F "chat_id=${CHAT_ID}" )
  form+=( -F "disable_notification=${TG_DISABLE_NOTIFICATION}" )
  [[ -n "$TG_MESSAGE_THREAD_ID" ]] && form+=( -F "message_thread_id=${TG_MESSAGE_THREAD_ID}" )

  # Telegram caption limit is 0-1024 after entities parsing; enforce hard cap. (No parse_mode here by default.)
  caption="${caption:0:1024}"
  form+=( -F "caption=${caption}" )
  form+=( -F "document=@${filepath}" )

  local response
  response=$(curl "${curl_common[@]}" -X POST "$url" "${form[@]}" 2>&1)
  local status=$?
  if [[ $status -ne 0 ]] || ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    log "ERROR sending document: status=$status response=$response"
    return 1
  fi
  return 0
}

extract_last_assistant_text() {
  local path="$1"
  local attempt out

  # Retry because Stop can arrive before transcript flush is fully visible.
  for attempt in 1 2 3 4 5 6 7 8; do
    # Get the last (first after tac) assistant message
    # Use -s flag to get the first complete JSON object only
    out="$(
      tac "$path" 2>/dev/null | jq -rs '
        def block_to_text:
          if type=="string" then .
          elif type=="array" then (
            map(
              if type=="string" then .
              elif (type=="object" and has("text")) then .text
              elif (type=="object" and has("content") and (.content|type=="string")) then .content
              else "" end
            ) | join("")
          )
          elif (type=="object" and has("text")) then .text
          elif (type=="object" and has("content") and (.content|type=="string")) then .content
          else "" end;

        # Find first assistant message (last in original file)
        map(select((.isSidechain // false) == false and .message.role? == "assistant"))
        | if length > 0 then (.[0].message.content | block_to_text) else "" end
      '
    )"
    if [[ -n "${out//[$' \t\r\n']/}" ]]; then
      printf '%s' "$out"
      return 0
    fi
    sleep 0.25
  done

  printf '%s' ""
}

send_done() {
  if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    tg_send_message_html "$(header_html) done
<pre>no transcript found</pre>"
    log "done: no transcript (session=$SESSION_ID event=$HOOK_EVENT)"
    return 0
  fi

  local out
  out="$(extract_last_assistant_text "$TRANSCRIPT_PATH")"
  if [[ -z "${out//[$' \t\r\n']/}" ]]; then
    tg_send_message_html "$(header_html) done
<pre>could not extract output</pre>"
    log "done: extract failed (session=$SESSION_ID transcript=$TRANSCRIPT_PATH)"
    return 0
  fi

  if (( ${#out} <= TG_MAX_INLINE )); then
    local out_escaped
    out_escaped="$(printf '%s' "$out" | html_escape)"
    # Real newlines preserved inside <pre>.
    tg_send_message_html "$(header_html) done
<pre>${out_escaped}</pre>"
    log "done: sent inline (session=$SESSION_ID chars=${#out})"
  else
    local tmp
    tmp="$(mktemp "/tmp/claude_${PROJECT}_${SHORT_ID}_XXXXXX.txt")"
    {
      echo "${PROJECT} [${SHORT_ID}]"
      [[ -n "$TMUX_LABEL" ]] && echo "tmux: ${TMUX_LABEL}"
      [[ -n "$CWD" ]] && echo "cwd: ${CWD}"
      echo "session: ${SESSION_ID}"
      echo "transcript: ${TRANSCRIPT_PATH}"
      echo
      echo "$out"
    } > "$tmp"

    tg_send_document "${PROJECT} [${SHORT_ID}] done (full output attached)" "$tmp"
    rm -f "$tmp"
    log "done: sent document (session=$SESSION_ID chars=${#out})"
  fi

  # Note: We don't auto-close topics anymore - let users close them manually or via /stop
}

send_question() {
  local q
  q="$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // empty')"
  local q_escaped
  q_escaped="$(printf '%s' "$q" | html_escape)"
  tg_send_message_html "$(header_html) needs input
<pre>${q_escaped}</pre>"
  log "question: sent (session=$SESSION_ID)"
}

case "$MODE" in
  question) send_question ;;
  done)     send_done ;;
  *)
    tg_send_message_html "$(header_html) event
<pre>mode=${MODE} hook=${HOOK_EVENT}</pre>"
    log "event: mode=$MODE hook=$HOOK_EVENT (session=$SESSION_ID)"
    ;;
esac
