#!/usr/bin/env bash
#
# setup-xray-reality.sh
#
# Installer / manager for a hardened Xray VLESS + TCP + XTLS-Vision + REALITY
# server on a Debian/Ubuntu VPS.
#
#   bash setup-xray-reality.sh   Install (safe to re-run) and add the `reality` command.
#   reality                      Interactive management menu.
#   reality help                 List every subcommand.
#
# Install never asks questions. It picks a live-verified SNI from SNI_POOL,
# port 443 and a random uTLS fingerprint; change them afterwards from
#   reality  ->  "Reality settings"
# (or `reality change-sni <domain>`, `change-port <port>`, `change-fingerprint <fp>`).
#
# Xray-core is installed once and is NEVER updated automatically. Run
# `reality update-core` when you want a newer release.
#
# Optional environment variables (honored on a first-time install only; once
# state exists, the saved values win):
#   SNI_DOMAIN             REALITY camouflage target (default: random from SNI_POOL)
#   LISTEN_PORT            Xray listen port          (default: 443)
#   FINGERPRINT            uTLS fingerprint          (default: random)
#   REALITY_ALERT_WEBHOOK  webhook URL for critical alerts
#   SCRIPT_SOURCE_URL      where `reality update` downloads this script from
#
# Every config change backs up the previous config + client info to
# /root/xray-backups/<timestamp>/ first.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Conservative YouTube/Google static-asset hosts (TLS1.3, not a mega-CDN edge).
# googlevideo.com is excluded on purpose: its hostnames are ephemeral.
SNI_POOL=(i.ytimg.com s.ytimg.com www.youtube.com)
FINGERPRINTS="chrome firefox safari ios android edge 360 qq random randomized"

SCRIPT_SOURCE_URL="${SCRIPT_SOURCE_URL:-https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh}"
XRAY_INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"

REALITY_SHORTCUT="/usr/local/bin/reality"
SERVICE_NAME="xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
STATE_FILE="${XRAY_CONFIG_DIR}/.reality-state"
USER_STOPPED_MARKER="${XRAY_CONFIG_DIR}/.user-stopped"
CLIENT_INFO_FILE="/root/xray-client-info.txt"
BACKUP_ROOT="/root/xray-backups"
AUDIT_LOG="/var/log/reality-setup.log"
LOCK_FILE="/var/lock/reality-setup.lock"

# Mutable settings: env defaults here, overridden by saved state (load_state).
SNI_DOMAIN="${SNI_DOMAIN:-}"
LISTEN_PORT="${LISTEN_PORT:-443}"
FINGERPRINT="${FINGERPRINT:-random}"
ALERT_WEBHOOK="${REALITY_ALERT_WEBHOOK:-}"
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SSH_PORT=""

CONFIG_CHANGED=0
OVERRIDE_CONF_CHANGED=0

# ---------------------------------------------------------------------------
# Output helpers (color only when the stream is a real terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi
if [[ -t 2 ]]; then
  E_RED=$'\033[31m'; E_YELLOW=$'\033[33m'; E_RESET=$'\033[0m'
else
  E_RED=""; E_YELLOW=""; E_RESET=""
fi

step() { echo ""; echo "${C_BOLD}=== [$1] $2 ===${C_RESET}"; }
ok()   { echo "  ${C_GREEN}OK:${C_RESET} $1"; }
warn() { echo "  ${E_YELLOW}WARNING:${E_RESET} $1" >&2; }
err()  { echo "  ${E_RED}ERROR:${E_RESET} $1" >&2; }
# die "message" ["hint line" ...]  -- print an error plus optional hints, exit 1.
die() {
  err "$1"; shift
  local line
  for line in "$@"; do echo "       ${line}" >&2; done
  exit 1
}

