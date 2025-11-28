#!/bin/bash
# ============================================
# Prewarm Worker - Optimized Version
# - Single curl request (no HEAD)
# - Batch processing with job control
# - Lower CPU/memory footprint
# - Per-variant stats
# - CF POP location tracking
# ============================================

JOB_ID="$1"
URL="$2"
PARALLEL="${3:-5}"

# Paths
PREWARM_DIR="/var/lib/prewarm"
RUNNING_DIR="$PREWARM_DIR/running"
JOB_FILE="$RUNNING_DIR/$JOB_ID.job"

# Configuration
TIMEOUT=10

# Update job file (atomic)
update_job() {
    local key="$1"
    local val="$2"
    if [ -f "$JOB_FILE" ]; then
        sed -i "s|\"${key}\": [0-9]*|\"${key}\": ${val}|" "$JOB_FILE"
    fi
}

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

log "Starting prewarm: $URL (parallel: $PARALLEL)"

# Get base URL and protocol
BASE_URL=$(dirname "$URL")
PROTOCOL=$(echo "$URL" | grep -oE "^https?")
DOMAIN=$(echo "$URL" | grep -oE "^https?://[^/]+")

# Build full URL helper
build_url() {
    local seg="$1" base="$2"
    case "$seg" in
        http*) echo "$seg" ;;
        //*) echo "${PROTOCOL}:${seg}" ;;
        /*) echo "${DOMAIN}${seg}" ;;
        *) echo "$base/$seg" ;;
    esac
}

# Fetch master playlist
MASTER=$(curl -s --max-time $TIMEOUT "$URL")
[ -z "$MASTER" ] && { log "ERROR: Failed to fetch master playlist"; exit 1; }

# Collect all URLs
URLS_FILE=$(mktemp)
echo "$URL" >> "$URLS_FILE"

# Parse playlists and track variants
VARIANTS_FILE=$(mktemp)
CHILD_PLAYLISTS=$(echo "$MASTER" | grep -E "\.m3u8$" | grep -v "^#" || true)

if [ -n "$CHILD_PLAYLISTS" ]; then
    while IFS= read -r child; do
        [ -z "$child" ] && continue
        CHILD_URL=$(build_url "$child" "$BASE_URL")
        echo "$CHILD_URL" >> "$URLS_FILE"
        
        # Extract variant name from path (e.g., mz_SfNml-hUhP from /mz_SfNml-hUhP/video.m3u8)
        VARIANT=$(echo "$CHILD_URL" | grep -oP '(?<=/)[^/]+(?=/[^/]+\.m3u8$)')
        [ -n "$VARIANT" ] && echo "$VARIANT" >> "$VARIANTS_FILE"
        
        CHILD_BASE=$(dirname "$CHILD_URL")
        curl -s --max-time $TIMEOUT "$CHILD_URL" | grep -E "\.ts$|\.jpeg$|^https?://|^//" | grep -v "^#" | while read -r seg; do
            [ -n "$seg" ] && echo "$(build_url "$seg" "$CHILD_BASE")" >> "$URLS_FILE"
        done
    done <<< "$CHILD_PLAYLISTS"
else
    echo "$MASTER" | grep -E "\.ts$|\.jpeg$|^https?://|^//" | grep -v "^#" | while read -r seg; do
        [ -n "$seg" ] && build_url "$seg" "$BASE_URL" >> "$URLS_FILE"
    done
fi

# Get unique variants
VARIANTS=$(sort -u "$VARIANTS_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
rm -f "$VARIANTS_FILE"

# Remove duplicates (keep first column for URL)
cut -d'|' -f1 "$URLS_FILE" | sort -u -o "${URLS_FILE}.clean"
mv "${URLS_FILE}.clean" "$URLS_FILE"

TOTAL=$(wc -l < "$URLS_FILE" | tr -d ' ')
log "Found $TOTAL unique URLs"
log "Variants: ${VARIANTS:-none}"
update_job "total" "$TOTAL"

# Stats file - format: STATUS|CACHE|POP|VARIANT|URL
STATS_FILE=$(mktemp)
POP_FILE=$(mktemp)

# Optimized HEAD-only prewarm (no body download)
do_prewarm() {
    local url="$1"
    
    # Extract variant from URL path (e.g., mz_SfNml-hUhP from /mz_SfNml-hUhP/video.m3u8)
    # Match: /{variant_id}/something.ts or /{variant_id}/video.m3u8
    local variant=$(echo "$url" | grep -oP '(?<=/)[^/]+(?=/[^/]+\.(ts|m3u8|jpeg))')
    [ -z "$variant" ] && variant="master"
    
    # HEAD request only - fast & no bandwidth
    local result=$(curl -s -I -4 \
        --connect-timeout 5 \
        --max-time $TIMEOUT \
        -w "\n%{http_code}|%{time_total}" \
        "$url" 2>/dev/null)
    
    local last_line=$(echo "$result" | tail -1)
    local code="${last_line%%|*}"
    local time_sec="${last_line##*|}"
    # แปลงเป็น ms โดยไม่ใช้ awk (เอาแค่ 3 ตำแหน่งแรกหลังจุด)
    local time_ms="${time_sec%%.*}$(echo "${time_sec#*.}" | cut -c1-3)"
    time_ms=$((10#${time_ms:-0}))
    
    local cache=$(echo "$result" | grep -i "cf-cache-status:" | awk '{print $2}' | tr -d '\r')
    local pop=$(echo "$result" | grep -i "cf-ray:" | sed 's/.*-//' | tr -d '\r' | head -c10)
    
    # Save POP location
    [ -n "$pop" ] && echo "$pop" >> "$POP_FILE"
    
    if [ "$code" = "200" ] || [ "$code" = "206" ]; then
        echo "OK|${cache:-NONE}|${pop:-UNK}|${variant}" >> "$STATS_FILE"
        echo "✓ $code | ${cache:-"-"} | ${pop:-"-"} | ${time_ms}ms | ${variant} | ${url##*/}"
    else
        echo "FAIL|${cache:-NONE}|${pop:-UNK}|${variant}" >> "$STATS_FILE"
        echo "✗ ${code:-ERR} | ${cache:-"-"} | ${pop:-"-"} | ${time_ms}ms | ${variant} | ${url##*/}"
    fi
}

