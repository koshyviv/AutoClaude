#!/usr/bin/env bash
set -euo pipefail

# ~/.claude/hooks/telegram-bot-listener.sh
#
# Telegram bot listener for Claude Code remote control
# Polls Telegram bot API and handles commands to start/stop Claude sessions
#
# Commands:
#   /start <directory> - Start interactive Claude session
#   /run <directory> <prompt> - Run Claude with specific prompt
#   /status - List active Claude sessions
#   /stop <session> - Stop a Claude session
#
# Environment variables (can be set in systemd service):
#   BOT_TOKEN - Telegram bot token (default: hardcoded below)
#   CHAT_ID - Allowed Telegram chat ID (default: hardcoded below)

# Configuration
BOT_TOKEN="${BOT_TOKEN:-8339956513:AAEKtFn_r7yQHYrwK-v8t9M_f-GvCUBax2A}"
ALLOWED_CHAT_ID="${ALLOWED_CHAT_ID:--1003289806131}"
POLL_TIMEOUT=30
MAX_CONCURRENT_SESSIONS=5
RATE_LIMIT_SECONDS=2

# Machine identification
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
MACHINE_SHORT="${MACHINE_ID:0:7}"

# Claude invocation (flag enforced)
CLAUDE_CMD="${CLAUDE_CMD:-claude --dangerously-skip-permissions}"
CLAUDE_BIN="${CLAUDE_CMD%% *}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# File paths
OFFSET_FILE="${HOME}/.claude/hooks/telegram-bot-offset.txt"
LOG_FILE="${HOME}/.claude/hooks/telegram-bot.log"
LAST_CMD_FILE="${HOME}/.claude/hooks/telegram-bot-lastcmd.txt"
SESSION_TOPIC_MAP="${HOME}/.claude/hooks/session-topics.json"
PROCESSED_MESSAGES="${HOME}/.claude/hooks/telegram-bot-processed.txt"

# Allowed directory prefix
ALLOWED_DIR_PREFIX="/home/ubuntu/code/"

# Utility functions
log() {
    printf '%s [BOT] %s\n' "$(date -Iseconds)" "$*" >&2
}

error() {
    printf '%s [ERROR] %s\n' "$(date -Iseconds)" "$*" >&2
}

# Telegram API functions
telegram_api() {
    local method="$1"
    shift
    local url="https://api.telegram.org/bot${BOT_TOKEN}/${method}"

    curl --silent --show-error \
        --connect-timeout 5 \
        --max-time $((POLL_TIMEOUT + 10)) \
        --retry 2 \
        --retry-delay 1 \
        "$@" \
        "$url"
}

send_message() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-}"
    local topic_id="${4:-}"

    local -a args=(
        -d "chat_id=${chat_id}"
        --data-urlencode "text=${text}"
    )

    [[ -n "$parse_mode" ]] && args+=(-d "parse_mode=${parse_mode}")
    [[ -n "$topic_id" ]] && args+=(-d "message_thread_id=${topic_id}")

    if ! telegram_api sendMessage "${args[@]}" >/dev/null; then
        error "Failed to send message: $text"
        return 1
    fi
    log "Sent message to ${chat_id}: ${text:0:50}..."
}

get_updates() {
    local offset="${1:-0}"

    telegram_api getUpdates \
        -d "offset=${offset}" \
        -d "timeout=${POLL_TIMEOUT}" \
        -d "allowed_updates=[\"message\"]"
}

# Topic management
create_session_topic() {
    local session_name="$1"
    local directory="$2"
    local project=$(basename "$directory")

    # Extract IST timestamp and random from session name for display
    # Format: claude_ec2feb9_260107103534123_42 -> 260107103534123_42
    local session_short=$(echo "$session_name" | cut -d'_' -f3-4)
    local topic_name="[${MACHINE_SHORT}] ${session_short} @ ${project}"

    # Icon colors - blue
    local icon_color="7322096"

    local response=$(telegram_api createForumTopic \
        -d "chat_id=${ALLOWED_CHAT_ID}" \
        -d "name=${topic_name}" \
        -d "icon_color=${icon_color}")

    local topic_id=$(echo "$response" | jq -r '.result.message_thread_id // empty')

    if [[ -n "$topic_id" ]]; then
        echo "$topic_id"
        return 0
    else
        error "Failed to create topic: $response"
        return 1
    fi
}

