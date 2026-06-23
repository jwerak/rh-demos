#!/bin/bash
set -euo pipefail
# CIS Level 2 kurovana remediace pro RHEL 9
# Aplikuje ~25 bezpecnych, vysokodopadovych oprav bez naruseni funkcnosti VM.

echo "=== CIS Level 2 Remediation Starting ==="

# --- Opravneni souboru (CIS 6.1.x) ---
echo "--- File permissions ---"
chmod 644 /etc/passwd /etc/group
chmod 000 /etc/shadow /etc/gshadow
[ -f /etc/passwd- ] && chmod 644 /etc/passwd-
[ -f /etc/shadow- ] && chmod 000 /etc/shadow-
chown root:root /etc/passwd /etc/shadow /etc/group /etc/gshadow

# --- auditd (CIS 4.1.x) ---
echo "--- auditd ---"
dnf install -y audit 2>/dev/null || rpm -q audit > /dev/null
systemctl enable --now auditd

cat > /etc/audit/rules.d/50-cis-remediation.rules <<'AUDITRULES'
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-a always,exit -F arch=b32 -C euid!=uid -F auid!=unset -S execve -k user_emulation
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -S clock_settime -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale
-a always,exit -F arch=b32 -S sethostname -S setdomainname -k system-locale
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=unset -k delete
-a always,exit -F arch=b32 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=unset -k delete
AUDITRULES
service auditd restart 2>/dev/null || true

# --- sysctl hardening (CIS 3.x) ---
echo "--- sysctl ---"
cat > /etc/sysctl.d/99-cis-hardening.conf <<'SYSCTL'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
SYSCTL
sysctl --system > /dev/null 2>&1

# --- SSH hardening (CIS 5.2.x) ---
echo "--- SSH hardening ---"
for PARAM in \
  "MaxAuthTries 4" \
  "PermitEmptyPasswords no" \
  "HostbasedAuthentication no" \
  "IgnoreRhosts yes" \
  "LogLevel VERBOSE" \
  "ClientAliveInterval 300" \
  "ClientAliveCountMax 3" \
  "LoginGraceTime 60" \
  "MaxStartups 10:30:60" \
  "MaxSessions 10" \
  "PermitUserEnvironment no"; do
  KEY=$(echo "$PARAM" | awk '{print $1}')
  sed -i "s/^#\?${KEY}.*/${PARAM}/" /etc/ssh/sshd_config
done
sshd -t 2>/dev/null && systemctl restart sshd

# --- Password policy (CIS 5.4.x) ---
echo "--- Password policy ---"
for PARAM in \
  "minlen = 14" \
  "minclass = 4" \
  "maxrepeat = 3" \
  "maxclassrepeat = 4" \
  "dcredit = -1" \
  "ucredit = -1" \
  "lcredit = -1" \
  "ocredit = -1"; do
  KEY=$(echo "$PARAM" | awk -F= '{print $1}' | xargs)
  sed -i "s/^#\?\s*${KEY}\s*=.*/${PARAM}/" /etc/security/pwquality.conf
done

# --- Core dump (CIS 1.5.x) ---
echo "--- Core dump ---"
grep -q '^\* hard core' /etc/security/limits.conf || echo '* hard core 0' >> /etc/security/limits.conf

# --- Login banner (CIS 1.7.x) ---
echo "--- Login banner ---"
echo "Authorized users only. All activity may be monitored and reported." > /etc/issue
echo "Authorized users only. All activity may be monitored and reported." > /etc/issue.net

# --- Disable unused services ---
echo "--- Disabling unused services ---"
systemctl disable --now rpcbind.service rpcbind.socket 2>/dev/null || true

# --- cron/at restrictions (CIS 5.1.x) ---
echo "--- Cron hardening ---"
chmod 0600 /etc/crontab
chmod 0700 /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.d 2>/dev/null || true

# --- Verification ---
echo ""
echo "=== Verification ==="
echo "auditd: $(systemctl is-active auditd)"
echo "sysctl tcp_syncookies: $(sysctl -n net.ipv4.tcp_syncookies)"
echo "sysctl randomize_va_space: $(sysctl -n kernel.randomize_va_space)"
echo "sysctl suid_dumpable: $(sysctl -n fs.suid_dumpable)"
echo ""
echo "=== CIS Level 2 Remediation Complete ==="
