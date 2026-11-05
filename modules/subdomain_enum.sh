#!/bin/bash
# Subdomain enumeration from multiple sources
#
# Pipeline:
#   1. PASSIVE   — subfinder (keyed) + godigger + crt.sh/crt.name + shosubgo
#   2. RESOLVE   — dnsx validates passive names against trusted resolvers,
#                  detects the apex wildcard so brute results can be filtered
#   3. BRUTE     — puredns + DNS wordlist (wildcard-filtered)      [gated: SF_DNS_BRUTE=1]
#   4. PERMUTE   — alterx mutates known-good names, puredns resolves [gated: SF_DNS_PERMUTE=1]
#   5. MERGE     — union everything into subdomains.txt (all names, for httpx),
#                  resolvable-only into resolved_subdomains.txt
#
# Stages 2-4 self-skip if their tools/resolvers/wordlist are absent, so on an
# image built before those tools were added this module runs passive-only.
#
# BRUTE and PERMUTE are mode-aware (ScopeFinder.sh exports SF_FULL_RUN):
#   - FULL pipeline run (no --replay/--replay-from, i.e. the pre-engagement
#     baseline)      -> ON  by default (thorough; wall-clock doesn't matter offline)
#   - targeted --replay subdomain_enum (fast a-la-carte refresh from the harness)
#                    -> OFF by default (quick passive delta)
#   - explicit SF_DNS_BRUTE / SF_DNS_PERMUTE (0 or 1) always override the default.
#
# They are deliberately THROTTLED: DNS brute does not touch the target's web/app
# infra at all, and the query rate is kept low (SF_DNS_RATE, default 500 q/s) so
# even a small self-hosted authoritative nameserver is never overwhelmed. The rate
# caps queries/sec to the resolvers; only cache-miss (mostly NXDOMAIN) lookups
# reach the target's authoritative NS, fanned out across resolvers and cache-absorbed.
# Examples:
#   ScopeFinder example.com                                   # baseline: brute+permute ON
#   ScopeFinder example.com --replay subdomain_enum           # refresh: passive only
#   SF_DNS_BRUTE=1 ScopeFinder example.com --replay subdomain_enum   # force brute on a refresh
#   SF_DNS_RATE=200 ScopeFinder example.com                   # gentler/slower baseline

MODULE_NAME="subdomain_enum"
MODULE_DESC="Enumerate subdomains using subfinder, godigger, crtsh-tool, shosubgo, then resolve (dnsx) and optionally brute/permute (puredns, alterx)"

# ---- tunables (env-overridable) ----
RESOLVERS_FILE="${SF_RESOLVERS:-/resolvers/resolvers.txt}"
DNS_WORDLIST="${SF_DNS_WORDLIST:-/wordlists/dns-subdomains.txt}"
DNS_RATE="${SF_DNS_RATE:-500}"
DNS_THREADS="${SF_DNS_THREADS:-50}"

module_init() {
    # Create output directories
    mkdir -p "${DIRS[SUBDOMAINS]}"

    # Set up output files
    SUBDOMAINS_FILE="${DIRS[SUBDOMAINS]}/${FILES[SUBDOMAINS]}"
    WILDCARD_FILE="${DIRS[SUBDOMAINS]}/${FILES[WILDCARD_SUBDOMAINS]}"
    RESOLVED_FILE="${DIRS[SUBDOMAINS]}/resolved_subdomains.txt"
    BRUTE_FILE="${DIRS[SUBDOMAINS]}/brute_subdomains.txt"
    PERM_FILE="${DIRS[SUBDOMAINS]}/permutation_subdomains.txt"
    WILDCARD_ROOTS_FILE="${DIRS[SUBDOMAINS]}/wildcard_roots.txt"
}

# Keep only well-formed hostnames; drop DNS-only (_dmarc, _domainkey ...),
# tool error/warning strings, and JSON noise. Operates in place.
_clean_hostnames() {
    local file=$1
    [[ -f "$file" ]] || return 0
    grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$' "$file" \
        > "${file}.clean" 2>/dev/null && mv "${file}.clean" "$file" || true
}