save_session_topic() {
    local session="$1"
    local topic_id="$2"
    local project="$3"

    local entry=$(jq -n \
        --arg s "$session" \
        --arg t "$topic_id" \
        --arg p "$project" \
        --arg m "$MACHINE_SHORT" \
        --arg created "$(date -Iseconds)" \
        '{session: $s, topic_id: $t, project: $p, machine: $m, created: $created}')

    if [[ -f "$SESSION_TOPIC_MAP" ]]; then
        jq ". + [$entry]" "$SESSION_TOPIC_MAP" > "${SESSION_TOPIC_MAP}.tmp"
        mv "${SESSION_TOPIC_MAP}.tmp" "$SESSION_TOPIC_MAP"
    else
        echo "[$entry]" > "$SESSION_TOPIC_MAP"
    fi

    log "Saved session $session → topic $topic_id mapping"
}

get_topic_for_session() {
    local session="$1"
    [[ -f "$SESSION_TOPIC_MAP" ]] || return 1
    jq -r ".[] | select(.session == \"$session\") | .topic_id" "$SESSION_TOPIC_MAP" 2>/dev/null || echo ""
}

cleanup_session_topic() {
    local session="$1"

    [[ -f "$SESSION_TOPIC_MAP" ]] || return 0

    # Get topic ID before removing from map
    local topic_id
    topic_id=$(jq -r ".[] | select(.session == \"$session\") | .topic_id" "$SESSION_TOPIC_MAP" 2>/dev/null)

    # Close the forum topic (marks as closed but keeps history)
    if [[ -n "$topic_id" ]]; then
        telegram_api closeForumTopic \
            -d "chat_id=${ALLOWED_CHAT_ID}" \
            -d "message_thread_id=${topic_id}" >/dev/null 2>&1 || true
        log "Closed topic $topic_id for session $session"
    fi

    # Remove from mapping
    jq "map(select(.session != \"$session\"))" "$SESSION_TOPIC_MAP" > "${SESSION_TOPIC_MAP}.tmp" 2>/dev/null || echo "[]" > "${SESSION_TOPIC_MAP}.tmp"
    mv "${SESSION_TOPIC_MAP}.tmp" "$SESSION_TOPIC_MAP"

    log "Cleaned up session-topic mapping for $session"
}

# Session management
get_session_name() {
    # Format: YYMMDDHHMMSSsss (IST timezone) + 2-digit random (10-99)
    # Example: 260107103534123_42
    local ist_timestamp
    ist_timestamp=$(TZ='Asia/Kolkata' date +%y%m%d%H%M%S%3N)
    local random_2digit
    random_2digit=$(( (RANDOM % 90) + 10 ))
    echo "claude_${MACHINE_SHORT}_${ist_timestamp}_${random_2digit}"
}

list_claude_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude_' || true
}

count_claude_sessions() {
    list_claude_sessions | wc -l
}

