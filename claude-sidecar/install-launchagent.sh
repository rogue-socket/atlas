#!/bin/sh
#
# install-launchagent.sh — install the Atlas Claude sidecar as a per-user
# launchd LaunchAgent, so it auto-starts on login and restarts if it crashes.
#
# Re-runnable: re-running reinstalls with refreshed node/claude paths.
#
# Uninstall:
#   launchctl unload ~/Library/LaunchAgents/com.atlas.claude-sidecar.plist
#   rm ~/Library/LaunchAgents/com.atlas.claude-sidecar.plist
#
set -eu

LABEL="com.atlas.claude-sidecar"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SERVER="$SCRIPT_DIR/server.mjs"

NODE=$(command -v node || true)
CLAUDE=$(command -v claude || true)

[ -f "$SERVER" ] || { echo "error: server.mjs not found next to this script" >&2; exit 1; }
[ -n "$NODE" ]   || { echo "error: 'node' not found on PATH" >&2; exit 1; }
[ -n "$CLAUDE" ] || { echo "error: 'claude' CLI not found on PATH" >&2; exit 1; }

NODE_DIR=$(dirname "$NODE")
CLAUDE_DIR=$(dirname "$CLAUDE")
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/atlas-claude-sidecar.log"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# launchd runs the agent with a minimal environment: pin absolute paths for
# node + server.mjs, and put node/claude on PATH so the `claude` shebang and
# the sidecar's child process resolve. CLAUDE_BIN is honored by server.mjs.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$SERVER</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_BIN</key><string>$CLAUDE</string>
    <key>PATH</key><string>$NODE_DIR:$CLAUDE_DIR:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed LaunchAgent: $PLIST"
echo "  node:   $NODE"
echo "  claude: $CLAUDE"
echo "  log:    $LOG"
echo
echo "The sidecar should now be running. Verify:"
echo "  curl -s http://127.0.0.1:8765/health"
