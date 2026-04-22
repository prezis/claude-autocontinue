#!/usr/bin/env bats
#
# Unit tests for the pure functions in claude-autocontinue.
# Sourced with CAC_LIB_ONLY=1 so the poll loop never starts.

setup() {
    export CAC_LIB_ONLY=1
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../claude-autocontinue"
    FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
}

# ── is_claude_code ────────────────────────────────────────────────────────────

@test "is_claude_code: matches new-format banner fixture" {
    run is_claude_code "$(cat "$FIXTURES/banner_new_format.txt")"
    [ "$status" -eq 0 ]
}

@test "is_claude_code: matches original-format banner fixture" {
    run is_claude_code "$(cat "$FIXTURES/banner_original_format.txt")"
    [ "$status" -eq 0 ]
}

@test "is_claude_code: matches minutes-format banner fixture" {
    run is_claude_code "$(cat "$FIXTURES/banner_minutes_format.txt")"
    [ "$status" -eq 0 ]
}

@test "is_claude_code: matches server-rate-limit fixture" {
    run is_claude_code "$(cat "$FIXTURES/banner_server_rate_limit.txt")"
    [ "$status" -eq 0 ]
}

@test "is_claude_code: rejects plain shell transcript" {
    run is_claude_code "$(cat "$FIXTURES/not_claude_code.txt")"
    [ "$status" -ne 0 ]
}

# ── has_rate_limit_banner ─────────────────────────────────────────────────────

@test "has_rate_limit_banner: detects 'You've hit your limit'" {
    run has_rate_limit_banner "$(cat "$FIXTURES/banner_new_format.txt")"
    [ "$status" -eq 0 ]
}

@test "has_rate_limit_banner: detects 'limit reached ∙ resets'" {
    run has_rate_limit_banner "$(cat "$FIXTURES/banner_original_format.txt")"
    [ "$status" -eq 0 ]
}

@test "has_rate_limit_banner: detects 'Limit reached (resets 8m)'" {
    run has_rate_limit_banner "$(cat "$FIXTURES/banner_minutes_format.txt")"
    [ "$status" -eq 0 ]
}

@test "has_rate_limit_banner: ignores prose mentioning the keywords" {
    run has_rate_limit_banner "$(cat "$FIXTURES/prose_false_positive.txt")"
    [ "$status" -ne 0 ]
}

@test "has_rate_limit_banner: ignores 'you hit your limit' without apostrophe" {
    run has_rate_limit_banner "you hit your limit yesterday"
    [ "$status" -ne 0 ]
}

@test "has_rate_limit_banner: ignores 'limit reached' without banner glyph" {
    run has_rate_limit_banner "the limit reached five but then stopped"
    [ "$status" -ne 0 ]
}

@test "has_rate_limit_banner: ignores server-rate-limit fixture (different branch)" {
    run has_rate_limit_banner "$(cat "$FIXTURES/banner_server_rate_limit.txt")"
    [ "$status" -ne 0 ]
}

# ── has_server_rate_limit_error ───────────────────────────────────────────────

@test "has_server_rate_limit_error: detects 'API Error: Server is temporarily limiting requests'" {
    run has_server_rate_limit_error "$(cat "$FIXTURES/banner_server_rate_limit.txt")"
    [ "$status" -eq 0 ]
}

@test "has_server_rate_limit_error: detects on a one-line input" {
    run has_server_rate_limit_error "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
    [ "$status" -eq 0 ]
}

@test "has_server_rate_limit_error: detects with HTTP status code (429)" {
    run has_server_rate_limit_error "API Error: 429 Server is temporarily limiting requests"
    [ "$status" -eq 0 ]
}

@test "has_server_rate_limit_error: detects with HTTP status code (529)" {
    run has_server_rate_limit_error "API Error: 529 Server is temporarily limiting requests · Rate limited"
    [ "$status" -eq 0 ]
}

@test "has_server_rate_limit_error: ignores prose about rate limits" {
    run has_server_rate_limit_error "$(cat "$FIXTURES/prose_server_rate_limit_false_positive.txt")"
    [ "$status" -ne 0 ]
}

@test "has_server_rate_limit_error: ignores usage-limit banner (different branch)" {
    run has_server_rate_limit_error "$(cat "$FIXTURES/banner_new_format.txt")"
    [ "$status" -ne 0 ]
}

@test "has_server_rate_limit_error: ignores plain 'rate limited' without API Error prefix" {
    run has_server_rate_limit_error "the request was rate limited yesterday"
    [ "$status" -ne 0 ]
}

@test "has_server_rate_limit_error: requires 'API Error:' prefix (no bare phrase)" {
    run has_server_rate_limit_error "Server is temporarily limiting requests"
    [ "$status" -ne 0 ]
}

# ── parse_reset_time ──────────────────────────────────────────────────────────

@test "parse_reset_time: extracts '2am'" {
    result="$(parse_reset_time "$(cat "$FIXTURES/banner_new_format.txt")")"
    [ "$result" = "2am" ]
}

