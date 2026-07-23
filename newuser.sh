#!/usr/bin/env bash
#
# KM — new user bootstrap. The very first thing you run on a fresh box that
# only has root. It creates one non-root, sudo-capable user with a password,
# both read interactively from the terminal so you set them freely.
#
#   Run as root (paste in your provider's web terminal):
#     curl -fsSL https://raw.githubusercontent.com/Ari6six6/KM/claude/vps-setup-user-creation-4o06e2/newuser.sh | bash
#
# That's it. No VPN, no firewall, no docker — this only makes the user.
# Once you're logged in as that user, run the real KM setup.sh next.
#
# Notes:
#   * Prompts read from /dev/tty, so `curl ... | bash` still works interactively.
#   * The password is never echoed and never written to a file or the log.
#   * Safe to re-run: an existing user is updated (password reset + sudo), not
#     recreated.
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
  if command -v apt-get >/dev/null 2>&1; then
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
    warn "invalid name — use lowercase letters, digits, '-' or '_', starting with a letter (max 32)"
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
  # Make sure an existing account has a home and a real shell.
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
# 6. Summary
# ===========================================================================
echo
say "Done. New user '$USERNAME' is ready."
echo
echo "  Next:"
echo "    - Log in as the new user:   su - $USERNAME       (or SSH in as $USERNAME)"
echo "    - It has sudo:              sudo whoami   ->  root"
echo
echo "  If you SSH in and password login is refused, root can enable it once with:"
echo "    sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
echo "    systemctl reload ssh 2>/dev/null || systemctl reload sshd"
echo
ok "You're set."