# Background progress updater
(
    while [ -f "$JOB_FILE" ]; do
        sleep 3
        [ -f "$STATS_FILE" ] || continue
        
        p=$(wc -l < "$STATS_FILE" 2>/dev/null | tr -d ' ')
        h=$(grep -c "|HIT|" "$STATS_FILE" 2>/dev/null || echo 0)
        m=$(grep -c "|MISS|" "$STATS_FILE" 2>/dev/null || echo 0)
        e=$(grep -c "|EXPIRED|" "$STATS_FILE" 2>/dev/null || echo 0)
        f=$(grep -c "^FAIL|" "$STATS_FILE" 2>/dev/null || echo 0)
        
        if [ -f "$JOB_FILE" ]; then
            sed -i "s|\"progress\": [0-9]*|\"progress\": ${p}|" "$JOB_FILE" 2>/dev/null
            sed -i "s|\"hit\": [0-9]*|\"hit\": ${h}|" "$JOB_FILE" 2>/dev/null
            sed -i "s|\"miss\": [0-9]*|\"miss\": ${m}|" "$JOB_FILE" 2>/dev/null
            sed -i "s|\"expired\": [0-9]*|\"expired\": ${e}|" "$JOB_FILE" 2>/dev/null
            sed -i "s|\"failed\": [0-9]*|\"failed\": ${f}|" "$JOB_FILE" 2>/dev/null
        fi
    done
) &
PROGRESS_PID=$!

# Process URLs with controlled parallelism
log "Pre-warming..."

# Use job control for parallel execution
exec 3< "$URLS_FILE"
running=0

