#!/bin/bash
set -euo pipefail
# Run from any directory after building or extracting the source workspace.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/../../release/native/Local Voice.app"
DESTINATION="$HOME/Applications/Local Voice.app"
if [[ "$(uname -s)" != Darwin ]]; then echo 'This installer requires macOS.' >&2; exit 1; fi
if [[ ! -d "$SOURCE_APP" ]]; then echo 'Build the app first: npm ci && npm run build:native' >&2; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
if [[ -e "$DESTINATION" ]]; then
  echo "An app already exists at $DESTINATION. Quit it and replace it in Finder after saving your work." >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$SOURCE_APP" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
/usr/bin/open "$DESTINATION"
echo "Installed $DESTINATION"