# Directory validation and expansion
validate_directory() {
    local dir="$1"

    # Expand shorthand: if doesn't start with /, prepend ALLOWED_DIR_PREFIX
    if [[ "$dir" != /* ]]; then
        dir="${ALLOWED_DIR_PREFIX}${dir}"
    fi

    # Check for path traversal
    if [[ "$dir" =~ \.\. ]]; then
        echo "Error: Directory path contains '..' (path traversal not allowed)"
        return 1
    fi

    # Check if directory starts with allowed prefix
    if [[ "$dir" != "${ALLOWED_DIR_PREFIX}"* ]]; then
        echo "Error: Directory must start with ${ALLOWED_DIR_PREFIX}"
        return 1
    fi

    # Check if directory exists
    if [[ ! -d "$dir" ]]; then
        echo "Error: Directory does not exist: $dir"
        return 1
    fi

    # Check if directory is readable
    if [[ ! -r "$dir" ]]; then
        echo "Error: Directory is not readable: $dir"
        return 1
    fi

    # Echo the expanded path for use by caller
    echo "$dir"
    return 0
}

# Rate limiting
check_rate_limit() {
    local chat_id="$1"
    local now
    now=$(date +%s)

    if [[ -f "$LAST_CMD_FILE" ]]; then
        local last_cmd_time
        last_cmd_time=$(cat "$LAST_CMD_FILE" 2>/dev/null || echo "0")
        local elapsed=$((now - last_cmd_time))

        if ((elapsed < RATE_LIMIT_SECONDS)); then
            log "Rate limit: ${elapsed}s since last command (min ${RATE_LIMIT_SECONDS}s)"
            return 1
        fi
    fi

    echo "$now" > "$LAST_CMD_FILE"
    return 0
}

# Command handlers
cmd_start() {
    local chat_id="$1"
    local directory="$2"

    log "Command: /start $directory"

    # Validate and expand directory
    local expanded_dir
    if ! expanded_dir=$(validate_directory "$directory" 2>&1); then
        send_message "$chat_id" "❌ $expanded_dir"
        return 1
    fi
    directory="$expanded_dir"

    # Check concurrent session limit
    local session_count
    session_count=$(count_claude_sessions)
    if ((session_count >= MAX_CONCURRENT_SESSIONS)); then
        send_message "$chat_id" "❌ Maximum concurrent sessions ($MAX_CONCURRENT_SESSIONS) reached. Stop a session first."
        return 1
    fi

    # Create session
    local session_name
    session_name=$(get_session_name)

    # Create topic BEFORE starting session
    local topic_id=$(create_session_topic "$session_name" "$directory")
    if [[ -z "$topic_id" ]]; then
        send_message "$chat_id" "❌ Failed to create topic for session"
        return 1
    fi

    # Save mapping
    save_session_topic "$session_name" "$topic_id" "$(basename "$directory")"

    # Start tmux session with CLAUDE_TOPIC_ID environment variable
    if tmux new-session -d -s "$session_name" -c "$directory" \
        "CLAUDE_TOPIC_ID=$topic_id CLAUDE_TMUX_SESSION=$session_name $CLAUDE_CMD" 2>&1; then
        log "Started session: $session_name in $directory with topic $topic_id"

        send_message "$chat_id" "✅ Started Claude Code
Directory: $directory
Session: <code>$session_name</code>

All updates will appear in this topic." "HTML" "$topic_id"
    else
        error "Failed to start tmux session: $session_name"
        send_message "$chat_id" "❌ Failed to start Claude Code session"
        return 1
    fi
}

cmd_run() {
    local chat_id="$1"
    local directory="$2"
    shift 2
    local prompt="$*"

    log "Command: /run $directory \"$prompt\""

    # Validate and expand directory
    local expanded_dir
    if ! expanded_dir=$(validate_directory "$directory" 2>&1); then
        send_message "$chat_id" "❌ $expanded_dir"
        return 1
    fi
    directory="$expanded_dir"

    # Check for empty prompt
    if [[ -z "$prompt" ]]; then
        send_message "$chat_id" "❌ Error: Prompt cannot be empty"
        return 1
    fi

    # Check concurrent session limit
    local session_count
    session_count=$(count_claude_sessions)
    if ((session_count >= MAX_CONCURRENT_SESSIONS)); then
        send_message "$chat_id" "❌ Maximum concurrent sessions ($MAX_CONCURRENT_SESSIONS) reached. Stop a session first."
        return 1
    fi

    # Create session with claude -p
    local session_name
    session_name=$(get_session_name)

    # Create topic BEFORE starting session
    local topic_id=$(create_session_topic "$session_name" "$directory")
    if [[ -z "$topic_id" ]]; then
        send_message "$chat_id" "❌ Failed to create topic for session"
        return 1
    fi

    # Save mapping
    save_session_topic "$session_name" "$topic_id" "$(basename "$directory")"

    # Escape single quotes in prompt for shell
    local escaped_prompt="${prompt//\'/\'\\\'\'}"

    # Start tmux session with CLAUDE_TOPIC_ID environment variable
    if tmux new-session -d -s "$session_name" -c "$directory" \
        "CLAUDE_TOPIC_ID=$topic_id CLAUDE_TMUX_SESSION=$session_name ${CLAUDE_CMD} -p '$escaped_prompt'" 2>&1; then
        log "Started session: $session_name with prompt: $prompt and topic $topic_id"
        local prompt_preview="${prompt:0:50}"
        [[ ${#prompt} -gt 50 ]] && prompt_preview="${prompt_preview}..."

        send_message "$chat_id" "✅ Running Claude Code
Directory: $directory
Session: <code>$session_name</code>
Prompt: \"$prompt_preview\"

All updates will appear in this topic." "HTML" "$topic_id"
    else
        error "Failed to start tmux session: $session_name"
        send_message "$chat_id" "❌ Failed to start Claude Code session"
        return 1
    fi
}

cmd_status() {
    local chat_id="$1"

    log "Command: /status"

    local sessions
    sessions=$(list_claude_sessions)

    if [[ -z "$sessions" ]]; then
        send_message "$chat_id" "📋 No active Claude Code sessions"
        return 0
    fi

    local count
    count=$(echo "$sessions" | wc -l)

    local message="📋 Active Claude Code sessions ($count):\n\n"

    while IFS= read -r session; do
        # Get session info
        local created attached
        created=$(tmux list-sessions -F '#{session_name} #{session_created}' 2>/dev/null | grep "^${session} " | awk '{print $2}')
        attached=$(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | grep "^${session} " | awk '{print $2}')

        # Convert created timestamp to readable format
        local created_date=""
        if [[ -n "$created" ]]; then
            created_date=$(date -d "@${created}" '+%H:%M:%S' 2>/dev/null || echo "unknown")
        fi

        local status="🔴 detached"
        [[ "$attached" == "1" ]] && status="🟢 attached"

        message+="• <code>$session</code>\n"
        message+="  Started: $created_date | $status\n\n"
    done <<< "$sessions"

    message+="Use /stop &lt;session-name&gt; to stop a session"

    send_message "$chat_id" "$message" "HTML"
}

cmd_stop() {
    local chat_id="$1"
    local session_name="$2"

    log "Command: /stop $session_name"

    # Validate session name format
    if [[ ! "$session_name" =~ ^claude_ ]]; then
        send_message "$chat_id" "❌ Error: Invalid session name. Must start with 'claude_'"
        return 1
    fi

    # Check if session exists
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        send_message "$chat_id" "❌ Error: Session not found: $session_name"
        return 1
    fi

    # Kill session
    if tmux kill-session -t "$session_name" 2>&1; then
        log "Stopped session: $session_name"

        # Cleanup session topic
        cleanup_session_topic "$session_name"

        send_message "$chat_id" "✅ Stopped session: <code>$session_name</code>" "HTML"
    else
        error "Failed to stop session: $session_name"
        send_message "$chat_id" "❌ Failed to stop session: $session_name"
        return 1
    fi
}

cmd_reply() {
    local chat_id="$1"
    local session_name="$2"
    shift 2
    local message="$*"

    log "Command: /reply $session_name \"$message\""

    # Validate session name format
    if [[ ! "$session_name" =~ ^claude_ ]]; then
        send_message "$chat_id" "❌ Error: Invalid session name. Must start with 'claude_'"
        return 1
    fi

    # Check if session exists
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        send_message "$chat_id" "❌ Error: Session not found: $session_name

The session may have completed and exited. Use /status to see active sessions."
        return 1
    fi

    # Check if message is empty
    if [[ -z "$message" ]]; then
        send_message "$chat_id" "❌ Error: Message cannot be empty

Usage: /reply &lt;session-name&gt; &lt;message&gt;" "HTML"
        return 1
    fi

    # Send message to tmux session
    # Use literal mode to send the exact text, then send Enter
    if tmux send-keys -t "$session_name" -l "$message" 2>&1 && \
       tmux send-keys -t "$session_name" Enter 2>&1; then
        log "Sent message to session: $session_name"
        local msg_preview="${message:0:100}"
        [[ ${#message} -gt 100 ]] && msg_preview="${msg_preview}..."

        send_message "$chat_id" "✅ Sent to session <code>$session_name</code>:
<pre>$msg_preview</pre>

You'll receive a notification when Claude responds." "HTML"
    else
        error "Failed to send message to session: $session_name"
        send_message "$chat_id" "❌ Failed to send message to session: $session_name"
        return 1
    fi
}

handle_topic_reply() {
    local chat_id="$1"
    local topic_id="$2"
    local message="$3"

    # Find session associated with this topic
    local session=$(jq -r ".[] | select(.topic_id == \"$topic_id\") | .session" "$SESSION_TOPIC_MAP" 2>/dev/null || echo "")

    if [[ -z "$session" ]]; then
        log "No session found for topic $topic_id"
        return 1
    fi

    # Check if session still exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        send_message "$chat_id" "⚠️ This session has completed and is no longer active." "" "$topic_id"
        return 1
    fi

    # Send message to tmux session (SILENT - no acknowledgment)
    if tmux send-keys -t "$session" -l "$message" 2>&1 && \
       tmux send-keys -t "$session" Enter 2>&1; then
        log "Topic reply sent to session $session: $message"
        # No acknowledgment message - silent forwarding for clean conversation
    else
        # Only notify on errors
        send_message "$chat_id" "❌ Failed to send message" "" "$topic_id"
    fi
}

handle_topic_done() {
    local chat_id="$1"
    local topic_id="$2"

    # Find session associated with this topic
    local session=$(jq -r ".[] | select(.topic_id == \"$topic_id\") | .session" "$SESSION_TOPIC_MAP" 2>/dev/null || echo "")

    if [[ -z "$session" ]]; then
        send_message "$chat_id" "⚠️ No active session found in this topic." "" "$topic_id"
        return 1
    fi

    # Check if session still exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        send_message "$chat_id" "ℹ️ Session has already completed." "" "$topic_id"
        # Clean up the mapping anyway
        cleanup_session_topic "$session"
        return 0
    fi

    # Stop the session
    if tmux kill-session -t "$session" 2>&1; then
        log "Stopped session $session via /done in topic $topic_id"

        # Clean up and close topic
        cleanup_session_topic "$session"

        send_message "$chat_id" "✅ Session ended. Topic closed." "" "$topic_id"
    else
        error "Failed to stop session: $session"
        send_message "$chat_id" "❌ Failed to end session" "" "$topic_id"
        return 1
    fi
}

cmd_help() {
    local chat_id="$1"

    local help_text="🤖 <b>Claude Code Bot - Available Commands:</b>

<b>/start &lt;directory&gt;</b>
Start an interactive Claude Code session (stays open)
Example: /start myproject (or /start /home/ubuntu/code/myproject)

<b>/run &lt;directory&gt; &lt;prompt&gt;</b>
Run Claude with a specific task/prompt (exits after completion)
Example: /run myproject list all python files

<b>/status</b>
List all active Claude Code sessions

<b>/stop &lt;session-name&gt;</b>
Stop a running Claude Code session (from #general)
Example: /stop claude_ec2feb9_1234567890_abcd1234

<b>/done</b>
End the current session (use this inside a topic thread)

<b>/help</b>
Show this help message

<b>💡 Tips:</b>
• Reply directly to messages in a session's topic thread to interact with Claude!
• Use <b>/done</b> inside a topic to end that session and close the topic
• Use short directory names (e.g., 'myproject') instead of full paths

<i>Note: Only directories under /home/ubuntu/code/ are allowed</i>"

    send_message "$chat_id" "$help_text" "HTML"
}

# Message processing
process_message() {
    local update="$1"

    # Extract message details
    local message_id chat_id text username message_thread_id
    message_id=$(echo "$update" | jq -r '.message.message_id // empty')
    chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
    text=$(echo "$update" | jq -r '.message.text // empty')
    username=$(echo "$update" | jq -r '.message.from.username // "unknown"')
    message_thread_id=$(echo "$update" | jq -r '.message.message_thread_id // empty')

    [[ -z "$message_id" || -z "$chat_id" || -z "$text" ]] && return 0

    # Deduplication: Check if we've already processed this message
    if [[ -f "$PROCESSED_MESSAGES" ]] && grep -q "^${message_id}$" "$PROCESSED_MESSAGES"; then
        log "Skipping duplicate message_id=$message_id"
        return 0
    fi

    # Mark message as processed
    echo "$message_id" >> "$PROCESSED_MESSAGES"

    # Keep only last 1000 processed message IDs to prevent file from growing infinitely
    if [[ -f "$PROCESSED_MESSAGES" ]]; then
        tail -1000 "$PROCESSED_MESSAGES" > "${PROCESSED_MESSAGES}.tmp"
        mv "${PROCESSED_MESSAGES}.tmp" "$PROCESSED_MESSAGES"
    fi

    log "Received message from chat_id=$chat_id username=$username topic=$message_thread_id: $text"

    # Check if chat_id is allowed
    if [[ "$chat_id" != "$ALLOWED_CHAT_ID" ]]; then
        log "Ignoring message from unauthorized chat_id: $chat_id"
        return 0
    fi

    # Parse command
    local cmd args
    cmd=$(echo "$text" | awk '{print $1}')
    args=$(echo "$text" | cut -d' ' -f2- 2>/dev/null || true)

    # Check if this is a topic message
    if [[ -n "$message_thread_id" ]]; then
        # Special handling for /done in topics - end the session
        if [[ "$cmd" == "/done" ]]; then
            handle_topic_done "$chat_id" "$message_thread_id"
            return 0
        fi

        # Regular message in topic (not a command) - send to session
        if [[ ! "$text" =~ ^/ ]]; then
            handle_topic_reply "$chat_id" "$message_thread_id" "$text"
            return 0
        fi
    fi

    # Rate limiting for commands only
    if ! check_rate_limit "$chat_id"; then
        send_message "$chat_id" "⏳ Please wait ${RATE_LIMIT_SECONDS} seconds between commands"
        return 0
    fi

    case "$cmd" in
        /start)
            local dir
            dir=$(echo "$args" | awk '{print $1}')
            if [[ -z "$dir" ]]; then
                send_message "$chat_id" "❌ Usage: /start <directory>"
                return 1
            fi
            cmd_start "$chat_id" "$dir"
            ;;

        /run)
            local dir prompt
            dir=$(echo "$args" | awk '{print $1}')
            prompt=$(echo "$args" | cut -d' ' -f2-)
            if [[ -z "$dir" ]]; then
                send_message "$chat_id" "❌ Usage: /run <directory> <prompt>"
                return 1
            fi
            cmd_run "$chat_id" "$dir" "$prompt"
            ;;

        /status)
            cmd_status "$chat_id"
            ;;

        /stop)
            local session
            session=$(echo "$args" | awk '{print $1}')
            if [[ -z "$session" ]]; then
                send_message "$chat_id" "❌ Usage: /stop <session-name>"
                return 1
            fi
            cmd_stop "$chat_id" "$session"
            ;;

        /reply)
            send_message "$chat_id" "ℹ️ The /reply command is deprecated.

Simply reply to messages directly in the session's topic thread!" "HTML"
            ;;

        /help|/start@*)
            cmd_help "$chat_id"
            ;;

        *)
            log "Unknown command: $cmd"
            send_message "$chat_id" "❌ Unknown command. Send /help for available commands."
            ;;
    esac
}

# Main loop
main() {
    log "Starting Telegram bot listener..."
    log "Bot token: ${BOT_TOKEN:0:10}..."
    log "Allowed chat ID: $ALLOWED_CHAT_ID"
    log "Poll timeout: ${POLL_TIMEOUT}s"
    log "Max concurrent sessions: $MAX_CONCURRENT_SESSIONS"

    # Validate dependencies
    for cmd in curl jq tmux "$CLAUDE_BIN"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Read last offset
    local offset=0
    if [[ -f "$OFFSET_FILE" ]]; then
        offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")
        log "Resuming from offset: $offset"
    fi

    log "Bot is ready. Waiting for messages..."

    while true; do
        # Get updates
        local response
        if ! response=$(get_updates "$offset" 2>&1); then
            error "Failed to get updates: $response"
            sleep 5
            continue
        fi

        # Check for error
        if echo "$response" | jq -e '.ok == false' >/dev/null 2>&1; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.description // "Unknown error"')
            error "Telegram API error: $error_msg"
            sleep 5
            continue
        fi

        # Process each update
        local updates
        updates=$(echo "$response" | jq -c '.result[]?' 2>/dev/null || true)

        if [[ -n "$updates" ]]; then
            while IFS= read -r update; do
                # Get update_id
                local update_id
                update_id=$(echo "$update" | jq -r '.update_id')

                # Process message
                process_message "$update" || true

                # Update offset
                offset=$((update_id + 1))
                echo "$offset" > "$OFFSET_FILE"
            done <<< "$updates"
        fi
    done
}

# Trap signals for graceful shutdown
trap 'log "Received shutdown signal, exiting..."; exit 0' SIGTERM SIGINT

# Run main loop
main
