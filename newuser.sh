#!/usr/bin/env bash
#
# KM — new user + hardening bootstrap. The first thing you run on a fresh box
# that only has root. It creates one non-root, sudo-capable user (username +
# password read interactively), then hardens the server.
#
#   Run as root (paste in your provider's web terminal):
#     curl -fsSL https://raw.githubusercontent.com/Ari6six6/KM/main/newuser.sh | bash
#
# What it does, in order:
#   1. Pre-flight (root, distro, admin group).
#   2. Ensure `sudo` is installed.
#   3. Read username (validated) + password (hidden, typed twice).
#   4. Create / update the user, set the password, grant sudo.
#   5. Optionally install an SSH public key for that user (paste it in).
#   6. Harden: automatic security updates, fail2ban, sysctl, a locked-down
#      sshd (root login off; key-only IF you installed a key and opt in), and
#      a ufw firewall that allows only SSH in.
#
# Safety:
#   * Prompts read from /dev/tty, so `curl ... | bash` stays interactive.
#   * The password is never echoed and never written to a file or the log.
#   * sshd is *reloaded*, not restarted — your current session stays alive.
#   * The firewall detects your real SSH port and allows it BEFORE enabling.
#   * Password login is only turned off when a key is present and you confirm.
#   * Set KM_SKIP_HARDEN=1 to create the user only, no hardening.
#
# No VPN, no docker — that's a different script (KM's setup.sh).
#
set -Eeuo pipefail

# --- pretty logging (colours only on a tty) --------------------------------
if [ -t 1 ]; then
  c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
else
  c_red=""; c_grn=""; c_ylw=""; c_cyn=""; c_rst=""