# ---------- Stage 1: passive collection ----------
_passive_collect() {
    log_info "[passive] Collecting from passive sources for: $DOMAIN"

    # subfinder (now keyed via .config/subfinder/provider-config.yaml)
    log_info "[passive] subfinder..."
    subfinder -d "$DOMAIN" -all -recursive -silent >> "$SUBDOMAINS_FILE" 2>/dev/null || true

    # godigger
    log_info "[passive] godigger..."
    godigger -domain "$DOMAIN" -search subdomains -t 20 >> "$SUBDOMAINS_FILE" 2>/dev/null || true

    # crtsh-tool (CT logs)
    log_info "[passive] crtsh-tool..."
    local crtsh_out
    crtsh_out=$(crtsh-tool --domain "$DOMAIN" 2>/dev/null || true)
    echo "$crtsh_out" | grep -v '[DEBUG]' | grep -v '\*\.' >> "$SUBDOMAINS_FILE" || true
    echo "$crtsh_out" | grep -v '[DEBUG]' | grep '\*\.' >> "$WILDCARD_FILE" || true

    # crt.name (plaintext, one hostname per line; may include *. wildcards)
    log_info "[passive] crt.name..."
    pick_user_agent
    local crtname_out
    crtname_out=$(curl -s --max-time 60 -A "$SELECTED_UA" \
        "https://crt.name/v1/search?apex=${DOMAIN}" 2>/dev/null || true)
    echo "$crtname_out" | grep -v '\*\.' >> "$SUBDOMAINS_FILE" || true
    echo "$crtname_out" | grep '\*\.' >> "$WILDCARD_FILE" || true

    # shosubgo (Shodan)
    log_info "[passive] shosubgo..."
    if [[ -n "${SHODAN_API_KEY:-}" ]]; then
        local shosubgo_out
        shosubgo_out=$(shosubgo -d "$DOMAIN" -s "$SHODAN_API_KEY" 2>/dev/null || true)
        echo "$shosubgo_out" | grep -v 'No subdomains found' | grep -v 'apishodan.JsonSubDomain' | grep -v '\*\.' >> "$SUBDOMAINS_FILE" || true
        echo "$shosubgo_out" | grep '\*\.' >> "$WILDCARD_FILE" || true
    else
        log_warn "[passive] Skipping shosubgo - SHODAN_API_KEY not set"
    fi

    _clean_hostnames "$SUBDOMAINS_FILE"
    dedupe_file "$SUBDOMAINS_FILE"
    dedupe_file "$WILDCARD_FILE"
}

# Are the resolver list + dnsx available for the active DNS stages?
_dns_ready() {
    if ! command -v dnsx >/dev/null 2>&1; then
        log_warn "[dns] dnsx not installed - skipping resolve/validate (passive-only build)"
        return 1
    fi
    if [[ ! -s "$RESOLVERS_FILE" ]]; then
        log_warn "[dns] resolver list missing ($RESOLVERS_FILE) - skipping active DNS stages"
        return 1
    fi
    return 0
}

# ---------- Stage 2: resolve/validate passive names + wildcard detection ----------
_resolve_passive() {
    _dns_ready || return 0
    [[ -s "$SUBDOMAINS_FILE" ]] || return 0

    log_info "[resolve] dnsx validating $(wc -l < "$SUBDOMAINS_FILE") passive names..."
    # -wd flags apex wildcard so downstream brute/permute can be filtered.
    dnsx -l "$SUBDOMAINS_FILE" -r "$RESOLVERS_FILE" \
         -t "$DNS_THREADS" -silent -wd "$DOMAIN" \
         -o "$RESOLVED_FILE" 2>/dev/null || true
    _clean_hostnames "$RESOLVED_FILE"
    dedupe_file "$RESOLVED_FILE"
    local n=0; [[ -f "$RESOLVED_FILE" ]] && n=$(wc -l < "$RESOLVED_FILE")
    log_info "[resolve] $n passive names resolve"
}

# ---------- Stage 3: DNS brute force (gated) ----------
_brute() {
    # Default: on for a full baseline run, off for a targeted a-la-carte replay.
    [[ "${SF_DNS_BRUTE:-${SF_FULL_RUN:-1}}" == "1" ]] || { log_info "[brute] disabled (a-la-carte replay default; set SF_DNS_BRUTE=1 to force)"; return 0; }
    if ! command -v puredns >/dev/null 2>&1; then
        log_warn "[brute] puredns not installed - skipping"; return 0
    fi
    if [[ ! -s "$RESOLVERS_FILE" || ! -s "$DNS_WORDLIST" ]]; then
        log_warn "[brute] resolver list or wordlist missing - skipping"; return 0
    fi
    log_info "[brute] puredns bruteforce ($(wc -l < "$DNS_WORDLIST") words, rate=$DNS_RATE) — wildcard-filtered..."
    puredns bruteforce "$DNS_WORDLIST" "$DOMAIN" \
        -r "$RESOLVERS_FILE" --rate-limit "$DNS_RATE" \
        --quiet --write "$BRUTE_FILE" 2>/dev/null || true
    _clean_hostnames "$BRUTE_FILE"
    dedupe_file "$BRUTE_FILE"
    local n=0; [[ -f "$BRUTE_FILE" ]] && n=$(wc -l < "$BRUTE_FILE")
    log_info "[brute] $n names found via brute force"
}

