#!/usr/bin/env bash
# Helper script to get your Telegram chat ID

if [[ -z "$1" ]]; then
    echo "Usage: $0 <bot-token>"
    echo "Example: $0 8339956513:AAEKtFn_r7yQHYrwK-v8t9M_f-GvCUBax2A"
    exit 1
fi

BOT_TOKEN="$1"

echo "Fetching recent updates from Telegram..."
echo "Send a message in your group now if you haven't already."
echo ""

RESPONSE=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates")

echo "Chat IDs found:"
echo "$RESPONSE" | jq -r '.result[].message.chat | "ID: \(.id) | Type: \(.type) | Title: \(.title // "N/A")"' | sort -u

echo ""
echo "For supergroups (forums), use the negative ID that starts with -100"