# Box drawing for the menu and usage list. Padding uses the VISIBLE width
# (ANSI codes stripped), so keep the text itself ASCII.
BOX_W=70
BOX_RULE=""
for ((_i = 0; _i < BOX_W; _i++)); do BOX_RULE+="─"; done
box_top() { printf '┌%s┐\n' "$BOX_RULE"; }
box_sep() { printf '├%s┤\n' "$BOX_RULE"; }
box_bot() { printf '└%s┘\n' "$BOX_RULE"; }
box_line() {
  local text="${1:-}" plain pad
  plain=$(printf '%s' "$text" | sed $'s/\033\\[[0-9;]*m//g')
  pad=$((BOX_W - 2 - ${#plain}))
  if [[ "$pad" -lt 0 ]]; then pad=0; fi
  printf '│  %s%*s│\n' "$text" "$pad" ""
}
box_cmd() { box_line "$(printf '%s%-30s%s %s' "$C_BLUE" "$1" "$C_RESET" "$2")"; }

usage() {
  box_top
  box_line "${C_BOLD}reality${C_RESET} control menu usages (subcommands):"
  box_line ""
  box_cmd "reality"                      "- Management menu (interactive)"
  box_cmd "reality install"              "- Install / re-apply full setup"
  box_cmd "reality update"               "- Update this script, then re-apply"
  box_cmd "reality update-core"          "- Update Xray-core (manual only)"
  box_cmd "reality uninstall"            "- Uninstall"
  box_sep
  box_cmd "reality start"                "- Start"
  box_cmd "reality stop"                 "- Stop (watchdog won't restart it)"
  box_cmd "reality restart"              "- Restart"
  box_cmd "reality status"               "- Current status"
  box_cmd "reality log [-f]"             "- Check logs (-f to follow)"
  box_cmd "reality enable"               "- Enable autostart on boot"
  box_cmd "reality disable"              "- Disable autostart on boot"
  box_sep
  box_cmd "reality show"                 "- Client link + QR code"
  box_cmd "reality change-sni <domain>"  "- Change the camouflage domain"
  box_cmd "reality change-port <port>"   "- Change the listen port"
  box_cmd "reality change-fingerprint V" "- Change client uTLS fingerprint"
  box_cmd "reality rotate-uuid"          "- New UUID (revokes the old link)"
  box_cmd "reality rotate-all"           "- New UUID + keys (revokes ALL)"
  box_sep
  box_cmd "reality health-check"         "- Run the watchdog check now"
  box_cmd "reality set-webhook <url>"    "- Alert webhook ('' to clear)"
  box_cmd "reality list-backups"         "- List config backups"
  box_cmd "reality restore <timestamp>"  "- Restore a backup"
  box_bot
  echo "Flags: --force / --yes skip confirmation prompts (needed when there is no terminal)."
}

# ---------------------------------------------------------------------------
# Small validators / probes
# ---------------------------------------------------------------------------
clean_domain()  { local d="${1#http://}"; d="${d#https://}"; d="${d%%/*}"; echo "${d%%:*}"; }
valid_port()    { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
# Strict hostname (letters, digits, hyphens, dots; not an IP). The value ends up in
# config.json and the state file, so anything looser is an injection risk.
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$'
valid_domain()  { [[ ${#1} -le 253 && "$1" =~ $DOMAIN_RE && ! "$1" =~ \.[0-9]+$ ]]; }
# http(s) URL limited to URL-safe characters: no quotes, backslashes, $, backticks or spaces.
WEBHOOK_RE='^https?://[A-Za-z0-9._~:/?#@!&*+,;=%-]+$'
valid_webhook() { [[ "$1" =~ $WEBHOOK_RE ]]; }
valid_fp()      { [[ " ${FINGERPRINTS} " == *" $1 "* ]]; }
sni_ok()        { timeout 6 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 </dev/null >/dev/null 2>&1; }
xray_version()  { xray version 2>/dev/null | sed -n 1p || true; }
port_listening(){ ss -tln 2>/dev/null | awk -v p=":${1}\$" '$4 ~ p {f=1} END {exit !f}'; }
tcp_connects()  { timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
ufw_active()    { [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; }

# NOTIFY-ONLY: at most once a day, remember the latest Xray-core release tag so the
# health check, status and menu can say "an update exists". Nothing is downloaded
# or installed; updating stays a manual `reality update-core`.
check_core_update() {
  local stamp="${XRAY_CONFIG_DIR}/.core-latest" tag
  if [[ -f "$stamp" && -z "$(find "$stamp" -mmin +1440 2>/dev/null)" ]]; then return 0; fi
  tag=$(curl -fsS --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+)+$ ]]; then echo "${tag#v}" > "$stamp"; else touch "$stamp" 2>/dev/null || true; fi
}
# Prints the newer release version and succeeds only if one is known.
core_update_available() {
  local latest installed
  latest=$(cat "${XRAY_CONFIG_DIR}/.core-latest" 2>/dev/null || true)
  installed=$(xray_version | awk '{print $2}')
  [[ -n "$latest" && -n "$installed" && "$latest" != "$installed" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | sed -n 1p)" == "$installed" ]] || return 1
  echo "$latest"
}

# Pick the camouflage domain: the preferred one (SNI_DOMAIN env, else a random
# pool entry) if it serves TLS1.3, otherwise the first pool entry that does.
choose_sni() {
  local first="${SNI_DOMAIN:-${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}}" candidate
  for candidate in "$first" "${SNI_POOL[@]}"; do
    if sni_ok "$candidate"; then
      if [[ "$candidate" != "$first" ]]; then
        warn "SNI '${first}' failed the live TLS1.3 check; using '${candidate}' instead."
      fi
      SNI_DOMAIN="$candidate"
      return 0
    fi
  done
  warn "Could not verify TLS1.3 for any SNI candidate (network issue?). Using '${first}' unverified."
  SNI_DOMAIN="$first"
}

# Print a note about UFW rules with this comment tag that are NOT for the given port.
# (Digit-boundary match, so a stale 2222 rule isn't hidden by a current 22.)
note_stale_ufw() {
  local tag="$1" port="$2" stale
  command -v ufw >/dev/null 2>&1 || return 0
  stale=$(ufw status numbered 2>/dev/null | grep "$tag" | grep -vE "(^|[^0-9])${port}/tcp" || true)
  if [[ -n "$stale" ]]; then
    echo "NOTE: UFW rule(s) tagged '${tag}' for a port other than the current one (${port}):"
    echo "$stale" | sed 's/^/  /'
    echo "      If stale, remove with: ufw delete <rule number>   (see 'ufw status numbered')"
  fi
}

# ---------------------------------------------------------------------------
# State, backups, credentials
# ---------------------------------------------------------------------------
# The state file is DATA, never code: it is parsed line by line against a key
# whitelist rather than `source`d, so a tampered or corrupted file (or a backup
# restored from one) cannot execute commands as root. Both the current
# KEY=value and the older KEY="value" formats are accepted.
load_state() {
  local key val
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
      val="${val%$'\r'}"; val="${val%\"}"; val="${val#\"}"
      case "$key" in
        SNI_DOMAIN|LISTEN_PORT|FINGERPRINT|UUID|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|SSH_PORT|ALERT_WEBHOOK)
          printf -v "$key" '%s' "$val" ;;
        *) ;;
      esac
    done < "$STATE_FILE"
  fi
  FINGERPRINT="${FINGERPRINT:-random}"
}

# Refuse to run with malformed settings (from env vars, a corrupted state file, ...):
# these values are written into config.json and passed to curl/ufw.
validate_state() {
  [[ -z "$SNI_DOMAIN" ]]     || valid_domain "$SNI_DOMAIN"     || die "Invalid SNI_DOMAIN '${SNI_DOMAIN}' (expected a plain hostname such as i.ytimg.com)."
  valid_port "$LISTEN_PORT"                                    || die "Invalid LISTEN_PORT '${LISTEN_PORT}' (expected 1-65535)."
  [[ -z "$SSH_PORT" ]]       || valid_port "$SSH_PORT"         || die "Invalid SSH_PORT '${SSH_PORT}' in ${STATE_FILE}."
  valid_fp "$FINGERPRINT"                                      || die "Invalid FINGERPRINT '${FINGERPRINT}'. Valid: ${FINGERPRINTS}"
  [[ "$UUID" =~ ^[0-9A-Fa-f-]*$ ]]                             || die "Invalid UUID in ${STATE_FILE}."
  [[ "$SHORT_ID" =~ ^[0-9A-Fa-f]*$ ]]                          || die "Invalid SHORT_ID in ${STATE_FILE}."
  [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_=-]*$ ]]                    || die "Invalid PRIVATE_KEY in ${STATE_FILE}."
  [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_=-]*$ ]]                     || die "Invalid PUBLIC_KEY in ${STATE_FILE}."
  [[ -z "$ALERT_WEBHOOK" ]]  || valid_webhook "$ALERT_WEBHOOK" || die "Invalid alert webhook URL in ${STATE_FILE} (or REALITY_ALERT_WEBHOOK)."
}

save_state() {
  local tmp
  tmp=$(mktemp "${XRAY_CONFIG_DIR}/.reality-state.XXXXXX")
  cat > "$tmp" <<EOF
SNI_DOMAIN=${SNI_DOMAIN}
LISTEN_PORT=${LISTEN_PORT}
FINGERPRINT=${FINGERPRINT}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SSH_PORT=${SSH_PORT}
ALERT_WEBHOOK=${ALERT_WEBHOOK}
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

require_install() {
  if [[ -z "$UUID" || -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    die "No existing install found (${STATE_FILE}). Run a full install first."
  fi
}

backup_current_state() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local dir
  dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a "$CONFIG_FILE" "$dir/config.json"
  if [[ -f "$CLIENT_INFO_FILE" ]]; then cp -a "$CLIENT_INFO_FILE" "$dir/client-info.txt"; fi
  if [[ -f "$STATE_FILE" ]]; then cp -a "$STATE_FILE" "$dir/state"; fi
  chmod 700 "$BACKUP_ROOT" "$dir"
  chmod 600 "$dir"/*
  echo "Backed up previous config to: $dir"
  # Keep only the 15 most recent backups.
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n -15 | xargs -r rm -rf
}

generate_uuid_and_shortid() {
  UUID=$(xray uuid) || die "'xray uuid' failed to run."
  SHORT_ID=$(openssl rand -hex 8)
  [[ -n "$UUID" && -n "$SHORT_ID" ]] || die "Failed to generate UUID or short ID."
}

# Handles both `xray x25519` output formats:
#   old: "Private key: x" / "Public key: x"
#   new: "PrivateKey: x"  / "Password (PublicKey): x"
generate_reality_keypair() {
  local out
  out=$(xray x25519) || die "'xray x25519' failed to run."
  PRIVATE_KEY=$(echo "$out" | grep -Ei '^[[:space:]]*(Private ?[Kk]ey)[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  PUBLIC_KEY=$(echo "$out" | grep -Ei '^[[:space:]]*(Public ?[Kk]ey|Password)([[:space:]]*\(.*\))?[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Failed to parse the REALITY keypair. Raw 'xray x25519' output:"
    echo "$out" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Xray config / service helpers
# ---------------------------------------------------------------------------
# Xray runs as the unprivileged 'xray' user, but the official installer resets
# /var/log/xray to its own base-unit user on every real install/update. Xray
# refuses to start if it can't open its log, so re-assert ownership after every
# run of the installer (and whenever config is written).
ensure_xray_log_permissions() {
  mkdir -p /var/log/xray
  if id -u xray >/dev/null 2>&1; then chown -R xray:xray /var/log/xray 2>/dev/null || true; fi
}

# Run the official Xray installer (up to 3 attempts). Used for the first install
# and for the manual `reality update-core` -- never from a timer.
install_xray_core() {
  local attempt tmp
  tmp=$(mktemp)
  for attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 10 --max-time 60 "$XRAY_INSTALLER_URL" -o "$tmp" && bash "$tmp" install; then
      rm -f "$tmp"
      ensure_xray_log_permissions
      return 0
    fi
    ensure_xray_log_permissions
    if (( attempt < 3 )); then
      echo "Xray-core install attempt ${attempt} failed, retrying in 5s..."
      sleep 5
    fi
  done
  rm -f "$tmp"
  return 1
}

# Record the xray binary's checksum so --health-check can spot unexpected changes.
# An existing record is only replaced when called with "force" (right after a
# deliberate install / `reality update-core`). Otherwise a re-run of the installer
# would quietly bless a binary that was swapped out behind our back.
record_xray_binary_checksum() {
  local path sum file="${XRAY_CONFIG_DIR}/.xray-binary.sha256"
  path=$(command -v xray 2>/dev/null) || return 0
  sum=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
  [[ -n "$sum" ]] || return 0
  if [[ "${1:-}" != "force" && -f "$file" && "$(cat "$file")" != "$sum" ]]; then
    warn "The xray binary (${path}) no longer matches the checksum recorded at install/update."
    echo "         Not re-recording it. If you replaced it on purpose, run: reality update-core" >&2
    return 0
  fi
  echo "$sum" > "$file"
  chmod 600 "$file"
}

record_config_checksum() {
  (cd "$XRAY_CONFIG_DIR" && sha256sum "$(basename "$CONFIG_FILE")" > .config.sha256 2>/dev/null) || true
  chmod 600 "${XRAY_CONFIG_DIR}/.config.sha256" 2>/dev/null || true
}

# Render config.json from the current settings. Validates it (JSON syntax, then
# Xray's own schema) before atomically replacing the live file; backs up the
# old one only if the content actually changed.
write_config() {
  mkdir -p "$XRAY_CONFIG_DIR"
  local tmp test_out
  tmp=$(mktemp "${XRAY_CONFIG_DIR}/.config.json.XXXXXX")
  cat > "$tmp" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://9.9.9.9/dns-query"
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "client1"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI_DOMAIN}:443",
          "xver": 0,
          "serverNames": ["${SNI_DOMAIN}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIP" }
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": { "response": { "type": "none" } }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "169.254.169.254/32",
          "169.254.0.0/16",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "fd00::/8",
          "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    die "Generated config.json is not valid JSON. Not restarting xray." \
        "Broken draft left at ${tmp}; the existing config was not touched."
  fi

  # The log directory must exist before `xray -test`, which opens the log path.
  ensure_xray_log_permissions
  if ! test_out=$(xray run -test -format json -config "$tmp" 2>&1); then
    err "Xray rejected the generated config:"
    echo "$test_out" | sed 's/^/  /' >&2
    die "Broken draft left at ${tmp}; the existing config was not touched."
  fi

  if [[ -f "$CONFIG_FILE" ]] && cmp -s "$tmp" "$CONFIG_FILE"; then
    CONFIG_CHANGED=0
  else
    CONFIG_CHANGED=1
    backup_current_state
  fi
  mv -f "$tmp" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE"
  record_config_checksum
}

# Handshake check: is Xray actually serving, not just "active"? Non-fatal --
# loopback quirks can cause false negatives a real client wouldn't hit.
verify_handshake() {
  local out
  if ! port_listening "$LISTEN_PORT"; then
    warn "Xray is active, but nothing is listening on port ${LISTEN_PORT}. Check: ss -tlnp | grep ${LISTEN_PORT}"
    return 0
  fi
  if ! tcp_connects "$LISTEN_PORT"; then
    warn "Port ${LISTEN_PORT} is listening, but a local TCP connect failed."
    return 0
  fi
  out=$(timeout 5 openssl s_client -connect "127.0.0.1:${LISTEN_PORT}" -servername "$SNI_DOMAIN" </dev/null 2>/dev/null || true)
  if [[ "$out" != *CONNECTED* ]]; then
    warn "TCP connects, but the TLS handshake on 127.0.0.1:${LISTEN_PORT} (SNI: ${SNI_DOMAIN}) didn't complete."
    echo "         May be a loopback quirk -- test from a real client; if that fails too: journalctl -u xray -e" >&2
    return 0
  fi
  ok "Handshake check passed: port listening, TCP connects, TLS handshake completes."
}

restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    die "xray service failed to start. Check: journalctl -u xray -e"
  fi
  ok "xray service is active"
  verify_handshake
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------
# POST a JSON body to the alert webhook. The URL is handed to curl on stdin (as a
# curl config), so a secret token inside it never appears in `ps`. Tracks delivery
# failures so `reality status` can show that alerts are not getting through.
post_webhook() {
  local file="${XRAY_CONFIG_DIR}/.webhook-failed" url
  [[ -n "$ALERT_WEBHOOK" ]] && command -v curl >/dev/null 2>&1 || return 1
  url="${ALERT_WEBHOOK//\\/\\\\}"; url="${url//\"/\\\"}"
  if printf 'url = "%s"\n' "$url" | curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -d "$1" -K - >/dev/null 2>&1; then
    rm -f "$file"
    return 0
  fi
  touch "$file" 2>/dev/null || true
  return 1
}

# Local alert (logger + wall) plus the optional webhook.
send_alert() {
  local msg="$1" host escaped
  logger -p daemon.crit "reality alert: ${msg}" 2>/dev/null || true
  wall "WARNING (xray REALITY): ${msg}" 2>/dev/null || true
  if [[ -n "$ALERT_WEBHOOK" ]]; then
    host=$(hostname 2>/dev/null || echo unknown-host)
    escaped=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    post_webhook "{\"host\":\"${host}\",\"message\":\"${escaped}\"}" \
      || logger -p daemon.warning "reality alert: webhook POST failed (network issue or bad URL?)" 2>/dev/null || true
  fi
}

# Alert only when a condition CHANGES state (fine -> bad), not on every tick.
# alert_on_transition <key> <is_bad 0|1> <bad message> <resolved message>
alert_on_transition() {
  local marker="${XRAY_CONFIG_DIR}/.alert-${1}"
  if [[ "$2" -eq 1 ]]; then
    if [[ ! -f "$marker" ]]; then
      touch "$marker"
      send_alert "$3"
    fi
  elif [[ -f "$marker" ]]; then
    rm -f "$marker"
    if [[ -n "$4" ]]; then logger -p daemon.notice "reality alert: ${4}" 2>/dev/null || true; fi
  fi
}

# ---------------------------------------------------------------------------
# Client link / QR
# ---------------------------------------------------------------------------
get_public_ip() {
  local args ip
  for args in "-4 https://ifconfig.me" "-4 https://api.ipify.org" "-4 https://icanhazip.com" \
              "-6 https://api64.ipify.org" "-6 https://icanhazip.com"; do
    # shellcheck disable=SC2086  # word splitting of $args is intended
    ip=$(curl -fsSL --max-time 5 $args 2>/dev/null | tr -d '[:space:]') || ip=""
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

output_client_info() {
  local ip link host_part previous tmp png="${CLIENT_INFO_FILE%.txt}-qr.png"
  if ! ip=$(get_public_ip); then
    warn "Could not determine the server's public IP; substitute it into the link below."
    ip="YOUR_SERVER_IP"
  elif [[ -f "$CLIENT_INFO_FILE" ]]; then
    previous=$(grep -m1 "^Server IP" "$CLIENT_INFO_FILE" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ' || true)
    if [[ -n "$previous" && "$previous" != "$ip" && "$previous" != "YOUR_SERVER_IP" ]]; then
      warn "Server IP changed since the last run: ${previous} -> ${ip}. Re-import the link below on your devices."
    fi
  fi

  host_part="$ip"
  if [[ "$ip" == *:* ]]; then host_part="[${ip}]"; fi   # IPv6 literals need brackets in a URL
  link="vless://${UUID}@${host_part}:${LISTEN_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision&spx=%2F#xray-reality-$(hostname)"

  # mktemp creates 0600, so the private key is never briefly world-readable.
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
================= Xray VLESS-TCP-XTLS-Vision-REALITY =================
Server IP     : ${ip}
Port          : ${LISTEN_PORT}
UUID          : ${UUID}
Flow          : xtls-rprx-vision
Security      : reality
SNI (dest)    : ${SNI_DOMAIN}
Public Key    : ${PUBLIC_KEY}
Short ID      : ${SHORT_ID}
Fingerprint   : ${FINGERPRINT}

Client import link:
${link}
========================================================================
Keep this file private: anyone holding this link can use your server.
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$CLIENT_INFO_FILE"

  if command -v qrencode >/dev/null 2>&1; then
    if (umask 077; qrencode -t PNG -o "$png" "$link") 2>/dev/null; then
      chmod 600 "$png"
    else
      warn "Could not write a QR PNG (qrencode may lack PNG support)."
    fi
  fi

  echo ""
  echo "############################################################"
  echo "  Service status : $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo "  Config file    : ${CONFIG_FILE}"
  echo "  Client info    : ${CLIENT_INFO_FILE} (chmod 600)"
  echo "############################################################"
  echo ""
  echo "Client link (import into v2rayN / NekoBox / Shadowrocket / etc.):"
  echo "${link}"
  echo ""
  echo "QR code:"
  # Guarded: a QR failure must not abort after new credentials are already written.
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 "$link" || warn "qrencode failed to render the terminal QR code."
  else
    warn "qrencode not found -- skipping the terminal QR code (the link above still works)."
  fi
}

# save + print + restart: the common tail of every command that changes config.
finish_and_restart() {
  save_state
  output_client_info
  restart_and_verify
}

# ===========================================================================
# Commands
# ===========================================================================

cmd_show() {
  require_install
  output_client_info
}

cmd_send_alert() { send_alert "${1:-Unspecified xray REALITY alert}"; }

cmd_set_webhook() {
  require_install
  local url="$1"
  if [[ -z "$url" ]]; then
    ALERT_WEBHOOK=""
    save_state
    ok "Webhook cleared. Critical alerts now go to the local log/wall only."
    return 0
  fi
  valid_webhook "$url" || die "That doesn't look like a safe webhook URL." "It must start with https:// and contain no spaces, quotes, backslashes, \$ or backticks."
  if [[ "$url" != https://* && "$FORCE" -ne 1 ]]; then
    die "Webhook URLs must use https:// (alerts carry the hostname and server state)." "Add --force to allow plain http:// anyway."
  fi
  ALERT_WEBHOOK="$url"
  save_state
  ok "Webhook saved. Sending a test alert..."
  send_alert "Test alert from $(hostname 2>/dev/null || echo this server) -- webhook is configured correctly if you received this."
}

# ---- service control ------------------------------------------------------
# `stop` leaves a marker so the watchdog doesn't undo it; start/restart clear it.
# These don't call `systemctl enable`, so they never undo a deliberate `disable`.
start_or_restart_service() {
  systemctl "$1" "$SERVICE_NAME" || true
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    die "xray service failed to start. Check: journalctl -u xray -e"
  fi
  ok "xray service is active"
  verify_handshake
}

cmd_start()   { rm -f "$USER_STOPPED_MARKER"; ensure_xray_log_permissions; start_or_restart_service start; }
cmd_restart() { rm -f "$USER_STOPPED_MARKER"; ensure_xray_log_permissions; start_or_restart_service restart; }

cmd_stop() {
  touch "$USER_STOPPED_MARKER"
  systemctl stop "$SERVICE_NAME" || true
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    die "xray is still running after 'systemctl stop'. Check: systemctl status xray"
  fi
  ok "xray stopped. The watchdog will leave it alone until you run: reality start"
  echo "     (With autostart enabled it still comes back after the next reboot, the daily one included.)"
}

cmd_enable() {
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || die "Could not enable the xray service. Check: systemctl status xray"
  ok "xray will start automatically on boot."
}

cmd_disable() {
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || die "Could not disable the xray service. Check: systemctl status xray"
  ok "xray will NOT start on boot (it keeps running until stopped or rebooted)."
  echo "     This server reboots daily, so xray stays down after the next reboot until: reality enable && reality start"
}

cmd_logs() {
  if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
    echo "Following the xray service log (Ctrl-C to stop)..."
    exec journalctl -u "$SERVICE_NAME" -f --no-hostname
  fi
  step "logs" "xray service log (journal, last 50 lines)"
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager 2>/dev/null || echo "  (journalctl is not available here)"
  if [[ -s /var/log/xray/error.log ]]; then
    step "logs" "xray error log (last 30 lines)"
    tail -n 30 /var/log/xray/error.log
  fi
  if [[ -f "$AUDIT_LOG" ]]; then
    step "logs" "reality run history (last 15 runs)"
    tail -n 15 "$AUDIT_LOG"
  fi
}

# ---- updates --------------------------------------------------------------
# Update THIS script from SCRIPT_SOURCE_URL, then re-apply the setup with it.
cmd_update() {
  step "update" "Updating this script from ${SCRIPT_SOURCE_URL}"
  local tmp answer="" sum changed="all (no installed copy to compare)"
  [[ "$SCRIPT_SOURCE_URL" == https://* ]] || die "SCRIPT_SOURCE_URL must be an https:// URL (got: '${SCRIPT_SOURCE_URL}')."
  tmp=$(mktemp)
  if ! curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_SOURCE_URL" -o "$tmp"; then
    rm -f "$tmp"
    die "Could not download ${SCRIPT_SOURCE_URL} (network issue, or a wrong SCRIPT_SOURCE_URL?)."
  fi
  # Only install something that is plausibly this script.
  if ! bash -n "$tmp" 2>/dev/null || ! head -n1 "$tmp" | grep -q '^#!.*bash' || ! grep -q 'setup-xray-reality' "$tmp"; then
    rm -f "$tmp"
    die "The downloaded file doesn't look like a valid copy of this script -- not installing it."
  fi
  if cmp -s "$tmp" "$REALITY_SHORTCUT" 2>/dev/null; then
    rm -f "$tmp"
    ok "Already running the latest version of this script. (To re-apply the setup anyway: reality install)"
    return 0
  fi
  # This file will run as root: show what is about to be installed, and let a
  # known-good hash (REALITY_SCRIPT_SHA256) pin it.
  sum=$(sha256sum "$tmp" | awk '{print $1}')
  if [[ -n "${REALITY_SCRIPT_SHA256:-}" && "${REALITY_SCRIPT_SHA256,,}" != "$sum" ]]; then
    rm -f "$tmp"
    die "SHA-256 mismatch: expected ${REALITY_SCRIPT_SHA256}, downloaded ${sum}. Not installing."
  fi
  if [[ -f "$REALITY_SHORTCUT" ]]; then
    changed="$(diff "$REALITY_SHORTCUT" "$tmp" | grep -c '^[<>]' || true) changed line(s)"
  fi
  echo "  Downloaded SHA-256 : ${sum}"
  echo "  Difference         : ${changed}"
  if [[ -t 0 && "$FORCE" -ne 1 ]]; then
    read -r -t 300 -p "A newer version is available. Install it and re-apply the setup (credentials are kept)? [y/N]: " answer || true
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      rm -f "$tmp"
      echo "Cancelled. No changes made."
      return 0
    fi
  fi
  # Write next to the target, then rename: overwriting in place would corrupt
  # this very process when it is running from that file.
  install -m 755 "$tmp" "${REALITY_SHORTCUT}.new"
  mv -f "${REALITY_SHORTCUT}.new" "$REALITY_SHORTCUT"
  rm -f "$tmp"
  ok "Installed the new version to ${REALITY_SHORTCUT}. Re-applying the setup (credentials are kept)..."
  exec 200>&-   # release our lock so the new process can take it
  exec "$REALITY_SHORTCUT" --install
}

# Manual Xray-core update. This is the ONLY way Xray-core gets updated.
cmd_update_core() {
  step "update-core" "Updating Xray-core (manual)"
  local before after
  before=$(xray_version)
  install_xray_core || die "Could not reach the Xray-core installer after 3 attempts (network issue?)."
  after=$(xray_version)
  record_xray_binary_checksum force
  if [[ "$before" == "$after" ]]; then
    ok "Xray-core already current (${after}) -- no restart needed."
  else
    ok "Xray-core updated: ${before:-none} -> ${after:-none}"
    restart_and_verify
  fi
}

# ---- uninstall ------------------------------------------------------------
# Removes the proxy and what was installed for it. Host hardening (UFW + SSH
# rule, fail2ban, BBR/sysctl, journald cap, unattended-upgrades policy) stays.
cmd_uninstall() {
  local answer="" unit rule_nums rule
  if [[ -t 0 ]]; then
    echo ""
    warn "This REMOVES the Xray proxy and what this script installed for it:"
    echo "    - the xray service, binary, config and credentials (the current client link stops working)"
    echo "    - the watchdog and daily-reboot timers"
    echo "    - ${REALITY_SHORTCUT}, the login banner, logs, backups and ${CLIENT_INFO_FILE}"
    echo "    - the UFW rule(s) for the Xray port (currently ${LISTEN_PORT})"
    echo "  Left in place: UFW itself + SSH rule, fail2ban, BBR/sysctl tuning, journald cap."
    read -r -t 300 -p "Type 'yes' to uninstall: " answer || true
    if [[ "$answer" != "yes" ]]; then
      echo "Cancelled. No changes made."
      return 0
    fi
  elif [[ "$FORCE" -ne 1 ]]; then
    die "uninstall removes the proxy and all credentials, and there is no terminal to confirm on." \
        "Re-run with: reality uninstall --force   if this is intentional."
  fi

  step "uninstall" "Removing Xray REALITY"
  # Timers first, so nothing restarts xray (or reboots the box) mid-removal.
  # The autoupdate/backup-maintenance units are legacy (older versions of this script).
  for unit in reality-watchdog reality-autoupdate reality-backup-maintenance daily-reboot; do
    systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"
  done
  ok "Removed the timers."

  if command -v ufw >/dev/null 2>&1; then
    # Highest rule number first so the remaining numbers stay valid.
    rule_nums=$(ufw status numbered 2>/dev/null | grep 'Xray REALITY' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn || true)
    for rule in $rule_nums; do ufw --force delete "$rule" >/dev/null 2>&1 || true; done
    ufw delete allow "${LISTEN_PORT}"/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    ok "Removed the UFW rule(s) for the Xray port."
  fi

  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/xray-alert.service
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/share/xray
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
  ok "Removed the xray service and binary."

  rm -f /etc/logrotate.d/xray /etc/logrotate.d/reality-setup /etc/update-motd.d/99-xray-reality
  rm -rf "$XRAY_CONFIG_DIR" /var/log/xray "$BACKUP_ROOT"
  rm -f "$CLIENT_INFO_FILE" "${CLIENT_INFO_FILE%.txt}-qr.png" "$AUDIT_LOG"
  if id -u xray >/dev/null 2>&1; then userdel xray >/dev/null 2>&1 || true; fi
  ok "Removed config, credentials, backups, logs and the xray service account."

  # Last: this may be the very file we're running from (fine on Linux).
  rm -f "$REALITY_SHORTCUT" "$LOCK_FILE"

  echo ""
  ok "Uninstalled. Host hardening was left in place. To undo any of it yourself:"
  echo "       /etc/sysctl.d/99-xray-hardening.conf   /etc/modules-load.d/bbr.conf"
  echo "       /etc/fail2ban/jail.d/sshd.local        /etc/systemd/journald.conf.d/99-xray-hardening.conf"
  echo "       /etc/apt/apt.conf.d/51-xray-security-only    (and 'ufw disable' if you don't want the firewall)"
}

# ---- backups --------------------------------------------------------------
cmd_list_backups() {
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    return 0
  fi
  echo "Available backups (use with: reality restore <timestamp>):"
  local dir
  for dir in "$BACKUP_ROOT"/*/; do
    echo "  $(basename "$dir")   ($(ls "$dir" 2>/dev/null | tr '\n' ' '))"
  done
}

cmd_restore() {
  local ts="$1" dir test_out port
  [[ -n "$ts" ]] || die "restore requires a timestamp. See: reality list-backups"
  dir="${BACKUP_ROOT}/${ts}"
  [[ -d "$dir" ]] || die "No backup found at ${dir}." "Run 'reality list-backups' to see available timestamps."
  [[ -f "${dir}/config.json" ]] || die "${dir} doesn't contain a config.json -- can't restore from it."
  jq empty "${dir}/config.json" >/dev/null 2>&1 || die "Backed-up config.json at ${dir} is not valid JSON. Not restoring."
  if ! test_out=$(xray run -test -format json -config "${dir}/config.json" 2>&1); then
    err "Backed-up config.json fails Xray's own schema check. Not restoring:"
    echo "$test_out" | sed 's/^/  /' >&2
    exit 1
  fi

  step "restore" "Restoring from backup: ${ts}"
  backup_current_state   # makes the restore itself undoable

  cp -a "${dir}/config.json" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE"
  record_config_checksum
  if [[ -f "${dir}/state" ]]; then cp -a "${dir}/state" "$STATE_FILE"; chmod 600 "$STATE_FILE"; fi
  if [[ -f "${dir}/client-info.txt" ]]; then cp -a "${dir}/client-info.txt" "$CLIENT_INFO_FILE"; chmod 600 "$CLIENT_INFO_FILE"; fi

  # The port may have changed since this backup (change-port closes the old
  # one in UFW), so re-open whatever port we restored to. Idempotent.
  port=$(jq -r '.inbounds[0].port // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ -n "$port" ]] && command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}"/tcp comment 'Xray REALITY' >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
  fi

  load_state   # pick up the restored settings for the handshake check
  restart_and_verify
  echo ""
  echo "Restored from ${ts}. Run 'reality show' to reprint the restored client link."
}

# ---- status ---------------------------------------------------------------
cmd_status() {
  local cc iface qdisc="" banned f2b="NOT loaded" backups=0 reboot="NOT enabled" next
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
  iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n "$iface" ]]; then qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/root/ {print $2; exit}') || true; fi
  if fail2ban-client status sshd >/dev/null 2>&1; then
    banned=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[ \t]/,"",$2); print $2}') || true
    [[ "$banned" =~ ^[0-9]+$ ]] || banned=0
    f2b="loaded (currently banned: ${banned})"
  fi
  if systemctl is-enabled --quiet daily-reboot.timer 2>/dev/null; then
    next=$(systemctl list-timers daily-reboot.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}') || true
    reboot="enabled (next: ${next:-unknown})"
  fi
  if [[ -d "$BACKUP_ROOT" ]]; then backups=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l); fi

  local newer hook="not set"
  newer=$(core_update_available || true)
  if [[ -n "$ALERT_WEBHOOK" ]]; then
    hook="configured"
    if [[ -f "${XRAY_CONFIG_DIR}/.webhook-failed" ]]; then hook="LAST DELIVERY FAILED -- alerts are not reaching you"; fi
  fi
  row() { printf '%-20s: %s\n' "$1" "$2"; }
  echo "=== Xray REALITY status ==="
  echo ""
  row "Service (${SERVICE_NAME})"  "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  row "Xray-core"                  "$(xray_version)${newer:+  (update available: ${newer} -- run: reality update-core)}"
  row "SNI (dest)"                 "${SNI_DOMAIN:-unknown}"
  row "Listen port"                "${LISTEN_PORT:-unknown}"
  row "Fingerprint"                "${FINGERPRINT}"
  row "Congestion control"         "${cc}$([[ "$cc" != bbr ]] && echo ' (expected bbr)' || true)"
  if [[ -n "$iface" ]]; then
    row "qdisc (${iface})"         "${qdisc:-unknown}$([[ "$qdisc" != fq ]] && echo ' (expected fq)' || true)"
  fi
  row "UFW"                        "$(ufw_active && echo active || echo 'NOT active')"
  row "fail2ban sshd jail"         "$f2b"
  row "Daily reboot timer"         "$reboot"
  row "Backups available"          "$backups"
  row "Alert webhook"              "$hook"
  echo ""
  note_stale_ufw "Xray REALITY" "$LISTEN_PORT"
  if [[ -f "$AUDIT_LOG" ]]; then
    echo ""
    echo "Recent activity (last 5 runs):"
    tail -n 5 "$AUDIT_LOG" | sed 's/^/  /'
  fi
}

# ---- health check (runs unattended on reality-watchdog.timer) -------------
# Silent when healthy. One self-heal restart if the service is down or not
# serving; alerts fire only when a condition changes state.
cmd_health_check() {
  local issue="" exit_code=0 kb=0 still_bad=0
  local drift=0 bin_drift=0 low_disk=0 clock=0 sni_bad=0 reboot=0 core_old=0 newer
  local bin_path recorded current pkgs

  # A service that is down ON PURPOSE (`reality stop` / `reality disable`) is not an outage.
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    rm -f "$USER_STOPPED_MARKER"
    if ! port_listening "$LISTEN_PORT"; then
      issue="active but nothing listening on port ${LISTEN_PORT}"
    elif ! tcp_connects "$LISTEN_PORT"; then
      issue="port ${LISTEN_PORT} listening but local TCP connect failed"
    fi
  elif [[ ! -f "$USER_STOPPED_MARKER" ]] && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    issue="service not active"
  fi

  if [[ -n "$issue" ]]; then
    logger -p daemon.warning "reality health-check: ${issue} -- attempting one restart" 2>/dev/null || true
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME" || ! port_listening "$LISTEN_PORT"; then still_bad=1; fi
    if [[ "$still_bad" -eq 1 ]]; then
      err "Health check failed and the self-heal restart did not resolve it: ${issue}"
      exit_code=1
    else
      ok "Issue detected (${issue}) -- restart resolved it."
      logger -p daemon.notice "reality health-check: restart resolved the issue (${issue})" 2>/dev/null || true
    fi
  fi
  alert_on_transition service-down "$still_bad" \
    "health-check: xray.service still unhealthy after a restart attempt (${issue}). Check: journalctl -u xray -e" \
    "xray.service is healthy again"

  # config.json changed outside this script?
  if [[ -f "${XRAY_CONFIG_DIR}/.config.sha256" && -f "$CONFIG_FILE" ]]; then
    if ! (cd "$XRAY_CONFIG_DIR" && sha256sum -c .config.sha256 >/dev/null 2>&1); then drift=1; fi
  fi
  alert_on_transition config-drift "$drift" \
    "health-check: ${CONFIG_FILE} does not match the last known-good checksum. If you didn't hand-edit it, investigate." ""

  # xray binary changed outside install / `reality update-core`?
  bin_path=$(command -v xray 2>/dev/null || true)
  if [[ -f "${XRAY_CONFIG_DIR}/.xray-binary.sha256" && -n "$bin_path" ]]; then
    recorded=$(cat "${XRAY_CONFIG_DIR}/.xray-binary.sha256")
    current=$(sha256sum "$bin_path" | awk '{print $1}')
    if [[ "$recorded" != "$current" ]]; then bin_drift=1; fi
  fi
  alert_on_transition binary-drift "$bin_drift" \
    "health-check: the xray binary (${bin_path}) doesn't match the checksum recorded at install/update. Possible tampering, manual replace, or disk corruption." \
    "xray binary checksum matches the recorded value again"

  kb=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  if [[ "$kb" =~ ^[0-9]+$ ]] && (( kb < 524288 )); then low_disk=1; fi
  alert_on_transition low-disk "$low_disk" \
    "health-check: less than 512MB free on / (found $((${kb:-0} / 1024))MB)." "disk space recovered"

  # REALITY handshakes are timestamp-sensitive.
  if command -v timedatectl >/dev/null 2>&1 && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then clock=1; fi
  alert_on_transition clock-drift "$clock" \
    "health-check: system clock is not NTP-synchronized (REALITY is timestamp-sensitive). See: timedatectl status" \
    "clock is NTP-synchronized again"

  # Camouflage target still serving TLS1.3?
  if [[ -n "$SNI_DOMAIN" ]] && ! sni_ok "$SNI_DOMAIN"; then sni_bad=1; fi
  alert_on_transition sni-broken "$sni_bad" \
    "health-check: REALITY camouflage target ${SNI_DOMAIN} no longer serves TLS1.3 on port 443. Pick another: reality change-sni <domain>" \
    "SNI target ${SNI_DOMAIN} is serving TLS1.3 again"

  # Notify-only: tell the admin a newer Xray-core exists (security fixes land there).
  check_core_update
  if newer=$(core_update_available); then core_old=1; fi
  alert_on_transition core-update "$core_old" \
    "health-check: Xray-core ${newer:-a newer release} is available. Review the release notes, then run: reality update-core" \
    "Xray-core is up to date"

  if [[ -f /var/run/reboot-required ]]; then reboot=1; fi
  pkgs=""
  if [[ "$reboot" -eq 1 && -f /var/run/reboot-required.pkgs ]]; then
    pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs | cut -c1-200)
  fi
  alert_on_transition reboot-required "$reboot" \
    "health-check: a package update needs a reboot${pkgs:+ (${pkgs})}. The daily reboot timer will handle it, or reboot sooner." \
    "pending reboot cleared"

  return "$exit_code"
}

