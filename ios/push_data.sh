#!/bin/zsh
# Copy the PC game folder to the iPad (/var/mobile/Media/NFSU2). Resumable: only files
# missing on the device or with a different size are sent (the iPad has no rsync).
# Skipped: MOVIES (the port runs with NOMOVIES), SDATA_OLD, Support, Windows DLLs/EXEs
# other than SPEED2.EXE. Game data: never commit it.
# Usage: ios/push_data.sh "<game dir>" [ssh-host]     env IPAD_SSH_OPTS: extra ssh options
set -euo pipefail
GAME="$1"; HOST="${2:-ipadmini2}"
[[ -f "$GAME/SPEED2.EXE" && -d "$GAME/TRACKS" ]] || { echo "not a game dir: $GAME" >&2; exit 1; }
ROOT=/var/mobile/Media/NFSU2
SSH=(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=8 ${=IPAD_SSH_OPTS:-} "$HOST")
TMP=$(mktemp -d)
"${SSH[@]}" "mkdir -p $ROOT && cd $ROOT && find . -type f -exec ls -ln {} +" \
  | perl -ane 'print "$F[4] ", join(" ", @F[8..$#F]), "\n"' | sort > "$TMP/remote"
( cd "$GAME" && find . -type f \
    ! -path './MOVIES/*' ! -path './SDATA_OLD/*' ! -path './Support/*' ! -name '.DS_Store' \
    ! -iname '*.dll' ! -iname '*.asi' \( ! -iname '*.exe' -o -iname 'SPEED2.EXE' \) \
    -exec stat -f '%z %N' {} + ) | sort > "$TMP/local"
comm -23 "$TMP/local" "$TMP/remote" | cut -d' ' -f2- > "$TMP/todo"
echo "$(wc -l < "$TMP/todo" | tr -d ' ') of $(wc -l < "$TMP/local" | tr -d ' ') files to send"
if [[ -s "$TMP/todo" ]]; then
  ( cd "$GAME" && COPYFILE_DISABLE=1 tar cf - --no-xattrs -T "$TMP/todo" ) | "${SSH[@]}" "tar xf - -C $ROOT"
fi
"${SSH[@]}" "chown -R mobile:mobile $ROOT && du -sh $ROOT"
rm -rf "$TMP"
