#!/bin/bash
# Usage: scripts/sparkle.sh <setup|check|backup FILE>
#   setup   Make auto-updates ready: fetch Sparkle's tools, create the signing
#           key if the keychain has none (and write its public half to
#           Info.plist), and upload the private key as the GitHub secret
#           SPARKLE_ED_PRIVATE_KEY if it is missing. Safe to re-run.
#   check   Verify the Info.plist key matches the keychain and the secret is
#           set. Exits non-zero otherwise. Runs before every release.
#   backup  Export the private key to FILE (keep it outside the repo).
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=wal-ley/Info.plist
DD=.build/sparkle
SECRET=SPARKLE_ED_PRIVATE_KEY

tools() {
  local dir="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
  if [ ! -x "$dir/generate_keys" ]; then
    if xcode-select -p | grep -q CommandLineTools; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    echo "Fetching Sparkle tools…" >&2
    xcodebuild -resolvePackageDependencies -project wal-ley.xcodeproj -scheme wal-ley \
      -derivedDataPath "$DD" >/dev/null
  fi
  echo "$dir"
}

have_gh() { command -v gh >/dev/null && gh auth status >/dev/null 2>&1; }
secret_set() { gh secret list | awk '{print $1}' | grep -qx "$SECRET"; }
plist_key() { /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || true; }
keychain_key() { "$BIN/generate_keys" -p 2>/dev/null || true; }

upload() {
  local f; f="$(mktemp)"; trap 'rm -f "$f"' RETURN
  "$BIN/generate_keys" -x "$f"
  gh secret set "$SECRET" < "$f"
}

BIN="$(tools)"
cmd="${1:-}"
case "$cmd" in
  setup)
    key="$(keychain_key)"
    if [ -z "$key" ]; then
      echo "No signing key in the keychain; generating one."
      "$BIN/generate_keys" >/dev/null
      key="$(keychain_key)"
      /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $key" "$PLIST"
      echo "Wrote the new public key to $PLIST. Commit it, and back the key up."
    fi
    [ "$(plist_key)" = "$key" ] || { echo "Info.plist SUPublicEDKey does not match the keychain key." >&2; exit 1; }
    echo "Public key OK: $key"
    if have_gh; then
      if secret_set; then echo "GitHub secret $SECRET already set."
      else upload; echo "Uploaded GitHub secret $SECRET."; fi
    else
      echo "gh is missing or not logged in. Install it (brew install gh && gh auth login)," >&2
      echo "then re-run, or set $SECRET yourself from: scripts/sparkle.sh backup FILE" >&2
      exit 1
    fi
    ;;
  check)
    key="$(keychain_key)"
    [ -n "$key" ] || { echo "No Sparkle key in the keychain. Run: task update-setup" >&2; exit 1; }
    [ "$(plist_key)" = "$key" ] || { echo "Info.plist SUPublicEDKey does not match the keychain key." >&2; exit 1; }
    if have_gh; then
      secret_set || { echo "GitHub secret $SECRET is missing. Run: task update-setup" >&2; exit 1; }
      echo "Sparkle OK."
    else
      echo "Sparkle key OK; could not verify the GitHub secret (gh missing or not logged in)." >&2
    fi
    ;;
  backup)
    [ -n "${2:-}" ] || { echo "usage: $0 backup FILE" >&2; exit 1; }
    "$BIN/generate_keys" -x "$2"
    chmod 600 "$2"
    ;;
  *) echo "usage: $0 <setup|check|backup FILE>" >&2; exit 1 ;;
esac