# ---- credentials / settings changes ---------------------------------------
cmd_rotate_uuid() {
  require_install
  step "rotate-uuid" "Rotating UUID + short ID (REALITY keypair unchanged)"
  backup_current_state
  generate_uuid_and_shortid
  write_config
  finish_and_restart
  echo ""
  echo "Old client link is now invalid. Any device using it must import the new link above."
}

cmd_rotate_all() {
  require_install
  local answer=""
  if [[ -t 0 && "$FORCE" -ne 1 ]]; then
    echo ""
    warn "This invalidates EVERY existing client link. Not undoable except by: reality restore"
    read -r -t 300 -p "Type 'yes' to continue: " answer || true
    if [[ "$answer" != "yes" ]]; then
      echo "Cancelled. No changes made."
      return 0
    fi
  elif [[ ! -t 0 && "$FORCE" -ne 1 ]]; then
    die "rotate-all invalidates EVERY existing client link and there's no terminal to confirm on." \
        "Re-run with: reality rotate-all --force   if this is intentional."
  fi
  step "rotate-all" "Rotating ALL credentials (UUID, short ID, REALITY keypair)"
  backup_current_state
  generate_uuid_and_shortid
  generate_reality_keypair
  write_config
  finish_and_restart
  echo ""
  echo "All previous client links are now permanently invalid."
}

