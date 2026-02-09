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
CONFIG_FILE="$PREWARM_DIR/config"

# Load config
REF_DOMAIN=""
if [ -f "$CONFIG_FILE" ]; then
    REF_DOMAIN=$(grep "^REF_DOMAIN=" "$CONFIG_FILE" | cut -d'=' -f2)
fi

# Configuration
TIMEOUT=10

# Build curl headers
CURL_HEADERS=""
if [ -n "$REF_DOMAIN" ]; then
    CURL_HEADERS="-H 'Referer: $REF_DOMAIN'"
fi

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
MASTER=$(curl -s --max-time $TIMEOUT $CURL_HEADERS "$URL")
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
        curl -s --max-time $TIMEOUT $CURL_HEADERS "$CHILD_URL" | grep -E "\.ts$|\.jpeg$|^https?://|^//" | grep -v "^#" | while read -r seg; do
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

# Stats file - format: STATUS|CACHE|POP|VARIANT
STATS_FILE=$(mktemp)
POP_FILE=$(mktemp)

# Background progress updater (optimized - less frequent updates)
(
    while [ -f "$JOB_FILE" ]; do
        sleep 5
        [ -f "$STATS_FILE" ] || continue
        [ -f "$JOB_FILE" ] || break
        
        # Use single awk call instead of multiple grep
        stats=$(awk -F'|' '
            BEGIN { ok=0; hit=0; miss=0; exp=0; fail=0 }
            /^OK\|/ { ok++ }
            /^FAIL\|/ { fail++ }
            /\|HIT\|/ { hit++ }
            /\|MISS\|/ { miss++ }
            /\|EXPIRED\|/ { exp++ }
            END { print ok+fail, hit, miss, exp, fail }
        ' "$STATS_FILE" 2>/dev/null)
        
        read p h m e f <<< "$stats"
        
        if [ -f "$JOB_FILE" ] && [ -n "$p" ]; then
            # Single sed call with multiple expressions
            sed -i -e "s|\"progress\": [0-9]*|\"progress\": ${p:-0}|" \
                   -e "s|\"hit\": [0-9]*|\"hit\": ${h:-0}|" \
                   -e "s|\"miss\": [0-9]*|\"miss\": ${m:-0}|" \
                   -e "s|\"expired\": [0-9]*|\"expired\": ${e:-0}|" \
                   -e "s|\"failed\": [0-9]*|\"failed\": ${f:-0}|" \
                   "$JOB_FILE" 2>/dev/null
        fi
    done
) &
PROGRESS_PID=$!

# Process URLs efficiently
log "Pre-warming with $PARALLEL parallel connections..."

# ULTRA LOW CPU MODE: Use xargs without subshell per request
# xargs spawns curl directly without bash wrapper

cat "$URLS_FILE" | xargs -P "$PARALLEL" -I {} \
    nice -n 19 curl -s -I -o /dev/null \
    --connect-timeout 2 \
    --max-time 5 \
    --http1.1 \
    $CURL_HEADERS \
    -w '%{http_code} %{time_total} {}\n' \
    {} 2>/dev/null | \
while read -r code time_sec url; do
    [[ -z "$code" ]] && continue
    
    # Extract variant
    variant="${url#*://}"; variant="${variant#*/}"; variant="${variant%%/*}"
    [[ "$variant" == *.* ]] && variant="master"
    
    if [[ "$code" == "200" || "$code" == "206" ]]; then
        echo "OK|HIT|SIN|${variant}" >> "$STATS_FILE"
        echo "✓ $code | ${time_sec}s | ${url##*/}"
    else
        echo "FAIL|NONE|UNK|${variant}" >> "$STATS_FILE"
        echo "✗ $code | ${time_sec}s | ${url##*/}"
    fi
done

# Stop progress updater
kill $PROGRESS_PID 2>/dev/null
wait $PROGRESS_PID 2>/dev/null

# Final stats (optimized using single awk call)
final_stats=$(awk -F'|' '
    BEGIN { ok=0; hit=0; miss=0; exp=0; fail=0 }
    /^OK\|/ { ok++ }
    /^FAIL\|/ { fail++ }
    /\|HIT\|/ { hit++ }
    /\|MISS\|/ { miss++ }
    /\|EXPIRED\|/ { exp++ }
    END { print ok+fail, hit, miss, exp, fail }
' "$STATS_FILE" 2>/dev/null)

read PROGRESS HIT MISS EXPIRED FAILED <<< "$final_stats"
PROGRESS=${PROGRESS:-0}
HIT=${HIT:-0}
MISS=${MISS:-0}
EXPIRED=${EXPIRED:-0}
FAILED=${FAILED:-0}

# Get unique CF POPs
CF_POPS=$(sort -u "$POP_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# Per-variant stats (optimized - single pass through file)
log ""
log "=========================================="
log "Per-Variant Stats:"
log "------------------------------------------"

# Build variant stats JSON using single awk pass
VARIANT_STATS=$(awk -F'|' '
    BEGIN { first=1 }
    {
        variant = $4
        if (variant == "") next
        
        total[variant]++
        if ($1 == "FAIL") failed[variant]++
        if ($2 == "HIT") hit[variant]++
        else if ($2 == "MISS") miss[variant]++
        else if ($2 == "EXPIRED") expired[variant]++
    }
    END {
        printf "["
        for (v in total) {
            if (!first) printf ","
            first = 0
            h = hit[v]+0
            m = miss[v]+0
            e = expired[v]+0
            f = failed[v]+0
            t = total[v]
            printf "{\"name\":\"%s\",\"total\":%d,\"hit\":%d,\"miss\":%d,\"expired\":%d,\"failed\":%d}", v, t, h, m, e, f
        }
        printf "]"
    }
' "$STATS_FILE" 2>/dev/null)

# Print variant stats to log
awk -F'|' '
    {
        variant = $4
        if (variant == "") next
        total[variant]++
        if ($2 == "HIT") hit[variant]++
        else if ($2 == "MISS") miss[variant]++
    }
    END {
        for (v in total) {
            t = total[v]
            h = hit[v]+0
            m = miss[v]+0
            if (t > 0) rate = (h / t) * 100
            else rate = 0
            printf "  %s: %d total | HIT %d | MISS %d | %.1f%%\n", v, t, h, m, rate
        }
    }
' "$STATS_FILE" 2>/dev/null | while read line; do log "$line"; done

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
