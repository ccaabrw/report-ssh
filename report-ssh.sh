#!/usr/bin/env bash
#
# report-ssh.sh - Report on SSH sessions opened on this system
#
# Collates all "session opened for user" messages from the secure log files
# (including rotated and compressed copies) and produces:
#   - A chronological list of every session-open event
#   - A collated summary of session counts per user
#
# Usage:
#   report-ssh.sh [OPTIONS]
#
# Options:
#   -a         Show authentication type for each session-open event
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
SHOW_AUTH_TYPE=0

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
while getopts ":d:e:o:ah" opt; do
    case "$opt" in
        a) SHOW_AUTH_TYPE=1 ;;
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

# ---------------------------------------------------------------------------
# Locate all candidate auth/secure log files, including rotated and
# gzip-compressed copies (e.g. auth.log.1, auth.log.2.gz, secure.1 …)
# Returns one path per line.
# ---------------------------------------------------------------------------
detect_log_files() {
    local found=()
    local f
    # Use nullglob so unmatched glob patterns expand to nothing
    local old_nullglob
    old_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    for f in \
        /var/log/auth.log \
        /var/log/auth.log.[0-9]* \
        /var/log/auth.log.[0-9]*.gz \
        /var/log/secure \
        /var/log/secure.[0-9]* \
        /var/log/secure.[0-9]*.gz \
        /var/log/messages
    do
        [ -f "$f" ] && found+=("$f")
    done
    eval "$old_nullglob"
    # De-duplicate (a plain glob like auth.log.[0-9]* also matches *.gz files)
    printf '%s\n' "${found[@]+"${found[@]}"}" | sort -u
}

# Populate LOG_FILES once at startup so the list is shared across sections
mapfile -t LOG_FILES < <(detect_log_files)

# ---------------------------------------------------------------------------
# Read a log file, transparently decompressing .gz files
# ---------------------------------------------------------------------------
read_log() {
    local f="$1"
    case "$f" in
        *.gz) zcat "$f" 2>/dev/null ;;
        *)    cat  "$f" 2>/dev/null ;;
    esac
}

# ---------------------------------------------------------------------------
# Emit epoch seconds for the start of the reporting window.
# Supports both GNU date (-d) and BSD date (-v).
# ---------------------------------------------------------------------------
cutoff_epoch() {
    date -d "-${DAYS} days" '+%s' 2>/dev/null \
        || date -v "-${DAYS}d" '+%s' 2>/dev/null \
        || echo 0
}

# ---------------------------------------------------------------------------
# Collect all "session opened for user" lines from all log files,
# filtered to the last $DAYS days.
#
# Syslog timestamp format (no year): "Mmm DD HH:MM:SS"
# We reconstruct a year-qualified timestamp for date comparison.
# ---------------------------------------------------------------------------
collect_session_lines() {
    local cutoff
    cutoff=$(cutoff_epoch)
    local current_year
    current_year=$(date '+%Y')

    if [ "${#LOG_FILES[@]}" -eq 0 ]; then
        return
    fi

    # When showing auth type, also collect "Accepted" lines so we can
    # correlate them with session-open events via the sshd PID.
    local grep_pattern='session opened for user'
    if [ "$SHOW_AUTH_TYPE" -eq 1 ]; then
        grep_pattern='session opened for user|sshd\[[0-9]+\]: Accepted '
    fi

    for f in "${LOG_FILES[@]}"; do
        if [ ! -r "$f" ]; then
            printf 'WARN: %s is not readable (try running as root)\n' "$f" >&2
            continue
        fi
        read_log "$f"
    done \
    | grep -E "$grep_pattern" \
    | awk -v cutoff="$cutoff" -v yr="$current_year" '
        # Syslog months (1-based index)
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", M)
            for (i=1; i<=12; i++) mon[M[i]] = i
        }
        NF >= 5 {
            # Fields: Month Day HH:MM:SS hostname process[pid]: message...
            mname = $1; day = $2; hms = $3
            split(hms, t, ":")
            ts = sprintf("%04d %02d %02d %02d %02d %02d",
                         yr, mon[mname]+0, day+0, t[1]+0, t[2]+0, t[3]+0)
            # Convert to epoch via mktime (gawk)
            epoch = mktime(ts)
            # If the computed epoch is in the future, the log entry is from the
            # previous year (e.g. Dec entries read in January)
            if (epoch > systime()) {
                yr_adj = yr - 1
                ts = sprintf("%04d %02d %02d %02d %02d %02d",
                             yr_adj, mon[mname]+0, day+0, t[1]+0, t[2]+0, t[3]+0)
                epoch = mktime(ts)
            }
            if (epoch >= cutoff) print $0
        }
    '
}

