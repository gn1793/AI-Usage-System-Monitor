#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/AIUsageSystemMonitor.app"
[[ -x "$APP/Contents/MacOS/AIUsageSystemMonitor" ]] || { echo 'Build first: ./scripts/build.sh' >&2; exit 1; }
DEST="$HOME/Applications"
FINAL_APP="$DEST/AIUsageSystemMonitor.app"
mkdir -p "$DEST"
STAGING="$(mktemp -d "$DEST/.aiusage-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/AIUsageSystemMonitor.app"
codesign --verify --deep --strict "$STAGING/AIUsageSystemMonitor.app"
BACKUP="$DEST/AIUsageSystemMonitor-backup-$(date +%Y%m%d-%H%M%S).app.backup"
if [[ -e "$FINAL_APP" ]]; then
  if [[ "${NO_LAUNCH:-0}" != '1' ]]; then
    echo 'Closing existing application, if running...'
    if pkill -f "^$FINAL_APP/Contents/MacOS/AIUsageSystemMonitor$"; then
      :
    else
      STOP_RESULT=$?
      if [[ "$STOP_RESULT" != '1' ]]; then
        echo 'Could not close the running app. Quit it first, or use NO_LAUNCH=1 to stage the update.' >&2
        exit 1
      fi
    fi
  fi
  mv "$FINAL_APP" "$BACKUP"
fi
if ! mv "$STAGING/AIUsageSystemMonitor.app" "$FINAL_APP"; then
  if [[ -e "$BACKUP" ]]; then mv "$BACKUP" "$FINAL_APP"; fi
  exit 1
fi
echo "Installed: $FINAL_APP"
if [[ -e "$BACKUP" ]]; then echo "Previous app backup: $BACKUP"; fi
if [[ "${NO_LAUNCH:-0}" != '1' ]]; then
  open "$FINAL_APP"
else
  echo 'Launch skipped. Any running previous version remains active until you quit and reopen it.'
fi
