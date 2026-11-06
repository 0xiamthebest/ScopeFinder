#!/bin/bash
# IP address discovery from various sources

MODULE_NAME="ip_discovery"
MODULE_DESC="Discover IP addresses using godigger (AlienVault, Common Crawl, urlscan.io, VirusTotal, WebArchive)"

module_init() {
    # Create output directories
    mkdir -p "${DIRS[SCANS]}"
}

module_run() {
    log_info "Discovering IP addresses for: $DOMAIN"

    # Run godigger for IP discovery
    if command -v godigger &> /dev/null; then
        log_info "Running godigger for IP discovery..."
        # godigger prints per-source failures ("Error: urlscan: No results
        # found", JSON decode errors on an HTML error page, ...) on stdout
        # alongside results; keep only lines that are actually IP addresses.
        local ips_out="${DIRS[SCANS]}/${FILES[IPS_FROM_SOURCES]}" godigger_raw
        godigger_raw=$(godigger -domain "$DOMAIN" -search ips -t 20 </dev/null 2>/dev/null || true)
        printf '%s\n' "$godigger_raw" | sed 's/[[:space:]]*$//' \
            | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F]*:[0-9a-fA-F:]+$' > "$ips_out" || true
        local godigger_errs
        godigger_errs=$(printf '%s\n' "$godigger_raw" | grep -ciE '^error' || true)
        [[ "${godigger_errs:-0}" -gt 0 ]] && log_warn "godigger reported ${godigger_errs} source error(s) during IP discovery"
        dedupe_file "$ips_out"
    else
        log_warn "godigger not found - skipping IP discovery"
    fi

    # Count results
    local ip_count=0
    [[ -f "${DIRS[SCANS]}/${FILES[IPS_FROM_SOURCES]}" ]] && ip_count=$(wc -l < "${DIRS[SCANS]}/${FILES[IPS_FROM_SOURCES]}")
    log_info "Found $ip_count IP addresses from open sources"

    return 0
}

module_cleanup() {
    log_debug "Cleaning up IP discovery artifacts"
}