@test "parse_reset_time: extracts '2pm'" {
    result="$(parse_reset_time "$(cat "$FIXTURES/banner_original_format.txt")")"
    [ "$result" = "2pm" ]
}

@test "parse_reset_time: extracts with minutes '10:30am'" {
    result="$(parse_reset_time "limit reached · resets 10:30am")"
    [ "$result" = "10:30am" ]
}

@test "parse_reset_time: returns empty on unparseable text" {
    result="$(parse_reset_time "this mentions resets but no clock time")"
    [ -z "$result" ]
}

@test "parse_reset_time: picks last match when multiple present" {
    input=$'scrollback says resets 1am here\nlater banner resets 2pm'
    result="$(parse_reset_time "$input")"
    [ "$result" = "2pm" ]
}

# v1.2.0 — dated banner form: "resets Apr 23, 9pm (Europe/London)"
@test "parse_reset_time: extracts dated form 'Apr 23, 9pm'" {
    result="$(parse_reset_time "$(cat "$FIXTURES/banner_dated_format.txt")")"
    [ "$result" = "Apr 23, 9pm" ]
}

@test "parse_reset_time: extracts dated form without comma" {
    result="$(parse_reset_time "You've hit your limit · resets Apr 23 9pm (UTC)")"
    [ "$result" = "Apr 23 9pm" ]
}

@test "parse_reset_time: extracts dated form with minutes" {
    result="$(parse_reset_time "resets Dec 5, 10:30pm (Europe/London)")"
    [ "$result" = "Dec 5, 10:30pm" ]
}

@test "parse_reset_time: dated form takes priority over legacy in same buffer" {
    input=$'noise resets 2am\nactual banner resets May 1, 7am'
    result="$(parse_reset_time "$input")"
    [ "$result" = "May 1, 7am" ]
}

# ── epoch_of_reset ────────────────────────────────────────────────────────────

@test "epoch_of_reset: '2am' parses to a non-zero epoch" {
    result="$(epoch_of_reset "2am")"
    [ "$result" -gt 0 ]
}

@test "epoch_of_reset: empty string returns 0" {
    result="$(epoch_of_reset "")"
    [ "$result" = "0" ]
}

@test "epoch_of_reset: garbage returns 0" {
    result="$(epoch_of_reset "not-a-time-xyz")"
    [ "$result" = "0" ]
}

# v1.2.0 — dated form must survive the comma that GNU date rejects raw.
@test "epoch_of_reset: dated form 'Apr 23, 9pm' parses to a non-zero epoch" {
    result="$(epoch_of_reset "Apr 23, 9pm")"
    [ "$result" -gt 0 ]
}

@test "epoch_of_reset: dated form with minutes parses to a non-zero epoch" {
    result="$(epoch_of_reset "Dec 5, 10:30pm")"
    [ "$result" -gt 0 ]
}

# v1.2.0 — TZ-aware computation (Europe/London vs UTC at Apr 23 21:00).
@test "epoch_of_reset: explicit TZ shifts the epoch" {
    # Apr 23 21:00 in Europe/London (BST = UTC+1) → 20:00 UTC = epoch E
    # Apr 23 21:00 in UTC           → 21:00 UTC = epoch E + 3600
    london="$(epoch_of_reset "Apr 23 9pm" "Europe/London")"
    utc="$(epoch_of_reset "Apr 23 9pm" "UTC")"
    [ "$london" -gt 0 ]
    [ "$utc" -gt 0 ]
    # UTC interpretation should be 1h later than London during BST.
    [ "$((utc - london))" -eq 3600 ]
}

# ── parse_reset_timezone ──────────────────────────────────────────────────────

@test "parse_reset_timezone: extracts 'Europe/London' from dated banner" {
    result="$(parse_reset_timezone "$(cat "$FIXTURES/banner_dated_format.txt")")"
    [ "$result" = "Europe/London" ]
}

@test "parse_reset_timezone: extracts 'America/New_York'" {
    result="$(parse_reset_timezone "You've hit your limit · resets May 1, 7am (America/New_York)")"
    [ "$result" = "America/New_York" ]
}

@test "parse_reset_timezone: returns empty when no TZ present" {
    result="$(parse_reset_timezone "limit reached · resets 2am")"
    [ -z "$result" ]
}

# ── regression: fixture → full pipeline ───────────────────────────────────────

@test "fixture banner_dated_format: is_claude_code + has_rate_limit_banner + parseable" {
    content="$(cat "$FIXTURES/banner_dated_format.txt")"
    run is_claude_code "$content"
    [ "$status" -eq 0 ]
    run has_rate_limit_banner "$content"
    [ "$status" -eq 0 ]
    reset="$(parse_reset_time "$content")"
    [ -n "$reset" ]
    epoch="$(epoch_of_reset "$reset")"
    [ "$epoch" -gt 0 ]
}
