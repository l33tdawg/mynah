#!/usr/bin/env bash
# Installs the appliance as a launchd agent, so it survives a reboot and a crash.
#
# Until now the daemon was started with `nohup … &`, which means PPID 1 and no
# supervisor: if it crashed, or the Mac restarted, it simply stopped answering.
# The owner finds that out by messaging it and getting silence — the worst
# possible failure for an appliance whose whole job is to be there when wanted.
#
# Run ON the appliance:
#
#   scripts/install-daemon.sh --allow +60123456789 \
#     [--account +60123456789] \
#     [--provider deepseek] [--model deepseek-v4-flash] \
#     [--app "/Users/you/Applications/SAGE Voice Bridge.app"]
#
# Re-running is how you change the arguments: it rewrites the plist and reloads.
set -euo pipefail

LABEL="local.sage.voicebridge"
APP="${MYNAH_APP_PATH:-$HOME/Applications/SAGE Voice Bridge.app}"
ALLOW=""
ACCOUNT=""
PROVIDER=""
MODEL=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow)    ALLOW="${2:?}"; shift 2 ;;
    --account)  ACCOUNT="${2:?}"; shift 2 ;;
    --provider) PROVIDER="${2:?}"; shift 2 ;;
    --model)    MODEL="${2:?}"; shift 2 ;;
    --app)      APP="${2:?}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$ALLOW" ]] || die "--allow is required (your own Signal number)"
BIN="$APP/Contents/MacOS/sage-voiced"
SAGE="$APP/Contents/Resources/SAGE.app/Contents/MacOS/sage-gui"
[[ -x "$BIN" ]] || die "no sage-voiced at $BIN"
[[ -x "$SAGE" ]] || die "no sage-gui at $SAGE"

LOG_DIR="$HOME/.sage/logs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

# A LaunchAgent, not a LaunchDaemon. The appliance needs the owner's login
# keychain (provider keys) and their signal-cli socket, both of which live in the
# user session; a root LaunchDaemon has neither.
{
  cat <<PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>daemon</string>
    <string>--allow</string><string>$ALLOW</string>
PLIST_HEAD
  [[ -n "$ACCOUNT"  ]] && printf '    <string>--account</string><string>%s</string>\n' "$ACCOUNT"
  [[ -n "$PROVIDER" ]] && printf '    <string>--provider</string><string>%s</string>\n' "$PROVIDER"
  [[ -n "$MODEL"    ]] && printf '    <string>--model</string><string>%s</string>\n' "$MODEL"
  cat <<PLIST_TAIL
    <string>--sage</string><string>$SAGE</string>
  </array>

  <key>RunAtLoad</key><true/>
  <!-- The whole point: bring it back if it exits for any reason. -->
  <key>KeepAlive</key><true/>
  <!-- launchd throttles restarts to once per 10s by default. A daemon that
       cannot start (bad key, missing model) would otherwise spin; this makes the
       retry visible in the log rather than a busy loop. -->
  <key>ThrottleInterval</key><integer>30</integer>

  <!-- Pinned, and it matters. The node derives a per-project agent identity from
       the working directory when nothing overrides it, so an unset cwd is an
       appliance whose memories depend on where it happened to be started.
       MynahIdentity pins the key explicitly as well; this is the second lock. -->
  <key>WorkingDirectory</key><string>$HOME</string>

  <key>StandardOutPath</key><string>$LOG_DIR/sage-voiced.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/sage-voiced.log</string>

  <key>ProcessType</key><string>Interactive</string>
  <!-- Answering a message is latency-sensitive, so it must not be treated as
       background work and de-prioritised by App Nap. -->
  <key>LowPriorityIO</key><false/>
</dict>
</plist>
PLIST_TAIL
} > "$PLIST"

plutil -lint "$PLIST" >/dev/null || die "generated a malformed plist at $PLIST"

# bootout before bootstrap, so re-running this is how you change arguments.
# `|| true` because the first install has nothing to unload.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# Any daemon started the old way would race the supervised one for the Signal
# socket, and the symptom is answers arriving twice.
pkill -f "sage-voiced daemon" 2>/dev/null || true
sleep 2

launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

echo "installed $LABEL"
echo "  plist:  $PLIST"
echo "  log:    $LOG_DIR/sage-voiced.log"
echo
echo "It now starts at login and restarts if it exits."
echo "  stop:    launchctl bootout gui/$UID/$LABEL"
echo "  status:  launchctl print gui/$UID/$LABEL | head -20"