# ---------- Stage 4: permutation scanning (gated) ----------
_permute() {
    # Default: on for a full baseline run, off for a targeted a-la-carte replay.
    [[ "${SF_DNS_PERMUTE:-${SF_FULL_RUN:-1}}" == "1" ]] || { log_info "[permute] disabled (a-la-carte replay default; set SF_DNS_PERMUTE=1 to force)"; return 0; }
    if ! command -v alterx >/dev/null 2>&1 || ! command -v puredns >/dev/null 2>&1; then
        log_warn "[permute] alterx/puredns not installed - skipping"; return 0
    fi
    if [[ ! -s "$RESOLVERS_FILE" ]]; then
        log_warn "[permute] resolver list missing - skipping"; return 0
    fi
    # Seed permutations from known-good names (resolved passive + brute hits).
    local seed="${DIRS[SUBDOMAINS]}/.perm_seed.txt"
    : > "$seed"
    [[ -s "$RESOLVED_FILE" ]] && cat "$RESOLVED_FILE" >> "$seed"
    [[ -s "$BRUTE_FILE" ]]    && cat "$BRUTE_FILE"    >> "$seed"
    dedupe_file "$seed"
    if [[ ! -s "$seed" ]]; then
        log_warn "[permute] no resolved seed names - skipping"; rm -f "$seed"; return 0
    fi
    log_info "[permute] alterx generating permutations from $(wc -l < "$seed") seeds, puredns resolving..."
    local perms="${DIRS[SUBDOMAINS]}/.perm_candidates.txt"
    alterx -l "$seed" -silent 2>/dev/null | sort -u > "$perms" || true
    if [[ -s "$perms" ]]; then
        puredns resolve "$perms" -r "$RESOLVERS_FILE" --rate-limit "$DNS_RATE" \
            --quiet --write "$PERM_FILE" 2>/dev/null || true
        _clean_hostnames "$PERM_FILE"
        dedupe_file "$PERM_FILE"
    fi
    rm -f "$seed" "$perms"
    local n=0; [[ -f "$PERM_FILE" ]] && n=$(wc -l < "$PERM_FILE")
    log_info "[permute] $n names found via permutation"
}

# ---------- Stage 5: merge ----------
_merge() {
    # All discovered names -> subdomains.txt (the downstream contract for httpx).
    for f in "$BRUTE_FILE" "$PERM_FILE"; do
        [[ -s "$f" ]] && cat "$f" >> "$SUBDOMAINS_FILE"
    done
    _clean_hostnames "$SUBDOMAINS_FILE"
    dedupe_file "$SUBDOMAINS_FILE"

    # Resolvable-only union -> resolved_subdomains.txt (validated seed/artifact).
    if command -v dnsx >/dev/null 2>&1 && [[ -s "$RESOLVERS_FILE" ]]; then
        { [[ -s "$RESOLVED_FILE" ]] && cat "$RESOLVED_FILE"
          [[ -s "$BRUTE_FILE" ]]    && cat "$BRUTE_FILE"
          [[ -s "$PERM_FILE" ]]     && cat "$PERM_FILE"; } \
            | sort -u > "${RESOLVED_FILE}.tmp" 2>/dev/null || true
        [[ -f "${RESOLVED_FILE}.tmp" ]] && mv "${RESOLVED_FILE}.tmp" "$RESOLVED_FILE"
        _clean_hostnames "$RESOLVED_FILE"
        dedupe_file "$RESOLVED_FILE"
    fi
}

module_run() {
    log_info "Enumerating subdomains for: $DOMAIN"

    _passive_collect
    _resolve_passive
    _brute
    _permute
    _merge

    # Counts
    local sub_count=0 res_count=0 wild_count=0
    [[ -f "$SUBDOMAINS_FILE" ]] && sub_count=$(wc -l < "$SUBDOMAINS_FILE")
    [[ -f "$RESOLVED_FILE" ]]   && res_count=$(wc -l < "$RESOLVED_FILE")
    [[ -f "$WILDCARD_FILE" ]]   && wild_count=$(wc -l < "$WILDCARD_FILE")

    log_info "Found $sub_count total subdomains ($res_count resolvable, $wild_count wildcard entries)"
    return 0
}

module_cleanup() {
    log_debug "Cleaning up subdomain enumeration artifacts"
    rm -f "${DIRS[SUBDOMAINS]}/.perm_seed.txt" "${DIRS[SUBDOMAINS]}/.perm_candidates.txt" 2>/dev/null || true
}