# change-sni <domain> [--force]: only the camouflage target; keys unchanged.
cmd_change_sni() {
  require_install
  local new
  new=$(clean_domain "$1")
  [[ -n "$new" ]] || die "Usage: reality change-sni <domain>   (add --force to skip the live TLS1.3 check)"
  valid_domain "$new" || die "'${new}' is not a valid hostname (letters, digits, hyphens and dots only; not an IP address)."
  if [[ "$new" == "$SNI_DOMAIN" ]]; then
    echo "That's already the current SNI ('${SNI_DOMAIN}'). No changes made."
    return 0
  fi
  if ! sni_ok "$new"; then
    if [[ "$FORCE" -ne 1 ]]; then
      die "Could not verify that '${new}' serves TLS1.3 on port 443." \
          "Use it anyway with: reality change-sni ${new} --force"
    fi
    warn "Could not verify TLS1.3 for '${new}', proceeding anyway (--force)."
  fi
  step "change-sni" "Changing REALITY SNI: ${SNI_DOMAIN} -> ${new}"
  backup_current_state
  SNI_DOMAIN="$new"
  write_config
  finish_and_restart
  echo ""
  echo "Old client link is now invalid (REALITY serverName mismatch). Import the new link above."
}

# change-fingerprint <value>: client-side only -- no config change, no restart.
cmd_change_fingerprint() {
  require_install
  local new="$1"
  [[ -n "$new" ]] || die "Usage: reality change-fingerprint <value>" "Valid values: ${FINGERPRINTS}"
  valid_fp "$new" || die "Unknown fingerprint '${new}'." "Valid values: ${FINGERPRINTS}"
  if [[ "$new" == "$FINGERPRINT" ]]; then
    echo "That's already the current fingerprint ('${FINGERPRINT}'). No changes made."
    return 0
  fi
  FINGERPRINT="$new"
  save_state
  output_client_info
  echo ""
  ok "Fingerprint changed to '${FINGERPRINT}'. No restart needed -- re-import the link above to use it."
}

