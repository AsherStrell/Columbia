#!/usr/bin/env bash
# Downloads YouTube audio → MP3 into music_files/ per tools/audio-manifest.json.
# Idempotent: skips files that already exist (>50KB).
# Usage:  ./tools/download-audio.sh
# Deps:   yt-dlp, ffmpeg, jq  (brew install yt-dlp ffmpeg jq)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/tools/audio-manifest.json"
OUT_DIR="${ROOT}/music_files"

# --- preflight ---
for cmd in yt-dlp ffmpeg jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing dependency: $cmd"
    echo "Install with:  brew install yt-dlp ffmpeg jq"
    exit 1
  fi
done

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found at $MANIFEST"
  exit 1
fi

mkdir -p "$OUT_DIR"

TOTAL=$(jq 'length' "$MANIFEST")
echo "Manifest entries: $TOTAL"
echo "Output directory: $OUT_DIR"
echo

declare -a FAILED
SUCCESS=0
SKIPPED=0

for i in $(seq 0 $((TOTAL - 1))); do
  entry=$(jq -c ".[$i]" "$MANIFEST")
  piece_id=$(jq -r '.pieceId' <<<"$entry")
  out_file=$(jq -r '.outputFile' <<<"$entry")
  yt_url=$(jq -r '.ytUrl // empty' <<<"$entry")
  search_fb=$(jq -r '.searchFallback // empty' <<<"$entry")
  trim_start=$(jq -r '.trim.start // empty' <<<"$entry")
  trim_end=$(jq -r '.trim.end // empty' <<<"$entry")
  out_path="${OUT_DIR}/${out_file}"

  printf '[%2d/%d] %-32s -> %s\n' "$((i + 1))" "$TOTAL" "$piece_id" "$out_file"

  # idempotent skip
  if [[ -f "$out_path" ]]; then
    size=$(stat -f%z "$out_path" 2>/dev/null || stat -c%s "$out_path" 2>/dev/null || echo 0)
    if [[ "$size" -gt 50000 ]]; then
      echo "        SKIP (already present, ${size} bytes)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # resolve source
  if [[ -n "$yt_url" ]]; then
    source="$yt_url"
  elif [[ -n "$search_fb" ]]; then
    source="ytsearch1:${search_fb}"
  else
    echo "        FAILED (no ytUrl or searchFallback)"
    FAILED+=("$piece_id (no source)")
    continue
  fi

  # yt-dlp output template — yt-dlp will use %(ext)s as the extension placeholder
  # and replace with mp3 (because of -x --audio-format mp3).
  # We use a temp basename so we can rename to the exact target afterward.
  tmp_base="${OUT_DIR}/.dl_${piece_id}"
  rm -f "${tmp_base}.mp3"

  if yt-dlp \
      --no-playlist \
      --quiet --no-warnings --progress \
      -x --audio-format mp3 --audio-quality 0 \
      --embed-metadata \
      -o "${tmp_base}.%(ext)s" \
      "$source" 2>&1 | tail -n 5; then
    if [[ -f "${tmp_base}.mp3" ]]; then
      if [[ -n "$trim_start" && -n "$trim_end" ]]; then
        # Trim with ffmpeg (fast seek before -i, re-encode for accurate cut points).
        if ffmpeg -y -loglevel error \
              -ss "$trim_start" -to "$trim_end" \
              -i "${tmp_base}.mp3" \
              -c:a libmp3lame -q:a 2 \
              "$out_path"; then
          rm -f "${tmp_base}.mp3"
          SUCCESS=$((SUCCESS + 1))
          sz=$(stat -f%z "$out_path" 2>/dev/null || stat -c%s "$out_path" 2>/dev/null || echo 0)
          echo "        OK trimmed [${trim_start}..${trim_end}] (${sz} bytes)"
        else
          echo "        FAILED (ffmpeg trim error)"
          FAILED+=("$piece_id (ffmpeg trim)")
          rm -f "${tmp_base}.mp3"
        fi
      else
        mv "${tmp_base}.mp3" "$out_path"
        SUCCESS=$((SUCCESS + 1))
        sz=$(stat -f%z "$out_path" 2>/dev/null || stat -c%s "$out_path" 2>/dev/null || echo 0)
        echo "        OK (${sz} bytes)"
      fi
    else
      echo "        FAILED (yt-dlp succeeded but mp3 not found)"
      FAILED+=("$piece_id (mp3 missing post-download)")
    fi
  else
    echo "        FAILED (yt-dlp non-zero exit)"
    FAILED+=("$piece_id (yt-dlp exit)")
    rm -f "${tmp_base}".*
  fi
done

echo
echo "===== SUMMARY ====="
echo "  Success: $SUCCESS"
echo "  Skipped: $SKIPPED"
echo "  Failed:  ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "Failures (retry by hand):"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
fi
echo

# Final audit: list any expected files still missing
MISSING=()
while IFS= read -r expected; do
  if [[ ! -f "${OUT_DIR}/${expected}" ]]; then
    MISSING+=("$expected")
  fi
done < <(jq -r '.[].outputFile' "$MANIFEST")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Missing files (${#MISSING[@]}):"
  for m in "${MISSING[@]}"; do echo "  - $m"; done
  exit 2
fi

echo "All manifest entries present in music_files/."