# ---------------------------------------------------------------------------
# Section helpers
# ---------------------------------------------------------------------------
divider() { printf '%s\n' "------------------------------------------------------------"; }
header()  { printf '\n%s\n  %s\n%s\n' "$(divider)" "$*" "$(divider)"; }

# ---------------------------------------------------------------------------
# Section 1: Chronological list of session-open events
# ---------------------------------------------------------------------------
section_session_list() {
    local data="$1"
    header "SSH SESSIONS OPENED (last ${DAYS} day(s))"

    if [ -z "$data" ]; then
        echo "  No 'session opened' records found."
        return
    fi

    if [ "$SHOW_AUTH_TYPE" -eq 1 ]; then
        printf '  %-14s %-16s %-15s %s\n' "TIMESTAMP" "USER" "AUTH TYPE" "LOG ENTRY"
        printf '  %-14s %-16s %-15s %s\n' "---------" "----" "---------" "---------"
    else
        printf '  %-14s %-16s %s\n' "TIMESTAMP" "USER" "LOG ENTRY"
        printf '  %-14s %-16s %s\n' "---------" "----" "---------"
    fi

    echo "$data" | awk -v show_auth="$SHOW_AUTH_TYPE" '
    /Accepted / {
        # Build PID -> auth-type map from "Accepted <method> for ..." lines.
        # Field 5 has the form "sshd[PID]:" – extract the numeric PID.
        pid = $5
        sub(/.*\[/, "", pid)
        sub(/\].*/, "", pid)
        for (i = 1; i <= NF; i++) {
            if ($i == "Accepted") { auth_map[pid] = $(i+1); break }
        }
        next
    }
    {
        ts = $1 " " $2 " " $3
        user = ""
        for (i = 1; i <= NF; i++) {
            if ($i == "user" && $(i+1) != "") {
                user = $(i+1)
                # Strip a trailing parenthesised uid if present, e.g. "alice(uid=1000)"
                sub(/\(.*/, "", user)
                break
            }
        }
        if (show_auth) {
            pid = $5
            sub(/.*\[/, "", pid)
            sub(/\].*/, "", pid)
            authtype = (pid in auth_map) ? auth_map[pid] : "-"
            printf "  %-14s %-16s %-15s %s\n", ts, user, authtype, $0
        } else {
            printf "  %-14s %-16s %s\n", ts, user, $0
        }
    }' | sort
}

# ---------------------------------------------------------------------------
# Section 2: Collated summary – session counts per user
# ---------------------------------------------------------------------------
section_user_summary() {
    local data="$1"
    header "USER SESSION SUMMARY (last ${DAYS} day(s))"

    if [ -z "$data" ]; then
        echo "  No 'session opened' records found."
        return
    fi

    printf '  %-20s %11s\n' "USERNAME" "SESSIONS"
    printf '  %-20s %11s\n' "--------" "--------"

    echo "$data" | awk '
    {
        for (i = 1; i <= NF; i++) {
            if ($i == "user" && $(i+1) != "") {
                user = $(i+1)
                sub(/\(.*/, "", user)
                count[user]++
                break
            }
        }
    }
    END {
        for (u in count) printf "  %-20s %11d\n", u, count[u]
    }' | sort -k2 -rn
}

# ---------------------------------------------------------------------------
# Assemble report
# ---------------------------------------------------------------------------
generate_report() {
    printf '%s\n' "============================================================"
    printf '  SSH Session Report\n'
    printf '  Host:      %s\n' "$REPORT_HOST"
    printf '  Generated: %s\n' "$REPORT_TIMESTAMP"
    printf '  Period:    Last %d day(s)\n' "$DAYS"
    if [ "${#LOG_FILES[@]}" -gt 0 ]; then
        printf '  Log files: %s\n' "${LOG_FILES[0]}"
        local f
        for f in "${LOG_FILES[@]:1}"; do
            printf '             %s\n' "$f"
        done
    else
        printf '  Log files: (none found)\n'
    fi
    printf '%s\n' "============================================================"

    local data
    data=$(collect_session_lines)

    section_session_list  "$data"
    section_user_summary  "$data"

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