# change-port <port>: ordered to fail safe -- the new UFW rule is added first and
# the old one removed only after Xray is confirmed healthy on the new port, so a
# failure leaves both ports open rather than neither.
cmd_change_port() {
  require_install
  local new="$1" old="$LISTEN_PORT" holder
  [[ -n "$new" ]] || die "Usage: reality change-port <port>"
  valid_port "$new" || die "Port must be a number between 1 and 65535 (got: '${new}')."
  if [[ "$new" == "$old" ]]; then
    echo "That's already the current port ('${old}'). No changes made."
    return 0
  fi
  # Xray is bound to the OLD port, so anything on the new one is unrelated.
  holder=$(ss -tlnp 2>/dev/null | awk -v p=":${new}\$" '$4 ~ p {print}')
  if [[ -n "$holder" ]]; then
    err "Port ${new} is already in use:"
    echo "$holder" | sed 's/^/  /' >&2
    exit 1
  fi

  step "change-port" "Changing Xray listen port: ${old} -> ${new}"
  backup_current_state
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${new}"/tcp comment 'Xray REALITY' || die "Failed to add a UFW rule for port ${new}. Nothing else was changed."
  fi
  LISTEN_PORT="$new"
  write_config
  finish_and_restart   # exits on failure, so the old rule below is only removed on success

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${old}"/tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
  fi
  echo ""
  echo "Old client link is now invalid (port changed). Import the new link above."
}

