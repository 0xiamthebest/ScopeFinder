#!/bin/bash
# Recursive discovery and download of lazy-loaded / code-split JS chunks

MODULE_NAME="js_chunk_discovery"
MODULE_DESC="Discover and download lazy-loaded/webpack JS chunks missed by direct probing"

# --- helpers (prefixed to avoid clobbering other sourced modules) -----------

# Origin host of a URL (scheme stripped, path stripped).
_jsc_host() {
    local u="${1#*://}"
    printf '%s\n' "${u%%/*}"
}

# Resolve a (possibly relative) reference against a base URL.
# $1 = base URL (the bundle's own URL), $2 = reference.
_jsc_resolve_url() {
    local base="$1" ref="$2"
    # strip surrounding quotes if any slipped through
    ref="${ref%\"}"; ref="${ref#\"}"
    ref="${ref%\'}"; ref="${ref#\'}"
    case "$ref" in
        http://*|https://*)
            printf '%s\n' "$ref" ;;
        //*)
            # scheme-relative
            printf '%s:%s\n' "${base%%:*}" "$ref" ;;
        /*)
            # absolute path: scheme://host + ref
            local scheme="${base%%/*}"          # e.g. "https:"
            local rest="${base#*://}"           # host/path...
            local host="${rest%%/*}"
            printf '%s//%s%s\n' "$scheme" "$host" "$ref" ;;
        *)
            # relative to the directory of the bundle
            local dir="${base%/*}"
            printf '%s/%s\n' "$dir" "$ref" ;;
    esac
}

# Read the "// Original URL: <url>" header written by js_download / this module.
_jsc_base_url() {
    local file="$1" first
    first=$(head -1 "$file" 2>/dev/null)
    if [[ "$first" == "// Original URL: "* ]]; then
        printf '%s\n' "${first#// Original URL: }"
    fi
}

# Emit candidate chunk URLs (absolute, same-origin) discovered in one JS file.
_jsc_candidates_from_file() {
    local file="$1"
    local base host
    base=$(_jsc_base_url "$file")
    [[ -z "$base" ]] && return 0
    host=$(_jsc_host "$base")

    {
        # 1) jsluice AST-based URL/path extraction
        if command -v jsluice &>/dev/null; then
            printf '%s\n' "$file" | jsluice urls 2>/dev/null \
                | jq -r '.url // empty' 2>/dev/null \
                | grep -iE '\.(m?js|chunk\.js)($|\?)' || true
        fi

        # 2) quoted string literals that look like JS asset paths
        #    (catches rollup/vite import() targets emitted as literals)
        grep -oE '"[^"[:space:]]+\.(chunk\.js|m?js)"' "$file" 2>/dev/null \
            | tr -d '"' || true
        grep -oE "'[^'[:space:]]+\.(chunk\.js|m?js)'" "$file" 2>/dev/null \
            | tr -d "'" || true

        # 3) webpack runtime reconstruction: chunk-id -> contenthash pairs are
        #    stored as {<id>:"<hash>",...} while the filename template lives
        #    elsewhere, so the full name never appears as one literal. Rebuild
        #    "<id>.<hash>.chunk.js" / "<id>.<hash>.js" relative to the bundle
        #    dir. Bad guesses simply 404 and are dropped at download time.
        grep -oE '[0-9]{1,6}:"[A-Za-z0-9_]{5,32}"' "$file" 2>/dev/null \
            | head -1500 \
            | while IFS=':' read -r id hash; do
                hash="${hash%\"}"; hash="${hash#\"}"
                printf '%s.%s.chunk.js\n' "$id" "$hash"
                printf '%s.%s.js\n' "$id" "$hash"
              done || true
    } | while read -r ref; do
        [[ -z "$ref" ]] && continue
        local abs
        abs=$(_jsc_resolve_url "$base" "$ref")
        # stay in scope: only same-origin asset hosts
        [[ "$(_jsc_host "$abs")" == "$host" ]] && printf '%s\n' "$abs"
    done
}

# ---------------------------------------------------------------------------

module_init() {
    mkdir -p "${DIRS[JS_DOWNLOADED]}"
    mkdir -p "${DIRS[URLS_ARTIFACTS]}"

    # Need at least one already-downloaded bundle to mine for chunk references.
    if [[ ! -d "${DIRS[JS_DOWNLOADED]}" ]] || [[ -z "$(ls -A "${DIRS[JS_DOWNLOADED]}" 2>/dev/null)" ]]; then
        log_info "No downloaded JS files to mine for chunks - skipping"
        return 1
    fi

    CHUNK_URLS_FILE="${DIRS[URLS_ARTIFACTS]}/${FILES[JS_CHUNK_URLS]}"
    MAX_ROUNDS="${JS_CHUNK_MAX_ROUNDS:-3}"
}

module_run() {
    log_info "Discovering lazy-loaded / code-split JS chunks"

    # Reset the discovered-chunk URL list for idempotent replays.
    > "$CHUNK_URLS_FILE"

    # Track which bundle files have already been mined so recursive rounds only
    # process newly downloaded chunks.
    declare -A JSC_MINED

    local round=0 total_new=0
    while (( round < MAX_ROUNDS )); do
        round=$((round + 1))

        local candidates="${DIRS[URLS_ARTIFACTS]}/jsc_candidates_round${round}.txt"
        > "$candidates"

        # Mine every not-yet-processed JS file for same-origin chunk references.
        local mined_this_round=0
        while IFS= read -r file; do
            [[ -n "${JSC_MINED[$file]:-}" ]] && continue
            JSC_MINED[$file]=1
            mined_this_round=$((mined_this_round + 1))
            _jsc_candidates_from_file "$file" >> "$candidates" 2>/dev/null || true
        done < <(find "${DIRS[JS_DOWNLOADED]}" -type f -name "*.js" 2>/dev/null)

        if (( mined_this_round == 0 )); then
            log_debug "Round $round: no new files to mine"
            break
        fi

        dedupe_file "$candidates"

        # Keep only URLs we have not already downloaded (dedupe by md5 filename).
        local to_download="${DIRS[URLS_ARTIFACTS]}/jsc_to_download_round${round}.txt"
        > "$to_download"
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            local hash
            hash=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
            [[ -f "${DIRS[JS_DOWNLOADED]}/${hash}.js" ]] && continue
            printf '%s\n' "$url" >> "$to_download"
        done < "$candidates"
        dedupe_file "$to_download"

        local round_count
        round_count=$(wc -l < "$to_download" 2>/dev/null || echo "0")
        if [[ "$round_count" -eq 0 ]]; then
            log_debug "Round $round: no new chunks discovered"
            rm -f "$candidates" "$to_download"
            break
        fi

        log_info "Round $round: downloading $round_count new chunk candidate(s)"

        # Download in parallel, mirroring js_download's fetch and header format
        # so downstream modules (linkfinder, secret_scan) treat them identically.
        cat "$to_download" | xargs -P10 -I{} bash -c '
            url="{}"
            hash=$(echo -n "$url" | md5sum | cut -d" " -f1)
            outfile="'"${DIRS[JS_DOWNLOADED]}"'/${hash}.js"
            [ -f "$outfile" ] && exit 0
            content=$(wget -q --no-check-certificate --retry-connrefused --wait=1 --random-wait --timeout=5 --tries=2 -O - "$url")
            [ -n "$content" ] && { echo "// Original URL: $url"; echo "$content"; } > "$outfile"
        ' 2>/dev/null || true

        # Record only the URLs that actually produced a file (non-empty 200s).
        while IFS= read -r url; do
            local hash
            hash=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
            [[ -f "${DIRS[JS_DOWNLOADED]}/${hash}.js" ]] && printf '%s\n' "$url" >> "$CHUNK_URLS_FILE"
        done < "$to_download"

        total_new=$((total_new + round_count))
        rm -f "$candidates" "$to_download"
    done

    dedupe_file "$CHUNK_URLS_FILE"
    local fetched
    fetched=$(wc -l < "$CHUNK_URLS_FILE" 2>/dev/null || echo "0")
    log_info "Chunk discovery complete: $fetched chunk URL(s) fetched over up to $MAX_ROUNDS round(s)"

    return 0
}

module_cleanup() {
    rm -f "${DIRS[URLS_ARTIFACTS]}"/jsc_candidates_round*.txt \
          "${DIRS[URLS_ARTIFACTS]}"/jsc_to_download_round*.txt
    log_debug "Cleaning up JS chunk discovery artifacts"
}
