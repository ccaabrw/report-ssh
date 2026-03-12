#!/usr/bin/env bash
#
# report-ssh.sh - Report on SSH connections to this system
#
# Captures:
#   - Interactive login sessions (sessions with PTY allocation)
#   - Jump/tunnel connections (direct-tcpip port forwarding sessions)
# Produces:
#   - Collated list of users and connection counts
#   - Summary of connection times per user
#
# Usage:
#   report-ssh.sh [OPTIONS]
#
# Options:
#   -d DAYS    Number of days to report on (default: 7)
#   -e EMAIL   Email address to send report to
#   -o FILE    Write report to FILE instead of stdout
#   -h         Show this help message
#
# Environment variables (override defaults):
#   REPORT_DAYS    Number of days (same as -d)
#   REPORT_EMAIL   Email address (same as -e)
#
# Cron example (daily report at 06:00, emailed to admin):
#   0 6 * * * /usr/local/bin/report-ssh.sh -d 1 -e admin@example.com

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (defaults; overridable via env vars or CLI options)
# ---------------------------------------------------------------------------
DAYS="${REPORT_DAYS:-7}"
OUTPUT_EMAIL="${REPORT_EMAIL:-}"
OUTPUT_FILE=""

# ---------------------------------------------------------------------------
# Helper: print usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
    exit 0
}

# ---------------------------------------------------------------------------
# Parse CLI options
# ---------------------------------------------------------------------------
while getopts ":d:e:o:h" opt; do
    case "$opt" in
        d) DAYS="$OPTARG" ;;
        e) OUTPUT_EMAIL="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option -$OPTARG." >&2; exit 1 ;;
    esac
done

# Validate DAYS is a positive integer
if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: -d DAYS must be a positive integer." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect system information
# ---------------------------------------------------------------------------
REPORT_HOST=$(hostname -f 2>/dev/null || hostname)
REPORT_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Locate the SSH auth log (distro-agnostic)
detect_auth_log() {
    local candidates=(
        /var/log/auth.log        # Debian / Ubuntu
        /var/log/secure          # RHEL / CentOS / Fedora
        /var/log/messages        # older distros / fallback
    )
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            echo "$f"
            return
        fi
    done
    echo ""
}
AUTH_LOG=$(detect_auth_log)

# ---------------------------------------------------------------------------
# Section helpers
# ---------------------------------------------------------------------------
divider() { printf '%s\n' "------------------------------------------------------------"; }
header()  { printf '\n%s\n  %s\n%s\n' "$(divider)" "$*" "$(divider)"; }

# ---------------------------------------------------------------------------
# Check whether the 'last' command supports -s (since <date>)
# (GNU coreutils ≥ 2.28 / util-linux ≥ 2.24 support -s)
# ---------------------------------------------------------------------------
last_supports_since() {
    last -s "-1days" -- /dev/null >/dev/null 2>&1
}

# Build the 'last' invocation appropriate for this system
# Output: username  tty  from  login-time  [logout-time]  [(duration)]
run_last() {
    if last_supports_since; then
        last -F -w -s "-${DAYS}days" 2>/dev/null
    else
        # Fallback: fetch more lines and let awk filter by date
        last -F -w 2>/dev/null | head -10000
    fi
}

# ---------------------------------------------------------------------------
# Filter a 'last -F' line by whether its login timestamp is within $DAYS days
# ---------------------------------------------------------------------------
cutoff_epoch() {
    date -d "-${DAYS} days" '+%s' 2>/dev/null \
        || date -v "-${DAYS}d" '+%s' 2>/dev/null \
        || echo 0
}

