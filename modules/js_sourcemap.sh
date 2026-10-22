#!/bin/bash
# Recover JavaScript source maps and reconstruct original source for analysis

MODULE_NAME="js_sourcemap"
MODULE_DESC="Recover .map files and reconstruct original JS source with sourcemapper"

module_init() {
    if ! command -v sourcemapper &>/dev/null; then
        log_warn "sourcemapper not found - skipping source map recovery"
        return 1
    fi

    mkdir -p "${DIRS[JS_SOURCEMAPS]}"
    mkdir -p "${DIRS[JS_RECONSTRUCTED]}"
    mkdir -p "${DIRS[URLS_ARTIFACTS]}"

    # Build the set of live JS URLs to probe for source maps: the direct
    # js_download endpoint list plus any chunks found by js_chunk_discovery.
    SM_URLS="${DIRS[URLS_ARTIFACTS]}/sm_urls_temp.txt"
    > "$SM_URLS"
    [[ -f "${DIRS[JS_ENDPOINTS]}/${FILES[JS_ENDPOINTS]}" ]] && \
        cat "${DIRS[JS_ENDPOINTS]}/${FILES[JS_ENDPOINTS]}" >> "$SM_URLS" 2>/dev/null || true
    [[ -f "${DIRS[URLS_ARTIFACTS]}/${FILES[JS_CHUNK_URLS]}" ]] && \
        cat "${DIRS[URLS_ARTIFACTS]}/${FILES[JS_CHUNK_URLS]}" >> "$SM_URLS" 2>/dev/null || true
    dedupe_file "$SM_URLS"

    if ! check_file "$SM_URLS"; then
        log_info "No JS URLs available for source map recovery - skipping"
        return 1
    fi
}

module_run() {
    local url_count
    url_count=$(wc -l < "$SM_URLS" 2>/dev/null || echo "0")
    log_info "Attempting source map recovery for $url_count JS URL(s)"

    # For each JS URL: let sourcemapper resolve the referenced sourceMappingURL
    # (handles inline data: maps and relative/absolute .map refs), and also try
    # the conventional "<url>.map" when no reference exists. Reconstructed
    # sources are written per-URL so replays can skip completed work.
    cat "$SM_URLS" | xargs -P8 -I{} bash -c '
        url="{}"
        hash=$(echo -n "$url" | md5sum | cut -d" " -f1)
        recon="'"${DIRS[JS_RECONSTRUCTED]}"'/${hash}"
        maps="'"${DIRS[JS_SOURCEMAPS]}"'"

        # Skip if already reconstructed (idempotent replay).
        if [ -d "$recon" ] && [ -n "$(ls -A "$recon" 2>/dev/null)" ]; then
            exit 0
        fi

        # 1) Follow the map referenced by the JS file itself.
        sourcemapper -jsurl "$url" -output "$recon" >/dev/null 2>&1 || true

        # 2) Fallback: brute the conventional <url>.map (strip any query first).
        if [ ! -d "$recon" ] || [ -z "$(ls -A "$recon" 2>/dev/null)" ]; then
            base="${url%%\?*}"
            mapfile="${maps}/${hash}.map"
            wget -q --no-check-certificate --timeout=5 --tries=2 -O "$mapfile" "${base}.map" 2>/dev/null || true
            if [ -s "$mapfile" ] && jq -e "has(\"sources\")" "$mapfile" >/dev/null 2>&1; then
                sourcemapper -url "$mapfile" -output "$recon" >/dev/null 2>&1 || true
            else
                rm -f "$mapfile"
            fi
        fi
    ' 2>/dev/null || true

    # Count what was recovered.
    local recon_targets src_files
    recon_targets=$(find "${DIRS[JS_RECONSTRUCTED]}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    src_files=$(find "${DIRS[JS_RECONSTRUCTED]}" -type f 2>/dev/null | wc -l)
    log_info "Source maps recovered for $recon_targets JS file(s); reconstructed $src_files source file(s) in ${DIRS[JS_RECONSTRUCTED]}/"

    return 0
}

module_cleanup() {
    rm -f "${DIRS[URLS_ARTIFACTS]}/sm_urls_temp.txt"
    log_debug "Cleaning up source map recovery artifacts"
}
