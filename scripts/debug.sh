#!/usr/bin/env bash
# Debug helper for AutoClaude

echo "AutoClaude Debug Information"
echo "============================"
echo ""

# Service status
echo "Service Status:"
systemctl --user status telegram-claude-bot.service --no-pager | head -15
echo ""

# Active sessions
echo "Active Claude Sessions:"
SESSIONS=$(tmux list-sessions 2>/dev/null | grep '^claude_' || echo "None")
if [[ "$SESSIONS" == "None" ]]; then
    echo "  No active sessions"
else
    echo "$SESSIONS"
fi
echo ""

# Session mappings
echo "Session-Topic Mappings:"
if [[ -f ~/.claude/hooks/session-topics.json ]]; then
    cat ~/.claude/hooks/session-topics.json | jq -r '.[] | "  \(.session) -> Topic \(.topic_id) (\(.project))"'
else
    echo "  No mappings file found"
fi
echo ""

# Recent logs
echo "Recent Bot Logs (last 10 lines):"
if [[ -f ~/.claude/hooks/telegram-bot.log ]]; then
    tail -10 ~/.claude/hooks/telegram-bot.log | sed 's/^/  /'
else
    echo "  No log file found"
fi
echo ""

echo "Recent Notification Logs (last 10 lines):"
if [[ -f ~/.claude/hooks/telegram-notify.log ]]; then
    tail -10 ~/.claude/hooks/telegram-notify.log | sed 's/^/  /'
else
    echo "  No log file found"
fi
echo ""

# Processed messages count
echo "Stats:"
if [[ -f ~/.claude/hooks/telegram-bot-processed.txt ]]; then
    COUNT=$(wc -l < ~/.claude/hooks/telegram-bot-processed.txt)
    echo "  Processed messages: $COUNT"
else
    echo "  Processed messages: 0"
fi

# Config check
echo ""
echo "Configuration:"
echo "  Bot script: $(ls -lh ~/.claude/hooks/telegram-bot-listener.sh 2>/dev/null | awk '{print $5}' || echo 'Not found')"
echo "  Notify script: $(ls -lh ~/.claude/hooks/telegram-notify.sh 2>/dev/null | awk '{print $5}' || echo 'Not found')"
echo "  Settings: $(ls -lh ~/.claude/settings.json 2>/dev/null | awk '{print $5}' || echo 'Not found')"
