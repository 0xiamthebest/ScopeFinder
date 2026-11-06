#!/bin/bash
# ASN range discovery

MODULE_NAME="asn_discovery"
MODULE_DESC="Discover ASN ranges for the organization using asnmap"

module_init() {
    # Create output directory
    # Fixed paths
    mkdir -p "${DIRS[ASN]}"

    # Extract base domain name
    DOMAIN_BASE_NAME=$(echo "$DOMAIN" | awk -F'.' '{print $(NF-1)}')
}

module_run() {
    log_info "Discovering ASN ranges for: $DOMAIN_BASE_NAME"

    # Run asnmap
    if command -v asnmap &> /dev/null; then
        local ranges_file="${DIRS[ASN]}/${FILES[ASN_RANGES]}"
        local cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9a-fA-F:]+:[0-9a-fA-F:]*/[0-9]{1,3}$'
        # asnmap needs a PDCP key; without a valid one it prints an interactive
        # "Enter PDCP API Key" prompt on STDOUT and reads stdin. Unattended, the
        # prompt text landed in asn_ip_ranges.txt and was fed to smap/CloudRecon
        # as an "IP range" (CloudRecon then hung); interactively it blocked the
        # whole run waiting for input. So: never give it a stdin, and keep only
        # lines that are actually CIDRs.
        local asn_raw
        asn_raw=$(asnmap -d "$DOMAIN_BASE_NAME" -silent </dev/null 2>/dev/null || true)
        if [[ "$asn_raw" == *"PDCP API Key"* ]]; then
            log_warn "asnmap needs a valid PDCP_API_KEY (ProjectDiscovery Cloud) - no ASN ranges retrieved"
        fi
        printf '%s\n' "$asn_raw" | grep -E "$cidr_re" >> "$ranges_file" 2>/dev/null || true
        # Re-filter the whole (append-mode) file so junk left by an earlier
        # run can't persist across replays.
        if [[ -f "$ranges_file" ]]; then
            { grep -E "$cidr_re" "$ranges_file" 2>/dev/null || true; } | awk '!seen[$0]++' > "${ranges_file}.tmp"
            mv -f "${ranges_file}.tmp" "$ranges_file"
        fi
    else
        log_warn "asnmap not found - skipping ASN discovery"
        return 0
    fi

    # Count results
    local range_count=0
    [[ -f "${DIRS[ASN]}/${FILES[ASN_RANGES]}" ]] && range_count=$(wc -l < "${DIRS[ASN]}/${FILES[ASN_RANGES]}")

    if [[ "$range_count" -eq 0 ]]; then
        log_info "No ASN ranges found for $DOMAIN_BASE_NAME"
    else
        log_info "Found $range_count ASN IP ranges"
    fi

    return 0
}

module_cleanup() {
    log_debug "Cleaning up ASN discovery artifacts"
}