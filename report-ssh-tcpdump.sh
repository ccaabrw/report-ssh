#!/usr/bin/env bash
#
# report-ssh-tcpdump.sh - Report on incoming SSH port 22 connections via tcpdump
#
# Runs tcpdump for a specified period, capturing TCP SYN packets destined for
# port 22, then produces a summary of source IP addresses and connection counts.
#
# Usage:
#   report-ssh-tcpdump.sh [OPTIONS]
#
# Options:
#   -t SECONDS  Duration to capture in seconds (default: 60)
#   -i IFACE    Network interface to capture on (default: any)
#   -e EMAIL    Email address to send report to
#   -o FILE     Write report to FILE instead of stdout
#   -h          Show this help message
#
# Environment variables (override defaults):
#   CAPTURE_SECONDS  Duration in seconds (same as -t)
#   CAPTURE_IFACE    Network interface (same as -i)
#   REPORT_EMAIL     Email address (same as -e)
#
# Cron example (capture 5 minutes every hour, email to admin):
#   0 * * * * root /usr/local/bin/report-ssh-tcpdump.sh -t 300 -e admin@example.com

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration (defaults; overridable via env vars or CLI options)
# ---------------------------------------------------------------------------
CAPTURE_SECONDS="${CAPTURE_SECONDS:-60}"
CAPTURE_IFACE="${CAPTURE_IFACE:-any}"
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
while getopts ":t:i:e:o:h" opt; do
    case "$opt" in
        t) CAPTURE_SECONDS="$OPTARG" ;;
        i) CAPTURE_IFACE="$OPTARG" ;;
        e) OUTPUT_EMAIL="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument." >&2; exit 1 ;;
        \?) echo "ERROR: Unknown option -$OPTARG." >&2; exit 1 ;;
    esac
done

# Validate CAPTURE_SECONDS is a positive integer
if ! [[ "$CAPTURE_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: -t SECONDS must be a positive integer." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v tcpdump >/dev/null 2>&1; then
    echo "ERROR: 'tcpdump' is not installed or not in PATH." >&2
    exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
    echo "ERROR: 'timeout' is not available on this system." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect system information
# ---------------------------------------------------------------------------
REPORT_HOST=$(hostname -f 2>/dev/null || hostname)
REPORT_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ---------------------------------------------------------------------------
# Section helpers
# ---------------------------------------------------------------------------
divider() { printf '%s\n' "------------------------------------------------------------"; }
header()  { printf '\n%s\n  %s\n%s\n' "$(divider)" "$*" "$(divider)"; }

# ---------------------------------------------------------------------------
# Capture TCP SYN packets to port 22 for $CAPTURE_SECONDS seconds.
# Returns the raw tcpdump output.
# ---------------------------------------------------------------------------
capture_connections() {
    # Filter: TCP packets destined for port 22 with SYN flag set and ACK unset
    # (i.e., new connection attempts only, not established sessions).
    timeout "$CAPTURE_SECONDS" \
        tcpdump -i "$CAPTURE_IFACE" -n -q \
            'dst port 22 and tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0' \
            2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Section 1: Connection attempts – raw list sorted by time
# ---------------------------------------------------------------------------
section_connection_list() {
    local raw="$1"
    header "INCOMING SSH CONNECTION ATTEMPTS"

    if [ -z "$raw" ]; then
        echo "  No SSH connection attempts detected during the capture window."
        return
    fi

    printf '  %-28s %-22s %s\n' "TIMESTAMP" "SOURCE IP" "SOURCE PORT"
    printf '  %-28s %-22s %s\n' "---------" "---------" "-----------"

    # tcpdump -q output format:
    # HH:MM:SS.ffffff IP src_ip.src_port > dst_ip.dst_port: tcp NNN
    echo "$raw" | awk '
    /^[0-9]/ && / > / {
        ts  = $1
        src = $3
        # Strip trailing ">" from the source field if present
        gsub(/>$/, "", src)
        # Split "ip.port" on the last dot to separate IP from port
        n = split(src, parts, ".")
        port = parts[n]
        ip = ""
        for (j = 1; j < n; j++) ip = (ip == "" ? parts[j] : ip "." parts[j])
        printf "  %-28s %-22s %s\n", ts, ip, port
    }'
}

# ---------------------------------------------------------------------------
# Section 2: Source IP summary – connection counts per source
# ---------------------------------------------------------------------------
section_source_summary() {
    local raw="$1"
    header "SOURCE IP SUMMARY"

    if [ -z "$raw" ]; then
        echo "  No SSH connection attempts detected during the capture window."
        return
    fi

    printf '  %-22s %11s\n' "SOURCE IP" "ATTEMPTS"
    printf '  %-22s %11s\n' "---------" "--------"

    echo "$raw" | awk '
    /^[0-9]/ && / > / {
        src = $3
        gsub(/>$/, "", src)
        n = split(src, parts, ".")
        ip = ""
        for (j = 1; j < n; j++) ip = (ip == "" ? parts[j] : ip "." parts[j])
        count[ip]++
    }
    END {
        for (ip in count) printf "  %-22s %11d\n", ip, count[ip]
    }' | sort -t'.' -k1,1n -k2,2n -k3,3n -k4,4n \
       | sort -k2 -rn
}

# ---------------------------------------------------------------------------
# Assemble report
# ---------------------------------------------------------------------------
generate_report() {
    local raw="$1"
    local total
    total=$(printf '%s\n' "$raw" | awk '/^[0-9]/{c++} END{print c+0}')

    printf '%s\n' "============================================================"
    printf '  SSH Port 22 Traffic Report (tcpdump)\n'
    printf '  Host:      %s\n' "$REPORT_HOST"
    printf '  Generated: %s\n' "$REPORT_TIMESTAMP"
    printf '  Interface: %s\n' "$CAPTURE_IFACE"
    printf '  Duration:  %d second(s)\n' "$CAPTURE_SECONDS"
    printf '  Captured:  %d connection attempt(s)\n' "$total"
    printf '%s\n' "============================================================"

    section_connection_list "$raw"
    section_source_summary  "$raw"

    printf '\n%s\n' "============================================================"
    printf '  End of Report\n'
    printf '%s\n' "============================================================"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "Capturing SSH traffic on interface '${CAPTURE_IFACE}' for ${CAPTURE_SECONDS} second(s)..." >&2

    local raw
    raw=$(capture_connections)

    local report
    report=$(generate_report "$raw")

    if [ -n "$OUTPUT_FILE" ]; then
        echo "$report" > "$OUTPUT_FILE"
        echo "Report written to $OUTPUT_FILE" >&2
    elif [ -n "$OUTPUT_EMAIL" ]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$report" \
                | mail -s "SSH Traffic Report: ${REPORT_HOST} $(date '+%Y-%m-%d')" \
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
