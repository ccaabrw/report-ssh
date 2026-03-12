# report-ssh

A Bash script that collates SSH session-open events on a Linux system by
scanning the secure log files.

## Features

- **Secure log scanning** – reads the system auth/secure log files, including
  rotated and gzip-compressed copies, to find every
  `session opened for user` message within the configured date window.
- **Chronological session list** – shows every session-open event with its
  timestamp and username.
- **User summary** – collates all unique users and their total session count,
  sorted by frequency.
- **Cron-friendly** – output can be directed to stdout, a file (`-o`), or
  emailed (`-e`).

## Requirements

- Bash 4+ with gawk (for `mktime`/`systime`)
- Read access to the SSH auth log:
  - Debian/Ubuntu: `/var/log/auth.log` (and rotated copies)
  - RHEL/CentOS/Fedora: `/var/log/secure` (and rotated copies)
- `zcat` (for reading gzip-compressed rotated logs)
- `mail` (optional, for email delivery)

The script must be run as **root** (or a user with read access to the auth
log files) to access all data sources.

## Installation

```bash
sudo cp report-ssh.sh /usr/local/bin/report-ssh.sh
sudo chmod 755 /usr/local/bin/report-ssh.sh
```

## Usage

```
report-ssh.sh [OPTIONS]

Options:
  -d DAYS    Number of days to report on (default: 7)
  -e EMAIL   Email address to send report to
  -o FILE    Write report to FILE instead of stdout
  -h         Show help
```

Environment variables `REPORT_DAYS` and `REPORT_EMAIL` mirror the `-d` and
`-e` options and can be set in cron environments.

### Examples

```bash
# Print a 7-day report to the terminal
sudo report-ssh.sh

# Report on the last 24 hours only
sudo report-ssh.sh -d 1

# Email a weekly report
sudo report-ssh.sh -d 7 -e admin@example.com

# Write a dated log file
sudo report-ssh.sh -d 1 -o /var/log/ssh-report-$(date +%Y%m%d).log
```

## Cron Setup

Copy the example cron file:

```bash
sudo cp cron.d/report-ssh /etc/cron.d/report-ssh
sudo chmod 644 /etc/cron.d/report-ssh
```

Edit `/etc/cron.d/report-ssh` to set your preferred schedule and email address.
The default runs daily at 06:00 and emails the report to `root`.

---

## report-ssh-tcpdump.sh

A companion script that uses **tcpdump** to capture and report on incoming TCP
connection attempts to SSH port 22 in real time.

### Features

- **Live packet capture** – uses `tcpdump` to capture TCP SYN packets destined
  for port 22 (new connection attempts, not established sessions).
- **Configurable duration** – captures traffic for a fixed number of seconds,
  making it safe to schedule as a periodic cron job.
- **Per-attempt log** – lists every observed connection attempt with timestamp,
  source IP, and source port.
- **Source IP summary** – collates unique source IPs and their attempt counts,
  sorted by highest frequency.
- **Cron-friendly** – output can be directed to stdout, a file (`-o`), or
  emailed (`-e`).

### Requirements

- Bash 4+
- `tcpdump` (must be installed and in `PATH`)
- `timeout` (GNU coreutils)
- Root privileges (required for raw packet capture)
- `mail` (optional, for email delivery)

### Installation

```bash
sudo cp report-ssh-tcpdump.sh /usr/local/bin/report-ssh-tcpdump.sh
sudo chmod 755 /usr/local/bin/report-ssh-tcpdump.sh
```

### Usage

```
report-ssh-tcpdump.sh [OPTIONS]

Options:
  -t SECONDS  Duration to capture in seconds (default: 60)
  -i IFACE    Network interface to capture on (default: any)
  -e EMAIL    Email address to send report to
  -o FILE     Write report to FILE instead of stdout
  -h          Show help
```

Environment variables `CAPTURE_SECONDS`, `CAPTURE_IFACE`, and `REPORT_EMAIL`
mirror the `-t`, `-i`, and `-e` options and can be set in cron environments.

### Examples

```bash
# Capture 60 seconds of traffic and print the report
sudo report-ssh-tcpdump.sh

# Capture for 5 minutes on a specific interface
sudo report-ssh-tcpdump.sh -t 300 -i eth0

# Email an hourly report
sudo report-ssh-tcpdump.sh -t 60 -e admin@example.com

# Write a dated log file
sudo report-ssh-tcpdump.sh -t 60 -o /var/log/ssh-traffic-$(date +%Y%m%d-%H).log
```

### Cron Setup

```bash
sudo cp cron.d/report-ssh-tcpdump /etc/cron.d/report-ssh-tcpdump
sudo chmod 644 /etc/cron.d/report-ssh-tcpdump
```

Edit `/etc/cron.d/report-ssh-tcpdump` to set your preferred schedule, capture
duration, and email address.  The default runs at the top of every hour,
captures 60 seconds of traffic, and emails the report to `root`.

### Sample Output

```
============================================================
  SSH Port 22 Traffic Report (tcpdump)
  Host:      myserver.example.com
  Generated: 2024-01-15 07:00:01 UTC
  Interface: any
  Duration:  60 second(s)
  Captured:  3 connection attempt(s)
============================================================

------------------------------------------------------------
  INCOMING SSH CONNECTION ATTEMPTS
------------------------------------------------------------
  TIMESTAMP                    SOURCE IP              SOURCE PORT
  ---------                    ---------              -----------
  07:00:03.124518              203.0.113.42           54321
  07:00:15.882341              198.51.100.7           61000
  07:00:47.003192              203.0.113.42           54399

------------------------------------------------------------
  SOURCE IP SUMMARY
------------------------------------------------------------
  SOURCE IP              ATTEMPTS
  ---------              --------
  203.0.113.42                  2
  198.51.100.7                  1

============================================================
  End of Report
============================================================
```

---

## Sample Output (report-ssh.sh)

```
============================================================
  SSH Session Report
  Host:      myserver.example.com
  Generated: 2024-01-15 06:00:01 UTC
  Period:    Last 7 day(s)
  Log files: /var/log/auth.log
             /var/log/auth.log.1
             /var/log/auth.log.2.gz
============================================================

------------------------------------------------------------
  SSH SESSIONS OPENED (last 7 day(s))
------------------------------------------------------------
  TIMESTAMP      USER             LOG ENTRY
  ---------      ----             ---------
  Jan  8 09:12  alice            Jan  8 09:12:34 myserver sshd[1234]: pam_unix(sshd:session): session opened for user alice by (uid=0)
  Jan  8 14:00  bob              Jan  8 14:00:00 myserver sshd[5678]: pam_unix(sshd:session): session opened for user bob by (uid=0)
  Jan  9 08:45  alice            Jan  9 08:45:11 myserver sshd[9012]: pam_unix(sshd:session): session opened for user alice by (uid=0)

------------------------------------------------------------
  USER SESSION SUMMARY (last 7 day(s))
------------------------------------------------------------
  USERNAME                    SESSIONS
  --------                    --------
  alice                              5
  bob                                2

============================================================
  End of Report
============================================================
```
