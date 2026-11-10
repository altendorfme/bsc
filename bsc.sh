#!/usr/bin/env bash
# BSC (Base Server Config) - https://github.com/altendorfme/bsc
set -Eeuo pipefail
umask 022

VERSION="1.0.0"
LOG=/var/log/bsc.log
TTY=/dev/tty
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
SSHD_DROPIN=/etc/ssh/sshd_config.d/00-bsc.conf
SOCKET_OVERRIDE=/etc/systemd/system/ssh.socket.d/00-bsc.conf
BASE_PACKAGES=(apt-transport-https ca-certificates curl gnupg2 software-properties-common htop ncdu nano sl)
CLOUD_USERS=(ubuntu debian admin ec2-user azureuser opc centos cloud-user)

# id|type|target|cloud|what stops working|level (ok, risky, never)
CLOUD_AGENTS=(
  "oracle-cloud-agent|pkg|oracle-cloud-agent|Oracle Cloud|Run Command, metrics, OS Management, Bastion plugin, Vulnerability Scan|ok"
  "unified-monitoring-agent|pkg|unified-monitoring-agent|Oracle Cloud|OCI unified Logging/Monitoring|ok"
  "amazon-ssm-agent|pkg|amazon-ssm-agent|AWS|Session Manager, SSM Run Command, Patch Manager|ok"
  "amazon-cloudwatch-agent|pkg|amazon-cloudwatch-agent|AWS|CloudWatch metrics and logs|ok"
  "ec2-instance-connect|pkg|ec2-instance-connect|AWS|EC2 Instance Connect (SSH from the console)|ok"
  "google-osconfig-agent|pkg|google-osconfig-agent|GCP|VM Manager / OS Config (patching and inventory)|ok"
  "google-guest-agent|pkg|google-guest-agent|GCP|SSH keys from metadata/OS Login, networking and hostname|risky"
  "walinuxagent|pkg|walinuxagent|Azure|VM provisioning, extensions and heartbeat|never"
  "droplet-agent|pkg|droplet-agent|DigitalOcean|Droplet Console (web access)|ok"
  "do-agent|pkg|do-agent|DigitalOcean|advanced dashboard metrics|ok"
  "aliyun-assist|custom|aliyun|Alibaba Cloud|Cloud Assistant (remote commands)|ok"
  "aegis|custom|aegis|Alibaba Cloud|Security Center (Aegis/AliYunDun), best-effort removal|ok"
  "tencent-qcloud|custom|qcloud|Tencent Cloud|YunJing, Stargate and Barad monitoring, best effort|ok"
  "landscape-client|pkg|landscape-client|Ubuntu|remote management through Landscape|ok"
)

ASSUME_YES=0
DO_UPGRADE="" DO_HARDEN="" DO_PORT="" DO_F2B="" DO_AUTOUPD="" DO_KERNEL=""
DO_RMUSER="" DO_AGENTS="" DO_DOCKER="" DO_DOCKER_GROUP="" DO_TS="" DO_TS_SSH=""
DO_DOCKHAND="" DO_HAWSER=""
OPT_USER="" OPT_PASSWORD_FILE="" OPT_RANDOM_PW=0 OPT_KEY="" OPT_SUDO=""
OPT_SWAP="" OPT_TZ="" OPT_SSH_PORT="" OPT_AUTO_REBOOT=""
OPT_AGENTS="" OPT_TS_KEYFILE="" OPT_DOCKHAND_BIND="" OPT_DOCKHAND_PORT="" OPT_DOCKHAND_NET=""
OPT_HAWSER_URL="" OPT_HAWSER_TOKENFILE="" OPT_HAWSER_CA=""

DISTRO="" CODENAME="" SESSION_USER="" CLIENT_IP="" PUBLIC_IP=""
TARGET_USER="" OLD_PORTS=() SSH_PORTS=() PORT_CHANGED=0 NEW_PORT=""
CHECK_OK=0 SSH_TOUCHED=0 TS_UP=0 TS_IP="" HARDENED=0
SUMMARY=()

if [[ -t 2 ]]; then C_B=$'\e[1m' C_G=$'\e[32m' C_Y=$'\e[33m' C_R=$'\e[31m' C_C=$'\e[36m' C_0=$'\e[0m'
else C_B="" C_G="" C_Y="" C_R="" C_C="" C_0=""; fi

info()  { printf '%s[•]%s %s\n' "$C_C" "$C_0" "$*" >&2; }
ok()    { printf '%s[✓]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn()  { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()   { printf '%s[✗]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
step()  { printf '\n%s━━━ %s ━━━%s\n' "$C_B" "$*" "$C_0" >&2; }
done_() { SUMMARY+=("OK   | $*"); }
skip_() { SUMMARY+=("--   | $*"); }
fail_() { SUMMARY+=("FAIL | $*"); }
on_err() { printf '%s[✗] Error on line %s: %s%s\n' "$C_R" "$1" "$2" "$C_0" >&2; }
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

to_tty() { if [[ -w $TTY ]] && { : >"$TTY"; } 2>/dev/null; then cat >"$TTY"; else cat >&2; fi; }

ask() {
  local __v=$1 prompt=$2 def=${3-} ans=""
  if [[ $ASSUME_YES == 1 ]]; then printf -v "$__v" '%s' "$def"; return 0; fi
  read -r -p "  ${prompt}${def:+ [$def]}: " ans <"$TTY" || true
  printf -v "$__v" '%s' "${ans:-$def}"
}

yn() {
  local prompt=$1 def=${2:-n} ans hint
  if [[ $ASSUME_YES == 1 ]]; then [[ $def == y ]]; return; fi
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -r -p "  ${prompt} [${hint}]: " ans <"$TTY" || ans=""
    ans=${ans:-$def}
    case ${ans,,} in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

decide() {
  local __v=$1
  [[ -n ${!__v} ]] && return 0
  if yn "$2" "$3"; then printf -v "$__v" 1; else printf -v "$__v" 0; fi
}

ask_secret() {
  local __v=$1 prompt=$2 confirm=${3:-1} a b
  while true; do
    read -r -s -p "  ${prompt}: " a <"$TTY" || a=""; echo >&2
    if [[ $confirm == 1 ]]; then
      read -r -s -p "  Confirm: " b <"$TTY" || b=""; echo >&2
      [[ $a == "$b" ]] || { warn "They do not match, try again."; continue; }
    fi
    break
  done
  printf -v "$__v" '%s' "$a"
}

choose() {
  local __v=$1 __title=$2 __def=$3; shift 3
  local __n=1 __ans __o
  if [[ $ASSUME_YES == 1 ]]; then printf -v "$__v" '%s' "$__def"; return 0; fi
  printf '  %s\n' "$__title" >&2
  for __o in "$@"; do printf '    %d) %s\n' "$__n" "$__o" >&2; __n=$((__n + 1)); done
  while true; do
    read -r -p "  Choice [${__def}]: " __ans <"$TTY" || __ans=""
    __ans=${__ans:-$__def}
    if [[ $__ans =~ ^[0-9]+$ ]] && ((__ans >= 1 && __ans <= $#)); then printf -v "$__v" '%s' "$__ans"; return 0; fi
    warn "Invalid option."
  done
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
snap_installed() { command -v snap >/dev/null 2>&1 && snap list "$1" >/dev/null 2>&1; }
apt_install() { apt-get install "${APT_OPTS[@]}" "$@"; }
user_home() { getent passwd "$1" | cut -d: -f6; }
has_netfilter_persistent() { pkg_installed netfilter-persistent && [[ -s /etc/iptables/rules.v4 ]]; }
docker_ok() { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; }

install_sudoers() { # content dest
  local tmp; tmp=$(mktemp)
  printf '%s\n' "$1" >"$tmp"
  if visudo -cf "$tmp" >/dev/null; then install -m 0440 -o root -g root "$tmp" "$2"; rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return 1
}

usage() {
  cat <<'EOF'
BSC (Base Server Config): Ubuntu/Debian server bootstrap

Without flags the script asks about everything. Flags pre-answer questions; with
--yes, anything not given uses the (safe) default without asking.

User and key
  --user NAME                 user to create (or use, if it already exists)
  --password-file FILE        password read from the first line of the file
  --random-password           generate a random password (shown once)
  --key copy:<user>|pubkey:<file>|generate
  --sudo-nopasswd | --sudo-password

System
  --[no-]upgrade              apt update/upgrade + base packages (default: yes)
  --timezone TZ               default: Etc/UTC
  --swap SIZE                 e.g. 2G, 512M, 0 = don't create

Security
  --[no-]ssh-harden           default: yes
  --ssh-port N                change the SSH port
  --[no-]fail2ban
  --[no-]auto-updates  --auto-reboot HH:MM
  --[no-]kernel-hardening     default: yes
  --[no-]journald             persistent logs with a size cap (default: yes)
  --[no-]remove-cloud-user
  --remove-cloud-agents LIST|all   (comma-separated ids; all skips risky items)

Apps
  --[no-]docker  --docker-group
  --[no-]tailscale  --tailscale-authkey-file FILE  --tailscale-ssh
  --[no-]dockhand  --dockhand-bind 127.0.0.1|tailscale|0.0.0.0  --dockhand-port N  --dockhand-network NAME
  --[no-]hawser  --hawser-url wss://...  --hawser-token-file FILE  --hawser-ca FILE

General
  --yes, -y                   never ask
  --help, -h
EOF
}

parse_args() {
  local flag
  while (($#)); do
    flag=$1
    case $flag in
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      --user) OPT_USER=${2:?}; shift ;;
      --password-file) OPT_PASSWORD_FILE=${2:?}; shift ;;
      --random-password) OPT_RANDOM_PW=1 ;;
      --key) OPT_KEY=${2:?}; shift ;;
      --sudo-nopasswd) OPT_SUDO=nopasswd ;;
      --sudo-password) OPT_SUDO=password ;;
      --timezone) OPT_TZ=${2:?}; shift ;;
      --swap) OPT_SWAP=${2:?}; shift ;;
      --ssh-port) OPT_SSH_PORT=${2:?}; DO_PORT=1; shift ;;
      --auto-reboot) OPT_AUTO_REBOOT=${2:?}; DO_AUTOUPD=1; shift ;;
      --remove-cloud-agents) OPT_AGENTS=${2:?}; DO_AGENTS=1; shift ;;
      --docker-group) DO_DOCKER_GROUP=1 ;;
      --tailscale-authkey-file) OPT_TS_KEYFILE=${2:?}; DO_TS=1; shift ;;
      --tailscale-ssh) DO_TS_SSH=1 ;;
      --dockhand-bind) OPT_DOCKHAND_BIND=${2:?}; DO_DOCKHAND=1; shift ;;
      --dockhand-port) OPT_DOCKHAND_PORT=${2:?}; DO_DOCKHAND=1; shift ;;
      --dockhand-network) OPT_DOCKHAND_NET=${2:?}; DO_DOCKHAND=1; shift ;;
      --hawser-url) OPT_HAWSER_URL=${2:?}; DO_HAWSER=1; shift ;;
      --hawser-token-file) OPT_HAWSER_TOKENFILE=${2:?}; DO_HAWSER=1; shift ;;
      --hawser-ca) OPT_HAWSER_CA=${2:?}; shift ;;
      --upgrade|--no-upgrade) DO_UPGRADE=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --ssh-harden|--no-ssh-harden) DO_HARDEN=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --fail2ban|--no-fail2ban) DO_F2B=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --auto-updates|--no-auto-updates) DO_AUTOUPD=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --kernel-hardening|--no-kernel-hardening) DO_KERNEL=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --remove-cloud-user|--no-remove-cloud-user) DO_RMUSER=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --no-remove-cloud-agents) DO_AGENTS=0 ;;
      --docker|--no-docker) DO_DOCKER=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --tailscale|--no-tailscale) DO_TS=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --dockhand|--no-dockhand) DO_DOCKHAND=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --hawser|--no-hawser) DO_HAWSER=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      --journald|--no-journald) DO_JOURNALD=$([[ $flag == --no-* ]] && echo 0 || echo 1) ;;
      *) die "Unknown flag: $flag (see --help)" ;;
    esac
    shift
  done
}

preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) DISTRO=ubuntu; CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}} ;;
    debian) DISTRO=debian; CODENAME=${VERSION_CODENAME:-} ;;
    *)
      if [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then DISTRO=ubuntu; CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
      elif [[ " ${ID_LIKE:-} " == *" debian "* ]]; then DISTRO=debian; CODENAME=${VERSION_CODENAME:-}
      else die "Unsupported distro: ${PRETTY_NAME:-unknown} (Ubuntu/Debian only)."; fi
      warn "${DISTRO} derivative detected (${PRETTY_NAME}); treating it as ${DISTRO}/${CODENAME}." ;;
  esac
  [[ -n $CODENAME ]] || die "Could not detect the distro codename."

  if [[ $ASSUME_YES == 0 ]] && ! { : <"$TTY"; } 2>/dev/null; then
    die "No interactive terminal. Run with 'ssh -t' or use --yes with flags."
  fi

  SESSION_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
  CLIENT_IP=$(detect_client_ip)
  [[ -f $SSHD_DROPIN ]] && ORIG_DROPIN=$(cat "$SSHD_DROPIN")
  mapfile -t OLD_PORTS < <(current_ssh_ports)
  ((${#OLD_PORTS[@]})) || OLD_PORTS=(22)
  SSH_PORTS=("${OLD_PORTS[@]}")
}

# sudo clears SSH_CLIENT, so walk the process tree (utmp/who is gone on newer distros).
detect_client_ip() {
  local pid=$$ ip=${SSH_CLIENT:-} ppid
  while [[ -z $ip && $pid -gt 1 ]]; do
    ip=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CLIENT=//p' | head -n1)
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo 1)
    pid=${ppid:-1}
  done
  echo "${ip%% *}"
}
ORIG_DROPIN=""

current_ssh_ports() {
  mkdir -p /run/sshd
  sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un
}

setup_logging() {
  touch "$LOG"; chmod 600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1
  printf '\n===== bsc %s — %s =====\n' "$VERSION" "$(date -Is)"
}

detect_public_ip() {
  [[ -n $PUBLIC_IP ]] && return 0
  PUBLIC_IP=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
  [[ $PUBLIC_IP =~ ^[0-9.]+$ ]] || PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
}

banner() {
  printf '%s\n' "${C_B}BSC ${VERSION}${C_0} — ${PRETTY_NAME:-$DISTRO $CODENAME}"
  info "Session: ${SESSION_USER}${CLIENT_IP:+ from $CLIENT_IP} | SSH on: ${OLD_PORTS[*]} | log: $LOG"
  warn "Keep THIS SSH session open until the end. The script asks you to test access from another window before cutting anything off."
  warn "Recommended: take a VM SNAPSHOT in your provider's console before continuing."
  if [[ $ASSUME_YES == 0 ]] && ! yn "Continue?" y; then exit 0; fi
}

step_system() {
  step "System"
  decide DO_UPGRADE "Run apt update/upgrade and install base packages?" y
  if [[ $DO_UPGRADE == 1 ]]; then
    apt-get update -q
    apt-get upgrade "${APT_OPTS[@]}"
    apt-get autoremove -y -q
    local p avail=()
    for p in "${BASE_PACKAGES[@]}"; do
      if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else warn "Package $p does not exist in this release, skipping."; fi
    done
    apt_install "${avail[@]}" openssl sudo
    done_ "System upgraded + base packages"
  else
    apt-get update -q || true
    skip_ "System upgrade"
  fi

  local tz cur
  cur=$(timedatectl show -p Timezone --value 2>/dev/null || echo "")
  while true; do
    tz=$OPT_TZ; [[ -n $tz ]] || ask tz "Timezone" "Etc/UTC"
    if timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then break; fi
    OPT_TZ=""; warn "Invalid timezone: $tz"
    [[ $ASSUME_YES == 1 ]] && { tz=Etc/UTC; break; }
  done
  [[ $tz == "$cur" ]] || timedatectl set-timezone "$tz"
  done_ "Timezone $tz"
}

size_to_mb() { local n=${1%[MmGg]} u=${1: -1}; [[ ${u^^} == G ]] && echo $((n * 1024)) || echo "$n"; }

step_swap() {
  step "Swap"
  local mem_mb sug size mb cur_mb fs avail_mb
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if ((mem_mb <= 2048)); then sug=2G; elif ((mem_mb <= 8192)); then sug="$(((mem_mb + 1023) / 1024))G"; else sug=4G; fi
  info "RAM: ${mem_mb}MB. Current swap:"; swapon --show 2>/dev/null | sed 's/^/      /' || true
  [[ -n $(swapon --noheadings 2>/dev/null) ]] || echo "      (none)"

  while true; do
    size=$OPT_SWAP; [[ -n $size ]] || ask size "Swap size for /swapfile (e.g. 2G, 512M; 0 = leave as is)" "$sug"
    [[ $size =~ ^(0|[1-9][0-9]*[MmGg])$ ]] && break
    OPT_SWAP=""; warn "Invalid format: $size"; [[ $ASSUME_YES == 1 ]] && size=0 && break
  done
  if [[ $size == 0 ]]; then skip_ "Swap"; return 0; fi
  mb=$(size_to_mb "$size")

  if [[ -f /swapfile ]]; then
    cur_mb=$(( $(stat -c %s /swapfile) / 1024 / 1024 ))
    if ((cur_mb == mb)) && swapon --show=NAME --noheadings | grep -qx /swapfile; then
      ok "/swapfile already exists with ${size}."
    else
      if ! yn "/swapfile already exists (${cur_mb}MB). Recreate it with ${size}?" y; then skip_ "Swap (kept ${cur_mb}MB)"; return 0; fi
      swapoff /swapfile 2>/dev/null || true
      rm -f /swapfile
    fi
  fi

  if [[ ! -f /swapfile ]]; then
    avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
    ((avail_mb > mb + 1024)) || { warn "Not enough free disk (${avail_mb}MB) for ${size} of swap."; fail_ "Swap (no space)"; return 0; }
    fs=$(findmnt -no FSTYPE -T / 2>/dev/null || echo "")
    if [[ $fs == btrfs ]] && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
      btrfs filesystem mkswapfile --size "${mb}m" /swapfile
    else
      fallocate -l "${mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
    fi
    chmod 600 /swapfile
    if ! swapon /swapfile 2>/dev/null; then
      warn "swapon failed (fallocate not supported here?), recreating with dd..."
      rm -f /swapfile
      dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
      chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
    fi
  fi
  grep -qE '^\s*/swapfile\s' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab

  local swp vfs
  ask swp "vm.swappiness" 10
  ask vfs "vm.vfs_cache_pressure" 50
  printf '# bsc.sh\nvm.swappiness=%s\nvm.vfs_cache_pressure=%s\n' "$swp" "$vfs" >/etc/sysctl.d/99-bsc-swap.conf
  sysctl -q -p /etc/sysctl.d/99-bsc-swap.conf
  done_ "Swap ${size} (swappiness=${swp}, vfs_cache_pressure=${vfs})"
}

list_key_users() {
  local u uid home shell
  while IFS=: read -r u _ uid _ _ home shell; do
    [[ $uid -eq 0 || ($uid -ge 1000 && $uid -lt 65534) ]] || continue
    [[ $shell =~ (nologin|false)$ ]] && continue
    [[ -s $home/.ssh/authorized_keys ]] && echo "$u"
  done </etc/passwd
}

describe_keys() { # file
  local fp
  while read -r fp; do printf '        %s\n' "$fp"; done < <(ssh-keygen -lf "$1" 2>/dev/null || echo "(could not read the keys)")
}

step_user() {
  step "User"
  local -a key_users others
  mapfile -t key_users < <(list_key_users)
  local u
  for u in "${key_users[@]}"; do [[ $u == root ]] || others+=("$u"); done

  if ((${#key_users[@]})); then
    info "Users with an SSH key (authorized_keys):"
    for u in "${key_users[@]}"; do
      printf '      %s%s%s\n' "$C_B" "$u" "$C_0" >&2
      describe_keys "$(user_home "$u")/.ssh/authorized_keys" >&2
    done
  else
    warn "No user has authorized_keys. You will need to paste or generate a key."
  fi

  local create=1
  if [[ -n $OPT_USER ]]; then
    id "$OPT_USER" >/dev/null 2>&1 && create=0
    TARGET_USER=$OPT_USER
  elif ((${#others[@]} == 0)); then
    info "Only root has access. A new user is required."
  else
    local c
    choose c "What do you want to do?" 1 "Create a new user (recommended)" "Use an existing user: ${others[*]}"
    if [[ $c == 2 ]]; then
      create=0
      if ((${#others[@]} == 1)); then TARGET_USER=${others[0]}
      else local i; choose i "Which user?" 1 "${others[@]}"; TARGET_USER=${others[$((i - 1))]}; fi
    fi
  fi

  if [[ $create == 1 ]]; then
    create_user
  else
    ok "Using the existing user: $TARGET_USER"
    done_ "Existing user $TARGET_USER"
  fi
  setup_key "${key_users[@]}"
}

create_user() {
  local name="$TARGET_USER"
  while true; do
    [[ -n $name ]] || ask name "New user name" ""
    if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then warn "Invalid name (lowercase letters, digits, _ and -)."
    elif id "$name" >/dev/null 2>&1; then warn "User $name already exists."
    else break; fi
    [[ $ASSUME_YES == 1 ]] && die "Provide a valid --user."
    name=""
  done
  TARGET_USER=$name

  local sudo_mode=$OPT_SUDO c
  if [[ -z $sudo_mode ]]; then
    choose c "Sudo for $name:" 1 "No password (NOPASSWD), handy for automation" "Ask for the password, safer"
    [[ $c == 1 ]] && sudo_mode=nopasswd || sudo_mode=password
  fi

  local pw="" pwmode
  if [[ -n $OPT_PASSWORD_FILE ]]; then
    pw=$(head -n1 "$OPT_PASSWORD_FILE"); pwmode="file"
  elif [[ $OPT_RANDOM_PW == 1 ]]; then pwmode=random
  elif [[ $ASSUME_YES == 1 ]]; then
    [[ $sudo_mode == password ]] && pwmode=random || pwmode=none
  else
    local opts=("Type a password" "Generate a random password")
    [[ $sudo_mode == nopasswd ]] && opts+=("No password (key-only login)")
    choose c "User password:" 2 "${opts[@]}"
    case $c in 1) pwmode=typed ;; 2) pwmode=random ;; 3) pwmode=none ;; esac
    if [[ $pwmode == typed ]]; then
      while true; do
        ask_secret pw "Password for $name" 1
        [[ -n $pw ]] && break
        warn "The password cannot be empty."
      done
    fi
  fi
  [[ $pwmode == random ]] && pw=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)

  useradd -m -s /bin/bash -G sudo "$name"
  if [[ -n $pw ]]; then
    printf '%s:%s\n' "$name" "$pw" | chpasswd
  else
    usermod -p '*' "$name"   # no password, but the account is not locked (key login works)
  fi
  if [[ $pwmode == random ]]; then
    printf '\n  %s>>> Generated password for %s: %s%s\n  (write it down now, it is not logged)\n\n' "$C_Y" "$name" "$pw" "$C_0" | to_tty
  fi
  unset pw

  local rule
  if [[ $sudo_mode == nopasswd ]]; then rule="$name ALL=(ALL) NOPASSWD:ALL"; else rule="$name ALL=(ALL:ALL) ALL"; fi
  install_sudoers "# bsc.sh"$'\n'"$rule" "/etc/sudoers.d/$name" || die "visudo rejected the sudo rule."
  ok "User $name created (sudo group, ${sudo_mode})."
  done_ "User $name created (sudo: $sudo_mode, password: $pwmode)"
}

append_keys() { # user source_file
  local u=$1 src=$2 home dst tmp
  home=$(user_home "$u"); dst=$home/.ssh/authorized_keys
  install -d -m 700 -o "$u" -g "$(id -gn "$u")" "$home/.ssh"
  tmp=$(mktemp)
  { [[ -f $dst ]] && cat "$dst"; cat "$src"; } | grep -vE '^\s*$' | awk '!seen[$0]++' >"$tmp"
  install -m 600 -o "$u" -g "$(id -gn "$u")" "$tmp" "$dst"
  rm -f "$tmp"
}

setup_key() {
  step "SSH key for $TARGET_USER"
  local -a key_users=("$@") sources=()
  local u home
  home=$(user_home "$TARGET_USER")
  for u in "${key_users[@]}"; do [[ $u == "$TARGET_USER" ]] || sources+=("$u"); done

  if [[ -s $home/.ssh/authorized_keys ]]; then
    info "$TARGET_USER already has key(s):"; describe_keys "$home/.ssh/authorized_keys" >&2
    if [[ -z $OPT_KEY ]] && ! yn "Add another key?" n; then done_ "Key for $TARGET_USER kept"; return 0; fi
  fi

  local mode="" from="" c
  case $OPT_KEY in
    copy:*) mode=copy; from=${OPT_KEY#copy:} ;;
    pubkey:*) mode=pubkey; from=${OPT_KEY#pubkey:} ;;
    generate) mode=generate ;;
    "")
      if [[ $ASSUME_YES == 1 ]]; then
        if [[ " ${sources[*]} " == *" $SESSION_USER "* ]]; then mode=copy; from=$SESSION_USER
        elif ((${#sources[@]})); then mode=copy; from=${sources[0]}
        else die "No key to copy. Use --key pubkey:<file> or --key generate."; fi
      else
        local opts=() map=()
        if ((${#sources[@]})); then opts+=("Copy authorized_keys from another user (${sources[*]})"); map+=(copy); fi
        opts+=("Paste a public key"); map+=(pubkey)
        opts+=("Generate a new ed25519 key pair here"); map+=(generate)
        choose c "How will $TARGET_USER get a key?" 1 "${opts[@]}"
        mode=${map[$((c - 1))]}
      fi ;;
    *) die "Invalid --key: $OPT_KEY" ;;
  esac

  case $mode in
    copy)
      if [[ -z $from ]]; then
        if ((${#sources[@]} == 1)); then from=${sources[0]}
        else
          local def=1 i=1
          for u in "${sources[@]}"; do [[ $u == "$SESSION_USER" ]] && def=$i; i=$((i + 1)); done
          choose c "Copy from which user?" "$def" "${sources[@]}"; from=${sources[$((c - 1))]}
        fi
      fi
      local src; src=$(user_home "$from")/.ssh/authorized_keys
      [[ -s $src ]] || die "$from has no authorized_keys."
      append_keys "$TARGET_USER" "$src"
      ok "Keys from $from copied to $TARGET_USER (authorized_keys only)."
      done_ "Key copied from $from" ;;
    pubkey)
      local tmp; tmp=$(mktemp)
      if [[ -n $from ]]; then cat "$from" >"$tmp"
      else
        info "Paste the public key(s) (ssh-ed25519/ssh-rsa/ecdsa...). An empty line ends input:"
        local line
        while IFS= read -r line <"$TTY"; do [[ -z $line ]] && break; printf '%s\n' "$line" >>"$tmp"; done
      fi
      if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; die "Invalid public key."; fi
      describe_keys "$tmp" >&2
      append_keys "$TARGET_USER" "$tmp"; rm -f "$tmp"
      done_ "Public key added to $TARGET_USER" ;;
    generate)
      local dir pass="" host; dir=$(mktemp -d); host=$(hostname -s)
      if [[ $ASSUME_YES == 0 ]] && yn "Protect the private key with a passphrase?" y; then ask_secret pass "Passphrase" 1; fi
      ssh-keygen -q -t ed25519 -a 100 -C "${TARGET_USER}@${host}" -N "$pass" -f "$dir/key"
      unset pass
      append_keys "$TARGET_USER" "$dir/key.pub"
      {
        printf '\n%s===== PRIVATE KEY for %s@%s: copy EVERYTHING between the lines =====%s\n' "$C_Y" "$TARGET_USER" "$host" "$C_0"
        cat "$dir/key"
        printf '%s===== END =====%s\n' "$C_Y" "$C_0"
        printf 'Save it on your computer as ~/.ssh/%s_ed25519 and run: chmod 600 ~/.ssh/%s_ed25519\n' "$host" "$host"
        printf 'Public: %s\n\n' "$(cat "$dir/key.pub")"
      } | to_tty
      if [[ $ASSUME_YES == 0 ]]; then
        local _; read -r -p "  Press ENTER after saving the private key (it will be deleted from the server)..." _ <"$TTY" || true
      else
        warn "--yes mode: the private key was shown only on the terminal. Save it now."
      fi
      shred -u "$dir/key" 2>/dev/null || rm -f "$dir/key"
      rm -rf "$dir"
      done_ "ed25519 pair generated for $TARGET_USER (private key deleted from the server)" ;;
  esac
}

ensure_include() {
  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-bsc
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
}

# sshd Port is cumulative: comment out Port in other files when changing it.
comment_other_ports() {
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$SSHD_DROPIN" ]] || continue
    if grep -qE '^\s*Port\s+' "$f"; then
      [[ -f $f.bak-bsc ]] || cp -a "$f" "$f.bak-bsc"
      sed -i -E 's/^(\s*Port\s+)/# bsc: \1/' "$f"
    fi
  done
}

write_sshd_dropin() {
  local p allow=${ALLOW_USERS:-}
  {
    echo "# Generated by bsc.sh, $(date -Is)"
    if [[ $PORT_CHANGED == 1 ]]; then for p in "${SSH_PORTS[@]}"; do echo "Port $p"; done; fi
    if [[ $HARDENED == 1 ]]; then
      cat <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
PrintMotd no
UseDNS no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
      echo "AllowTcpForwarding ${SSH_TCP_FWD:-local}"
      [[ -n $allow ]] && echo "AllowUsers $allow"
    elif [[ -n $ORIG_DROPIN ]]; then
      grep -vE '^\s*(#|Port\s|$)' <<<"$ORIG_DROPIN" || true
    fi
  } >"$SSHD_DROPIN.new"
}

restart_ssh() {
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    if [[ $PORT_CHANGED == 1 && ! -x /usr/lib/systemd/system-generators/sshd-socket-generator ]]; then
      mkdir -p "$(dirname "$SOCKET_OVERRIDE")"
      { echo "[Socket]"; echo "ListenStream="; for p in "${SSH_PORTS[@]}"; do echo "ListenStream=$p"; done; } >"$SOCKET_OVERRIDE"
    fi
    systemctl daemon-reload
    systemctl stop ssh.service 2>/dev/null || true   # KillMode=process: open sessions stay up
    systemctl restart ssh.socket
    systemctl start ssh.service 2>/dev/null || true
  else
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
  fi
}

apply_sshd() {
  ensure_include
  mkdir -p /run/sshd
  [[ $PORT_CHANGED == 1 ]] && comment_other_ports
  write_sshd_dropin
  [[ -f $SSHD_DROPIN ]] && cp -a "$SSHD_DROPIN" "$SSHD_DROPIN.prev"
  mv "$SSHD_DROPIN.new" "$SSHD_DROPIN"; chmod 644 "$SSHD_DROPIN"
  if ! sshd -t; then
    warn "sshd -t rejected the config; reverting."
    if [[ -f $SSHD_DROPIN.prev ]]; then mv "$SSHD_DROPIN.prev" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    return 1
  fi
  rm -f "$SSHD_DROPIN.prev"
  restart_ssh
  SSH_TOUCHED=1
}

port_listening() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

iptables_persistent_allow() {
  local p=$1
  has_netfilter_persistent || return 0
  command -v iptables >/dev/null || return 0
  if ! iptables -C INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
    if command -v ip6tables >/dev/null && [[ -s /etc/iptables/rules.v6 ]]; then
      ip6tables -C INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null ||
        ip6tables -I INPUT 1 -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
    fi
    netfilter-persistent save >/dev/null 2>&1 || true
    info "Port $p/tcp opened in persistent iptables (cloud rules)."
  fi
}
iptables_persistent_remove() {
  local p=$1
  has_netfilter_persistent || return 0
  while iptables -D INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do :; done
  while ip6tables -D INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null; do :; done
  netfilter-persistent save >/dev/null 2>&1 || true
}

step_ssh_port() {
  step "SSH port"
  decide DO_PORT "Change the SSH port (current: ${OLD_PORTS[*]})?" n
  [[ $DO_PORT == 1 ]] || { skip_ "SSH port change"; return 0; }
  local p=$OPT_SSH_PORT
  while true; do
    [[ -n $p ]] || ask p "New port (1024-65535)" 2222
    if [[ ! $p =~ ^[0-9]+$ ]] || ((p < 1024 || p > 65535)); then warn "Invalid port."
    elif [[ " ${OLD_PORTS[*]} " == *" $p "* ]]; then warn "That is already the current port."
    elif port_listening "$p"; then warn "Port $p is already in use."
    else break; fi
    [[ $ASSUME_YES == 1 ]] && { warn "Keeping the current port."; DO_PORT=0; skip_ "SSH port change"; return 0; }
    p=""
  done
  NEW_PORT=$p
  warn "OPEN port $NEW_PORT/tcp in the provider firewall (Security List/Group, NSG...) BEFORE the test."
  PORT_CHANGED=1
  SSH_PORTS=("${OLD_PORTS[@]}" "$NEW_PORT")
  iptables_persistent_allow "$NEW_PORT"
  if apply_sshd && port_listening "$NEW_PORT"; then
    ok "SSH listening on ${SSH_PORTS[*]} (the old port goes away after the test)."
  else
    warn "Could not enable port $NEW_PORT; keeping ${OLD_PORTS[*]}."
    PORT_CHANGED=0; SSH_PORTS=("${OLD_PORTS[@]}"); NEW_PORT=""; DO_PORT=0
    rm -f "$SOCKET_OVERRIDE"; restore_port_backups; restore_orig_dropin; restart_ssh || true
    fail_ "SSH port change"
  fi
}

SSH_TCP_FWD=local

step_checkpoint() {
  step "Access test (anti-lockout)"
  local home; home=$(user_home "$TARGET_USER")
  if [[ ! -s $home/.ssh/authorized_keys ]]; then
    warn "$TARGET_USER has no key. Hardening and user/agent removal will be SKIPPED."
    CHECK_OK=0; return 0
  fi
  local test_port=${NEW_PORT:-${OLD_PORTS[0]}}
  detect_public_ip
  if [[ $ASSUME_YES == 1 ]]; then
    if ssh-keyscan -p "$test_port" -T 5 127.0.0.1 >/dev/null 2>&1; then CHECK_OK=1; ok "sshd answers on port $test_port and $TARGET_USER has a key."
    else CHECK_OK=0; warn "sshd did not answer on port $test_port."; fi
  else
    printf '\n  Open ANOTHER terminal (do not close this one) and run:\n\n      %sssh -p %s %s@%s%s\n      sudo whoami     # should print root\n\n' \
      "$C_B" "$test_port" "$TARGET_USER" "${PUBLIC_IP:-<server-ip>}" "$C_0" >&2
    if yn "Did you log in and did sudo work?" n; then CHECK_OK=1; else CHECK_OK=0; fi
  fi

  if [[ $CHECK_OK == 1 ]]; then
    done_ "Access tested: $TARGET_USER on port $test_port"
  else
    warn "Access not confirmed. Hardening, port change and removals will be skipped."
    if [[ $PORT_CHANGED == 1 ]]; then
      warn "Reverting the new port $NEW_PORT."; fail_ "SSH port change reverted (no access test)"
      iptables_persistent_remove "$NEW_PORT"
      PORT_CHANGED=0; SSH_PORTS=("${OLD_PORTS[@]}"); NEW_PORT=""
      rm -f "$SOCKET_OVERRIDE"
      restore_port_backups
      restore_orig_dropin
      restart_ssh || true
    fi
    fail_ "Access test not confirmed"
  fi
}

restore_orig_dropin() {
  if [[ -n $ORIG_DROPIN ]]; then printf '%s\n' "$ORIG_DROPIN" >"$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
}

restore_port_backups() {
  local b
  for b in /etc/ssh/sshd_config.bak-bsc /etc/ssh/sshd_config.d/*.bak-bsc; do
    [[ -f $b ]] && mv -f "$b" "${b%.bak-bsc}"
  done
  return 0
}

step_ssh_finalize() {
  step "SSH hardening"
  if [[ $CHECK_OK != 1 ]]; then skip_ "SSH hardening (no access test)"; return 0; fi
  decide DO_HARDEN "Apply hardening (no root, no passwords, keys only, MaxAuthTries 3...)?" y
  ALLOW_USERS=""
  if [[ $DO_HARDEN == 1 ]]; then
    HARDENED=1
    if [[ $ASSUME_YES == 0 ]] && yn "Restrict SSH with AllowUsers (only listed users can log in)?" y; then
      ask ALLOW_USERS "Allowed users (space-separated)" "$TARGET_USER"
    fi
    local c
    choose c "TCP forwarding (ssh -L/-R tunnels):" 1 \
      "Local only (-L): allows tunnels to dashboards like Dockhand; blocks -R (recommended)" \
      "Disable completely" "Allow everything (OpenSSH default)"
    case $c in 1) SSH_TCP_FWD=local ;; 2) SSH_TCP_FWD=no ;; 3) SSH_TCP_FWD=yes ;; esac
  fi
  if [[ $PORT_CHANGED == 1 ]]; then
    SSH_PORTS=("$NEW_PORT")
    local p
    for p in "${OLD_PORTS[@]}"; do
      [[ $p == 22 ]] || iptables_persistent_remove "$p"
    done
  fi
  [[ $HARDENED == 1 || $PORT_CHANGED == 1 ]] || { skip_ "SSH hardening"; return 0; }
  if apply_sshd; then
    [[ $HARDENED == 1 ]] && done_ "SSH hardening${ALLOW_USERS:+ (AllowUsers $ALLOW_USERS)}"
    [[ $PORT_CHANGED == 1 ]] && done_ "SSH now only on port $NEW_PORT"
    sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|maxauthtries|allowusers) ' | sed 's/^/      /'
  else
    fail_ "SSH hardening (sshd -t failed)"
  fi
}

step_fail2ban() {
  step "Fail2ban"
  decide DO_F2B "Install fail2ban (bans IPs with many failed SSH logins)?" n
  [[ $DO_F2B == 1 ]] || { skip_ "Fail2ban"; return 0; }
  local bantime maxretry ignore="127.0.0.1/8 ::1" extra action
  ask bantime "Ban time" 1h
  ask maxretry "Attempts before a ban" 5
  if [[ -n $CLIENT_IP ]] && yn "Never ban your current IP ($CLIENT_IP)?" y; then ignore+=" $CLIENT_IP"; fi
  ask extra "Other IPs/networks to ignore (space-separated; empty = none)" ""
  [[ -n $extra ]] && ignore+=" $extra"
  apt_install fail2ban python3-systemd
  if command -v nft >/dev/null && ! command -v iptables >/dev/null; then action=nftables-multiport
  else action=iptables-multiport; fi
  local ports; ports=$(IFS=,; echo "${SSH_PORTS[*]}")
  cat >/etc/fail2ban/jail.d/sshd.local <<EOF
# Generated by bsc.sh
[DEFAULT]
ignoreip = ${ignore}
banaction = ${action}

[sshd]
enabled  = true
port     = ${ports}
backend  = systemd
bantime  = ${bantime}
findtime = 10m
maxretry = ${maxretry}
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 2
  if fail2ban-client status sshd >/dev/null 2>&1; then done_ "Fail2ban (sshd, port ${ports}, ${maxretry}x → ${bantime})"
  else warn "fail2ban did not start the sshd jail; see: journalctl -u fail2ban"; fail_ "Fail2ban"; fi
}

step_auto_updates() {
  step "Automatic updates"
  decide DO_AUTOUPD "Enable unattended-upgrades (security patches only)?" y
  [[ $DO_AUTOUPD == 1 ]] || { skip_ "Automatic updates"; return 0; }
  apt_install unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  local reboot=$OPT_AUTO_REBOOT
  if [[ -z $reboot ]] && yn "Reboot automatically when an update requires it?" n; then
    while true; do ask reboot "Reboot time (HH:MM)" "04:00"; [[ $reboot =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break; warn "Invalid time."; done
  fi
  {
    echo "// Generated by bsc.sh"
    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
    if [[ -n $reboot ]]; then
      echo 'Unattended-Upgrade::Automatic-Reboot "true";'
      echo "Unattended-Upgrade::Automatic-Reboot-Time \"$reboot\";"
    else
      echo 'Unattended-Upgrade::Automatic-Reboot "false";'
    fi
  } >/etc/apt/apt.conf.d/52bsc-unattended
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  info "Validating with unattended-upgrade --dry-run..."
  if timeout 300 unattended-upgrade --dry-run >/dev/null 2>&1; then ok "Dry-run OK."
  else warn "unattended-upgrade dry run failed; see /var/log/unattended-upgrades/."; fi
  done_ "Automatic updates${reboot:+ (reboot at $reboot)}"
}

step_docker() {
  step "Docker"
  if docker_ok; then
    info "Docker already installed: $(docker --version)"
    DO_DOCKER=1
  else
    decide DO_DOCKER "Install Docker (official repository)?" n
    [[ $DO_DOCKER == 1 ]] || { skip_ "Docker"; return 0; }
    local p
    for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
      pkg_installed "$p" && apt-get remove -y -q "$p" || true
    done
    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSI "https://download.docker.com/linux/${DISTRO}/dists/${CODENAME}/Release" >/dev/null 2>&1; then
      curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
        >/etc/apt/sources.list.d/docker.list
      apt-get update -q
      apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      warn "The official Docker repository has no ${DISTRO}/${CODENAME} yet; using distro packages."
      local compose=docker-compose-v2
      apt-cache show docker-compose-v2 >/dev/null 2>&1 || compose=docker-compose
      apt_install docker.io "$compose"
    fi
  fi

  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    systemctl restart docker
  else
    info "/etc/docker/daemon.json already exists; log rotation left unchanged."
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true

  if [[ $TARGET_USER != root ]] && ! id -nG "$TARGET_USER" | grep -qw docker; then
    warn "Being in the docker group is equivalent to root."
    decide DO_DOCKER_GROUP "Add $TARGET_USER to the docker group?" y
    [[ $DO_DOCKER_GROUP == 1 ]] && usermod -aG docker "$TARGET_USER"
  fi
  done_ "Docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
}

step_tailscale() {
  step "Tailscale"
  decide DO_TS "Install Tailscale?" n
  [[ $DO_TS == 1 ]] || { skip_ "Tailscale"; return 0; }
  if ! command -v tailscale >/dev/null; then
    if curl -fsSI "https://pkgs.tailscale.com/stable/${DISTRO}/${CODENAME}.noarmor.gpg" >/dev/null 2>&1; then
      curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO}/${CODENAME}.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
      curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO}/${CODENAME}.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
      apt-get update -q
      apt_install tailscale
    else
      warn "No Tailscale repository for ${DISTRO}/${CODENAME}; using the official installer (tailscale.com/install.sh)."
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true

  local key="" kf hn args=()
  if [[ -n $OPT_TS_KEYFILE ]]; then key=$(head -n1 "$OPT_TS_KEYFILE")
  elif [[ $ASSUME_YES == 0 ]]; then
    info "Create an auth key at https://login.tailscale.com/admin/settings/keys (empty = connect later)."
    ask_secret key "Tailscale auth key (tskey-...)" 0
  fi
  if [[ -z $key ]]; then
    warn "No auth key. To connect later: sudo tailscale up"
    done_ "Tailscale installed (not connected)"; return 0
  fi
  ask hn "Tailnet hostname" "$(hostname -s)"
  decide DO_TS_SSH "Enable Tailscale SSH (--ssh)?" n
  kf=$(mktemp); chmod 600 "$kf"; printf '%s\n' "$key" >"$kf"; unset key
  args=(--auth-key="file:$kf" --hostname="$hn")
  [[ $DO_TS_SSH == 1 ]] && args+=(--ssh)
  if timeout 90 tailscale up "${args[@]}"; then
    TS_UP=1; TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
    ok "Tailscale connected: $TS_IP"
    done_ "Tailscale connected ($hn, $TS_IP)"
  else
    warn "tailscale up failed (invalid/expired key?)."
    fail_ "Tailscale up"
  fi
  shred -u "$kf" 2>/dev/null || rm -f "$kf"
}

step_dockhand() {
  docker_ok || return 0
  step "Dockhand"
  decide DO_DOCKHAND "Install Dockhand (web dashboard for Docker)?" n
  [[ $DO_DOCKHAND == 1 ]] || { skip_ "Dockhand"; return 0; }
  local tag port bind c
  ask tag "fnsys/dockhand image tag" latest
  port=$OPT_DOCKHAND_PORT; [[ -n $port ]] || ask port "Dockhand port" 3000
  bind=$OPT_DOCKHAND_BIND
  if [[ -z $bind ]]; then
    local opts=("Localhost only (127.0.0.1), access through an SSH tunnel (recommended)")
    [[ $TS_UP == 1 ]] && opts+=("Tailscale: localhost + 'tailscale serve' on tailnet port $port")
    opts+=("Public (0.0.0.0): restrict access in the cloud firewall")
    choose c "Where should Dockhand be exposed?" 1 "${opts[@]}"
    case "${opts[$((c - 1))]}" in
      Localhost*) bind=127.0.0.1 ;; Tailscale*) bind=tailscale ;; *) bind=0.0.0.0 ;;
    esac
  fi
  local host_ip=127.0.0.1
  [[ $bind == 0.0.0.0 ]] && host_ip=0.0.0.0

  local net=$OPT_DOCKHAND_NET nets net_yaml=""
  if [[ -z $net && $ASSUME_YES == 0 ]]; then
    nets=$(docker network ls --filter driver=bridge --format '{{.Name}}' | grep -vx bridge | grep -v '_default$' | tr '\n' ' ')
    info "To publish Dockhand through a reverse proxy container, join the proxy's Docker network."
    [[ -n $nets ]] && info "Existing networks: $nets"
    ask net "Docker network shared with the reverse proxy (empty = none)" ""
  fi
  if [[ -n $net ]]; then
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      docker network create "$net" >/dev/null
      info "Network $net created. Attach the proxy to it as an external network."
    fi
    net_yaml=$(printf '    networks:\n      - default\n      - %s\nnetworks:\n  %s:\n    external: true' "$net" "$net")
  fi

  install -d -m 755 /opt/dockhand /opt/dockhand/data
  cat >/opt/dockhand/docker-compose.yml <<EOF
# Generated by bsc.sh, persistent data in /opt/dockhand/data
services:
  dockhand:
    image: fnsys/dockhand:${tag}
    container_name: dockhand
    restart: unless-stopped
    ports:
      - "${host_ip}:${port}:3000"
    environment:
      HOST_DATA_DIR: /opt/dockhand/data
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/dockhand/data:/app/data
${net_yaml}
EOF
  docker compose -f /opt/dockhand/docker-compose.yml up -d --quiet-pull
  sleep 3
  if [[ $(docker inspect -f '{{.State.Running}}' dockhand 2>/dev/null) == true ]]; then
    case $bind in
      127.0.0.1) info "Access with: ssh -L ${port}:127.0.0.1:${port} -p ${SSH_PORTS[0]} ${TARGET_USER}@${PUBLIC_IP:-<ip>} and open http://localhost:${port}" ;;
      tailscale)
        if tailscale serve --bg --tcp "$port" "tcp://127.0.0.1:${port}" >/dev/null 2>&1; then
          info "Access through the tailnet: http://${TS_IP}:${port}"
        else warn "tailscale serve failed; Dockhand is only on 127.0.0.1:${port}."; fi ;;
      0.0.0.0) warn "Dockhand is public at http://${PUBLIC_IP:-<ip>}:${port}. Create the admin user NOW and restrict access in the cloud firewall." ;;
    esac
    if [[ -n $net ]]; then
      info "Reverse proxy target: http://dockhand:3000 (network $net)."
      warn "Enable authentication in Dockhand (Settings > Authentication) before publishing it through the proxy."
    fi
    done_ "Dockhand ${tag} on ${bind}:${port}${net:+ + network $net} (data in /opt/dockhand/data)"
  else
    docker logs --tail 30 dockhand 2>&1 | sed 's/^/      /' || true
    fail_ "Dockhand is not running"
  fi
}

step_hawser() {
  docker_ok || return 0
  step "Hawser (Dockhand Edge agent)"
  decide DO_HAWSER "Install Hawser in Edge mode (connects this Docker to a remote Dockhand)?" n
  [[ $DO_HAWSER == 1 ]] || { skip_ "Hawser"; return 0; }
  if [[ $(docker inspect -f '{{.State.Running}}' dockhand 2>/dev/null) == true ]]; then
    info "This server's Dockhand already manages local Docker through the socket; Hawser is for connecting to ANOTHER Dockhand."
  fi
  local url=$OPT_HAWSER_URL token="" name ca=$OPT_HAWSER_CA id
  while true; do
    [[ -n $url ]] || ask url "Dockhand URL (wss://dockhand.example.com/api/hawser/connect)" ""
    [[ $url =~ ^wss?://[^/]+ ]] && break
    warn "The URL must start with wss:// or ws://"
    [[ $ASSUME_YES == 1 ]] && { fail_ "Hawser (invalid URL)"; return 0; }
    url=""
  done
  if [[ -n $OPT_HAWSER_TOKENFILE ]]; then token=$(head -n1 "$OPT_HAWSER_TOKENFILE")
  elif [[ $ASSUME_YES == 0 ]]; then
    info "Create the token in Dockhand under Settings → Environments → add a Hawser (Edge) environment. It is shown only once."
    while true; do ask_secret token "Hawser token" 0; ((${#token} >= 24)) && break; warn "The token must be at least 24 characters long."; done
  fi
  [[ ${#token} -ge 24 ]] || { warn "Token missing or too short."; fail_ "Hawser (no token)"; return 0; }
  ask name "Agent name (AGENT_NAME)" "$(hostname -s)"
  if [[ -z $ca && $url == wss://* && $ASSUME_YES == 0 ]] && yn "Does Dockhand use a self-signed certificate or a private CA?" n; then
    ask ca "Path to the CA file (PEM) on this server" ""
  fi

  install -d -m 755 /opt/hawser /opt/hawser/stacks
  install -d -m 700 /opt/hawser/certs
  umask 077; printf '%s\n' "$token" >/opt/hawser/token; umask 022; unset token
  chmod 600 /opt/hawser/token
  id=$(sed -n 's/^AGENT_ID=//p' /opt/hawser/hawser.env 2>/dev/null || true)
  [[ -n $id ]] || id=$(cat /proc/sys/kernel/random/uuid)
  {
    echo "# Generated by bsc.sh"
    echo "DOCKHAND_SERVER_URL=$url"
    echo "TOKEN_FILE=/run/secrets/hawser_token"
    echo "AGENT_NAME=$name"
    echo "AGENT_ID=$id"
    echo "STACKS_DIR=/opt/hawser/stacks"
  } >/opt/hawser/hawser.env
  local ca_mount=""
  if [[ -n $ca ]]; then
    if [[ -f $ca ]]; then
      install -m 644 "$ca" /opt/hawser/certs/ca.crt
      echo "CA_CERT=/certs/ca.crt" >>/opt/hawser/hawser.env
      ca_mount="      - /opt/hawser/certs/ca.crt:/certs/ca.crt:ro"
    else warn "CA $ca not found; continuing without it."; fi
  fi
  chmod 600 /opt/hawser/hawser.env
  cat >/opt/hawser/docker-compose.yml <<EOF
# Generated by bsc.sh, persistent data in /opt/hawser
services:
  hawser:
    image: ghcr.io/finsys/hawser:latest
    container_name: hawser
    restart: unless-stopped
    env_file: hawser.env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/hawser/stacks:/opt/hawser/stacks
      - /opt/hawser/token:/run/secrets/hawser_token:ro
${ca_mount}
EOF
  sed -i '/^$/d' /opt/hawser/docker-compose.yml
  docker compose -f /opt/hawser/docker-compose.yml up -d --quiet-pull
  info "Waiting for Hawser to connect to Dockhand (up to 60s)..."
  local i health=""
  for i in $(seq 1 12); do
    health=$(docker exec hawser wget -qO- http://localhost:2376/_hawser/health 2>/dev/null || true)
    [[ $health == *'"connected":true'* ]] && break
    sleep 5
  done
  docker logs --tail 6 hawser 2>&1 | sed 's/^/      /' || true
  if [[ $health == *'"connected":true'* ]]; then done_ "Hawser Edge connected → $url (agent $name)"
  else
    warn "Hawser is running but did NOT connect (${health:-no response}). Check the URL/token: docker logs -f hawser"
    fail_ "Hawser running, but not connected to Dockhand"
  fi
}

step_journald() {
  step "System logs (journald)"
  decide DO_JOURNALD "Make logs persistent with a disk cap?" y
  [[ $DO_JOURNALD == 1 ]] || { skip_ "journald"; return 0; }
  local max
  ask max "Maximum log size" 500M
  mkdir -p /var/log/journal /etc/systemd/journald.conf.d
  systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
  cat >/etc/systemd/journald.conf.d/00-bsc.conf <<EOF
# Generated by bsc.sh
[Journal]
Storage=persistent
SystemMaxUse=${max}
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=3month
EOF
  systemctl restart systemd-journald
  done_ "Persistent journald (max ${max})"
}
DO_JOURNALD=""

step_kernel() {
  step "Kernel hardening (sysctl)"
  decide DO_KERNEL "Apply network/kernel hardening through sysctl?" y
  [[ $DO_KERNEL == 1 ]] || { skip_ "Kernel hardening"; return 0; }
  local rp=1
  # Docker/Tailscale work better with "loose" rp_filter.
  if docker_ok || command -v tailscale >/dev/null; then rp=2; fi
  cat >/etc/sysctl.d/99-bsc-hardening.conf <<EOF
# Generated by bsc.sh
net.ipv4.conf.all.rp_filter = ${rp}
net.ipv4.conf.default.rp_filter = ${rp}
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
  sysctl -q -e -p /etc/sysctl.d/99-bsc-hardening.conf || warn "Some sysctl keys do not apply to this kernel."
  done_ "Kernel hardening (rp_filter=${rp})"
}

FINAL_OK=1
rollback_access() {
  warn "Reverting SSH changes..."
  rm -f "$SOCKET_OVERRIDE"
  restore_port_backups
  restore_orig_dropin
  PORT_CHANGED=0; SSH_PORTS=("${OLD_PORTS[@]}")
  restart_ssh || true
  ok "SSH is back to its original config (ports ${OLD_PORTS[*]})."
  fail_ "SSH rollback applied"
}

step_final_check() {
  [[ $SSH_TOUCHED == 1 ]] || return 0
  [[ $CHECK_OK == 1 ]] || return 0
  step "Final access test"
  local host=${PUBLIC_IP:-<ip>}
  if [[ $ASSUME_YES == 1 ]]; then
    ssh-keyscan -p "${SSH_PORTS[0]}" -T 5 127.0.0.1 >/dev/null 2>&1 || { FINAL_OK=0; rollback_access; }
    return 0
  fi
  printf '\n  In ANOTHER terminal, test again with the final config:\n\n      %sssh -p %s %s@%s%s\n\n' "$C_B" "${SSH_PORTS[0]}" "$TARGET_USER" "$host" "$C_0" >&2
  if yn "Did it work?" y; then done_ "Final access test OK"; return 0; fi
  FINAL_OK=0
  if yn "Revert the SSH changes now?" y; then rollback_access; fi
}

remove_user_from_sudoers() {
  local u=$1 f tmp
  for f in /etc/sudoers.d/*; do
    [[ -f $f ]] || continue
    grep -qE "^\s*${u}\s" "$f" || continue
    tmp=$(mktemp)
    grep -vE "^\s*${u}\s" "$f" | grep -vE "^# User rules for ${u}\s*$" >"$tmp" || true
    if ! grep -qvE '^\s*(#|$)' "$tmp"; then rm -f "$f" "$tmp"
    elif visudo -cf "$tmp" >/dev/null; then install -m 0440 "$tmp" "$f"; rm -f "$tmp"
    else rm -f "$tmp"; warn "Could not clean $f safely; review it by hand."; fi
  done
}

step_remove_cloud_user() {
  step "Default cloud users"
  local -a found=()
  local u
  for u in "${CLOUD_USERS[@]}"; do
    [[ $u == "$TARGET_USER" ]] && continue
    id "$u" >/dev/null 2>&1 && found+=("$u")
  done
  ((${#found[@]})) || { info "No default cloud user found."; return 0; }
  if [[ $CHECK_OK != 1 || $FINAL_OK != 1 ]]; then
    warn "Access as $TARGET_USER not confirmed; not removing ${found[*]}."; skip_ "Cloud user removal"; return 0
  fi
  info "Found: ${found[*]}"
  [[ " ${found[*]} " == *" opc "* ]] && info "'opc' is created by OCI/oracle-cloud-agent (used by Bastion and the console)."
  [[ -n $DO_RMUSER ]] || DO_RMUSER=ask
  for u in "${found[@]}"; do
    if [[ $DO_RMUSER == 0 ]]; then skip_ "Remove $u"; continue; fi
    if [[ $DO_RMUSER == ask ]] && ! yn "Remove user $u (and its home)?" y; then skip_ "Remove $u"; continue; fi
    if [[ $u == "$SESSION_USER" ]]; then
      warn "You are logged in as $u, so it cannot be removed now."
      printf '  After logging in as %s, run:\n      %ssudo deluser --remove-home %s && sudo rm -f /etc/sudoers.d/90-cloud-init-users%s\n' \
        "$TARGET_USER" "$C_B" "$u" "$C_0" >&2
      cat >/root/remove-cloud-user-"$u".sh <<EOF
#!/bin/sh
# Generated by bsc.sh, run as root after leaving the $u session
loginctl terminate-user $u 2>/dev/null; pkill -KILL -u $u 2>/dev/null; sleep 1
deluser --remove-home $u
grep -lE '^\s*$u\s' /etc/sudoers.d/* 2>/dev/null | while read -r f; do sed -i -E '/^\s*$u\s/d; /^# User rules for $u\s*\$/d' "\$f"; grep -qvE '^\s*(#|\$)' "\$f" || rm -f "\$f"; [ -f "\$f" ] && { visudo -cf "\$f" >/dev/null || echo "review \$f"; }; done
rm -f "\$0"
EOF
      chmod 700 /root/remove-cloud-user-"$u".sh
      skip_ "Remove $u (deferred: run sudo /root/remove-cloud-user-$u.sh)"
      continue
    fi
    loginctl terminate-user "$u" 2>/dev/null || true
    pkill -KILL -u "$u" 2>/dev/null || true
    sleep 1
    deluser --remove-home "$u" >/dev/null 2>&1 || userdel -r "$u"
    remove_user_from_sudoers "$u"
    ok "User $u removed."
    done_ "User $u removed"
  done
}

agent_present() { # type target
  case $1 in
    pkg) snap_installed "$2" || pkg_installed "$2" ;;
    custom)
      case $2 in
        aliyun) pkg_installed aliyun-assist || [[ -d /usr/local/share/aliyun-assist ]] ;;
        aegis) [[ -d /usr/local/aegis ]] ;;
        qcloud) [[ -d /usr/local/qcloud ]] ;;
        *) return 1 ;;
      esac ;;
  esac
}

remove_custom_aliyun() {
  systemctl disable --now aliyun.service 2>/dev/null || true
  pkg_installed aliyun-assist && apt-get purge -y -q aliyun-assist || true
  rm -rf /usr/local/share/aliyun-assist /etc/systemd/system/aliyun.service
}
remove_custom_aegis() {
  local s
  for s in aegis AliYunDun AliYunDunMonitor AliYunDunUpdate; do systemctl disable --now "$s" 2>/dev/null || true; done
  pkill -9 -f AliYunDun 2>/dev/null || true; pkill -9 -f aegis_ 2>/dev/null || true
  rm -rf /usr/local/aegis /etc/systemd/system/aegis.service /etc/init.d/aegis /etc/systemd/system/AliYunDun*.service
}
remove_custom_qcloud() {
  local s
  for s in /usr/local/qcloud/stargate/admin/uninstall.sh /usr/local/qcloud/YunJing/uninst.sh /usr/local/qcloud/monitor/barad/admin/uninstall.sh; do
    [[ -x $s ]] && "$s" >/dev/null 2>&1 || true
  done
  rm -rf /usr/local/qcloud
  if crontab -l 2>/dev/null | grep -q qcloud; then crontab -l | grep -v qcloud | crontab -; fi
}

remove_agent() { # id type target
  local id=$1 type=$2 target=$3
  if [[ $type == pkg ]]; then
    if snap_installed "$target"; then snap remove --purge "$target"; fi
    if pkg_installed "$target"; then apt-get purge -y -q "$target"; fi
  else
    "remove_custom_${target}"
  fi
  if [[ $id == oracle-cloud-agent ]]; then
    rm -f /etc/sudoers.d/090-oca-vss-plugin-commands /etc/sudoers.d/100-oracle-cloud-agent-users
    local u; for u in ocarun oracle-cloud-agent oracle-cloud-agent-updater; do id "$u" >/dev/null 2>&1 && userdel "$u" 2>/dev/null || true; done
  fi
  systemctl daemon-reload
}

step_cloud_agents() {
  step "Cloud agents"
  local entry id type target cloud what level
  local -a present=()
  for entry in "${CLOUD_AGENTS[@]}"; do
    IFS='|' read -r id type target cloud what level <<<"$entry"
    agent_present "$type" "$target" && present+=("$entry")
  done
  if ((${#present[@]} == 0)); then info "No known cloud agent found."; skip_ "Cloud agents (none)"; offer_snapd_removal; return 0; fi
  if [[ $CHECK_OK != 1 || $FINAL_OK != 1 ]]; then
    warn "Access not confirmed; keeping the agents (they may be your emergency access)."; skip_ "Agent removal"; return 0
  fi
  info "Found:"
  for entry in "${present[@]}"; do IFS='|' read -r id type target cloud what level <<<"$entry"; printf '      - %s (%s)\n' "$id" "$cloud" >&2; done
  [[ -n $DO_AGENTS ]] || { yn "Review removal of these agents?" n && DO_AGENTS=1 || DO_AGENTS=0; }
  [[ $DO_AGENTS == 1 ]] || { skip_ "Agent removal"; return 0; }

  for entry in "${present[@]}"; do
    IFS='|' read -r id type target cloud what level <<<"$entry"
    printf '\n  %s%s%s (%s)\n    Stops working: %s\n' "$C_B" "$id" "$C_0" "$cloud" "$what" >&2
    case $level in
      never)
        warn "    Removal not recommended: the VM depends on it. Kept."; skip_ "Agent $id (essential)"; continue ;;
      risky)
        warn "    RISKY: may cut off VM access/networking."
        if [[ $ASSUME_YES == 1 ]]; then [[ ",$OPT_AGENTS," == *",$id,"* ]] || { skip_ "Agent $id"; continue; }
        else
          local typed; ask typed "    To remove it, type the exact name ($id); empty = keep" ""
          [[ $typed == "$id" ]] || { skip_ "Agent $id"; continue; }
        fi ;;
      *)
        if [[ $ASSUME_YES == 1 ]]; then
          [[ $OPT_AGENTS == all || ",$OPT_AGENTS," == *",$id,"* ]] || { skip_ "Agent $id"; continue; }
        elif ! yn "    Remove $id?" n; then skip_ "Agent $id"; continue; fi ;;
    esac
    if remove_agent "$id" "$type" "$target"; then ok "$id removed."; done_ "Agent $id removed"
    else warn "Failed to remove $id."; fail_ "Agent $id"; fi
  done
  offer_snapd_removal
}

offer_snapd_removal() {
  pkg_installed snapd || return 0
  local left
  left=$(snap list 2>/dev/null | awk 'NR>1{print $1}' | grep -vxE 'core|core[0-9]+|snapd|bare' || true)
  [[ -z $left ]] || return 0
  info "No application snaps left; snapd is no longer needed."
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  if yn "Remove snapd as well?" n; then
    systemctl disable --now snapd.socket snapd.service >/dev/null 2>&1 || true
    apt-get purge -y -q snapd
    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
    yn "Block automatic reinstallation of snapd (apt-mark hold)?" y && apt-mark hold snapd >/dev/null
    done_ "snapd removed"
  fi
}

summary() {
  step "Summary"
  local l
  for l in "${SUMMARY[@]}"; do printf '  %s\n' "$l"; done
  detect_public_ip
  printf '\n  Access: %sssh -p %s %s@%s%s\n' "$C_B" "${SSH_PORTS[0]}" "$TARGET_USER" "${PUBLIC_IP:-<ip>}" "$C_0"
  [[ $PORT_CHANGED == 1 ]] && printf '  Remember: port %s must be open in the provider firewall (and 22 can be closed there).\n' "$NEW_PORT"
  [[ -f /var/run/reboot-required ]] && printf '  %sReboot pending%s (kernel/libs updated): sudo reboot\n' "$C_Y" "$C_0"
  printf '  Backups: set up weekly snapshots at the provider and a daily copy of the data (e.g. /opt/*/data) off the VM. Test the restore.\n'
  printf '  Log: %s\n\n' "$LOG"
}

self_cleanup() {
  local self
  self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  [[ -f $self && $self != /dev/* && $self != /proc/* ]] || return 0
  if yn "Delete this script from the server ($self)?" y; then
    rm -f "$self" && ok "Script removed."
  fi
}

main() {
  parse_args "$@"
  preflight
  setup_logging
  banner
  step_system
  step_swap
  step_user
  step_ssh_port
  step_checkpoint
  step_ssh_finalize
  step_fail2ban
  step_auto_updates
  step_docker
  step_tailscale
  step_dockhand
  step_hawser
  step_kernel
  step_journald
  step_final_check
  step_remove_cloud_user
  step_cloud_agents
  summary
  self_cleanup
}

main "$@"