# ===========================================================================
# Install (no prompts; safe to re-run)
# ===========================================================================

install_systemd_hardening() {
  local conf="/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf" tmp verify
  mkdir -p "$(dirname "$conf")"
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
[Unit]
OnFailure=xray-alert.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=xray
Group=xray
Restart=on-failure
RestartSec=5
LimitCORE=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/xray
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
# List-type settings MERGE across the base unit and drop-ins, so reset the
# inherited capabilities first; Xray only needs CAP_NET_BIND_SERVICE.
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectProc=invisible
RestrictNamespaces=true
RestrictRealtime=true
RemoveIPC=true
RestrictAddressFamilies=AF_INET AF_INET6
UMask=0077
PrivateDevices=true
ProcSubset=pid
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
EOF
  if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
  else
    OVERRIDE_CONF_CHANGED=1
    mv -f "$tmp" "$conf"
    chmod 644 "$conf"
  fi

  # Fires once the restart budget (StartLimitBurst) is exhausted.
  cat > /etc/systemd/system/xray-alert.service <<'EOF'
[Unit]
Description=Local alert when xray.service exhausts its restart attempts

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/bin/reality --send-alert "xray.service has FAILED and exhausted its restart attempts -- check: journalctl -u xray -e" || { logger -p daemon.crit "xray.service has FAILED and exhausted its restart attempts -- check: journalctl -u xray -e"; wall "WARNING: xray.service has failed and given up restarting. Check: journalctl -u xray -e"; }'
EOF

  if command -v systemd-analyze >/dev/null 2>&1; then
    # The base unit's User=nobody warning is expected (our drop-in overrides it).
    verify=$(systemd-analyze verify "${SERVICE_NAME}.service" xray-alert.service 2>&1 | grep -v "Special user nobody configured" || true)
    if [[ -n "$verify" ]]; then
      warn "systemd-analyze flagged potential issues with the unit files:"
      echo "$verify" | sed 's/^/  /' >&2
    fi
  fi
  # Register now; the single restart happens at the very end of the install.
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

install_firewall() {
  SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1 || true)
  SSH_PORT="${SSH_PORT:-22}"

  note_stale_ufw "SSH" "$SSH_PORT"
  note_stale_ufw "Xray REALITY" "$LISTEN_PORT"

  # Make UFW filter IPv6 too, or a public IPv6 address stays unfiltered.
  if [[ -f /etc/default/ufw ]] && grep -qE '^IPV6=no' /etc/default/ufw; then
    sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
    echo "Enabled IPv6 support in UFW."
  fi
  ufw default deny incoming
  ufw default allow outgoing
  # Both rules are load-bearing: a failure must stop the script.
  ufw allow "${SSH_PORT}"/tcp comment 'SSH' \
    || die "Failed to add the UFW rule for SSH port ${SSH_PORT}. Not enabling the firewall." \
           "Fix manually, then re-run: ufw allow ${SSH_PORT}/tcp && ufw --force enable"
  ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY' \
    || die "Failed to add the UFW rule for Xray port ${LISTEN_PORT}. Not enabling the firewall."
  ufw --force enable
  ufw reload
  ufw_active || die "UFW did not report active after enabling." "Check: ufw status verbose"
}

install_fail2ban() {
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
bantime = 1h
findtime = 10m
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  sleep 1
  if ! systemctl is-active --quiet fail2ban; then
    warn "fail2ban did not come up; SSH brute-force protection is NOT active. Check: journalctl -u fail2ban -e"
  elif ! fail2ban-client status sshd >/dev/null 2>&1; then
    warn "fail2ban is running but the sshd jail did not load. Check: fail2ban-client status"
  fi
}

