#!/usr/bin/env bash
# export-case-archive.sh — Export Jawafdehi case archive from API
#
# Usage:
#   ./scripts/export-case-archive.sh [OPTIONS]
#
# Options:
#   --output-dir DIR      Output directory (default: ./case-archive)
#   --format FORMAT       Output format: jsonl, json, or both (default: both)
#   --case-type TYPE      Filter by case type (CORRUPTION, PROMISES)
#   --search TERM         Full-text search filter
#   --include-sources     Fetch detailed source info per case (slower)
#   --include-entities    Fetch entity details per case
#   --max-pages N         Maximum pages to fetch (default: unlimited)
#   --base-url URL        API base URL (default: https://api.jawafdehi.org/api)
#   --api-key KEY         API key for token auth (optional, used for draft access)
#   --resume              Resume from last checkpoint
#   --help                Show this message
#
# Requirements: curl, jq
#
# Output structure:
#   <output-dir>/
#   ├── cases/                    # Individual case JSON files
#   │   └── <slug>.json
#   ├── cases.jsonl               # All cases as JSONL (when format=jsonl or both)
#   ├── cases.json                # All cases as JSON array (when format=json or both)
#   ├── index.json                # Export manifest
#   └── checkpoint                # Resume checkpoint

set -euo pipefail

# ── defaults ──────────────────────────────────────────────
OUTPUT_DIR="./case-archive"
FORMAT="both"
CASE_TYPE=""
SEARCH=""
INCLUDE_SOURCES=false
INCLUDE_ENTITIES=false
MAX_PAGES=0
BASE_URL="${JAWAFDEHI_API_URL:-https://api.jawafdehi.org/api}"
API_KEY="${JAWAFDEHI_API_KEY:-}"
RESUME=false
PAGE_SIZE=20

# ── URL encoding helper ───────────────────────────────────
urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null \
    || python -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# ── parse args ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    --format)          FORMAT="$2"; shift 2 ;;
    --case-type)       CASE_TYPE="$2"; shift 2 ;;
    --search)          SEARCH="$2"; shift 2 ;;
    --include-sources) INCLUDE_SOURCES=true; shift ;;
    --include-entities) INCLUDE_ENTITIES=true; shift ;;
    --max-pages)       MAX_PAGES="$2"; shift 2 ;;
    --base-url)        BASE_URL="$2"; shift 2 ;;
    --api-key)         API_KEY="$2"; shift 2 ;;
    --resume)          RESUME=true; shift ;;
    --help)
      sed -n '2,31p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# Validate format
case "$FORMAT" in
  jsonl|json|both) ;;
  *) echo "Invalid format: $FORMAT (must be jsonl, json, or both)" >&2; exit 1 ;;
esac

