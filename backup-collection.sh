#!/usr/bin/env bash
# Snapshot the Anki collection into backups/ before bulk card-mutation work.
# Run this with Anki CLOSED so the write-ahead log is flushed and the copy is
# clean.
#
# Finds the collection in Anki's default data folder for this OS:
#   macOS    ~/Library/Application Support/Anki2/<profile>
#   Linux    ~/.local/share/Anki2/<profile>
#   Windows  %APPDATA%\Anki2\<profile>   (from Git Bash)
#
# Environment overrides:
#   ANKI_PROFILE   profile name (default "User 1", Anki's default)
#   ANKI_BASE      the Anki2 data folder, if it isn't in the default place
#   BACKUP_KEEP    snapshots to keep (default 5); older ones are deleted,
#                  along with their -shm/-wal side files
set -euo pipefail

PROFILE="${ANKI_PROFILE:-User 1}"
if [[ -n "${ANKI_BASE:-}" ]]; then
  BASE="$ANKI_BASE"
else
  case "$(uname -s)" in
    Darwin) BASE="$HOME/Library/Application Support/Anki2" ;;
    Linux)  BASE="${XDG_DATA_HOME:-$HOME/.local/share}/Anki2" ;;
    MINGW*|MSYS*|CYGWIN*) BASE="${APPDATA}/Anki2" ;;
    *) echo "Unknown OS; set ANKI_BASE to your Anki2 data folder." >&2; exit 1 ;;
  esac
fi
SRC_DIR="$BASE/$PROFILE"
DEST_DIR="$(cd "$(dirname "$0")" && pwd)/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
KEEP="${BACKUP_KEEP:-5}"

if [[ ! -f "$SRC_DIR/collection.anki2" ]]; then
  echo "No collection found at: $SRC_DIR/collection.anki2" >&2
  if [[ -d "$BASE" ]]; then
    echo "Profiles in $BASE:" >&2
    for dir in "$BASE"/*/; do
      [[ -f "$dir/collection.anki2" ]] && echo "  $(basename "$dir")" >&2
    done
    echo "Set ANKI_PROFILE to one of these." >&2
  else
    echo "Set ANKI_BASE to your Anki2 data folder." >&2
  fi
  exit 1
fi

mkdir -p "$DEST_DIR"
for ext in .anki2 .anki2-shm .anki2-wal; do
  src="$SRC_DIR/collection$ext"
  [ -f "$src" ] || continue
  cp -p "$src" "$DEST_DIR/collection-backup-$STAMP$ext"
  echo "backed up collection$ext -> collection-backup-$STAMP$ext"
done
echo "Done: $DEST_DIR/collection-backup-$STAMP.anki2"

# Prune: timestamps sort chronologically by name, so everything before the last
# $KEEP main .anki2 files is older. (The glob expands in sorted order.)
shopt -s nullglob
backups=("$DEST_DIR"/collection-backup-*.anki2)
prune_count=$(( ${#backups[@]} - KEEP ))
for (( i = 0; i < prune_count; i++ )); do
  rm -f "${backups[$i]}" "${backups[$i]}-shm" "${backups[$i]}-wal"
  echo "pruned $(basename "${backups[$i]}")"
done