install_kernel_and_logging() {
  local cc iface qdisc

  # sysctl doesn't trigger module loading, so load tcp_bbr via modules-load.d too.
  modprobe tcp_bbr 2>/dev/null || true
  mkdir -p /etc/modules-load.d
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

  cat > /etc/sysctl.d/99-xray-hardening.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Basic network hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.default.accept_source_route = 0

# Restrict ptrace to direct child processes only
kernel.yama.ptrace_scope = 1

# Throughput/latency tuning for a proxy
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# Extra hardening (all safe defaults on any modern kernel)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
net.ipv4.tcp_rfc1337 = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 2
EOF
  # Keys unknown to an older kernel just print an error; they must not abort the install.
  sysctl --system >/dev/null 2>&1 || warn "sysctl reported errors for some keys (older kernel?). Check: sysctl --system"

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
  if [[ "$cc" != "bbr" ]]; then
    warn "Requested BBR but the kernel reports '${cc}' (tcp_bbr module unavailable?). Not fatal, just slower."
  fi

  # default_qdisc doesn't change an interface that is already up; BBR wants fq
  # for pacing, so apply it live.
  iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}') || true
  if [[ -n "$iface" ]]; then
    qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/root/ {print $2; exit}') || true
    if [[ "$qdisc" != "fq" ]]; then
      if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
        ok "Applied fq qdisc live to ${iface} (was: ${qdisc:-unknown})."
      else
        warn "Could not apply fq qdisc live to ${iface}; it takes effect after the next reboot."
      fi
    fi
  fi

  # REALITY handshakes are timestamp-sensitive: make sure NTP is on.
  if command -v timedatectl >/dev/null 2>&1 && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
    sleep 2
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
      warn "System clock is not confirmed NTP-synchronized; check: timedatectl status"
    fi
  fi

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-xray-hardening.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  systemctl restart systemd-journald

  mkdir -p /etc/logrotate.d
  cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/error.log {
  weekly
  rotate 4
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
  cat > /etc/logrotate.d/reality-setup <<EOF
${AUDIT_LOG} {
  monthly
  rotate 6
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF
}

install_daily_reboot() {
  # RandomizedDelaySec spreads reboots over ~30min so installs of this public
  # script don't all reboot in lockstep.
  cat > /etc/systemd/system/daily-reboot.service <<'EOF'
[Unit]
Description=Daily scheduled reboot

[Service]
Type=oneshot
ExecStart=/sbin/shutdown -r now "Scheduled daily reboot"
EOF
  cat > /etc/systemd/system/daily-reboot.timer <<'EOF'
[Unit]
Description=Daily reboot at midnight

[Timer]
OnCalendar=*-*-* 00:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now daily-reboot.timer
}

# Install a copy of this script as `reality` (a copy, not a symlink, so it
# survives the original being moved). Falls back to downloading when $0 isn't a
# real file (e.g. `bash <(curl ...)`).
install_shortcut() {
  local self target tmp
  self=$(readlink -f "$0" 2>/dev/null || echo "$0")
  target=$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")
  if [[ "$self" == "$target" ]]; then
    chown root:root "$REALITY_SHORTCUT" 2>/dev/null || true
    chmod 755 "$REALITY_SHORTCUT"
  elif [[ -f "$self" ]]; then
    install -m 755 -o root -g root "$self" "$REALITY_SHORTCUT"
  else
    tmp=$(mktemp)
    if curl -fsSL --connect-timeout 10 --max-time 30 "$SCRIPT_SOURCE_URL" -o "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
      install -m 755 -o root -g root "$tmp" "$REALITY_SHORTCUT"
      rm -f "$tmp"
    else
      rm -f "$tmp"
      warn "Could not install the 'reality' command (not run from a file, and re-downloading failed)."
      echo "         Add it manually: curl -fsSL ${SCRIPT_SOURCE_URL} -o ${REALITY_SHORTCUT} && chmod +x ${REALITY_SHORTCUT}" >&2
    fi
  fi
}

# Watchdog timer, login banner, security-only unattended upgrades.
install_automation() {
  local unit

  # Older versions installed an Xray-core auto-update timer and a backup
  # dedupe timer. Xray-core is no longer updated automatically: remove them.
  for unit in reality-autoupdate reality-backup-maintenance; do
    systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service"
  done

  if [[ -x "$REALITY_SHORTCUT" ]]; then
    cat > /etc/systemd/system/reality-watchdog.service <<EOF
[Unit]
Description=Periodic Xray REALITY health check

[Service]
Type=oneshot
ExecStart=${REALITY_SHORTCUT} --health-check
EOF
    cat > /etc/systemd/system/reality-watchdog.timer <<'EOF'
[Unit]
Description=Run reality health check every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now reality-watchdog.timer >/dev/null 2>&1 \
      || warn "Could not enable the watchdog timer. Check: systemctl list-timers 'reality-*'"
    ok "Watchdog timer enabled (health check every 10 minutes)."
  else
    warn "Skipping the watchdog timer: the 'reality' command isn't in place (see above)."
  fi

  mkdir -p /etc/update-motd.d
  cat > /etc/update-motd.d/99-xray-reality <<EOF
#!/bin/sh
${REALITY_SHORTCUT} --status 2>/dev/null | head -n 25
echo ""
echo "  Run 'reality' for the management menu."
EOF
  chmod +x /etc/update-motd.d/99-xray-reality

  # Security updates only: avoids uncoordinated package churn on a proxy box.
  if dpkg -l unattended-upgrades >/dev/null 2>&1; then
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/51-xray-security-only <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
    ok "Configured unattended-upgrades for security-only updates."
  fi
}

cmd_install() {
  local disk_kb apt=(apt-get -o DPkg::Lock::Timeout=300) holder doh_bad="" host code

  valid_port "$LISTEN_PORT" || die "LISTEN_PORT must be a number between 1 and 65535 (got: '${LISTEN_PORT}')."
  valid_fp "$FINGERPRINT"   || die "FINGERPRINT must be one of: ${FINGERPRINTS} (got: '${FINGERPRINT}')."
  command -v apt-get >/dev/null 2>&1 || die "This script only supports Debian/Ubuntu (apt-based) systems."
  disk_kb=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  if [[ "$disk_kb" =~ ^[0-9]+$ ]] && (( disk_kb < 1048576 )); then
    die "Less than 1GB free on / (found $((disk_kb / 1024))MB)." \
        "Free up space first (e.g. 'apt autoremove --purge -y'), then re-run."
  fi

  step "1/10" "Preparing server (updates, cleanup, essential tools)"
  export DEBIAN_FRONTEND=noninteractive
  # Lock timeout: fresh VPSes often have unattended-upgrades holding dpkg for minutes.
  "${apt[@]}" update -y
  "${apt[@]}" upgrade -y
  "${apt[@]}" autoremove -y --purge
  "${apt[@]}" autoclean -y
  # unzip is needed by the official Xray installer.
  "${apt[@]}" install -y --no-install-recommends curl unzip jq openssl qrencode ufw fail2ban ca-certificates
  if ! "${apt[@]}" install -y --no-install-recommends logrotate; then
    echo "NOTE: logrotate was unavailable; Xray's error log won't be rotated until it's installed."
  fi
  if [[ -f /var/run/reboot-required ]]; then
    echo "NOTE: A previous update marked this system as needing a reboot (the daily reboot timer will handle it)."
  fi

  step "2/10" "Installing Xray-core (official installer)"
  mkdir -p "$XRAY_CONFIG_DIR"
  if command -v xray >/dev/null 2>&1; then
    ok "Xray-core already installed ($(xray_version)) -- not updating. Use 'reality update-core' to update."
  else
    install_xray_core || die "Failed to install Xray-core after 3 attempts (likely a network issue reaching GitHub)."
    record_xray_binary_checksum force
  fi
  ensure_xray_log_permissions
  record_xray_binary_checksum   # warns (never overwrites) if the binary no longer matches the record

  step "3/10" "Settings and credentials"
  if [[ -z "$UUID" || -z "$SNI_DOMAIN" ]]; then choose_sni; fi
  echo "SNI: ${SNI_DOMAIN} | port: ${LISTEN_PORT} | fingerprint: ${FINGERPRINT}"
  echo "(Change any of these later: run 'reality' -> Reality settings.)"
  if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
    echo "Existing credentials found -- reusing them (client links stay valid)."
  else
    echo "Generating new credentials (first-time install)."
    generate_uuid_and_shortid
    generate_reality_keypair
  fi
  # Unprivileged account the service runs as (see the systemd drop-in below).
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
  fi
  # A listener that is our own xray is fine; anything else is a real conflict.
  holder=$(ss -tlnp 2>/dev/null | awk -v p=":${LISTEN_PORT}\$" '$4 ~ p {print}')
  if [[ -n "$holder" && "${holder,,}" != *xray* ]]; then
    err "Port ${LISTEN_PORT} is already in use by something other than Xray:"
    echo "$holder" | sed 's/^/  /' >&2
    die "Stop that service first, or pick another port (LISTEN_PORT=... on a first install, or 'reality change-port')."
  fi
  save_state

  step "4/10" "Writing Xray config (privacy-minded: no access logging)"
  write_config
  ok "Config written and validated"
  # Some networks block DoH; warn if the configured resolvers are unreachable.
  for host in 1.1.1.1 9.9.9.9; do
    code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://${host}/dns-query" 2>/dev/null) || code=000
    if [[ "$code" == "000" ]]; then doh_bad+="${host} "; fi
  done
  if [[ -n "$doh_bad" ]]; then
    warn "Could not reach the configured DoH server(s): ${doh_bad}"
    echo "         Xray's domain-based routing may fail; edit the \"dns\" block in ${CONFIG_FILE} if so." >&2
  fi

  step "5/10" "Hardening the systemd service"
  install_systemd_hardening

  step "6/10" "Configuring firewall (UFW)"
  install_firewall

  step "7/10" "Configuring fail2ban for SSH brute-force protection"
  install_fail2ban

  step "8/10" "Enabling BBR, kernel hardening, NTP and log limits"
  install_kernel_and_logging

  step "9/10" "Setting up daily reboot at midnight"
  install_daily_reboot

  step "10/10" "Installing the 'reality' command, watchdog and login summary"
  install_shortcut
  install_automation

  # Print everything first; restart xray as the last action.
  save_state
  output_client_info
  echo ""
  echo "Setup complete. Server will reboot daily at ~00:00 (+/-30min jitter, server local time)."
  echo "Check timezone with: timedatectl   (change with: timedatectl set-timezone <Region/City>)"
  echo "Cancel the daily reboot with: systemctl disable --now daily-reboot.timer"
  echo "Xray-core is not updated automatically; run 'reality update-core' when you want to."
  echo ""
  echo "Management command installed -- run ${C_BOLD}reality${C_RESET} for the interactive menu,"
  echo "or use the subcommands below."
  usage

  step "final" "Restarting Xray"
  if [[ "$CONFIG_CHANGED" -eq 0 && "$OVERRIDE_CONF_CHANGED" -eq 0 ]] && systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Nothing changed (config identical, service already running) -- skipping restart."
    verify_handshake
  else
    restart_and_verify
  fi
}

# ===========================================================================
# Interactive menu (every action re-runs this script, so menu and CLI can't drift)
# ===========================================================================
MENU_SELF=""

menu_pause()   { local _x=""; echo ""; read -r -p "${C_YELLOW}Press enter to continue: ${C_RESET}" _x || true; }
menu_run()     { "$MENU_SELF" "$@" || true; }   # a failing action must not kill the menu
menu_row()     { box_line "$(printf '%s%3s.%s %s' "$C_GREEN" "$1" "$C_RESET" "$2")"; }
menu_confirm() { local a=""; read -r -p "$1 [y/N]: " a || true; [[ "$a" =~ ^[Yy]$ ]]; }

menu_status() {
  local state boot
  load_state   # actions run as separate processes, so re-read saved state
  if systemctl is-active --quiet "$SERVICE_NAME"; then state="${C_GREEN}Running${C_RESET}"; else state="${C_RED}Not running${C_RESET}"; fi
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then boot="${C_GREEN}Yes${C_RESET}"; else boot="${C_RED}No${C_RESET}"; fi
  echo "Xray state:      ${state}"
  echo "Start on boot:   ${boot}"
  echo "Xray-core:       $(xray_version)$(core_update_available >/dev/null && echo "   ${C_YELLOW}(update available: $(core_update_available))${C_RESET}" || true)"
  echo "SNI / port:      ${SNI_DOMAIN} / ${LISTEN_PORT}   (fingerprint: ${FINGERPRINT})"
  if [[ -f "$USER_STOPPED_MARKER" ]]; then
    echo "${C_YELLOW}Stopped manually: the watchdog won't restart it. Choose 'Start' to bring it back.${C_RESET}"
  fi
}

# ---- Reality settings submenu: the only place SNI / port / fingerprint are asked for ----
menu_change_sni() {
  local d
  read -r -p "New SNI domain [current: ${SNI_DOMAIN}; empty to cancel]: " d || true
  d=$(clean_domain "$d")
  if [[ -z "$d" ]]; then echo "Cancelled."; return 0; fi
  if ! valid_domain "$d"; then err "'${d}' is not a valid hostname (letters, digits, hyphens and dots only; not an IP)."; return 0; fi
  if sni_ok "$d"; then
    ok "Confirmed: ${d} resolves and serves TLS1.3 on port 443."
  else
    warn "Couldn't confirm ${d} serves TLS1.3 on port 443 (DNS failure, no response, or no TLS1.3). REALITY needs it."
    menu_confirm "Use it anyway?" || { echo "Cancelled."; return 0; }
  fi
  menu_run --change-sni "$d" --force   # already verified/confirmed above
}

menu_change_port() {
  local p
  read -r -p "New port [current: ${LISTEN_PORT}; empty to cancel]: " p || true
  if [[ -z "$p" ]]; then echo "Cancelled."; return 0; fi
  if ! valid_port "$p"; then err "Port must be a number between 1 and 65535."; return 0; fi
  menu_run --change-port "$p"
}

menu_change_fingerprint() {
  local fp
  echo "Valid: ${FINGERPRINTS}"
  read -r -p "New fingerprint [current: ${FINGERPRINT}; empty to cancel]: " fp || true
  if [[ -z "$fp" ]]; then echo "Cancelled."; return 0; fi
  menu_run --change-fingerprint "$fp"
}

menu_reality() {
  local choice
  while true; do
    load_state
    echo ""
    box_top
    box_line "${C_GREEN}Reality settings${C_RESET}"
    box_sep
    box_line "SNI (camouflage domain) : ${SNI_DOMAIN}"
    box_line "Listen port             : ${LISTEN_PORT}"
    box_line "Client fingerprint      : ${FINGERPRINT}"
    box_sep
    menu_row 1 "Change SNI (camouflage domain)"
    menu_row 2 "Change port"
    menu_row 3 "Change client fingerprint"
    menu_row 4 "Rotate UUID (revoke the current client link)"
    menu_row 5 "Rotate ALL credentials (UUID + keys)"
    menu_row 0 "Back to main menu"
    box_bot
    echo ""
    choice=""
    read -r -p "Please enter your selection [0-5]: " choice || return 0
    case "$choice" in
      0) return 0 ;;
      1) menu_change_sni; menu_pause ;;
      2) menu_change_port; menu_pause ;;
      3) menu_change_fingerprint; menu_pause ;;
      4)
        if menu_confirm "Rotate the UUID? The current client link stops working."; then menu_run --rotate-uuid; fi
        menu_pause ;;
      5) menu_run --rotate-all; menu_pause ;;   # asks for its own 'yes'
      *) warn "Please enter a number between 0 and 5."; sleep 1 ;;
    esac
  done
}

