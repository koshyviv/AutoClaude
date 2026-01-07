# AutoClaude

Run Claude Code sessions remotely via Telegram. Each session gets its own forum topic. Reply directly in topics to interact with Claude.

## Quick Start

Prerequisites:
- A Telegram bot (create one via @BotFather)
- A Telegram supergroup with forum topics enabled
- Claude Code CLI installed
- Linux system with systemd

### 1. Create Telegram Bot

```bash
# Talk to @BotFather on Telegram
/newbot
# Follow prompts, save the bot token

# Add bot to your supergroup as admin
# Enable forum topics in group settings
# Make bot admin with "Manage Topics" permission
```

### 2. Get Your Chat ID

```bash
# Send a message in your group, then:
curl "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates"
# Look for "chat":{"id": -1003289806131} in the response
```

### 3. Install

```bash
git clone git@github.com:koshyviv/AutoClaude.git
cd AutoClaude

# Edit the config files with your credentials:
# - .claude/hooks/telegram-bot-listener.sh (line 20-21)
# - .claude/hooks/telegram-notify.sh (line 24-25)
# - .config/systemd/user/telegram-claude-bot.service (line 10-11)

# Copy files
mkdir -p ~/.claude/hooks ~/.config/systemd/user
cp .claude/hooks/*.sh ~/.claude/hooks/
cp .claude/settings.json ~/.claude/settings.json
cp .config/systemd/user/telegram-claude-bot.service ~/.config/systemd/user/
chmod +x ~/.claude/hooks/*.sh

# Update PATH in service file to point to your claude binary
which claude  # Note the path
# Edit telegram-claude-bot.service line 12 with correct PATH

# Start the bot
systemctl --user daemon-reload
systemctl --user enable telegram-claude-bot.service
systemctl --user start telegram-claude-bot.service
systemctl --user status telegram-claude-bot.service
```

### 4. Use It

In your Telegram group:

```
/start myproject
```

A new topic is created. Reply in the topic to chat with Claude. No commands needed. Type `/done` when finished.

## How It Works

The bot creates a tmux session for each Claude Code instance. Topic ID is passed via environment variable (`CLAUDE_TOPIC_ID`). Notification hook reads this variable and sends responses to the correct topic.

Key files:
- `telegram-bot-listener.sh`: Polls Telegram, manages sessions
- `telegram-notify.sh`: Hook that sends Claude responses to topics
- `settings.json`: Configures Claude hooks
- Session mapping stored in `~/.claude/hooks/session-topics.json`

## Commands

- `/start <dir>` - Start interactive session
- `/run <dir> <prompt>` - Run one-off task
- `/status` - List active sessions
- `/stop <session>` - Stop a session
- `/done` - End session from within topic

Directory shortcuts work: `/start myproject` expands to `/home/ubuntu/code/myproject`

## Architecture Notes

Multiple sessions in the same directory work correctly. Each tmux session gets a unique `CLAUDE_TOPIC_ID` environment variable. The notification hook prioritizes reading from this variable over fuzzy matching, eliminating cross-talk between sessions.

Message deduplication prevents Telegram API duplicates. Rate limiting prevents command spam. Topics auto-close when sessions end via `/done` or `/stop`.

## Debugging

```bash
# Check bot status
systemctl --user status telegram-claude-bot.service

# View logs
tail -f ~/.claude/hooks/telegram-bot.log
tail -f ~/.claude/hooks/telegram-notify.log

# Check active sessions
tmux list-sessions | grep claude

# Inspect session mappings
cat ~/.claude/hooks/session-topics.json | jq .
```

## Multi-Instance Setup

The system supports multiple machines. Sessions are prefixed with machine ID (first 7 chars of `/etc/machine-id`). Topic names show: `[ec2feb9] 17377636 @ myproject`

To run on multiple machines, clone the repo on each, update credentials, and each will create topics with its own machine prefix.

## Security

Only directories under `/home/ubuntu/code/` are accessible by default. Change `ALLOWED_DIR_PREFIX` in `telegram-bot-listener.sh` to modify this. Bot only responds to your configured `CHAT_ID`.

Credentials are in the scripts. Do not commit your tokens to public repos. Use environment variables or keep your fork private.

## License

MIT
