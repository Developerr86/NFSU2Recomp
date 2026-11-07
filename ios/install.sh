#!/bin/zsh
# Install out/ios/NFSU2.app on the iPad (rootful jailbreak) and register it.
# The bundle is staged in /var/tmp first and its binary size checked; only then is
# /Applications/NFSU2.app replaced, so a dropped Wi-Fi connection can't leave a
# half-written app behind (seen 2026-11-07: "tar: Write error").
# Usage: ios/install.sh [ssh-host]      env IPAD_SSH_OPTS: extra ssh options
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-ipadmini2}"
APP=NFSU2.app
SZ=$(stat -f %z out/ios/$APP/NFSU2)
SSH=(ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=6 ${=IPAD_SSH_OPTS:-} "$HOST")
for try in 1 2 3; do
  if COPYFILE_DISABLE=1 tar cf - --no-xattrs -C out/ios "$APP" | "${SSH[@]}" \
       "rm -rf /var/tmp/nfsu2-stage && mkdir -p /var/tmp/nfsu2-stage && tar xf - -C /var/tmp/nfsu2-stage \
        && [ \$(stat -c %s /var/tmp/nfsu2-stage/$APP/NFSU2) = $SZ ]"; then
    break
  fi
  echo "transfer failed (try $try)"; [ $try = 3 ] && exit 1
done
"${SSH[@]}" "killall NFSU2 2>/dev/null; rm -rf /Applications/$APP && mv /var/tmp/nfsu2-stage/$APP /Applications/ \
   && chown -R root:wheel /Applications/$APP && chmod 755 /Applications/$APP/NFSU2 \
   && (uicache -p /Applications/$APP >/dev/null 2>&1 || uicache >/dev/null 2>&1); ls -l /Applications/$APP/NFSU2"
echo "installed; launch: ssh $HOST uiopen -b com.legacylab.nfsu2"
