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

## Sample Output

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
