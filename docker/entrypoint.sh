#!/bin/sh
# Starts as root only to read the master key secret (a mounted file is often root-only) and to make
# /data writable, then drops to the unprivileged "family" user for the server itself.
set -e

if [ "$(id -u)" = "0" ]; then
  if [ -n "$FAMILY_AI_MASTER_KEY_FILE" ]; then
    if [ ! -r "$FAMILY_AI_MASTER_KEY_FILE" ]; then
      echo "Fehler: Master-Schlüssel-Datei $FAMILY_AI_MASTER_KEY_FILE nicht lesbar" >&2
      exit 1
    fi
    FAMILY_AI_MASTER_KEY="$(cat "$FAMILY_AI_MASTER_KEY_FILE")"
    export FAMILY_AI_MASTER_KEY
    unset FAMILY_AI_MASTER_KEY_FILE
  fi
  chown family:family "$FAMILY_AI_DATA" 2>/dev/null || true
  exec setpriv --reuid=10001 --regid=10001 --clear-groups /app/FamilyAIServer "$@"
fi
exec /app/FamilyAIServer "$@"
