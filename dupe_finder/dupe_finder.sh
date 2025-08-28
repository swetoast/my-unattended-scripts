#!/usr/bin/env bash

set -euo pipefail

DB_FILE="file_tracker.db"
THRESHOLD=5
timestamp=$(date +"%Y-%m-%d %H:%M:%S")
declare -A current_files

usage() {
  echo "Usage: $0 --mode {exact|phash|fuzzytext} --dir PATH [--threshold N]"
  exit 1
}

parse_args() {
  MODE=""
  DIR=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --mode) MODE="$2"; shift 2 ;;
      --dir) DIR="$2"; shift 2 ;;
      --threshold) THRESHOLD="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -z "$MODE" || -z "$DIR" ]] && usage
}

check_dependencies() {
  local deps_common=("sqlite3" "find" "awk" "stat")
  local deps_exact=("sha256sum")
  local deps_phash=("phash")
  local deps_fuzzy=("simhash" "pdftotext" "docx2txt")
  local missing=()

  for cmd in "${deps_common[@]}"; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done

  case "$MODE" in
    exact) for cmd in "${deps_exact[@]}"; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done ;;
    phash) for cmd in "${deps_phash[@]}"; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done ;;
    fuzzytext) for cmd in "${deps_fuzzy[@]}"; do command -v "$cmd" >/dev/null || missing+=("$cmd"); done ;;
  esac

  if (( ${#missing[@]} )); then
    echo "Missing: ${missing[*]}"
    echo "Debian/Ubuntu: sudo apt install ${missing[*]}"
    echo "Arch/Manjaro:  sudo pacman -S ${missing[*]}"
    exit 1
  fi
}

init_db() {
  sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS files (
  path TEXT PRIMARY KEY,
  hash TEXT,
  mode TEXT,
  last_seen TEXT
);
EOF
}

record_file() {
  local mode="$1" hash="$2" path="$3"
  current_files["$path"]=1
  sqlite3 "$DB_FILE" <<EOF
INSERT INTO files (path, hash, mode, last_seen)
VALUES ('$path', '$hash', '$mode', '$timestamp')
ON CONFLICT(path) DO UPDATE SET
  hash=excluded.hash,
  mode=excluded.mode,
  last_seen=excluded.last_seen;
EOF
}

scan_exact() {
  find "$DIR" -type f ! -size 0 -exec sha256sum {} + | sort | \
  awk '{ if (hash[$1]++) print "DUPLICATE:", $2 }' | \
  while read -r _ file; do
    hash=$(sha256sum "$file" | awk '{print $1}')
    record_file "exact" "$hash" "$file"
  done
}

scan_phash() {
  TMPFILE=$(mktemp)
  find "$DIR" -type f \( -iname '*.jpg' -o -iname '*.png' \) | \
  while read -r f; do
    H=$(phash "$f" 2>/dev/null | awk '{print $NF}')
    [[ -n "$H" ]] && echo "$H|$f"
  done > "$TMPFILE"

  while IFS='|' read -r h1 f1; do
    record_file "phash" "$h1" "$f1"
    while IFS='|' read -r h2 f2; do
      [[ "$f1" == "$f2" ]] && continue
      DIST=$(echo "$h1 $h2" | awk '{d=0; for(i=1;i<=length($1);i++) if(substr($1,i,1)!=substr($2,i,1)) d++; print d}')
      (( DIST <= THRESHOLD )) && echo "POSSIBLE DUPLICATE ($DIST): $f1 <> $f2"
    done < "$TMPFILE"
  done < "$TMPFILE"
  rm "$TMPFILE"
}

scan_fuzzytext() {
  find "$DIR" -type f | while read -r f; do
    case "$f" in
      *.pdf) TEXT=$(pdftotext "$f" -) ;;
      *.docx) TEXT=$(docx2txt < "$f" -) ;;
      *.txt) TEXT=$(cat "$f") ;;
      *) continue ;;
    esac
    HASH=$(echo "$TEXT" | simhash)
    record_file "fuzzytext" "$HASH" "$f"
  done | sort | uniq -w20 -d --all-repeated=separate
}

prune_db() {
  sqlite3 "$DB_FILE" <<EOF
DELETE FROM files
WHERE path NOT IN ($(printf "'%s'," "${!current_files[@]}" | sed 's/,$//'));
EOF
}

parse_args "$@"
check_dependencies
init_db

case "$MODE" in
  exact) scan_exact ;;
  phash) scan_phash ;;
  fuzzytext) scan_fuzzytext ;;
  *) usage ;;
esac

prune_db
echo "Scan complete. Database updated: $DB_FILE"