# ---------------------------------------------------------------------------
# Section 1: Interactive SSH logins
# ---------------------------------------------------------------------------
section_interactive_logins() {
    header "INTERACTIVE SSH LOGINS (last ${DAYS} day(s))"

    if ! command -v last >/dev/null 2>&1; then
        echo "  'last' command not available on this system."
        return
    fi

    local output
    output=$(run_last | grep -v '^reboot\|^shutdown\|^wtmp begins\|^$' || true)

    if [ -z "$output" ]; then
        echo "  No login records found."
        return
    fi

    printf '  %-12s %-8s %-20s %-28s %-28s %s\n' \
        "USER" "TTY" "FROM" "LOGIN" "LOGOUT" "DURATION"
    printf '  %-12s %-8s %-20s %-28s %-28s %s\n' \
        "----" "---" "----" "-----" "------" "--------"

    echo "$output" | awk -v days="$DAYS" '
    NF >= 4 {
        user   = $1
        tty    = $2
        from   = $3
        # last -F produces: Www Mmm DD HH:MM:SS YYYY  (5 tokens per timestamp)
        login  = $4 " " $5 " " $6 " " $7 " " $8
        logout = ""
        dur    = ""
        if (NF >= 13) {
            logout = $9 " " $10 " " $11 " " $12 " " $13
        }
        if (match($0, /\(([0-9+:]+)\)/, arr)) {
            dur = arr[1]
        } else if (match($0, /still logged in/)) {
            dur = "active"
        } else if (match($0, /no logout/)) {
            dur = "no logout"
        }
        printf "  %-12s %-8s %-20s %-28s %-28s %s\n", user, tty, from, login, logout, dur
    }'
}

# ---------------------------------------------------------------------------
# Section 2: Jump / tunnel connections
# Identified by "direct-tcpip" entries in the SSH auth log.
# When a server acts as a ProxyJump host the connecting client opens a
# direct-tcpip channel; this appears in the auth log even if no PTY is used.
# ---------------------------------------------------------------------------
section_jump_connections() {
    header "JUMP / TUNNEL CONNECTIONS (last ${DAYS} day(s))"

    if [ -z "$AUTH_LOG" ]; then
        echo "  SSH auth log not found on this system."
        return
    fi

    if [ ! -r "$AUTH_LOG" ]; then
        echo "  Auth log '$AUTH_LOG' is not readable. Try running as root."
        return
    fi

    # Build a date pattern covering the last $DAYS days (Month Day format)
    local patterns=()
    local i
    for (( i=0; i<DAYS; i++ )); do
        patterns+=("$(date -d "-${i} days" '+%b %e' 2>/dev/null \
                   || date -v "-${i}d" '+%b %e' 2>/dev/null)")
    done

    # Grep the auth log for direct-tcpip lines within the date window
    local grep_pattern
    grep_pattern=$(IFS='|'; echo "${patterns[*]}")

    local results
    results=$(grep -E "direct-tcpip" "$AUTH_LOG" 2>/dev/null \
              | grep -E "($grep_pattern)" || true)

    if [ -z "$results" ]; then
        echo "  No jump/tunnel connections found in '$AUTH_LOG'."
        return
    fi

    printf '  %-12s %-22s %-22s %s\n' "USER" "FROM (client)" "TO (destination)" "TIMESTAMP"
    printf '  %-12s %-22s %-22s %s\n' "----" "-------------" "----------------" "---------"

    # Example log line:
    # Jan  1 12:00:00 host sshd[1234]: Accepted publickey for alice from 1.2.3.4 port 54321 ...
    # Jan  1 12:00:01 host sshd[1234]: direct-tcpip: hostbound [alice] to server.example.com port 22 from 1.2.3.4 port 54321
    echo "$results" | awk '
    {
        # Timestamp = fields 1-3
        ts = $1 " " $2 " " $3
        # Extract user (after "for" keyword)
        user = ""
        from = ""
        to   = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "for" && $(i+1) != "") { user = $(i+1) }
            if ($i == "from" && $(i+1) != "") { from = $(i+1) }
            if (($i == "to" || $i == "host") && $(i+1) != "") {
                candidate = $(i+1)
                if (candidate ~ /^[a-zA-Z0-9._-]+$/) { to = candidate }
            }
        }
        printf "  %-12s %-22s %-22s %s\n", user, from, to, ts
    }'
}

# ---------------------------------------------------------------------------
# Section 3: User summary – connection counts
# ---------------------------------------------------------------------------
section_user_summary() {
    header "USER CONNECTION SUMMARY (last ${DAYS} day(s))"

    if ! command -v last >/dev/null 2>&1; then
        echo "  'last' command not available on this system."
        return
    fi

    printf '  %-16s %11s\n' "USERNAME" "CONNECTIONS"
    printf '  %-16s %11s\n' "--------" "-----------"

    run_last \
        | grep -v '^reboot\|^shutdown\|^wtmp begins\|^$' \
        | awk '{print $1}' \
        | sort \
        | uniq -c \
        | sort -rn \
        | awk '{printf "  %-16s %11d\n", $2, $1}' \
        || echo "  No records found."
}