while read -r url <&3; do
    [ -z "$url" ] && continue
    
    do_prewarm "$url" &
    ((running++))
    
    # Wait if at parallel limit
    if [ $running -ge $PARALLEL ]; then
        wait -n 2>/dev/null || wait
        ((running--))
    fi
done

# Stop progress updater first (before wait)
kill $PROGRESS_PID 2>/dev/null
wait $PROGRESS_PID 2>/dev/null

# Wait for remaining curl jobs
wait
exec 3<&-

# Final stats
PROGRESS=$(wc -l < "$STATS_FILE" 2>/dev/null | tr -d ' ')
HIT=$(grep -c "|HIT|" "$STATS_FILE" 2>/dev/null || echo 0)
MISS=$(grep -c "|MISS|" "$STATS_FILE" 2>/dev/null || echo 0)
EXPIRED=$(grep -c "|EXPIRED|" "$STATS_FILE" 2>/dev/null || echo 0)
FAILED=$(grep -c "^FAIL|" "$STATS_FILE" 2>/dev/null || echo 0)

# Get unique CF POPs
CF_POPS=$(sort -u "$POP_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# Per-variant stats
log ""
log "=========================================="
log "Per-Variant Stats:"
log "------------------------------------------"

# Build variant stats JSON
VARIANT_STATS="["
FIRST_VARIANT=true

for variant in $(cut -d'|' -f4 "$STATS_FILE" 2>/dev/null | sort -u); do
    [ -z "$variant" ] && continue
    
    v_total=$(grep "|${variant}$" "$STATS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    v_hit=$(grep "|HIT|.*|${variant}$" "$STATS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    v_miss=$(grep "|MISS|.*|${variant}$" "$STATS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    v_expired=$(grep "|EXPIRED|.*|${variant}$" "$STATS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    v_failed=$(grep "^FAIL|.*|${variant}$" "$STATS_FILE" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$v_total" -gt 0 ]; then
        v_hitrate=$(awk "BEGIN {printf \"%.1f\", ($v_hit / $v_total) * 100}")
    else
        v_hitrate="0.0"
    fi
    
    log "  $variant: $v_total total | HIT $v_hit | MISS $v_miss | ${v_hitrate}%"
    
    # Add to JSON
    if [ "$FIRST_VARIANT" = true ]; then
        FIRST_VARIANT=false
    else
        VARIANT_STATS="$VARIANT_STATS,"
    fi
    VARIANT_STATS="$VARIANT_STATS{\"name\":\"$variant\",\"total\":$v_total,\"hit\":$v_hit,\"miss\":$v_miss,\"expired\":$v_expired,\"failed\":$v_failed}"
done
VARIANT_STATS="$VARIANT_STATS]"

log "------------------------------------------"
log "CF Cache Locations: ${CF_POPS:-none}"
log "=========================================="

update_job "progress" "$PROGRESS"
update_job "hit" "$HIT"
update_job "miss" "$MISS"
update_job "expired" "$EXPIRED"
update_job "failed" "$FAILED"

# Save extended stats to job file
if [ -f "$JOB_FILE" ]; then
    # Add cf_pops and variants to job file
    sed -i "s|\"failed\": [0-9]*|\"failed\": $FAILED,\n  \"cf_pops\": \"$CF_POPS\",\n  \"variants\": $VARIANT_STATS|" "$JOB_FILE" 2>/dev/null || true
fi

log ""
log "=========================================="
log "Summary: $TOTAL total | HIT $HIT | MISS $MISS | EXPIRED $EXPIRED | FAILED $FAILED"
[ "$TOTAL" -gt 0 ] && log "Hit Rate: $(awk "BEGIN {printf \"%.1f\", ($HIT / $TOTAL) * 100}")%"
log "CF POPs: ${CF_POPS:-none}"
log "=========================================="
log "Completed!"

rm -f "$URLS_FILE" "$STATS_FILE" "$POP_FILE"