menu_backups() {
  local sub ts
  echo ""
  echo "  1. List backups"
  echo "  2. Restore a backup"
  echo "  0. Back"
  read -r -p "Selection [0-2]: " sub || true
  case "$sub" in
    1) menu_run --list-backups ;;
    2)
      menu_run --list-backups
      read -r -p "Timestamp to restore (as listed above, empty to cancel): " ts || true
      if [[ -n "$ts" ]] && menu_confirm "Restore ${ts}? (the current state is backed up first)"; then
        menu_run --restore "$ts"
      fi ;;
    *) ;;
  esac
}

cmd_menu() {
  [[ -t 0 && -t 1 ]] || die "The menu needs an interactive terminal. Run 'reality help' to see the subcommands."
  if [[ -x "$REALITY_SHORTCUT" ]]; then
    MENU_SELF="$REALITY_SHORTCUT"
  elif [[ -f "$0" ]]; then
    MENU_SELF="$(readlink -f "$0")"
  else
    die "Can't find the installed 'reality' command to run menu actions with. Run a full install first."
  fi

  local choice hook
  while true; do
    echo ""
    box_top
    box_line "${C_GREEN}Xray REALITY Management Script${C_RESET}"
    menu_row 0 "Exit"
    box_sep
    menu_row 1 "Install / re-apply full setup"
    menu_row 2 "Update this script"
    menu_row 3 "Update Xray-core (manual)"
    menu_row 4 "Uninstall"
    box_sep
    menu_row 5 "Show client link + QR code"
    menu_row 6 "Reality settings (SNI, port, fingerprint, keys)"
    box_sep
    menu_row 7 "Start"
    menu_row 8 "Stop"
    menu_row 9 "Restart"
    menu_row 10 "Check status"
    menu_row 11 "View logs"
    menu_row 12 "Enable autostart on boot"
    menu_row 13 "Disable autostart on boot"
    box_sep
    menu_row 14 "Run health check now"
    menu_row 15 "Alert webhook"
    menu_row 16 "Backups (list / restore)"
    box_bot
    echo ""
    menu_status
    echo ""

    choice=""
    if ! read -r -p "Please enter your selection [0-16]: " choice; then
      echo ""
      return 0   # EOF (Ctrl-D)
    fi

    case "$choice" in
      0) return 0 ;;
      1)
        if menu_confirm "Re-apply the full setup now (credentials are kept)?"; then menu_run --install; fi
        menu_pause ;;
      2) menu_run --update; menu_pause ;;
      3) menu_run --update-core; menu_pause ;;
      4)
        menu_run --uninstall
        if [[ ! -x "$MENU_SELF" ]]; then return 0; fi   # uninstalled: nothing left to run
        menu_pause ;;
      5) menu_run --show; menu_pause ;;
      6) menu_reality ;;
      7) menu_run --start; menu_pause ;;
      8) menu_run --stop; menu_pause ;;
      9) menu_run --restart; menu_pause ;;
      10) menu_run --status; menu_pause ;;
      11) menu_run --logs; menu_pause ;;
      12) menu_run --enable-autostart; menu_pause ;;
      13) menu_run --disable-autostart; menu_pause ;;
      14)
        # The check prints nothing when healthy, so say so explicitly.
        if "$MENU_SELF" --health-check; then
          ok "Health check finished: nothing needs attention (it prints nothing when healthy)."
        else
          warn "The health check reported a problem -- see above, or run: reality log"
        fi
        menu_pause ;;
      15)
        hook=""
        read -r -p "Webhook URL for alerts (leave empty to clear it): " hook || true
        if [[ -n "$hook" ]]; then
          menu_run --set-webhook "$hook"
        elif menu_confirm "Clear the alert webhook?"; then
          menu_run --set-webhook ""
        fi
        menu_pause ;;
      16) menu_backups; menu_pause ;;
      *) warn "Please enter a number between 0 and 16."; sleep 1 ;;
    esac
  done
}

# ===========================================================================
# Entry point
# ===========================================================================
BARE=0
if [[ $# -eq 0 ]]; then BARE=1; fi

# --force / --yes may appear anywhere; everything else is positional.
FORCE=0
ARGS=()
for _a in "$@"; do
  case "$_a" in
    --force|--yes) FORCE=1 ;;
    *) ARGS+=("$_a") ;;
  esac
done
CMD="${ARGS[0]:-}"
ARG="${ARGS[1]:-}"

# Subcommands work with or without leading dashes (`reality status` / `--status`).
CMD="${CMD#--}"
case "$CMD" in
  "")                           CMD=install ;;
  -h)                           CMD=help ;;
  enable-autostart)             CMD=enable ;;
  disable-autostart)            CMD=disable ;;
  log)                          CMD=logs ;;
  update-xray|update-core-only) CMD=update-core ;;
  *) ;;
esac
case "$CMD" in
  install|menu|start|stop|restart|enable|disable|logs|update|update-core|uninstall|\
  rotate-uuid|rotate-all|change-sni|change-fingerprint|change-port|show|\
  list-backups|restore|status|health-check|set-webhook|send-alert) ;;
  help) usage; exit 0 ;;
  *) err "Unknown argument '${ARGS[0]}'."; usage >&2; exit 1 ;;
esac

# Bare `reality` in a terminal on an existing install opens the menu. Anything
# else (cloud-init, cron, `curl | bash`, a downloaded copy) keeps installing.
if [[ "$CMD" == install && "$BARE" -eq 1 && -t 0 && -t 1 && -f "$STATE_FILE" ]]; then
  if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" == "$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")" ]]; then
    CMD=menu
  fi
fi

# One audit line per run (also on early failures). The menu is only a launcher
# and uninstall deletes the log itself, so neither is logged.
log_run_outcome() {
  local rc=$? outcome=success host
  case "$CMD" in menu|uninstall|logs) return 0 ;; esac
  if [[ "$rc" -ne 0 ]]; then outcome="failed(exit ${rc})"; fi
  echo "$(date -Is) mode=${CMD} outcome=${outcome}" >> "$AUDIT_LOG" 2>/dev/null || true
  # Unattended installs: tell the webhook how it went.
  if [[ "$CMD" == install && -n "$ALERT_WEBHOOK" ]]; then
    host=$(hostname 2>/dev/null || echo unknown-host)
    post_webhook "{\"host\":\"${host}\",\"message\":\"reality install finished: ${outcome}\"}" || true
  fi
}
trap log_run_outcome EXIT

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# Prevent concurrent runs. The menu and `logs` don't lock (the menu only
# launches other runs, each of which locks itself); the timer-driven
# health-check waits briefly instead of failing on a collision.
exec 200>"$LOCK_FILE"
case "$CMD" in
  menu|logs) ;;
  health-check) flock -w 30 200 || die "Another run is in progress (lock: ${LOCK_FILE})." ;;
  *) flock -n 200 || die "Another run is in progress (lock: ${LOCK_FILE})." \
                         "Wait for it to finish, or remove the lock if nothing is running: rm -f ${LOCK_FILE}" ;;
esac

case "$CMD" in install|uninstall|send-alert|menu) ;; *)
  command -v xray >/dev/null 2>&1 || die "Xray is not installed yet. Run the script with no arguments first."
esac

# Tools each config-changing command actually uses.
case "$CMD" in
  rotate-uuid|rotate-all|change-sni|change-port|restore)
    for _dep in jq openssl; do
      command -v "$_dep" >/dev/null 2>&1 || die "Required tool '${_dep}' is missing." "Reinstall it with: apt-get install -y ${_dep}"
    done ;;
  *) ;;
esac

load_state
case "$CMD" in uninstall|send-alert) ;; *) validate_state ;; esac

case "$CMD" in
  install)            cmd_install ;;
  menu)               cmd_menu ;;
  show)               cmd_show ;;
  status)             cmd_status ;;
  start)              cmd_start ;;
  stop)               cmd_stop ;;
  restart)            cmd_restart ;;
  enable)             cmd_enable ;;
  disable)            cmd_disable ;;
  logs)               cmd_logs "$ARG" ;;
  update)             cmd_update ;;
  update-core)        cmd_update_core ;;
  uninstall)          cmd_uninstall ;;
  rotate-uuid)        cmd_rotate_uuid ;;
  rotate-all)         cmd_rotate_all ;;
  change-sni)         cmd_change_sni "$ARG" ;;
  change-fingerprint) cmd_change_fingerprint "$ARG" ;;
  change-port)        cmd_change_port "$ARG" ;;
  list-backups)       cmd_list_backups ;;
  restore)            cmd_restore "$ARG" ;;
  health-check)       cmd_health_check ;;
  set-webhook)        cmd_set_webhook "$ARG" ;;
  send-alert)         cmd_send_alert "$ARG" ;;
  *)                  die "Unhandled command '${CMD}'." ;;
esac