# ---------------------------------------------------------------------------
# Section 4: Connection time summary – total and per-user
# ---------------------------------------------------------------------------
# Parse a duration string like "00:30", "1:30", or "5+02:30" into seconds
duration_to_seconds() {
    local d="$1"
    local days=0 hours=0 mins=0
    if [[ "$d" == *+* ]]; then
        days="${d%%+*}"
        d="${d#*+}"
    fi
    hours="${d%%:*}"
    mins="${d##*:}"
    echo $(( (days * 86400) + (hours * 3600) + (mins * 60) ))
}

section_connection_times() {
    header "CONNECTION TIME SUMMARY (last ${DAYS} day(s))"

    if ! command -v last >/dev/null 2>&1; then
        echo "  'last' command not available on this system."
        return
    fi

    # Collect raw data: username and duration token
    local data
    data=$(run_last | grep -v '^reboot\|^shutdown\|^wtmp begins\|^$' || true)

    if [ -z "$data" ]; then
        echo "  No records found."
        return
    fi

    printf '  %-16s %10s %10s %10s %10s\n' \
        "USERNAME" "SESSIONS" "TOTAL(h)" "AVG(h)" "STATUS"
    printf '  %-16s %10s %10s %10s %10s\n' \
        "--------" "--------" "--------" "------" "------"

    echo "$data" | awk '
    function seconds_from_dur(dur,    d, h, m) {
        d = 0; h = 0; m = 0
        if (index(dur, "+") > 0) {
            d = substr(dur, 1, index(dur, "+") - 1)
            dur = substr(dur, index(dur, "+") + 1)
        }
        split(dur, a, ":")
        h = a[1]; m = a[2]
        return (d * 86400) + (h * 3600) + (m * 60)
    }
    {
        user = $1
        sessions[user]++
        # Look for duration token "(D+HH:MM)" or "(HH:MM)"
        if (match($0, /\(([0-9]+\+)?[0-9]+:[0-9]+\)/, arr)) {
            dur = substr(arr[0], 2, length(arr[0]) - 2)
            total_secs[user] += seconds_from_dur(dur)
        }
        # Track active/no-logout sessions
        if ($0 ~ /still logged in/)  active[user]++
        if ($0 ~ /no logout/)        no_logout[user]++
    }
    END {
        for (user in sessions) {
            s = sessions[user]
            t = total_secs[user]
            total_h = t / 3600.0
            avg_h   = (s > 0) ? (total_h / s) : 0
            status  = ""
            if (user in active)   status = active[user]   " active"
            if (user in no_logout) status = (status ? status ", " : "") no_logout[user] " no-logout"
            printf "  %-16s %10d %10.2f %10.2f %10s\n", user, s, total_h, avg_h, status
        }
    }' | sort -k1
}

# ---------------------------------------------------------------------------
# Assemble report
# ---------------------------------------------------------------------------
generate_report() {
    printf '%s\n' "============================================================"
    printf '  SSH Connection Report\n'
    printf '  Host:      %s\n' "$REPORT_HOST"
    printf '  Generated: %s\n' "$REPORT_TIMESTAMP"
    printf '  Period:    Last %d day(s)\n' "$DAYS"
    if [ -n "$AUTH_LOG" ]; then
        printf '  Auth log:  %s\n' "$AUTH_LOG"
    fi
    printf '%s\n' "============================================================"

    section_interactive_logins
    section_jump_connections
    section_user_summary
    section_connection_times

    printf '\n%s\n' "============================================================"
    printf '  End of Report\n'
    printf '%s\n' "============================================================"
}

# ---------------------------------------------------------------------------
# Output: stdout, file, or email
# ---------------------------------------------------------------------------
main() {
    local report
    report=$(generate_report)

    if [ -n "$OUTPUT_FILE" ]; then
        echo "$report" > "$OUTPUT_FILE"
        echo "Report written to $OUTPUT_FILE" >&2
    elif [ -n "$OUTPUT_EMAIL" ]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$report" \
                | mail -s "SSH Report: ${REPORT_HOST} $(date '+%Y-%m-%d')" \
                       "$OUTPUT_EMAIL"
            echo "Report emailed to $OUTPUT_EMAIL" >&2
        else
            echo "WARNING: 'mail' not found; printing report to stdout." >&2
            echo "$report"
        fi
    else
        echo "$report"
    fi
}

main