fi
say()  { printf '%s==>%s %s\n' "$c_cyn" "$c_rst" "$*"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%sERR %s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

trap 'die "failed at line $LINENO (command: $BASH_COMMAND)"' ERR

# ===========================================================================
# 1. Pre-flight
# ===========================================================================
say "Pre-flight checks"

[[ $EUID -eq 0 ]] || die "run as root:  curl -fsSL <url> | bash   (you are $(id -un))"

# Read prompts from the real terminal so this works under `curl ... | bash`,
# where stdin is the pipe rather than the keyboard.
if [[ -r /dev/tty ]]; then
  TTY=/dev/tty
else
  TTY=/dev/stdin
  warn "no /dev/tty — reading from stdin (run interactively, not from a pipe)"
fi

ask_yn() {  # ask_yn "Question? [y/N]" <default:N>  -> exit 0 on yes
  local prompt="$1" default="${2:-N}" ans=""
  printf '%s ' "$prompt" >"$TTY"
  read -r ans <"$TTY" || ans=""
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

IS_DEBIAN=0
command -v apt-get >/dev/null 2>&1 && IS_DEBIAN=1

# Pick the right admin group for this distro (sudo on Debian/Ubuntu, wheel on
# RHEL-likes). Create 'sudo' if neither exists on a very bare image.
if getent group sudo >/dev/null 2>&1; then
  ADMIN_GROUP=sudo
elif getent group wheel >/dev/null 2>&1; then
  ADMIN_GROUP=wheel
else
  ADMIN_GROUP=sudo
  groupadd "$ADMIN_GROUP"
fi
ok "admin group: $ADMIN_GROUP"

# ===========================================================================
# 2. Make sure `sudo` is actually installed (bare images sometimes lack it)
# ===========================================================================
if ! command -v sudo >/dev/null 2>&1; then
  say "Installing sudo"
  if [[ "$IS_DEBIAN" -eq 1 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null && apt-get install -y sudo >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo >/dev/null
  else
    warn "no known package manager — install 'sudo' yourself if it's missing"
  fi
  command -v sudo >/dev/null 2>&1 && ok "sudo installed" || warn "sudo still not found"
fi

# ===========================================================================
# 3. Read the username
# ===========================================================================
say "New user"

USERNAME=""
while :; do
  printf 'Username: ' >"$TTY"
  read -r USERNAME <"$TTY" || die "no input"
  USERNAME="${USERNAME// /}"
  [[ -n "$USERNAME" ]] || { warn "username can't be empty"; continue; }
  # Linux username rules: start with a letter or underscore, then lowercase
  # letters / digits / underscore / hyphen, max 32 chars.
  if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ || ${#USERNAME} -gt 32 ]]; then
    warn "invalid name — lowercase letters, digits, '-' or '_', starting with a letter (max 32)"
    continue
  fi
  break
done

USER_EXISTS=0
if id "$USERNAME" >/dev/null 2>&1; then
  USER_EXISTS=1
  warn "user '$USERNAME' already exists — I'll reset its password and ensure sudo"
fi

# ===========================================================================
# 4. Read the password (twice, hidden, confirmed)
# ===========================================================================
PASSWORD=""
while :; do
  printf 'Password: ' >"$TTY"
  read -rs PASSWORD <"$TTY" || die "no input"
  printf '\n' >"$TTY"
  [[ -n "$PASSWORD" ]] || { warn "password can't be empty"; continue; }
  if [[ ${#PASSWORD} -lt 8 ]]; then
    warn "that's under 8 characters — weak. Type it again to keep it, or Ctrl-C to bail."
  fi
  printf 'Confirm : ' >"$TTY"
  read -rs PASSWORD2 <"$TTY" || die "no input"
  printf '\n' >"$TTY"
  [[ "$PASSWORD" == "$PASSWORD2" ]] || { warn "passwords don't match — try again"; continue; }
  break
done
unset PASSWORD2

# ===========================================================================
# 5. Create / update the user
# ===========================================================================
say "Setting up '$USERNAME'"

if [[ "$USER_EXISTS" -eq 0 ]]; then
  useradd -m -s /bin/bash "$USERNAME"
  ok "user created (home: /home/$USERNAME, shell: /bin/bash)"
else
  [[ -d "/home/$USERNAME" ]] || { mkdir -p "/home/$USERNAME"; chown "$USERNAME:$USERNAME" "/home/$USERNAME"; }
  usermod -s /bin/bash "$USERNAME" 2>/dev/null || true
fi

# Set the password (chpasswd reads user:pass on stdin; nothing hits the disk).
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
unset PASSWORD
ok "password set"

usermod -aG "$ADMIN_GROUP" "$USERNAME"
ok "added to '$ADMIN_GROUP' — sudo works (it'll ask for this password)"

# ===========================================================================
# 6. Optional: install an SSH public key for the new user
# ===========================================================================
HAVE_KEY=0
say "SSH public key (optional)"
echo "  Paste an SSH *public* key (one line, e.g. 'ssh-ed25519 AAAA... you@host')"
echo "  to enable key-based login. Leave blank to skip and keep password login."
printf 'Public key: ' >"$TTY"
read -r PUBKEY <"$TTY" || PUBKEY=""
PUBKEY="${PUBKEY#"${PUBKEY%%[![:space:]]*}"}"   # ltrim
PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"   # rtrim
if [[ -n "$PUBKEY" ]]; then
  if [[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]; then
    SSH_DIR="/home/$USERNAME/.ssh"
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
    touch "$SSH_DIR/authorized_keys"
    grep -qxF "$PUBKEY" "$SSH_DIR/authorized_keys" 2>/dev/null || printf '%s\n' "$PUBKEY" >>"$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
    HAVE_KEY=1
    ok "SSH key installed for $USERNAME"
  else
    warn "that doesn't look like a public key — skipping (keeping password login)"
  fi
else
  ok "no key provided — password login stays on"
fi

# ===========================================================================
# 7. Hardening
# ===========================================================================
if [[ "${KM_SKIP_HARDEN:-0}" == "1" ]]; then
  warn "KM_SKIP_HARDEN=1 — skipping hardening; user-only setup done"
else
say "Hardening the server"
export DEBIAN_FRONTEND=noninteractive

# Detect the real SSH port up front (we never change it — we just protect it).
# Every command substitution here ends in `|| true`: under `set -Eeuo pipefail`
# a probe that exits non-zero (sshd not on PATH, `sshd -T` refusing to run with
# no host keys or a Match block, or grep finding nothing) would otherwise fire
# the ERR trap and kill the whole script. Detection must never be fatal — worst
# case we fall through to the safe default of 22.
detect_ssh_port() {
  local p="" sshd_bin=""
  # sshd is usually in /usr/sbin, which isn't always on root's PATH.
  sshd_bin="$(command -v sshd 2>/dev/null || true)"
  [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]] && sshd_bin=/usr/sbin/sshd
  # Ask the running sshd for its effective port (authoritative when it works).
  if [[ -n "$sshd_bin" ]]; then
    p="$("$sshd_bin" -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  fi
  # Fall back to the config files (first explicit Port directive wins).
  p="$(grep -rhiE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2; exit}' || true)"
  [[ "$p" =~ ^[0-9]+$ ]] && { echo "$p"; return; }
  # Nothing said otherwise — the SSH default.
  echo 22
}
SSH_PORT="$(detect_ssh_port)"
ok "SSH port detected: $SSH_PORT"

# --- 7a. Packages ---------------------------------------------------------
if [[ "$IS_DEBIAN" -eq 1 ]]; then
  apt-get update -y >/dev/null 2>&1 || warn "apt-get update had issues — continuing"
  apt-get install -y fail2ban unattended-upgrades ufw >/dev/null 2>&1 \
    && ok "installed fail2ban, unattended-upgrades, ufw" \
    || warn "some hardening packages failed to install — continuing"
else
  warn "hardening is tuned for Debian/Ubuntu; on this distro some steps are skipped"
  command -v dnf >/dev/null 2>&1 && { dnf install -y fail2ban >/dev/null 2>&1 || true; }
fi

# --- 7b. Automatic security updates (Debian/Ubuntu) -----------------------
if [[ "$IS_DEBIAN" -eq 1 ]]; then
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 \
    && ok "automatic security updates enabled" \
    || warn "could not enable unattended-upgrades"
fi

# --- 7c. fail2ban SSH jail (drop-in — never touch shipped jail.conf) ------
if command -v fail2ban-server >/dev/null 2>&1 || [[ -d /etc/fail2ban ]]; then
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/km-sshd.local <<EOF
[sshd]
enabled  = true
backend  = systemd
port     = $SSH_PORT
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl reload-or-restart fail2ban >/dev/null 2>&1 || true
  ok "fail2ban sshd jail active (5 tries / 10m -> 1h ban)"
fi

# --- 7d. sysctl hardening -------------------------------------------------
cat >/etc/sysctl.d/99-km.conf <<'EOF'
# KM hardening — managed by newuser.sh
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.log_martians=1
kernel.kptr_restrict=2
EOF
sysctl --system >/dev/null 2>&1 && ok "sysctl hardening applied" || warn "sysctl apply had issues"

# --- 7e. sshd lockdown (reload, never restart; validated; revertible) -----
# Decide password auth: only turn it OFF when a key is installed AND you opt in.
PW_AUTH=yes
if [[ "$HAVE_KEY" -eq 1 ]]; then
  if ask_yn "Disable password login entirely (key-only, most secure)? [y/N]" N; then
    PW_AUTH=no
  fi
else
  warn "no SSH key installed — keeping password login ON (key-only would lock you out)"
fi

SSHD_MAIN=/etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
# Make sure drop-ins are actually honored (first-match-wins: the Include must
# sit above any conflicting directive in the main file).
if [[ -f "$SSHD_MAIN" ]] && ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
  cp -a "$SSHD_MAIN" "${SSHD_MAIN}.km.bak"
  { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "${SSHD_MAIN}.km.bak"; } >"${SSHD_MAIN}.km.tmp" \
    && mv "${SSHD_MAIN}.km.tmp" "$SSHD_MAIN"
  ok "ensured sshd Include for drop-ins (backup: ${SSHD_MAIN}.km.bak)"
fi

cat >/etc/ssh/sshd_config.d/99-km.conf <<EOF
# KM SSH hardening — managed by newuser.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $PW_AUTH
KbdInteractiveAuthentication $PW_AUTH
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  if [[ "$PW_AUTH" == "no" ]]; then
    ok "sshd hardened: root login OFF, KEY-ONLY auth (reloaded — session preserved)"
  else
    ok "sshd hardened: root login OFF, password login kept ON (reloaded — session preserved)"
  fi
else
  warn "sshd config test failed — reverting SSH hardening (leaving SSH as it was)"
  rm -f /etc/ssh/sshd_config.d/99-km.conf
  [[ -f "${SSHD_MAIN}.km.bak" ]] && mv "${SSHD_MAIN}.km.bak" "$SSHD_MAIN"
fi

# --- 7f. Firewall: allow SSH in, deny the rest ----------------------------
FW_STATUS="none"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true   # allow SSH BEFORE enabling
  ufw default deny incoming  >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  if ufw --force enable >/dev/null 2>&1; then
    FW_STATUS="ufw (allow ${SSH_PORT}/tcp in, deny rest)"
    ok "firewall enabled: only SSH (port $SSH_PORT) allowed inbound"
  else
    warn "could not enable ufw"
  fi
elif command -v firewall-cmd >/dev/null 2>&1; then
  systemctl enable --now firewalld >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  FW_STATUS="firewalld (port ${SSH_PORT}/tcp)"
  ok "firewalld configured for SSH port $SSH_PORT"
else
  warn "no ufw/firewalld available — firewall step skipped"
fi

fi  # end hardening

# ===========================================================================
# 8. Summary
# ===========================================================================
echo
say "Done. New user '$USERNAME' is ready."
echo
echo "  User:      $USERNAME  (sudo via '$ADMIN_GROUP', uses the password you set)"
echo "  SSH key:   $([[ "$HAVE_KEY" -eq 1 ]] && echo "installed" || echo "none (password login)")"
if [[ "${KM_SKIP_HARDEN:-0}" != "1" ]]; then
  echo "  SSH:       root login OFF; password login ${PW_AUTH:-yes}; port ${SSH_PORT:-22}"
  echo "  Firewall:  ${FW_STATUS:-none}"
  echo "  Also:      fail2ban + automatic security updates + sysctl hardening"
fi
echo
echo "  ${c_ylw}Before you close this session, TEST the new login in a SECOND window:${c_rst}"
echo "     ssh $USERNAME@<server-ip>        # confirm you get in, then: sudo whoami -> root"
echo
echo "  Your current session was preserved (sshd was reloaded, not restarted)."
echo "  If anything goes wrong with SSH, your host's web/console terminal still"
echo "  logs in as root independently of SSH — you're not locked out."
echo
ok "You're set."
