# report-ssh

A Bash script that reports on SSH connections to a Linux system.

## Features

- **Interactive logins** – lists sessions where a PTY was allocated (standard
  shell logins), including login/logout timestamps and session duration.
- **Jump / tunnel connections** – identifies sessions used as SSH jump hosts
  or port-forwarding tunnels (`direct-tcpip` entries in the auth log).
- **User summary** – collates all unique users and their total connection count.
- **Connection time summary** – per-user totals and averages for session
  duration, plus flags for sessions still active or lacking a clean logout.
- **Cron-friendly** – output can be directed to stdout, a file (`-o`), or
  emailed (`-e`).

## Requirements

- Bash 4+
- `last` / `lastb` (util-linux or equivalent)
- Read access to the SSH auth log:
  - Debian/Ubuntu: `/var/log/auth.log`
  - RHEL/CentOS/Fedora: `/var/log/secure`
- `mail` (optional, for email delivery)

The script must be run as **root** (or a user with read access to the auth log
and `/var/log/wtmp`) to access all data sources.

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
  SSH Connection Report
  Host:      myserver.example.com
  Generated: 2024-01-15 06:00:01 UTC
  Period:    Last 7 day(s)
  Auth log:  /var/log/auth.log
============================================================

------------------------------------------------------------
  INTERACTIVE SSH LOGINS (last 7 day(s))
------------------------------------------------------------
  USER         TTY      FROM                 LOGIN                        LOGOUT                       DURATION
  ----         ---      ----                 -----                        ------                       --------
  alice        pts/0    10.0.0.5             Mon Jan 08 09:12:34 2024     Mon Jan 08 10:45:01 2024     1:32
  bob          pts/1    192.168.1.20         Tue Jan 09 14:00:00 2024     still logged in              active

------------------------------------------------------------
  JUMP / TUNNEL CONNECTIONS (last 7 day(s))
------------------------------------------------------------
  USER         FROM (client)          TO (destination)       TIMESTAMP
  ----         -------------          ----------------       ---------
  alice        10.0.0.5               server2.internal       Jan  8 09:13

------------------------------------------------------------
  USER CONNECTION SUMMARY (last 7 day(s))
------------------------------------------------------------
  USERNAME          CONNECTIONS
  --------          -----------
  alice                       5
  bob                         2

------------------------------------------------------------
  CONNECTION TIME SUMMARY (last 7 day(s))
------------------------------------------------------------
  USERNAME          SESSIONS   TOTAL(h)     AVG(h)     STATUS
  --------          --------   --------     ------     ------
  alice                    5       8.25       1.65
  bob                      2       0.00       0.00      1 active

============================================================
  End of Report
============================================================
```