# ── auth header ───────────────────────────────────────────
AUTH_HEADER=()
if [[ -n "$API_KEY" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")
fi

# ── setup directories ─────────────────────────────────────
CASES_DIR="$OUTPUT_DIR/cases"
CHECKPOINT_FILE="$OUTPUT_DIR/checkpoint"

# Clean stale files on fresh start
if ! $RESUME; then
  rm -rf "$CASES_DIR"
fi
mkdir -p "$CASES_DIR"

# ── resume ────────────────────────────────────────────────
START_PAGE=1
EXISTING_COUNT=0
if $RESUME && [[ -f "$CHECKPOINT_FILE" ]]; then
  START_PAGE=$(cat "$CHECKPOINT_FILE")
  # Count already-exported cases for accurate totals
  EXISTING_COUNT=$(ls "$CASES_DIR"/*.json 2>/dev/null | wc -l)
  echo "[export] Resuming from page $START_PAGE ($EXISTING_COUNT cases already exported)"
fi

# ── build query params ────────────────────────────────────
build_url() {
  local page=$1
  local url="$BASE_URL/cases/?page=$page&page_size=$PAGE_SIZE"
  [[ -n "$CASE_TYPE" ]] && url="$url&case_type=$(urlencode "$CASE_TYPE")"
  [[ -n "$SEARCH" ]] && url="$url&search=$(urlencode "$SEARCH")"
  echo "$url"
}

# ── fetch case detail ─────────────────────────────────────
fetch_case_detail() {
  local slug=$1
  local detail_url="$BASE_URL/cases/$slug/"
  local sep="?"
  if $INCLUDE_SOURCES; then
    detail_url="$detail_url${sep}fetch_sources=true"
    sep="&"
  fi
  if $INCLUDE_ENTITIES; then
    detail_url="$detail_url${sep}fetch_entities=true"
    sep="&"
  fi
  curl -sS --fail-with-body --connect-timeout 10 --max-time 30 "${AUTH_HEADER[@]}" "$detail_url"
}

# ── main export loop ──────────────────────────────────────
echo "[export] Starting case archive export"
echo "[export] Base URL: $BASE_URL"
echo "[export] Output: $OUTPUT_DIR"
echo "[export] Format: $FORMAT"

TOTAL_CASES=$EXISTING_COUNT
PAGE=$START_PAGE

# Clear output files on fresh start
if ! $RESUME || [[ $START_PAGE -eq 1 ]]; then
  [[ "$FORMAT" == "jsonl" || "$FORMAT" == "both" ]] && : > "$OUTPUT_DIR/cases.jsonl"
  [[ "$FORMAT" == "json" || "$FORMAT" == "both" ]] && echo "[]" > "$OUTPUT_DIR/cases.json"
fi

while :; do
  # Check max pages limit
  if [[ $MAX_PAGES -gt 0 && $PAGE -gt $MAX_PAGES ]]; then
    echo "[export] Reached max pages limit ($MAX_PAGES)"
    break
  fi

  URL=$(build_url "$PAGE")
  echo "[export] Fetching page $PAGE: $URL"

  RESPONSE=$(curl -sS --fail-with-body --connect-timeout 10 --max-time 30 "${AUTH_HEADER[@]}" "$URL") || {
    echo "[export] HTTP request failed on page $PAGE (exit code $?)" >&2
    exit 1
  }

  # Check for API errors
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.detail // .error // empty')
  if [[ -n "$ERROR_MSG" ]]; then
    echo "[export] API error on page $PAGE: $ERROR_MSG" >&2
    exit 1
  fi

  # Extract results
  RESULTS=$(echo "$RESPONSE" | jq -c '.results') || {
    echo "[export] Failed to parse JSON response on page $PAGE" >&2
    echo "[export] Response: ${RESPONSE:0:500}" >&2
    exit 1
  }
  COUNT=$(echo "$RESULTS" | jq 'length') || {
    echo "[export] Failed to count results on page $PAGE" >&2
    exit 1
  }

  if [[ "$COUNT" -eq 0 ]]; then
    echo "[export] No more results — export complete"
    break
  fi

  # Process each case on this page
  PAGE_CASES=0
  for i in $(seq 0 $((COUNT - 1))); do
    CASE_JSON=$(echo "$RESULTS" | jq -c ".[$i]")
    SLUG=$(echo "$CASE_JSON" | jq -r '.slug // empty')

    # Save individual case file
    echo "$CASE_JSON" | jq '.' > "$CASES_DIR/${SLUG}.json"

    # Fetch detail if requested
    if $INCLUDE_SOURCES || $INCLUDE_ENTITIES; then
      DETAIL=$(fetch_case_detail "$SLUG") || {
        echo "[export] Warning: failed to fetch detail for case $SLUG (continuing)" >&2
      }
      if [[ -n "${DETAIL:-}" ]]; then
        echo "$DETAIL" | jq '.' > "$CASES_DIR/${SLUG}.json"
        CASE_JSON="$DETAIL"
      fi
    fi

    # Append to JSONL if format requires it
    if [[ "$FORMAT" == "jsonl" || "$FORMAT" == "both" ]]; then
      echo "$CASE_JSON" >> "$OUTPUT_DIR/cases.jsonl"
    fi

    PAGE_CASES=$((PAGE_CASES + 1))
    TOTAL_CASES=$((TOTAL_CASES + 1))
  done

  echo "[export] Page $PAGE: $PAGE_CASES cases (total in export: $TOTAL_CASES)"

  # Save checkpoint
  echo "$((PAGE + 1))" > "$CHECKPOINT_FILE"

  # Check if we got a full page (if not, we're at the end)
  if [[ "$COUNT" -lt $PAGE_SIZE ]]; then
    echo "[export] Partial page — export complete"
    break
  fi

  PAGE=$((PAGE + 1))
  sleep 0.3  # Rate limiting
done

# ── build JSON array ──────────────────────────────────────
if [[ $TOTAL_CASES -gt 0 ]]; then
  if [[ "$FORMAT" == "json" || "$FORMAT" == "both" ]]; then
    echo "[export] Building JSON array..."
    if [[ "$FORMAT" == "both" ]]; then
      jq -s '.' "$OUTPUT_DIR/cases.jsonl" > "$OUTPUT_DIR/cases.json"
    else
      # When format=json only, compile from individual files
      jq -s '.' "$CASES_DIR"/*.json > "$OUTPUT_DIR/cases.json" 2>/dev/null || \
        echo "[]" > "$OUTPUT_DIR/cases.json"
    fi
  fi
fi

# ── create manifest ───────────────────────────────────────
EXPORT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EXPORT_DATE_PT=$(TZ=America/Los_Angeles date +"%Y-%m-%dT%H:%M:%S%z")
MANIFEST=$(cat <<JSON
{
  "export_date_utc": "$EXPORT_DATE",
  "export_date_pt": "$EXPORT_DATE_PT",
  "total_cases": $TOTAL_CASES,
  "base_url": "$BASE_URL",
  "case_type": "${CASE_TYPE:-all}",
  "search": "${SEARCH:-none}",
  "include_sources": $INCLUDE_SOURCES,
  "include_entities": $INCLUDE_ENTITIES,
  "format": "$FORMAT",
  "files": {
    "cases_jsonl": "cases.jsonl",
    "cases_json": "cases.json",
    "cases_dir": "cases/",
    "manifest": "index.json"
  }
}
JSON
)
echo "$MANIFEST" | jq '.' > "$OUTPUT_DIR/index.json"

# ── summary ───────────────────────────────────────────────
echo ""
echo "──────────── Export Summary ────────────"
echo "  Total cases:       $TOTAL_CASES"
echo "  Output directory:  $OUTPUT_DIR"
echo "  Manifest:          $OUTPUT_DIR/index.json"
[[ "$FORMAT" == "jsonl" || "$FORMAT" == "both" ]] && echo "  Cases JSONL:       $OUTPUT_DIR/cases.jsonl"
[[ "$FORMAT" == "json" || "$FORMAT" == "both" ]] && echo "  Cases JSON:        $OUTPUT_DIR/cases.json"
echo "  Individual cases:  $CASES_DIR/"
echo "  Export date (PT):  $EXPORT_DATE_PT"
echo "────────────────────────────────────────"

# Clean up checkpoint on successful completion
rm -f "$CHECKPOINT_FILE"
echo "[export] Done — checkpoint cleared"
