#!/usr/bin/env bash
set -euo pipefail

# AutoClaude installation script

echo "AutoClaude Installation"
echo "======================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v claude &>/dev/null; then
    echo "Error: claude command not found. Install Claude Code CLI first."
    exit 1
fi

if ! command -v tmux &>/dev/null; then
    echo "Error: tmux not found. Install tmux first."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq not found. Install jq first."
    exit 1
fi

echo "All prerequisites met."
echo ""

# Get credentials
read -p "Enter your Telegram bot token: " BOT_TOKEN
read -p "Enter your Telegram chat ID (e.g., -1003289806131): " CHAT_ID

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "Error: Bot token and chat ID are required"
    exit 1
fi

echo ""
echo "Installing AutoClaude..."

# Create directories
mkdir -p ~/.claude/hooks
mkdir -p ~/.config/systemd/user

# Copy files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

cp "$SCRIPT_DIR/.claude/hooks/telegram-bot-listener.sh" ~/.claude/hooks/
cp "$SCRIPT_DIR/.claude/hooks/telegram-notify.sh" ~/.claude/hooks/
cp "$SCRIPT_DIR/.claude/settings.json" ~/.claude/settings.json
cp "$SCRIPT_DIR/.config/systemd/user/telegram-claude-bot.service" ~/.config/systemd/user/

chmod +x ~/.claude/hooks/*.sh

# Update credentials in files
echo "Configuring credentials..."

sed -i "s/BOT_TOKEN=\".*\"/BOT_TOKEN=\"${BOT_TOKEN}\"/" ~/.claude/hooks/telegram-bot-listener.sh
sed -i "s/BOT_TOKEN=\".*\"/BOT_TOKEN=\"${BOT_TOKEN}\"/" ~/.claude/hooks/telegram-notify.sh
sed -i "s/ALLOWED_CHAT_ID=\".*\"/ALLOWED_CHAT_ID=\"${CHAT_ID}\"/" ~/.claude/hooks/telegram-bot-listener.sh
sed -i "s/CHAT_ID=\".*\"/CHAT_ID=\"${CHAT_ID}\"/" ~/.claude/hooks/telegram-notify.sh
sed -i "s|Environment=\"ALLOWED_CHAT_ID=.*\"|Environment=\"ALLOWED_CHAT_ID=${CHAT_ID}\"|" ~/.config/systemd/user/telegram-claude-bot.service
sed -i "s|Environment=\"BOT_TOKEN=.*\"|Environment=\"BOT_TOKEN=${BOT_TOKEN}\"|" ~/.config/systemd/user/telegram-claude-bot.service

# Update PATH in systemd service
CLAUDE_PATH=$(which claude)
CLAUDE_DIR=$(dirname "$CLAUDE_PATH")
sed -i "s|Environment=\"PATH=.*\"|Environment=\"PATH=${CLAUDE_DIR}:/usr/local/bin:/usr/bin:/bin\"|" ~/.config/systemd/user/telegram-claude-bot.service

echo "Starting service..."

# Enable and start service
systemctl --user daemon-reload
systemctl --user enable telegram-claude-bot.service
systemctl --user start telegram-claude-bot.service

echo ""
echo "Installation complete!"
echo ""
echo "Check status:"
echo "  systemctl --user status telegram-claude-bot.service"
echo ""
echo "View logs:"
echo "  tail -f ~/.claude/hooks/telegram-bot.log"
echo ""
echo "Test in Telegram:"
echo "  /start myproject"
