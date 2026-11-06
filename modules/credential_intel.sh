#!/bin/bash
# Email and credential intelligence gathering

MODULE_NAME="credential_intel"
MODULE_DESC="Gather emails and leaked credentials using Hunter.io and DeHashed APIs"

module_init() {
    # Create output directories
    mkdir -p "${DIRS[CREDENTIALS]}"
    mkdir -p "${DIRS[CREDENTIALS]}/artifacts"

    # Set up output files
    EMAILS_FILE="${DIRS[CREDENTIALS]}/${FILES[EMAILS]}"
    EMAIL_PASSWD_FILE="${DIRS[CREDENTIALS]}/${FILES[LEAKED_EMAIL_PASSWD]}"
    USERNAME_PASSWD_FILE="${DIRS[CREDENTIALS]}/${FILES[LEAKED_USERNAME_PASSWD]}"
}

module_run() {
    log_info "Gathering email intelligence for: $DOMAIN"

    # Hunter.io search
    if [[ -n "${HUNTERIO_API_KEY:-}" ]]; then
        log_info "Searching Hunter.io..."
        mkdir -p "${DIRS[CREDENTIALS]}/artifacts"
        local hunter_response="${DIRS[CREDENTIALS]}/artifacts/hunter_raw.json"
        curl -s "https://api.hunter.io/v2/domain-search?domain=${DOMAIN}&api_key=${HUNTERIO_API_KEY}" \
            > "$hunter_response" 2>/dev/null || true
        # Surface API errors (bad key, quota) instead of reporting "0 emails".
        if ! jq -e '.data.emails' "$hunter_response" >/dev/null 2>&1; then
            log_warn "Hunter.io query failed: $(jq -r '[.errors[]? | .details // .id] | join("; ") // empty' "$hunter_response" 2>/dev/null | head -c 200)"
        fi
        jq -r '.data.emails[].value' "$hunter_response" >> "$EMAILS_FILE" 2>/dev/null || true
    else
        log_warn "Skipping Hunter.io - HUNTERIO_API_KEY not set"
    fi

    # DeHashed search
    if [[ -n "${DEHASHED_API_KEY:-}" ]]; then
        log_info "Searching DeHashed..."

        local dehashed_response="${DIRS[CREDENTIALS]}/artifacts/dehashed_raw.json"
        curl -s -X POST 'https://api.dehashed.com/v2/search' \
            --header "Dehashed-Api-Key: $DEHASHED_API_KEY" \
            --header "Content-Type: application/json" \
            --data-raw "{\"query\": \"$DOMAIN\", \"size\": 10000, \"wildcard\": true, \"regex\": false, \"de_dupe\": true}" > "$dehashed_response" 2>/dev/null || true

        if ! jq -e 'has("entries")' "$dehashed_response" >/dev/null 2>&1; then
            log_warn "DeHashed query failed: $(jq -r '.error // .message // empty' "$dehashed_response" 2>/dev/null | head -c 200)"
        fi

        # Extract emails
        jq -r '.entries[] | .email[]? | select(. != null and . != "")' "$dehashed_response" >> "$EMAILS_FILE" 2>/dev/null || true

        # Extract email:password pairs
        jq -r '
            reduce .entries[] as $item ({};
                if ($item.email and $item.password and ($item.email | length > 0) and ($item.password | length > 0))
                then
                    reduce $item.email[] as $e (.; .[$e] = ((.[$e] // []) + $item.password))
                else . end
            )
            | to_entries
            | map(.value |= unique)
            | .[]
            | "\(.key): \(.value[])"
        ' "$dehashed_response" >> "$EMAIL_PASSWD_FILE" 2>/dev/null || true

        # Extract username:password pairs
        jq -r '
            reduce .entries[] as $item ({};
                if ($item.username and $item.password and ($item.username | length > 0) and ($item.password | length > 0))
                then
                    reduce $item.username[] as $u (.; .[$u] = ((.[$u] // []) + $item.password))
                else . end
            )
            | to_entries
            | map(.value |= unique)
            | .[]
            | "\(.key): \(.value[])"
        ' "$dehashed_response" >> "$USERNAME_PASSWD_FILE" 2>/dev/null || true
    else
        log_warn "Skipping DeHashed - DEHASHED_API_KEY not set"
    fi

    # Deduplicate results
    dedupe_file "$EMAILS_FILE"
    dedupe_file "$EMAIL_PASSWD_FILE"
    dedupe_file "$USERNAME_PASSWD_FILE"

    # Count results
    local email_count=0
    local email_passwd_count=0
    local username_passwd_count=0
    [[ -f "$EMAILS_FILE" ]] && email_count=$(wc -l < "$EMAILS_FILE")
    [[ -f "$EMAIL_PASSWD_FILE" ]] && email_passwd_count=$(wc -l < "$EMAIL_PASSWD_FILE")
    [[ -f "$USERNAME_PASSWD_FILE" ]] && username_passwd_count=$(wc -l < "$USERNAME_PASSWD_FILE")

    log_info "Found $email_count unique emails, $email_passwd_count email:password pairs, and $username_passwd_count username:password pairs"

    return 0
}

module_cleanup() {
    log_debug "Cleaning up email intelligence artifacts"
}