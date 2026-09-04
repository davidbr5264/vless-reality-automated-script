#!/usr/bin/env bash
#
# setup-xray-reality.sh
#
# Automated installer / manager for a hardened Xray VLESS-TCP-XTLS-Vision-REALITY
# instance on a Debian/Ubuntu VPS, for personal use.
#
# Usage:
#   ./setup-xray-reality.sh                Install (or re-apply) full setup
#   ./setup-xray-reality.sh --rotate-uuid  Replace UUID + short ID only
#                                           (keeps REALITY keypair; use this to
#                                           revoke a leaked client link without
#                                           regenerating your server's identity)
#   ./setup-xray-reality.sh --rotate-all   Replace UUID + short ID + REALITY
#                                           keypair (invalidates ALL client links)
#   ./setup-xray-reality.sh --change-sni [domain]
#                                           Change only the REALITY camouflage
#                                           target (SNI) -- keeps UUID, short
#                                           ID, and keypair unchanged. Prompts
#                                           interactively if domain is omitted;
#                                           requires one non-interactively. The
#                                           new domain gets the same live
#                                           TLS1.3 check as install (add
#                                           --force to skip it). Still
#                                           invalidates existing client links
#                                           (server name has to match).
#   ./setup-xray-reality.sh --show         Reprint the current client link/QR
#                                           without changing anything
#   ./setup-xray-reality.sh --list-backups List available backups with timestamps
#   ./setup-xray-reality.sh --dedupe-backups Remove redundant backups where a
#                                           consecutive run has identical config
#                                           (keeps the most recent of each run)
#   ./setup-xray-reality.sh --restore TS   Restore config/state from a backup
#                                           (backs up current state first)
#   ./setup-xray-reality.sh --status       Consolidated health check: BBR, qdisc,
#                                           UFW, fail2ban jail, reboot timer,
#                                           backup count, last update check
#   ./setup-xray-reality.sh --health-check Verify the service is actually
#                                           serving (not just "active"); auto-
#                                           restart once if not, then alert.
#                                           Meant to be run on a timer -- see
#                                           the reality-watchdog.timer unit.
#   ./setup-xray-reality.sh --update-core-only
#                                           Check for and apply an Xray-core
#                                           update only, independent of a full
#                                           re-run. Restarts the service only
#                                           if the binary actually changed.
#   ./setup-xray-reality.sh --rotate-all --force
#                                           Same as --rotate-all, but skips
#                                           the interactive confirmation
#                                           prompt (required when there's no
#                                           TTY, e.g. run from cron/CI).
#   ./setup-xray-reality.sh --set-webhook <url>
#                                           Send critical alerts (health-check
#                                           giving up, service restart-budget
#                                           exhausted) to a webhook URL too,
#                                           not just local logger/wall. Sends
#                                           a test alert immediately. Run
#                                           with an empty URL to clear it:
#                                           --set-webhook ""
#   ./setup-xray-reality.sh --help         Show this help
#
# Unattended timers (installed automatically by a full install, see step 10):
#   reality-watchdog.timer      every 10 min  -> --health-check
#   reality-autoupdate.timer    weekly        -> --update-core-only
#   reality-backup-maintenance.timer  weekly  -> --dedupe-backups
# All three are ordinary systemd timers; inspect/disable with the usual
# systemctl commands (e.g. `systemctl disable --now reality-watchdog.timer`).
#
# What a full install does:
#   1. Prepares the server: full apt update/upgrade, cleanup, essential tools
#   2. Installs latest official Xray-core (XTLS/Xray-install)
#   3. Generates UUID, REALITY x25519 keypair, and a short ID
#   4. Writes a minimal-logging config.json (VLESS + TCP + XTLS-Vision + REALITY)
#      camouflaged as a real site (randomly picked from a small pool of
#      YouTube/Google-owned domains, live-verified -- see SNI_POOL below)
#   5. Locks the systemd unit down (NoNewPrivileges, ProtectSystem, etc.)
#   6. Configures UFW (only SSH + Xray port open) and fail2ban for sshd
#   7. Enables BBR + fq congestion control, applies basic sysctl hardening
#   8. Schedules a daily reboot at midnight (server local time)
#   9. Prints a ready-to-import vless:// link + QR code
#  10. Installs unattended reliability timers (health-check watchdog,
#      Xray-core auto-update, config-drift check) and a login banner
#
# Re-running (install or any --rotate mode) automatically backs up the
# previous config + client info under /root/xray-backups/<timestamp>/
# before making changes, so nothing is silently lost.
#
# Environment variable overrides (only take effect on a genuinely
# first-time install -- once state exists, re-runs always keep whatever's
# already saved, and a mismatched env var just prints a warning that it
# was ignored rather than silently changing a running install):
#   SNI_DOMAIN            REALITY camouflage target (default: random pick
#                          from SNI_POOL, live-verified)
#   LISTEN_PORT            Xray listen port (default: 443)
#   FINGERPRINT            uTLS ClientHello fingerprint (default: random)
#   REALITY_ALERT_WEBHOOK  webhook URL for critical alerts (default: unset;
#                          same as running --set-webhook <url> after install)
#   SCRIPT_SOURCE_URL      where the self-update check and 'reality'
#                          shortcut fallback re-download from (default:
#                          this script's own GitHub repo)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Terminal output helpers (plain text, no color/animation)
# ---------------------------------------------------------------------------
step() {
  echo ""
  echo "=== [$1] $2 ==="
}

ok()   { echo "  OK: $1"; }
warn() { echo "  WARNING: $1" >&2; }
err()  { echo "  ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Configuration (edit if needed, or override via environment variables)
# ---------------------------------------------------------------------------
SNI_DOMAIN_ENV_OVERRIDE="${SNI_DOMAIN:-}"
# Pool of conservative, well-established YouTube/Google-owned static-asset
# subdomains -- same risk profile as the original single default (TLS1.3,
# not a mega-CDN edge like google.com/microsoft.com itself, low anti-bot
# friction), but randomized per fresh install so every install of this
# public script doesn't converge on one identical, easily-cataloged SNI.
# Live-verified below regardless (see the SNI check further down, which
# now also runs for non-interactive installs, not just interactive ones)
# and always overridable -- interactively, via SNI_DOMAIN=..., or later
# via --rotate-all.
#
# Deliberately excludes anything under googlevideo.com: unlike ytimg.com/
# youtube.com, it has no stable, fixed public hostname for actual video
# delivery -- that traffic goes through ephemeral, per-session redirector
# subdomains (e.g. rr1---sn-xxxx.googlevideo.com) assigned at request time
# to a specific edge node, which can be reassigned or stop resolving at any
# point with no warning. Not a fit for a fixed REALITY target.
SNI_POOL=(i.ytimg.com s.ytimg.com www.youtube.com)
if [[ -n "$SNI_DOMAIN_ENV_OVERRIDE" ]]; then
  SNI_DOMAIN_DEFAULT="$SNI_DOMAIN_ENV_OVERRIDE"
else
  SNI_DOMAIN_DEFAULT="${SNI_POOL[$((RANDOM % ${#SNI_POOL[@]}))]}"
fi
LISTEN_PORT_DEFAULT="${LISTEN_PORT:-443}"         # Xray listen port
# uTLS ClientHello fingerprint the client presents. "random" rotates it
# per-connection rather than always presenting an identical "chrome"
# fingerprint on every single handshake -- a static fingerprint is itself
# a pattern an observer could key on across many connections/servers.
# Persisted in state like SNI/port once set, so re-runs stay consistent
# rather than changing under you.
FINGERPRINT_DEFAULT="${FINGERPRINT:-random}"
# Used as a fallback to install the 'reality' shortcut when this script is
# run via a process substitution / pipe (e.g. `bash <(curl -Ls ...)`),
# where $0 doesn't point to an actual file on disk. Override via env var
# if you're running a fork of this script from a different location.
SCRIPT_SOURCE_URL="${SCRIPT_SOURCE_URL:-https://raw.githubusercontent.com/davidbr5264/vless-reality-automated-script/master/setup-xray-reality.sh}"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
STATE_FILE="${XRAY_CONFIG_DIR}/.reality-state"    # remembers settings between runs
CLIENT_INFO_FILE="/root/xray-client-info.txt"
BACKUP_ROOT="/root/xray-backups"
SERVICE_NAME="xray"
# Optional: a webhook URL (Slack/Discord/ntfy/generic POST endpoint) that
# critical alerts (--health-check giving up, restart-budget exhaustion) get
# POSTed to, in addition to the existing local logger/wall alerting. Unset
# by default -- everything works exactly as before with no network calls if
# this isn't set. Set once via: reality --set-webhook <url>  (saved to state,
# survives re-runs) or export REALITY_ALERT_WEBHOOK=... before running.
ALERT_WEBHOOK="${REALITY_ALERT_WEBHOOK:-}"

MODE="install"
RESTORE_TS=""
case "${1:-}" in
  --rotate-uuid)   MODE="rotate-uuid" ;;
  --rotate-all)    MODE="rotate-all" ;;
  --change-sni)
    MODE="change-sni"
    NEW_SNI_ARG="${2:-}"
    ;;
  --show)          MODE="show" ;;
  --list-backups)  MODE="list-backups" ;;
  --dedupe-backups) MODE="dedupe-backups" ;;
  --status)        MODE="status" ;;
  --health-check)  MODE="health-check" ;;
  --update-core-only) MODE="update-core-only" ;;
  --set-webhook)
    MODE="set-webhook"
    WEBHOOK_ARG="${2:-}"
    ;;
  --send-alert)
    # Internal mode: shared by --health-check and the xray-alert.service
    # OnFailure unit, so "how do we notify" (local logger/wall + optional
    # webhook) lives in one place instead of being duplicated across both.
    # Not intended to be run by hand, though nothing stops you.
    MODE="send-alert"
    ALERT_MSG="${2:-Unspecified xray REALITY alert}"
    ;;
  --restore)
    MODE="restore"
    RESTORE_TS="${2:-}"
    if [[ -z "$RESTORE_TS" ]]; then
      err "--restore requires a timestamp. See --list-backups for available ones."
      exit 1
    fi
    ;;
  --help|-h)
    sed -n '2,102p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    err "Unknown argument '$1'. Use --help for usage."
    exit 1
    ;;
esac

# Optional second flag, currently only meaningful for --rotate-all (see
# below): explicit opt-in to skip the interactive confirmation prompt when
# there's no TTY to prompt on (cron, CI, orchestration tools, etc).
FORCE_CONFIRM=0
for arg in "$@"; do
  [[ "$arg" == "--force" || "$arg" == "--yes" ]] && FORCE_CONFIRM=1
done

# One line per run, appended on every exit path (success, error, or an
# early exit deep in some step) via the EXIT trap -- so "when did I last
# touch this, and did it work" is answerable later without guessing from
# backup timestamps alone (which get pruned).
#
# Registered here -- right after MODE is resolved and before the
# LISTEN_PORT/root preflight checks below -- rather than further down,
# specifically so a bad LISTEN_PORT env var or a not-run-as-root invocation
# also gets logged and, for install mode, notified via webhook if
# configured. Those are exactly the kind of environment-misconfiguration
# failures a headless deployment (e.g. a cloud-init runcmd with a typo'd
# env var) would otherwise fail completely silently on.
AUDIT_LOG="/var/log/reality-setup.log"
log_run_outcome() {
  local exit_code=$?
  local outcome="success"
  [[ "$exit_code" -ne 0 ]] && outcome="failed(exit ${exit_code})"
  echo "$(date -Is) mode=${MODE} outcome=${outcome}" >> "$AUDIT_LOG" 2>/dev/null || true

  # For install mode specifically -- the one-shot "did my unattended
  # deployment actually work" moment, e.g. a cloud-init/DigitalOcean
  # runcmd on first boot with no one watching -- notify a configured
  # webhook of the outcome directly here, rather than through send_alert().
  # This trap can fire from a very early failure (preflight checks, before
  # send_alert's own function definition is even reached during normal
  # top-to-bottom script execution), so it stays self-contained and
  # dependency-free instead of risking "command not found" on an early
  # exit. Deliberately minimal: no private info, just host + outcome.
  if [[ "${MODE:-}" == "install" && -n "${ALERT_WEBHOOK:-}" ]] && command -v curl >/dev/null 2>&1; then
    local host_now
    host_now=$(hostname 2>/dev/null || echo "unknown-host")
    curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" \
      -d "{\"host\":\"${host_now}\",\"message\":\"reality install finished: ${outcome}\"}" \
      "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi
}
trap log_run_outcome EXIT

if ! [[ "$LISTEN_PORT_DEFAULT" =~ ^[0-9]+$ ]] || [[ "$LISTEN_PORT_DEFAULT" -lt 1 ]] || [[ "$LISTEN_PORT_DEFAULT" -gt 65535 ]]; then
  err "LISTEN_PORT must be a number between 1 and 65535 (got: '${LISTEN_PORT_DEFAULT}')."
  exit 1
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (use sudo)."
  exit 1
fi

# Prevent two concurrent runs (e.g. accidentally launched in two terminals)
# from racing on the same config/backup/state files. Held for the life of
# this process; released automatically on exit, including on error.
#
# Modes driven by the unattended timers (watchdog every 10min, autoupdate
# and backup-maintenance weekly) wait briefly for the lock instead of
# failing immediately -- an interactive/manual run should fail fast on a
# genuine double-launch, but two automated timers occasionally landing in
# the same few seconds is expected and shouldn't produce a spurious
# "failed" entry in the audit log when a short wait would have avoided it.
LOCK_FILE="/var/lock/reality-setup.lock"
exec 200>"$LOCK_FILE"
LOCK_ACQUIRED=1
case "$MODE" in
  health-check|update-core-only|dedupe-backups)
    flock -w 30 200 || LOCK_ACQUIRED=0
    ;;
  *)
    flock -n 200 || LOCK_ACQUIRED=0
    ;;
esac
if [[ "$LOCK_ACQUIRED" -ne 1 ]]; then
  err "Another run of this script appears to be in progress (lock: ${LOCK_FILE})."
  echo "       Wait for it to finish, or remove the lock file if you're sure nothing" >&2
  echo "       is actually running: rm -f ${LOCK_FILE}" >&2
  exit 1
fi

if [[ "$MODE" != "install" ]] && ! command -v xray >/dev/null 2>&1; then
  err "Xray is not installed yet. Run the script with no arguments first."
  exit 1
fi

# A handful of non-install modes rely on jq/openssl/qrencode (rotate modes
# regenerate credentials and print a QR; restore validates JSON), but
# several others (--status, --health-check, --send-alert, --set-webhook,
# --list-backups, --dedupe-backups, --update-core-only) don't touch any of
# these three at all. Gating all of them on all three tools was overly
# broad -- worst case, it meant --send-alert (the mechanism meant to tell
# you something is wrong) could itself be blocked by, say, qrencode going
# missing for an unrelated reason. Check only what each mode actually uses.
case "$MODE" in
  rotate-uuid|rotate-all|change-sni)
    REQUIRED_DEPS="jq openssl qrencode"
    ;;
  show)
    REQUIRED_DEPS="qrencode"
    ;;
  restore)
    REQUIRED_DEPS="jq"
    ;;
  *)
    REQUIRED_DEPS=""
    ;;
esac
for dep in $REQUIRED_DEPS; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    err "Required tool '${dep}' is missing (it should have been installed already)."
    echo "       Reinstall it with: apt-get install -y ${dep}" >&2
    exit 1
  fi
done

if [[ "$MODE" == "install" ]] && ! command -v apt-get >/dev/null 2>&1; then
  err "This script only supports Debian/Ubuntu (apt-based) systems."
  exit 1
fi

# Fail with a clear message rather than a confusing mid-script error if
# there's not enough room for apt upgrades, Xray-core, and logs/backups.
if [[ "$MODE" == "install" ]]; then
  AVAILABLE_KB=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  MIN_REQUIRED_KB=1048576  # 1GB
  if [[ -n "$AVAILABLE_KB" ]] && [[ "$AVAILABLE_KB" -lt "$MIN_REQUIRED_KB" ]]; then
    err "Less than 1GB free on / (found $((AVAILABLE_KB / 1024))MB)."
    echo "       apt upgrades, Xray-core, and logs need headroom to install safely." >&2
    echo "       Free up space first (e.g. 'apt autoremove --purge -y'), then re-run." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Load any previously saved state (SNI/port/keys), so rotate/show modes
# reuse the same settings instead of falling back to defaults.
# ---------------------------------------------------------------------------
SNI_DOMAIN="$SNI_DOMAIN_DEFAULT"
LISTEN_PORT="$LISTEN_PORT_DEFAULT"
FINGERPRINT="$FINGERPRINT_DEFAULT"
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
SSH_PORT=""

if [[ -f "$STATE_FILE" ]]; then
  # Existing state always wins over env var defaults, on purpose -- this is
  # what makes plain re-runs preserve credentials instead of regenerating
  # them. But that means SNI_DOMAIN=/LISTEN_PORT=... env vars silently do
  # nothing on an existing install, which is confusing without a message.
  # Changing just the SNI has its own command (--change-sni); there's still
  # no equivalent for the port without a full --rotate-all.
  # shellcheck disable=SC1090
  source "$STATE_FILE"

  # Only warn when the person actually set the env var themselves --
  # comparing against the pool-randomized default (rather than a fixed
  # sentinel string) would otherwise false-positive on every re-run purely
  # because this run's random pick differs from both "i.ytimg.com" and
  # whatever the existing install already uses.
  if [[ -n "$SNI_DOMAIN_ENV_OVERRIDE" && "$SNI_DOMAIN_ENV_OVERRIDE" != "$SNI_DOMAIN" ]]; then
    warn "SNI_DOMAIN env var ('${SNI_DOMAIN_ENV_OVERRIDE}') was set, but an existing install already"
    echo "         uses '${SNI_DOMAIN}' -- existing state always wins, so the env var was ignored." >&2
    echo "         To actually change it: reality --change-sni ${SNI_DOMAIN_ENV_OVERRIDE}" >&2
  fi
  if [[ "$LISTEN_PORT_DEFAULT" != "443" && "$LISTEN_PORT_DEFAULT" != "$LISTEN_PORT" ]]; then
    warn "LISTEN_PORT env var ('${LISTEN_PORT_DEFAULT}') was set, but an existing install already"
    echo "         uses port ${LISTEN_PORT} -- existing state always wins, so the env var was ignored." >&2
  fi
  # FINGERPRINT was added to state after this script's initial release, so
  # an older install re-running this newer version may have no saved value
  # yet -- fall back to the default rather than leaving it empty.
  [[ -z "$FINGERPRINT" ]] && FINGERPRINT="$FINGERPRINT_DEFAULT"
fi

if [[ "$MODE" == "show" ]]; then
  if [[ -z "$UUID" || -z "$PUBLIC_KEY" ]]; then
    err "No saved state found (${STATE_FILE}). Run a full install first."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Helper: back up current config + client info before any change
# ---------------------------------------------------------------------------
backup_current_state() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local ts backup_dir
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="${BACKUP_ROOT}/${ts}"
    mkdir -p "$backup_dir"
    cp -a "$CONFIG_FILE" "$backup_dir/config.json" 2>/dev/null || true
    [[ -f "$CLIENT_INFO_FILE" ]] && cp -a "$CLIENT_INFO_FILE" "$backup_dir/client-info.txt" 2>/dev/null || true
    [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$backup_dir/state" 2>/dev/null || true
    chmod -R 600 "$backup_dir"/* 2>/dev/null || true
    # Lock down the directories themselves too, not just the files inside --
    # mkdir uses the process umask (often 755), which would otherwise leave
    # backup directory *listings* (filenames, sizes, timestamps) readable to
    # any local user even though file contents are individually protected.
    chmod 700 "$BACKUP_ROOT" "$backup_dir" 2>/dev/null || true
    echo "Backed up previous config to: $backup_dir"

    # Keep only the most recent 15 backups so this directory doesn't grow
    # forever across years of periodic rotates/reinstalls.
    if [[ -d "$BACKUP_ROOT" ]]; then
      local backup_count
      backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
      if [[ "$backup_count" -gt 15 ]]; then
        find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$((backup_count - 15))" | xargs -r rm -rf
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helper: generate UUID + short ID (used by install and --rotate-uuid)
# ---------------------------------------------------------------------------
generate_uuid_and_shortid() {
  UUID=$(xray uuid) || { err "'xray uuid' command failed to run."; exit 1; }
  SHORT_ID=$(openssl rand -hex 8)
  if [[ -z "$UUID" || -z "$SHORT_ID" ]]; then
    err "Failed to generate UUID or short ID."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: generate REALITY x25519 keypair (used by install and --rotate-all)
# Handles both old and new `xray x25519` CLI output formats:
#   Old: "Private key: xxx" / "Public key: xxx"
#   New: "PrivateKey: xxx"  / "Password (PublicKey): xxx" / "Hash32: xxx"
# ---------------------------------------------------------------------------
generate_reality_keypair() {
  local key_output
  key_output=$(xray x25519) || { err "'xray x25519' command failed to run."; exit 1; }

  PRIVATE_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Private ?[Kk]ey)[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)
  PUBLIC_KEY=$(echo "$key_output" | grep -Ei '^[[:space:]]*(Public ?[Kk]ey|Password)([[:space:]]*\(.*\))?[[:space:]]*:' | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d ' \r' || true)

  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "Failed to parse REALITY keypair."
    echo "  PRIVATE_KEY=${PRIVATE_KEY:-<empty>}" >&2
    echo "  PUBLIC_KEY=${PUBLIC_KEY:-<empty>}" >&2
    echo "  Raw 'xray x25519' output was:" >&2
    echo "$key_output" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helper: write config.json from current UUID/keys/short ID
# ---------------------------------------------------------------------------
write_config() {
  mkdir -p "$XRAY_CONFIG_DIR"
  local tmp_config
  tmp_config=$(mktemp "${XRAY_CONFIG_DIR}/.config.json.XXXXXX")
  cat > "$tmp_config" <<EOF
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
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": {
        "response": {
          "type": "none"
        }
      }
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
  # Fail fast with a clear message if the config we just wrote is malformed,
  # rather than letting it surface later as an opaque "service failed to
  # start" from systemd.
  if ! jq empty "$tmp_config" >/dev/null 2>&1; then
    err "Generated config.json is not valid JSON. Not restarting xray."
    echo "  Broken draft left at ${tmp_config} for inspection." >&2
    echo "  Existing config (if any) at ${CONFIG_FILE} was left untouched." >&2
    exit 1
  fi

  # jq only confirms valid JSON syntax -- it says nothing about whether
  # Xray's own schema actually accepts the field names/structure. Xray-core
  # has a real config-test mode built for exactly this; use it so a typo'd
  # field surfaces here with a clear message, not as a cryptic runtime
  # failure from systemd later.
  #
  # NOTE: the log directory must exist before this runs -- the config
  # references /var/log/xray/error.log, and xray -test fails to even load
  # the config if that path's parent directory doesn't exist yet (confirmed
  # by testing against a real xray-core binary: this order bug would have
  # broken every fresh install otherwise).
  mkdir -p /var/log/xray
  chown -R xray:xray /var/log/xray 2>/dev/null || true

  if command -v xray >/dev/null 2>&1; then
    if ! XRAY_TEST_OUTPUT=$(xray run -test -format json -config "$tmp_config" 2>&1); then
      err "Xray rejected the generated config (schema/field error, not a JSON syntax error):"
      echo "$XRAY_TEST_OUTPUT" | sed 's/^/  /' >&2
      echo "  Broken draft left at ${tmp_config} for inspection." >&2
      echo "  Existing config (if any) at ${CONFIG_FILE} was left untouched." >&2
      exit 1
    fi
  fi

  # Only back up if this is actually going to change something. Any real
  # credential/SNI/port difference necessarily shows up in config.json, so
  # comparing content here reliably detects "did anything meaningful
  # change" -- without this, a completely no-op re-run (e.g. plain
  # 'reality' with nothing to update) was creating a new backup every
  # single time, burning through the 15-backup retention window fast.
  #
  # CONFIG_CHANGED (global, read by callers) lets install mode also skip
  # an unnecessary restart on a genuine no-op run -- see the final restart
  # check at the end of install mode, which also independently checks
  # whether the xray-core binary itself was updated.
  if [[ -f "$CONFIG_FILE" ]] && cmp -s "$tmp_config" "$CONFIG_FILE"; then
    CONFIG_CHANGED=0
  else
    CONFIG_CHANGED=1
    backup_current_state
  fi

  # Atomic swap: rename is a single filesystem operation, so a crash here
  # never leaves a half-written config.json -- you get the old one or the
  # fully-written new one, never something in between.
  mv -f "$tmp_config" "$CONFIG_FILE"

  # Config contains the REALITY private key -- restrict to root + the xray
  # service user rather than leaving it world-readable.
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true

  # Record a checksum of this known-good write so --health-check can detect
  # if config.json changes outside the script later (hand edit, disk fault,
  # another actor with root) instead of that going unnoticed indefinitely.
  (cd "$XRAY_CONFIG_DIR" && sha256sum "$(basename "$CONFIG_FILE")" > .config.sha256 2>/dev/null) || true
  chmod 600 "${XRAY_CONFIG_DIR}/.config.sha256" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: save state so future rotate/show runs remember settings
# ---------------------------------------------------------------------------
save_state() {
  local tmp_state
  tmp_state=$(mktemp "${XRAY_CONFIG_DIR}/.reality-state.XXXXXX")
  cat > "$tmp_state" <<EOF
SNI_DOMAIN="${SNI_DOMAIN}"
LISTEN_PORT="${LISTEN_PORT}"
FINGERPRINT="${FINGERPRINT}"
UUID="${UUID}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
SSH_PORT="${SSH_PORT}"
ALERT_WEBHOOK="${ALERT_WEBHOOK}"
EOF
  chmod 600 "$tmp_state"
  mv -f "$tmp_state" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Helper: restart xray and confirm it came up healthy
# ---------------------------------------------------------------------------
restart_and_verify() {
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}"
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    err "xray service failed to start. Check: journalctl -u xray -e"
    exit 1
  fi
  ok "xray service is active"
  verify_handshake
}

# ---------------------------------------------------------------------------
# Helper: best-effort network-level check that Xray is actually serving
# REALITY correctly, not just that the process is running. "Active" in
# systemd only means the process didn't crash -- it says nothing about
# whether the port is reachable or the TLS handshake actually works.
# Non-fatal: prints warnings rather than aborting, since this check can
# have environmental false negatives (e.g. loopback quirks) that a real
# remote client wouldn't hit.
# ---------------------------------------------------------------------------
verify_handshake() {
  local port="${LISTEN_PORT:-443}"
  local sni="${SNI_DOMAIN:-}"

  if ! ss -tln 2>/dev/null | grep -q ":${port} "; then
    warn "Xray is active, but nothing appears to be listening on port ${port}."
    echo "         Check: ss -tlnp | grep ${port}" >&2
    return 0
  fi

  if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    warn "Port ${port} is listed as listening, but a local TCP connect failed."
    return 0
  fi

  if [[ -n "$sni" ]] && command -v openssl >/dev/null 2>&1; then
    if ! timeout 5 bash -c "echo | openssl s_client -connect 127.0.0.1:${port} -servername '${sni}' 2>/dev/null" | grep -q "CONNECTED"; then
      warn "TCP connects, but a TLS handshake against 127.0.0.1:${port} (SNI: ${sni})"
      echo "         didn't complete cleanly. This can be a loopback/self-connect quirk --" >&2
      echo "         test from a real client before assuming something's wrong. If a real" >&2
      echo "         client also fails, check: journalctl -u xray -e" >&2
      return 0
    fi
  fi

  ok "Handshake check passed: port listening, TCP connects, TLS handshake completes."
}

# ---------------------------------------------------------------------------
# Helper: send a critical alert both locally (logger + wall, as before) and,
# if configured, to $ALERT_WEBHOOK. Shared by --health-check and the
# xray-alert.service OnFailure unit so there's one place that knows how to
# notify, instead of duplicating logger/wall/curl calls in both.
#
# Local alerting (logger + wall) always happens regardless of webhook config
# -- the webhook is additive, not a replacement, so this still works exactly
# as before on a box with no webhook set.
# ---------------------------------------------------------------------------
send_alert() {
  local message="$1"
  logger -p daemon.crit "reality alert: ${message}" 2>/dev/null || true
  wall "WARNING (xray REALITY): ${message}" 2>/dev/null || true

  if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl >/dev/null 2>&1; then
    local hostname_now escaped_message
    hostname_now=$(hostname 2>/dev/null || echo "unknown-host")
    # Minimal JSON string escaping (backslashes, quotes, newlines) -- the
    # messages passed in are our own fixed strings, not arbitrary user
    # input, but escaping costs nothing and avoids a malformed payload if
    # a future message ever includes a quote.
    escaped_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    # Generic JSON POST body. Works as-is with ntfy and most simple
    # webhook receivers; for Slack/Discord specifically you'd normally
    # want a {"text": "..."} or {"content": "..."} shape instead -- if
    # yours needs that, adjust the payload below to match.
    curl -fsS --max-time 10 -X POST \
      -H "Content-Type: application/json" \
      -d "{\"host\":\"${hostname_now}\",\"message\":\"${escaped_message}\"}" \
      "$ALERT_WEBHOOK" >/dev/null 2>&1 || \
      logger -p daemon.warning "reality alert: webhook POST failed (network issue or bad URL?)" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: only actually alert on a condition *changing* state (fine -> bad,
# or bad -> fine), not on every single --health-check tick a condition
# happens to still be true. Without this, a persistent issue (disk still
# low, SNI target still broken, etc) would re-fire a wall broadcast and
# webhook POST every 10 minutes for as long as it remains unresolved --
# noisy enough that real alerts risk getting tuned out. State is tracked
# via a marker file per condition under $XRAY_CONFIG_DIR.
# ---------------------------------------------------------------------------
alert_on_transition() {
  local condition_key="$1" is_bad="$2" bad_message="$3" resolved_message="$4"
  local marker="${XRAY_CONFIG_DIR}/.alert-${condition_key}"

  if [[ "$is_bad" -eq 1 ]]; then
    if [[ ! -f "$marker" ]]; then
      touch "$marker" 2>/dev/null || true
      send_alert "$bad_message"
    fi
  else
    if [[ -f "$marker" ]]; then
      rm -f "$marker" 2>/dev/null || true
      [[ -n "$resolved_message" ]] && logger -p daemon.notice "reality alert: ${resolved_message}" 2>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helper: record the currently installed xray binary's checksum, called
# right after a legitimate install/update (step 2 of a full install, and
# --update-core-only). --health-check later compares against this to catch
# the binary changing through any OTHER path (tampering, a botched manual
# update, disk corruption) -- the same class of integrity check already
# done for config.json, extended to the binary itself. Also doubles as a
# lightweight supply-chain audit trail: logs what was actually installed,
# not just that a version string changed, so "what binary was running on
# such-and-such date" is answerable later from the log alone.
# ---------------------------------------------------------------------------
record_xray_binary_checksum() {
  local xray_path checksum
  xray_path=$(command -v xray 2>/dev/null) || return 0
  checksum=$(sha256sum "$xray_path" 2>/dev/null | awk '{print $1}')
  [[ -z "$checksum" ]] && return 0
  echo "$checksum" > "${XRAY_CONFIG_DIR}/.xray-binary.sha256" 2>/dev/null || true
  chmod 600 "${XRAY_CONFIG_DIR}/.xray-binary.sha256" 2>/dev/null || true
  echo "$(date -Is) xray_binary_sha256=${checksum} xray_path=${xray_path} version=$(xray version 2>/dev/null | head -n1)" >> "$AUDIT_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: build vless:// link, write client info file, print summary + QR
# ---------------------------------------------------------------------------
output_client_info() {
  local server_ip
  server_ip=$(curl -fsSL -4 --max-time 5 https://ifconfig.me 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -fsSL -4 --max-time 5 https://icanhazip.com 2>/dev/null || \
              true)
  server_ip=$(echo "$server_ip" | tr -d '[:space:]')

  # IPv4-only lookups leave an IPv6-only VPS with no usable IP even though
  # the listener itself is dual-stack ("listen": "::"). Fall back to an
  # IPv6-capable lookup before giving up, rather than assuming IPv4 always
  # exists.
  if [[ -z "$server_ip" ]]; then
    server_ip=$(curl -fsSL -6 --max-time 5 https://api64.ipify.org 2>/dev/null || \
                curl -fsSL -6 --max-time 5 https://icanhazip.com 2>/dev/null || \
                true)
    server_ip=$(echo "$server_ip" | tr -d '[:space:]')
  fi

  if [[ -z "$server_ip" ]]; then
    warn "Could not determine the server's public IP (all lookup services unreachable, IPv4 or IPv6)."
    echo "         Everything else succeeded -- find your IP manually (e.g. 'curl ifconfig.me' or" >&2
    echo "         your VPS provider's dashboard) and substitute it into the link below." >&2
    server_ip="YOUR_SERVER_IP"
  fi

  # Detect IP changes since the last time this was generated (VPS
  # migration, provider re-assigning the address, etc). Without this, a
  # changed IP goes completely unnoticed -- old client links just
  # silently stop working with no hint as to why.
  if [[ -f "$CLIENT_INFO_FILE" ]] && [[ "$server_ip" != "YOUR_SERVER_IP" ]]; then
    local previous_ip
    previous_ip=$(grep -m1 "^Server IP" "$CLIENT_INFO_FILE" 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
    if [[ -n "$previous_ip" ]] && [[ "$previous_ip" != "$server_ip" ]] && [[ "$previous_ip" != "YOUR_SERVER_IP" ]]; then
      warn "Server IP changed since the last run: ${previous_ip} -> ${server_ip}"
      echo "         Any device using the old link needs to re-import the new one below." >&2
    fi
  fi

  local vless_link="vless://${UUID}@${server_ip}:${LISTEN_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision&spx=%2F#xray-reality-$(hostname)"

  # Write via mktemp (created 0600 by default) + atomic rename, rather than
  # `cat > "$CLIENT_INFO_FILE"` followed by a separate chmod -- the latter
  # briefly creates the file at the process's default umask (often 644)
  # before the chmod runs, leaving the private key world-readable for a
  # short window. mktemp avoids that window entirely.
  local tmp_info
  tmp_info=$(mktemp)
  cat > "$tmp_info" <<EOF
================= Xray VLESS-TCP-XTLS-Vision-REALITY =================
Server IP     : ${server_ip}
Port          : ${LISTEN_PORT}
UUID          : ${UUID}
Flow          : xtls-rprx-vision
Security      : reality
SNI (dest)    : ${SNI_DOMAIN}
Public Key    : ${PUBLIC_KEY}
Private Key   : ${PRIVATE_KEY}   (server-side only, keep secret)
Short ID      : ${SHORT_ID}
Fingerprint   : ${FINGERPRINT}

Client import link:
${vless_link}
========================================================================
Keep this file secret. It contains your private key.
EOF
  chmod 600 "$tmp_info"
  mv -f "$tmp_info" "$CLIENT_INFO_FILE"

  # Also drop a scannable QR image alongside the text link, so it can be
  # retrieved (e.g. via scp) without needing a live interactive terminal
  # to run --show. Best-effort: qrencode's PNG output needs libpng support,
  # which isn't guaranteed on every install, so don't fail the run over it.
  if command -v qrencode >/dev/null 2>&1; then
    if ! qrencode -t PNG -o "${CLIENT_INFO_FILE%.txt}-qr.png" "${vless_link}" 2>/dev/null; then
      warn "Could not write a QR PNG (qrencode may be missing PNG/libpng support)."
      echo "         The text link and terminal QR code above still work fine." >&2
    else
      chmod 600 "${CLIENT_INFO_FILE%.txt}-qr.png" 2>/dev/null || true
    fi
  fi

  local status_now
  status_now=$(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo unknown)

  echo ""
  echo "############################################################"
  echo "  Service status : ${status_now}"
  echo "  Config file    : ${CONFIG_FILE}"
  echo "  Client info    : ${CLIENT_INFO_FILE} (chmod 600)"
  echo "############################################################"
  echo ""
  echo "Client link (import into v2rayN / NekoBox / Shadowrocket / etc.):"
  echo "${vless_link}"
  echo ""
  echo "QR code:"
  # Guarded rather than a bare call: this runs before the caller's
  # restart_and_verify (see finish_and_restart) in the rotate-uuid/
  # rotate-all/install flows. An unguarded failure here (e.g. qrencode
  # missing) would abort under `set -e` right at this display step --
  # after new credentials are already written to config.json and this
  # file, but *before* Xray has actually been restarted to pick them up,
  # leaving the running service on old credentials while the file on disk
  # claims new ones. A terminal QR code is worth skipping gracefully, not
  # worth risking that inconsistency over.
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 "${vless_link}" || warn "qrencode failed to render the terminal QR code (the PNG above and the link/text file are unaffected)."
  else
    warn "qrencode not found -- skipping the terminal QR code (the link above still works, and a PNG may have been saved next to ${CLIENT_INFO_FILE})."
  fi
}

# ---------------------------------------------------------------------------
# Helper: shared by every mode that ends with save+print+restart, so this
# sequence only has to be correct in one place instead of being hand-rolled
# identically across rotate-uuid/rotate-all (install mode's version differs
# slightly -- it can skip the restart entirely on a genuine no-op run, via
# the CONFIG_CHANGED/version-compare check -- so it stays separate, inline,
# near the end of the script).
# ---------------------------------------------------------------------------
finish_and_restart() {
  save_state
  output_client_info
  restart_and_verify
}

# ---------------------------------------------------------------------------
# MODE: --show  (read-only, no changes)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "show" ]]; then
  output_client_info
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --send-alert "message"  (internal; shared by --health-check and the
# xray-alert.service OnFailure unit -- see send_alert() helper above)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "send-alert" ]]; then
  send_alert "$ALERT_MSG"
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --set-webhook <url>  (or "" to clear)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "set-webhook" ]]; then
  if [[ -z "$UUID" ]]; then
    err "No existing install found (${STATE_FILE}). Run a full install first."
    exit 1
  fi
  if [[ -z "$WEBHOOK_ARG" ]]; then
    ALERT_WEBHOOK=""
    save_state
    ok "Webhook cleared. Critical alerts will only go to local logger/wall from now on."
  else
    if [[ "$WEBHOOK_ARG" != http://* && "$WEBHOOK_ARG" != https://* ]]; then
      err "Webhook URL should start with http:// or https:// (got: '${WEBHOOK_ARG}')."
      exit 1
    fi
    ALERT_WEBHOOK="$WEBHOOK_ARG"
    save_state
    ok "Webhook saved. Sending a test alert now..."
    send_alert "Test alert from $(hostname 2>/dev/null || echo this server) -- webhook is configured correctly if you received this."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --list-backups  (read-only, no changes)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list-backups" ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    exit 0
  fi
  echo "Available backups (use with --restore <timestamp>):"
  for dir in "$BACKUP_ROOT"/*/; do
    ts=$(basename "$dir")
    contents=$(ls "$dir" 2>/dev/null | tr '\n' ' ')
    echo "  ${ts}   (${contents})"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --dedupe-backups  (remove redundant consecutive-duplicate backups)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "dedupe-backups" ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No backups found under ${BACKUP_ROOT}."
    exit 0
  fi

  step "dedupe" "Scanning backups for redundant consecutive duplicates"

  # Only collapses a *consecutive run* of identical config.json content
  # (e.g. from repeated no-op 'reality' re-runs before the backup-skip fix)
  # down to the most recent one in that run. Two backups with matching
  # content that AREN'T consecutive -- meaning something changed and then
  # changed back -- are left alone, since they represent genuinely
  # different points in history that happen to coincide.
  mapfile -t ALL_BACKUPS < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

  PREV_HASH=""
  PREV_DIR=""
  REMOVED_COUNT=0
  KEPT_COUNT=0

  for dir in "${ALL_BACKUPS[@]}"; do
    if [[ ! -f "${dir}/config.json" ]]; then
      # No config.json to compare -- leave it alone, don't guess.
      PREV_HASH=""
      PREV_DIR=""
      continue
    fi
    CURRENT_HASH=$(sha256sum "${dir}/config.json" 2>/dev/null | awk '{print $1}')

    if [[ -n "$PREV_HASH" && "$CURRENT_HASH" == "$PREV_HASH" ]]; then
      # This one matches the previous one in sequence -- the previous
      # backup is now redundant (this one is strictly newer with the
      # same content), so remove the previous one and keep this one as
      # the new "most recent representative" of the run.
      rm -rf "$PREV_DIR"
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    else
      KEPT_COUNT=$((KEPT_COUNT + 1))
    fi
    PREV_HASH="$CURRENT_HASH"
    PREV_DIR="$dir"
  done

  ok "Removed ${REMOVED_COUNT} redundant backup(s), kept ${KEPT_COUNT}."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --status  (read-only consolidated health check)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "status" ]]; then
  SERVICE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "unknown")
  ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

  PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
  CURRENT_QDISC=""
  if [[ -n "$PRIMARY_IFACE" ]]; then
    CURRENT_QDISC=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/root/ {print $2; exit}')
  fi

  UFW_ACTIVE=0
  ufw status 2>/dev/null | grep -q "Status: active" && UFW_ACTIVE=1

  FAIL2BAN_ACTIVE=0
  BANNED_COUNT=0
  if fail2ban-client status sshd >/dev/null 2>&1; then
    FAIL2BAN_ACTIVE=1
    BANNED_COUNT=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[ \t]/,"",$2); print $2}')
    [[ "$BANNED_COUNT" =~ ^[0-9]+$ ]] || BANNED_COUNT=0
  fi

  REBOOT_TIMER_ENABLED=0
  NEXT_REBOOT=""
  if systemctl is-enabled --quiet daily-reboot.timer 2>/dev/null; then
    REBOOT_TIMER_ENABLED=1
    NEXT_REBOOT=$(systemctl list-timers daily-reboot.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}')
  fi

  BACKUP_COUNT=0
  if [[ -d "$BACKUP_ROOT" ]]; then
    BACKUP_COUNT=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  fi

  XRAY_UPDATE_CHECK_CACHE="${XRAY_CONFIG_DIR}/.last-xray-checkupdate"
  LAST_CHECK_STR=""
  if [[ -f "$XRAY_UPDATE_CHECK_CACHE" ]]; then
    LAST_CHECK_EPOCH=$(cat "$XRAY_UPDATE_CHECK_CACHE" 2>/dev/null || echo "")
    if [[ "$LAST_CHECK_EPOCH" =~ ^[0-9]+$ ]]; then
      LAST_CHECK_STR=$(date -d "@${LAST_CHECK_EPOCH}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    fi
  fi

  echo "=== Xray REALITY status ==="
  echo ""
  echo "Service (${SERVICE_NAME})   : ${SERVICE_STATE}"
  echo "Congestion control  : ${ACTIVE_CC} $( [[ "$ACTIVE_CC" != "bbr" ]] && echo "(expected bbr)" )"
  if [[ -n "$PRIMARY_IFACE" ]]; then
    echo "qdisc (${PRIMARY_IFACE})       : ${CURRENT_QDISC:-unknown} $( [[ "$CURRENT_QDISC" != "fq" ]] && echo "(expected fq)" )"
  fi
  if [[ "$UFW_ACTIVE" == "1" ]]; then
    echo "UFW                 : active"
  else
    echo "UFW                 : NOT active"
  fi
  if [[ "$FAIL2BAN_ACTIVE" == "1" ]]; then
    echo "fail2ban sshd jail  : loaded (currently banned: ${BANNED_COUNT})"
  else
    echo "fail2ban sshd jail  : NOT loaded"
  fi
  if [[ "$REBOOT_TIMER_ENABLED" == "1" ]]; then
    echo "Daily reboot timer  : enabled (next: ${NEXT_REBOOT:-unknown})"
  else
    echo "Daily reboot timer  : NOT enabled"
  fi
  echo "Backups available   : ${BACKUP_COUNT}"
  if [[ -n "$LAST_CHECK_STR" ]]; then
    echo "Xray-core last checked for updates: ${LAST_CHECK_STR}"
  fi

  if [[ -f "$AUDIT_LOG" ]]; then
    echo ""
    echo "Recent activity (last 5 runs):"
    tail -n 5 "$AUDIT_LOG" | sed 's/^/  /'
  fi

  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --health-check  (meant to run unattended on reality-watchdog.timer)
#
# Goes further than systemd's own "active" notion of health: a process can
# be running and still not actually be serving REALITY correctly (hung,
# wedged, listening socket dropped, etc). Reuses the same handshake check
# the install/rotate paths already run once at the end of a change, but on
# a recurring schedule so problems that appear *between* manual runs get
# caught instead of sitting silently broken until someone notices their
# client can't connect.
#
# One self-heal attempt (a single restart), then loud local alerting if
# that doesn't fix it -- deliberately not a restart loop, since silently
# retrying forever can mask a real underlying problem (bad config, port
# conflict, expired/rotated upstream SNI target) that actually needs a
# human to look at.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "health-check" ]]; then
  HEALTH_ISSUE=""
  HEALTH_EXIT_CODE=0

  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    HEALTH_ISSUE="service not active"
  elif ! ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
    HEALTH_ISSUE="active but nothing listening on port ${LISTEN_PORT}"
  elif ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${LISTEN_PORT}" 2>/dev/null; then
    HEALTH_ISSUE="port ${LISTEN_PORT} listed as listening but local TCP connect failed"
  fi

  # Config-drift check: does the file on disk still match the checksum
  # recorded at the end of the last successful write_config? A mismatch
  # means something changed config.json outside this script since then
  # (hand edit, disk fault, another actor with root) -- surfaced here
  # rather than only being noticed the next time someone happens to run
  # --status manually.
  CONFIG_HASH_FILE="${XRAY_CONFIG_DIR}/.config.sha256"
  DRIFT_DETECTED=0
  if [[ -f "$CONFIG_HASH_FILE" && -f "$CONFIG_FILE" ]]; then
    if ! (cd "$XRAY_CONFIG_DIR" && sha256sum -c "$(basename "$CONFIG_HASH_FILE")" >/dev/null 2>&1); then
      DRIFT_DETECTED=1
    fi
  fi

  # Binary integrity check: same idea as config-drift, but for the xray
  # binary itself. A mismatch means the installed binary changed through
  # some path other than this script's own install/--update-core-only
  # (tampering, a manual replace, disk corruption) -- worth knowing about
  # regardless of whether the running service still looks healthy.
  BINARY_DRIFT=0
  XRAY_BINARY_HASH_FILE="${XRAY_CONFIG_DIR}/.xray-binary.sha256"
  if [[ -f "$XRAY_BINARY_HASH_FILE" ]]; then
    XRAY_PATH_NOW=$(command -v xray 2>/dev/null || true)
    if [[ -n "$XRAY_PATH_NOW" ]]; then
      RECORDED_BINARY_HASH=$(cat "$XRAY_BINARY_HASH_FILE" 2>/dev/null || true)
      CURRENT_BINARY_HASH=$(sha256sum "$XRAY_PATH_NOW" 2>/dev/null | awk '{print $1}')
      if [[ -n "$RECORDED_BINARY_HASH" && -n "$CURRENT_BINARY_HASH" && "$RECORDED_BINARY_HASH" != "$CURRENT_BINARY_HASH" ]]; then
        BINARY_DRIFT=1
      fi
    fi
  fi

  # Low-disk check: apt upgrades, xray-core updates, logs, and backups all
  # need headroom -- catching this here means "disk full" gets flagged on
  # its own well before it manifests as some other, more confusing failure
  # (failed apt upgrade, failed backup, etc).
  LOW_DISK=0
  AVAILABLE_KB=$(df --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')
  if [[ -n "$AVAILABLE_KB" ]] && [[ "$AVAILABLE_KB" -lt 524288 ]]; then  # 512MB
    LOW_DISK=1
  fi

  # Clock drift check: REALITY handshakes are timestamp-sensitive (see the
  # same check done once at install time). Drift can develop later even if
  # NTP was confirmed synced during install (e.g. ntp service dies).
  CLOCK_DRIFT=0
  if command -v timedatectl >/dev/null 2>&1 && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    CLOCK_DRIFT=1
  fi

  # SNI camouflage target check: if the domain REALITY is impersonating
  # stops serving TLS1.3 (site redesign, cert change, goes offline), the
  # tunnel can start failing in a way that looks like a REALITY problem but
  # actually isn't -- worth surfacing on its own so troubleshooting doesn't
  # start in the wrong place. Best-effort, not fatal.
  SNI_BROKEN=0
  if [[ -n "$SNI_DOMAIN" ]] && command -v openssl >/dev/null 2>&1; then
    if ! timeout 6 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 </dev/null >/dev/null 2>&1; then
      SNI_BROKEN=1
    fi
  fi

  # Reboot-required check: apt (unattended-upgrades or a manual run) can
  # mark the system as needing a reboot to actually apply a security
  # update (new kernel, libc, etc). The daily reboot timer will eventually
  # pick this up, but "eventually, silently, up to 24h later" isn't the
  # same as knowing about it now -- worth a one-time heads-up.
  REBOOT_REQUIRED=0
  [[ -f /var/run/reboot-required ]] && REBOOT_REQUIRED=1

  if [[ -z "$HEALTH_ISSUE" && "$DRIFT_DETECTED" -eq 0 && "$BINARY_DRIFT" -eq 0 && "$LOW_DISK" -eq 0 && "$CLOCK_DRIFT" -eq 0 && "$SNI_BROKEN" -eq 0 && "$REBOOT_REQUIRED" -eq 0 ]]; then
    # Healthy and quiet -- this mode is designed to run every few minutes
    # unattended, so success prints nothing and just exits 0. Clear any
    # stale "service-down" marker from a previous unhealthy run (e.g. it
    # recovered on its own between ticks, not via this script's restart),
    # so a *future* failure alerts again instead of staying silently
    # debounced against an alert that already resolved.
    rm -f "${XRAY_CONFIG_DIR}/.alert-service-down" 2>/dev/null || true
    exit 0
  fi

  if [[ -n "$HEALTH_ISSUE" ]]; then
    logger -p daemon.warning "reality health-check: ${HEALTH_ISSUE} -- attempting one restart" 2>/dev/null || true
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    sleep 2

    STILL_BROKEN=0
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
      STILL_BROKEN=1
    elif ! ss -tln 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
      STILL_BROKEN=1
    fi

    if [[ "$STILL_BROKEN" -eq 1 ]]; then
      alert_on_transition "service-down" 1 \
        "health-check: xray.service still unhealthy after a restart attempt (${HEALTH_ISSUE}). Check: journalctl -u xray -e" ""
      err "Health check failed and self-heal restart did not resolve it: ${HEALTH_ISSUE}"
      # Deliberately not exiting here -- a broken service is exactly when
      # the checks below (disk, drift, clock, SNI, reboot-required,
      # webhook delivery) are most useful for troubleshooting, and while
      # this stays broken every subsequent 10-minute tick would otherwise
      # exit before ever reaching them again. Exit code is set now and
      # applied at the very end, after everything has run.
      HEALTH_EXIT_CODE=1
    else
      alert_on_transition "service-down" 0 "" "xray.service is healthy again after a restart"
      logger -p daemon.notice "reality health-check: restart resolved the issue (${HEALTH_ISSUE})" 2>/dev/null || true
      ok "Issue detected (${HEALTH_ISSUE}) -- restart resolved it."
    fi
  fi

  if [[ "$DRIFT_DETECTED" -eq 1 ]]; then
    alert_on_transition "config-drift" 1 \
      "health-check: ${CONFIG_FILE} does not match the last known-good checksum -- possible unexpected change. If you didn't hand-edit it, investigate." ""
  else
    alert_on_transition "config-drift" 0 "" ""
  fi

  if [[ "$BINARY_DRIFT" -eq 1 ]]; then
    alert_on_transition "binary-drift" 1 \
      "health-check: the installed xray binary (${XRAY_PATH_NOW}) does not match the checksum recorded after the last legitimate install/update. This could mean tampering, a manual replace, or disk corruption -- worth investigating before trusting this instance." ""
  else
    alert_on_transition "binary-drift" 0 "" "xray binary checksum matches the recorded known-good value again"
  fi

  if [[ "$LOW_DISK" -eq 1 ]]; then
    alert_on_transition "low-disk" 1 \
      "health-check: less than 512MB free on / (found $((AVAILABLE_KB / 1024))MB). Free up space before it affects updates, logs, or backups." ""
  else
    alert_on_transition "low-disk" 0 "" "disk space recovered above 512MB free"
  fi

  if [[ "$CLOCK_DRIFT" -eq 1 ]]; then
    alert_on_transition "clock-drift" 1 \
      "health-check: system clock is not NTP-synchronized. REALITY handshakes are timestamp-sensitive; check timedatectl status." ""
  else
    alert_on_transition "clock-drift" 0 "" "clock is NTP-synchronized again"
  fi

  if [[ "$SNI_BROKEN" -eq 1 ]]; then
    alert_on_transition "sni-broken" 1 \
      "health-check: REALITY camouflage target ${SNI_DOMAIN} no longer serves TLS1.3 on port 443. This can break handshakes; consider --rotate-all with a new SNI if it stays broken." ""
  else
    alert_on_transition "sni-broken" 0 "" "SNI camouflage target ${SNI_DOMAIN} is serving TLS1.3 again"
  fi

  if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    REBOOT_PKGS=""
    [[ -f /var/run/reboot-required.pkgs ]] && REBOOT_PKGS=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-200)
    alert_on_transition "reboot-required" 1 \
      "health-check: a package update requires a reboot to take effect${REBOOT_PKGS:+ (${REBOOT_PKGS})}. The daily reboot timer will handle it automatically; reboot manually sooner if you'd rather not wait." ""
  else
    alert_on_transition "reboot-required" 0 "" "pending reboot requirement cleared (system was rebooted)"
  fi

  # Webhook delivery self-check: everything above only reveals a broken
  # webhook when there's a real alert to send -- on an otherwise-healthy
  # server, that might never happen, so a bad URL or a dead receiver could
  # go unnoticed indefinitely. Actively verify delivery on its own slower
  # cadence (weekly, tracked via a timestamp marker rather than a second
  # timer unit) instead of only finding out passively.
  if [[ -n "$ALERT_WEBHOOK" ]] && command -v curl >/dev/null 2>&1; then
    WEBHOOK_CHECK_MARKER="${XRAY_CONFIG_DIR}/.last-webhook-verify"
    NOW_EPOCH=$(date +%s)
    LAST_VERIFY_EPOCH=0
    if [[ -f "$WEBHOOK_CHECK_MARKER" ]]; then
      LAST_VERIFY_EPOCH=$(cat "$WEBHOOK_CHECK_MARKER" 2>/dev/null || echo 0)
      [[ "$LAST_VERIFY_EPOCH" =~ ^[0-9]+$ ]] || LAST_VERIFY_EPOCH=0
    fi
    if [[ $((NOW_EPOCH - LAST_VERIFY_EPOCH)) -ge 604800 ]]; then  # 7 days
      if curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" \
          -d "{\"host\":\"$(hostname 2>/dev/null || echo unknown)\",\"message\":\"weekly webhook delivery check -- if you see this, alerting is working\"}" \
          "$ALERT_WEBHOOK" >/dev/null 2>&1; then
        echo "$NOW_EPOCH" > "$WEBHOOK_CHECK_MARKER" 2>/dev/null || true
      else
        # Can't route this through send_alert -- that would just retry
        # the same broken webhook. Local-only on purpose.
        logger -p daemon.warning "reality health-check: webhook delivery check failed -- alerts sent via --set-webhook may not be reaching ${ALERT_WEBHOOK}" 2>/dev/null || true
        wall "WARNING (xray REALITY): webhook alert delivery check failed. Alerts may not be reaching you -- check the URL or re-run: reality --set-webhook <url>" 2>/dev/null || true
      fi
    fi
  fi

  exit "$HEALTH_EXIT_CODE"
fi

# ---------------------------------------------------------------------------
# MODE: --update-core-only  (meant to run unattended on reality-autoupdate.timer)
#
# Just the Xray-core version-check-and-install logic from a full install,
# decoupled from everything else (apt upgrade, firewall, fail2ban, sysctl,
# etc). Restarts the service only if the binary actually changed, so a
# no-op check (already current) doesn't cause an unnecessary reconnect.
# Lets Xray-core stay current on a schedule without needing to remember to
# re-run the full script.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "update-core-only" ]]; then
  step "update-core" "Checking Xray-core for updates"
  BEFORE_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")

  XRAY_INSTALL_ATTEMPTS=3
  UPDATE_SUCCEEDED=0
  for attempt in $(seq 1 "$XRAY_INSTALL_ATTEMPTS"); do
    if bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install; then
      UPDATE_SUCCEEDED=1
      break
    fi
    if [[ "$attempt" -lt "$XRAY_INSTALL_ATTEMPTS" ]]; then
      echo "Xray-core update attempt ${attempt} failed, retrying in 5s..."
      sleep 5
    fi
  done

  if [[ "$UPDATE_SUCCEEDED" -ne 1 ]]; then
    warn "Could not reach the Xray-core installer after ${XRAY_INSTALL_ATTEMPTS} attempts (network issue?)."
    echo "         Will try again on the next scheduled run." >&2
    exit 1
  fi

  date +%s > "${XRAY_CONFIG_DIR}/.last-xray-checkupdate"
  AFTER_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")
  record_xray_binary_checksum

  # Backup integrity check runs before the restart below -- it doesn't
  # depend on the restart succeeding, and restart_and_verify exits the
  # script on failure, which would otherwise skip this check entirely on
  # exactly the run where a schema change is most likely to have just
  # happened. Confirms the most recent backup's config.json still passes
  # Xray's own schema validation against whatever binary is now installed.
  # A backup that silently stopped being restorable is only useful to
  # find out about now, not during an actual emergency restore.
  if [[ -d "$BACKUP_ROOT" ]]; then
    LATEST_BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1)
    if [[ -n "$LATEST_BACKUP_DIR" && -f "${LATEST_BACKUP_DIR}/config.json" ]]; then
      if ! xray run -test -format json -config "${LATEST_BACKUP_DIR}/config.json" >/dev/null 2>&1; then
        send_alert "update-core: the most recent backup (${LATEST_BACKUP_DIR}) no longer passes Xray's config validation against the currently installed binary. It may not restore cleanly with --restore if you needed it in an emergency -- consider running a plain re-run (reality) to refresh a known-good backup."
      fi
    fi
  fi

  if [[ "$BEFORE_XRAY_VERSION" == "$AFTER_XRAY_VERSION" ]]; then
    ok "Xray-core already current (${AFTER_XRAY_VERSION}) -- no restart needed."
  else
    ok "Xray-core updated: ${BEFORE_XRAY_VERSION} -> ${AFTER_XRAY_VERSION}"
    restart_and_verify
  fi

  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --restore <timestamp>  (restore config + state from a prior backup)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "restore" ]]; then
  RESTORE_DIR="${BACKUP_ROOT}/${RESTORE_TS}"
  if [[ ! -d "$RESTORE_DIR" ]]; then
    err "No backup found at ${RESTORE_DIR}."
    echo "       Run --list-backups to see available timestamps." >&2
    exit 1
  fi
  if [[ ! -f "${RESTORE_DIR}/config.json" ]]; then
    err "${RESTORE_DIR} doesn't contain a config.json -- can't restore from it."
    exit 1
  fi

  step "restore" "Restoring from backup: ${RESTORE_TS}"
  # Back up the current (about-to-be-overwritten) state too, so restoring
  # is itself undoable.
  backup_current_state

  if ! jq empty "${RESTORE_DIR}/config.json" >/dev/null 2>&1; then
    err "Backed-up config.json at ${RESTORE_DIR} is not valid JSON. Not restoring."
    exit 1
  fi

  # Same schema-level check write_config uses -- jq only confirms JSON
  # syntax, not that Xray's own schema still accepts this backup (e.g. if
  # it predates a field rename). Format must be specified explicitly since
  # this path doesn't end in .json.
  if command -v xray >/dev/null 2>&1; then
    if ! RESTORE_TEST_OUTPUT=$(xray run -test -format json -config "${RESTORE_DIR}/config.json" 2>&1); then
      err "Backed-up config.json at ${RESTORE_DIR} fails Xray's own schema check. Not restoring:"
      echo "$RESTORE_TEST_OUTPUT" | sed 's/^/  /' >&2
      exit 1
    fi
  fi

  cp -a "${RESTORE_DIR}/config.json" "$CONFIG_FILE"
  chown root:xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  # Refresh the drift-detection checksum too, or --health-check would flag
  # this restored (but legitimate) config as unexpectedly changed forever.
  (cd "$XRAY_CONFIG_DIR" && sha256sum "$(basename "$CONFIG_FILE")" > .config.sha256 2>/dev/null) || true
  chmod 600 "${XRAY_CONFIG_DIR}/.config.sha256" 2>/dev/null || true
  [[ -f "${RESTORE_DIR}/state" ]] && cp -a "${RESTORE_DIR}/state" "$STATE_FILE" && chmod 600 "$STATE_FILE"
  [[ -f "${RESTORE_DIR}/client-info.txt" ]] && cp -a "${RESTORE_DIR}/client-info.txt" "$CLIENT_INFO_FILE" && chmod 600 "$CLIENT_INFO_FILE"

  restart_and_verify
  echo ""
  echo "Restored from ${RESTORE_TS}. Run --show to reprint the restored client link."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --rotate-uuid  (new UUID + short ID; keeps REALITY keypair)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "rotate-uuid" ]]; then
  step "rotate-uuid" "Rotating UUID + short ID (REALITY keypair unchanged)"
  if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    err "No existing REALITY keypair found in state. Run a full install first."
    exit 1
  fi
  backup_current_state
  generate_uuid_and_shortid
  write_config
  finish_and_restart
  echo ""
  echo "Old client link is now invalid. Any device using it must import the new link above."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --change-sni [domain]  (new REALITY camouflage target only; keeps
# UUID, short ID, and REALITY keypair unchanged)
#
# Previously the only way to change the SNI was --rotate-all, which also
# regenerates the REALITY keypair -- unnecessary blast radius if all you
# actually want is a different camouflage target (e.g. the current one
# stopped serving TLS1.3, or you just want a less-common choice than the
# pool default). This changes only realitySettings.target/serverNames.
#
# Still invalidates existing client links, same as --rotate-uuid: the
# server's REALITY serverName has to match what's in a client's saved
# config, so anything importing the old link needs the new one after this.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "change-sni" ]]; then
  if [[ -z "$UUID" || -z "$PRIVATE_KEY" ]]; then
    err "No existing install found (${STATE_FILE}). Run a full install first."
    exit 1
  fi

  NEW_SNI="$NEW_SNI_ARG"
  if [[ -n "$NEW_SNI" ]]; then
    # Same sanitization as the install-time prompt: strip scheme, path,
    # port, in case someone pastes a full URL by mistake.
    NEW_SNI="${NEW_SNI#http://}"
    NEW_SNI="${NEW_SNI#https://}"
    NEW_SNI="${NEW_SNI%%/*}"
    NEW_SNI="${NEW_SNI%%:*}"
  fi

  if [[ -z "$NEW_SNI" ]]; then
    if [[ ! -t 0 ]]; then
      err "--change-sni requires a domain when there's no terminal to prompt on."
      echo "       Usage: reality --change-sni <domain>   (add --force to skip the live TLS1.3 check)" >&2
      exit 1
    fi
    while true; do
      echo ""
      echo "Change REALITY camouflage target (SNI)"
      echo "Current: ${SNI_DOMAIN}"
      read -r -t 300 -p "New domain to use: " NEW_SNI || true
      if [[ -z "$NEW_SNI" ]]; then
        echo "No domain entered. Cancelled -- no changes made."
        exit 0
      fi
      NEW_SNI="${NEW_SNI#http://}"
      NEW_SNI="${NEW_SNI#https://}"
      NEW_SNI="${NEW_SNI%%/*}"
      NEW_SNI="${NEW_SNI%%:*}"
      if [[ "$NEW_SNI" == "$SNI_DOMAIN" ]]; then
        echo "That's already the current SNI. No changes made."
        exit 0
      fi
      if command -v openssl >/dev/null 2>&1; then
        if timeout 6 openssl s_client -connect "${NEW_SNI}:443" -servername "${NEW_SNI}" -tls1_3 </dev/null >/dev/null 2>&1; then
          ok "Confirmed: ${NEW_SNI} resolves and serves TLS1.3 on port 443."
          break
        else
          warn "Couldn't confirm ${NEW_SNI} serves TLS1.3 on port 443."
          read -r -t 300 -p "Use it anyway? (y/N): " SNI_FORCE || true
          [[ "$SNI_FORCE" =~ ^[Yy]$ ]] && break
          # loop back and re-prompt
        fi
      else
        break
      fi
    done
  else
    if [[ "$NEW_SNI" == "$SNI_DOMAIN" ]]; then
      echo "That's already the current SNI ('${SNI_DOMAIN}'). No changes made."
      exit 0
    fi
    if command -v openssl >/dev/null 2>&1 && ! timeout 6 openssl s_client -connect "${NEW_SNI}:443" -servername "${NEW_SNI}" -tls1_3 </dev/null >/dev/null 2>&1; then
      if [[ "$FORCE_CONFIRM" -ne 1 ]]; then
        err "Could not verify '${NEW_SNI}' serves TLS1.3 on port 443."
        echo "       Re-run with --force to use it anyway: reality --change-sni ${NEW_SNI} --force" >&2
        exit 1
      fi
      warn "Could not verify TLS1.3 for '${NEW_SNI}', proceeding anyway (--force)."
    fi
  fi

  step "change-sni" "Changing REALITY SNI: ${SNI_DOMAIN} -> ${NEW_SNI}"
  backup_current_state
  SNI_DOMAIN="$NEW_SNI"
  write_config
  finish_and_restart
  echo ""
  echo "Old client link is now invalid (REALITY serverName mismatch)."
  echo "Any device using it must import the new link above."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: --rotate-all  (new UUID + short ID + REALITY keypair)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "rotate-all" ]]; then
  if [[ -t 0 ]]; then
    echo ""
    warn "This invalidates EVERY existing client link. Not undoable except by --restore."
    read -r -t 300 -p "Type 'yes' to continue: " CONFIRM_ROTATE_ALL || true
    if [[ "$CONFIRM_ROTATE_ALL" != "yes" ]]; then
      echo "Cancelled. No changes made."
      exit 0
    fi
  elif [[ "$FORCE_CONFIRM" -ne 1 ]]; then
    # No TTY to prompt on (cron, CI, remote orchestration, etc). Previously
    # this silently proceeded with a fully destructive, only-undoable-via-
    # --restore action with zero confirmation. Require an explicit --force
    # (or --yes) instead of defaulting to "go ahead".
    err "--rotate-all invalidates EVERY existing client link and there's no TTY to confirm on."
    echo "       Re-run with --rotate-all --force if you're sure this is intentional" >&2
    echo "       (e.g. from a script or cron job), or run it interactively instead." >&2
    exit 1
  fi
  step "rotate-all" "Rotating ALL credentials (UUID, short ID, REALITY keypair)"
  backup_current_state
  generate_uuid_and_shortid
  generate_reality_keypair
  write_config
  finish_and_restart
  echo ""
  echo "All previous client links are now permanently invalid."
  exit 0
fi

# ---------------------------------------------------------------------------
# MODE: install (default) — full setup, safe to re-run
# ---------------------------------------------------------------------------

# Best-effort check: is the copy of this script actually running (e.g. the
# installed 'reality' shortcut) behind what's currently on GitHub? This is
# a NOTIFICATION only -- it never replaces or modifies the running script
# (self-modifying a script mid-execution is a real footgun: truncated
# reads, races). It just tells you clearly if you're out of date and how
# to fix it. Silently skipped if $0 isn't a real file (e.g. piped via
# process substitution -- that path already always re-downloads fresh) or
# if GitHub isn't reachable within a few seconds.
#
# Runs in the background so its network round-trip overlaps with the SNI
# prompt (waiting on you) and step 1's apt operations below, instead of
# adding its own few seconds serially before anything else starts. The
# result is collected further down, once there's been time for it to finish.
SELF_UPDATE_CHECK_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
SELF_UPDATE_RESULT_FILE=$(mktemp)
SELF_UPDATE_BG_PID=""
if [[ -f "$SELF_UPDATE_CHECK_PATH" ]]; then
  (
    # Close the inherited lock fd immediately -- otherwise, if the parent
    # script exits early (e.g. apt-get update fails under set -e) before
    # this background job finishes, this orphaned subshell keeps its own
    # copy of the flock held for as long as it keeps running, blocking a
    # re-run unnecessarily in the meantime.
    exec 200>&- 2>/dev/null || true
    REMOTE_SCRIPT_TMP=$(mktemp)
    if curl -fsSL --connect-timeout 5 --max-time 10 "$SCRIPT_SOURCE_URL" -o "$REMOTE_SCRIPT_TMP" 2>/dev/null \
       && bash -n "$REMOTE_SCRIPT_TMP" 2>/dev/null; then
      LOCAL_HASH=$(sha256sum "$SELF_UPDATE_CHECK_PATH" 2>/dev/null | awk '{print $1}')
      REMOTE_HASH=$(sha256sum "$REMOTE_SCRIPT_TMP" 2>/dev/null | awk '{print $1}')
      if [[ -n "$LOCAL_HASH" && -n "$REMOTE_HASH" && "$LOCAL_HASH" != "$REMOTE_HASH" ]]; then
        echo "outdated" > "$SELF_UPDATE_RESULT_FILE"
      fi
    fi
    rm -f "$REMOTE_SCRIPT_TMP"
  ) &
  SELF_UPDATE_BG_PID=$!
fi

# Only prompt for a custom SNI on a genuinely first-time install (no UUID
# yet means no existing state) and only when there's an actual interactive
# terminal to prompt on -- piped/scripted/non-interactive runs just fall
# through to the existing default (env var override, or the pool-randomized
# pick from SNI_POOL -- see the non-interactive verification block further
# down for how that gets checked too).
if [[ -z "$UUID" ]] && [[ -t 0 ]]; then
  while true; do
    echo ""
    echo "REALITY camouflage target (SNI)"
    echo "This is the real site Xray impersonates during the TLS handshake."
    echo "It should be a real TLS1.3 site, not a huge one (avoid google.com/"
    echo "microsoft.com-scale sites -- large certs can trip protocol issues,"
    echo "and CDN-fronted domains make REALITY easier to fingerprint)."
    read -r -t 300 -p "Domain to use [${SNI_DOMAIN}]: " SNI_INPUT || true
    if [[ -n "$SNI_INPUT" ]]; then
      # Basic sanitization in case someone pastes a full URL by mistake:
      # strip scheme, path, port, and trailing slashes -- keep just the host.
      SNI_INPUT="${SNI_INPUT#http://}"
      SNI_INPUT="${SNI_INPUT#https://}"
      SNI_INPUT="${SNI_INPUT%%/*}"
      SNI_INPUT="${SNI_INPUT%%:*}"
      if [[ -n "$SNI_INPUT" ]]; then
        SNI_DOMAIN="$SNI_INPUT"
      fi
    fi

    # Best-effort live check: does this domain actually resolve and serve
    # TLS1.3 on 443? openssl may not be installed yet this early (that
    # happens in step 1 below) -- skip the check gracefully if so, rather
    # than block on a tool that isn't there yet.
    if command -v openssl >/dev/null 2>&1; then
      if timeout 6 openssl s_client -connect "${SNI_DOMAIN}:443" -servername "${SNI_DOMAIN}" -tls1_3 </dev/null >/dev/null 2>&1; then
        ok "Confirmed: ${SNI_DOMAIN} resolves and serves TLS1.3 on port 443."
        break
      else
        warn "Couldn't confirm ${SNI_DOMAIN} serves TLS1.3 on port 443 (DNS failure, no"
        echo "         response, or TLS1.3 unsupported). REALITY requires this to work." >&2
        read -r -t 300 -p "Use it anyway? (y/N): " SNI_FORCE || true
        if [[ "$SNI_FORCE" =~ ^[Yy]$ ]]; then
          break
        fi
        # loop back and re-prompt
      fi
    else
      break
    fi
  done
  echo "Using: ${SNI_DOMAIN}"
fi

# Non-interactive first installs (piped/scripted/automated) previously
# skipped SNI verification entirely -- the live TLS1.3 check above only
# ever ran inside the interactive prompt loop. That left the (now
# pool-randomized) default entirely unverified for anyone running this via
# `bash <(curl ...)` non-interactively or through automation. Do the same
# live check here, falling through the rest of the pool if the picked
# candidate fails, rather than silently proceeding with something REALITY
# might not actually work against.
if [[ -z "$UUID" ]] && [[ ! -t 0 ]] && command -v openssl >/dev/null 2>&1; then
  SNI_VERIFIED=0
  for candidate in "$SNI_DOMAIN" "${SNI_POOL[@]}"; do
    if timeout 6 openssl s_client -connect "${candidate}:443" -servername "${candidate}" -tls1_3 </dev/null >/dev/null 2>&1; then
      if [[ "$candidate" != "$SNI_DOMAIN" ]]; then
        warn "SNI target '${SNI_DOMAIN}' didn't verify; using '${candidate}' instead (first pool candidate that passed a live TLS1.3 check)."
      fi
      SNI_DOMAIN="$candidate"
      SNI_VERIFIED=1
      break
    fi
  done
  if [[ "$SNI_VERIFIED" -ne 1 ]]; then
    warn "Could not verify TLS1.3 on port 443 for any SNI candidate (network issue during install?)."
    echo "         Proceeding with '${SNI_DOMAIN}' unverified -- if the tunnel doesn't work," >&2
    echo "         check connectivity and reconsider the SNI with --rotate-all." >&2
  fi
fi

step "1/10" "Preparing server (updates, cleanup, essential tools)"
export DEBIAN_FRONTEND=noninteractive
# -o DPkg::Lock::Timeout=300: fresh VPS instances commonly have
# unattended-upgrades holding the dpkg lock for the first few minutes
# after boot. Without this, apt-get fails immediately instead of waiting
# for it to finish -- wait up to 5 minutes rather than failing outright.
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 upgrade -y
apt-get -o DPkg::Lock::Timeout=300 autoremove -y --purge
apt-get -o DPkg::Lock::Timeout=300 autoclean -y

# Packages this script actually depends on -- install must succeed.
# --no-install-recommends skips recommended-but-unused extras (docs,
# fonts, etc.) that several of these commonly pull in by default on a
# headless VPS that doesn't need them -- a real, if modest, bandwidth
# and install-time saving on every run that needs to install anything here.
# (unzip isn't referenced by name below, but is a real dependency of the
# official Xray installer script itself, which unzips the downloaded
# release -- confirmed by reading that installer's source directly.)
apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
  curl unzip jq openssl qrencode ufw fail2ban ca-certificates

# logrotate is the only "nice to have" actually used (by the
# /etc/logrotate.d/xray config written in step 8). Not required by
# anything else, so a missing package here should warn, not abort.
if ! apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends logrotate; then
  echo "NOTE: logrotate was unavailable; continuing anyway. Xray's error log just won't"
  echo "      be rotated automatically until it's installed."
fi

if [[ -f /var/run/reboot-required ]]; then
  echo "NOTE: A previous update marked this system as needing a reboot."
  echo "      The daily reboot timer set up later in this script will handle it,"
  echo "      or reboot manually now with: reboot"
fi

# Collect the backgrounded self-update check (started before the SNI
# prompt) now that step 1's apt operations have given it plenty of time
# to finish -- its network round-trip overlapped with real work above
# instead of adding its own delay serially before anything started.
if [[ -n "$SELF_UPDATE_BG_PID" ]]; then
  wait "$SELF_UPDATE_BG_PID" 2>/dev/null || true
  if [[ -s "$SELF_UPDATE_RESULT_FILE" ]]; then
    warn "This copy of the script is out of date (differs from ${SCRIPT_SOURCE_URL})."
    echo "         Update with: bash <(curl -Ls ${SCRIPT_SOURCE_URL})" >&2
    echo "         Continuing with the current (older) copy for this run." >&2
  fi
fi
rm -f "$SELF_UPDATE_RESULT_FILE"

step "2/10" "Installing Xray-core (official installer)"
mkdir -p "$XRAY_CONFIG_DIR"
BEFORE_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")

# The official installer always makes a full network round-trip to check
# the latest release, even when almost certainly already current. Skip
# that full check if we already have xray installed and checked within
# the last 24h -- falls back to the full check on first install, or once
# the cache goes stale, so this can't silently skip updates forever.
XRAY_UPDATE_CHECK_CACHE="${XRAY_CONFIG_DIR}/.last-xray-checkupdate"
SKIP_INSTALLER_CHECK=0
if command -v xray >/dev/null 2>&1 && [[ -f "$XRAY_UPDATE_CHECK_CACHE" ]]; then
  LAST_CHECK=$(cat "$XRAY_UPDATE_CHECK_CACHE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ "$LAST_CHECK" =~ ^[0-9]+$ ]] && [[ $((NOW - LAST_CHECK)) -lt 86400 ]]; then
    SKIP_INSTALLER_CHECK=1
  fi
fi

if [[ "$SKIP_INSTALLER_CHECK" -eq 1 ]]; then
  ok "Xray-core was checked for updates within the last 24h -- skipping the full check this run."
else
  XRAY_INSTALL_ATTEMPTS=3
  for attempt in $(seq 1 "$XRAY_INSTALL_ATTEMPTS"); do
    if bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install; then
      break
    fi
    if [[ "$attempt" -eq "$XRAY_INSTALL_ATTEMPTS" ]]; then
      err "Failed to install Xray-core after ${XRAY_INSTALL_ATTEMPTS} attempts (likely a network issue reaching GitHub)."
      exit 1
    fi
    echo "Xray-core install attempt ${attempt} failed, retrying in 5s..."
    sleep 5
  done
  date +%s > "$XRAY_UPDATE_CHECK_CACHE"
fi

AFTER_XRAY_VERSION=$(xray version 2>/dev/null | head -n1 || echo "none")
record_xray_binary_checksum

step "3/10" "Setting up credentials (UUID, REALITY keypair, short ID)"
if [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" ]]; then
  echo "Existing credentials found in ${STATE_FILE} -- reusing them (client links stay valid)."
  echo "Need fresh credentials instead? Use --rotate-uuid or --rotate-all, not a plain re-run."
else
  echo "No existing credentials found -- generating new ones (first-time install)."
  generate_uuid_and_shortid
  generate_reality_keypair
fi

# Dedicated unprivileged system account for the xray service to run as
# (see step 5 below). Created here, before write_config, so the config
# file's ownership can be set correctly on first install.
if ! id -u xray >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin xray
fi

# Catch a port conflict here with a clear message, rather than letting it
# surface later as a generic "service failed to start". A listener that IS
# our own xray (e.g. a re-run on an already-running instance) is expected
# and fine; anything else bound to this port is a real conflict.
PORT_HOLDER=$(ss -tlnp 2>/dev/null | awk -v p=":${LISTEN_PORT}\$" '$4 ~ p {print}')
if [[ -n "$PORT_HOLDER" ]] && ! echo "$PORT_HOLDER" | grep -qi "xray"; then
  err "Port ${LISTEN_PORT} is already in use by something other than Xray:"
  echo "$PORT_HOLDER" | sed 's/^/  /' >&2
  echo "  Stop that service first, or choose a different port (LISTEN_PORT=... env var)." >&2
  exit 1
fi

step "4/10" "Writing Xray config (privacy-minded: no access logging)"
write_config
ok "Config written and validated"

# Best-effort check: is the DoH DNS config we just wrote actually reachable
# from this VPS? Some regions/networks block DoH providers at the network
# level -- if that happens, Xray's own domain-based routing could silently
# fail even though the REALITY tunnel itself stays up, since the two are
# largely independent. Non-fatal, since a transient failure here isn't
# worth aborting the whole install over.
DOH_UNREACHABLE=""
for doh_host in 1.1.1.1 9.9.9.9; do
  DOH_CODE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "https://${doh_host}/dns-query" 2>/dev/null)
  DOH_RC=$?
  if [[ "$DOH_RC" -ne 0 ]] || [[ "$DOH_CODE" == "000" ]]; then
    DOH_UNREACHABLE="${DOH_UNREACHABLE}${doh_host} "
  fi
done
if [[ -n "$DOH_UNREACHABLE" ]]; then
  warn "Could not reach the configured DoH DNS server(s): ${DOH_UNREACHABLE}"
  echo "         If this VPS's network blocks these, Xray's own domain-based" >&2
  echo "         routing may fail even though REALITY itself still works." >&2
  echo "         Check reachability manually, or edit the \"dns\" block in" >&2
  echo "         ${CONFIG_FILE} to use a DoH provider that works from here." >&2
fi

step "5/10" "Hardening the systemd service"
mkdir -p /etc/systemd/system/${SERVICE_NAME}.service.d
OVERRIDE_CONF="/etc/systemd/system/${SERVICE_NAME}.service.d/override.conf"
# Same "only restart if something actually changed" logic write_config uses
# for config.json -- otherwise the systemd hardening drop-in gets silently
# rewritten on every re-run but never actually takes effect until some
# unrelated later reboot, since the final restart decision only checked
# CONFIG_CHANGED and the Xray-core version, not this file.
OVERRIDE_CONF_CHANGED=0
OVERRIDE_CONF_TMP=$(mktemp)
cat > "$OVERRIDE_CONF_TMP" <<'EOF'
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
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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
EOF

if [[ -f "$OVERRIDE_CONF" ]] && cmp -s "$OVERRIDE_CONF_TMP" "$OVERRIDE_CONF"; then
  rm -f "$OVERRIDE_CONF_TMP"
else
  OVERRIDE_CONF_CHANGED=1
  mv -f "$OVERRIDE_CONF_TMP" "$OVERRIDE_CONF"
fi

# OnFailure= above fires once the restart-attempt budget (StartLimitBurst)
# is exhausted and the service gives up -- not on every individual
# transient restart. Routes through the shared send_alert() logic (via
# `reality --send-alert`) so this reaches the optional webhook too, not
# just local logger/wall -- see --set-webhook. The /usr/local/bin/reality
# path is hardcoded rather than looked up: this unit only actually fires
# later, by which point step 10 below has always installed the shortcut
# (on both a fresh install and every re-run), so this ordering is safe.
cat > /etc/systemd/system/xray-alert.service <<'EOF'
[Unit]
Description=Local alert when xray.service exhausts its restart attempts

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/bin/reality --send-alert "xray.service has FAILED and exhausted its restart attempts -- check: journalctl -u xray -e" || { logger -p daemon.crit "xray.service has FAILED and exhausted its restart attempts -- check: journalctl -u xray -e"; wall "WARNING: xray.service has failed and given up restarting. Check: journalctl -u xray -e"; }'
EOF

# Catch unit-file mistakes automatically (e.g. a directive sitting in the
# wrong section, silently ignored by systemd) instead of relying on
# someone noticing manually -- this exact class of bug was found once
# already in this script's own override.conf during manual testing.
# Non-fatal: this is a best-effort catch, not a hard gate.
#
# Filters out the "Special user nobody configured" warning: the official
# Xray installer's base unit always sets User=nobody by default (confirmed
# from its source), which our own drop-in correctly overrides to
# User=xray -- but systemd-analyze reports it against the unmerged base
# file regardless, so it fires on every single real install whether or
# not our own override actually has a problem. Suppressing this specific,
# expected, already-handled line keeps the check meaningful instead of
# crying wolf every run.
if command -v systemd-analyze >/dev/null 2>&1; then
  SYSTEMD_VERIFY_OUTPUT=$(systemd-analyze verify "${SERVICE_NAME}.service" xray-alert.service 2>&1 | grep -v "Special user nobody configured" || true)
  if [[ -n "$SYSTEMD_VERIFY_OUTPUT" ]]; then
    warn "systemd-analyze flagged potential issues with the unit files just written:"
    echo "$SYSTEMD_VERIFY_OUTPUT" | sed 's/^/  /' >&2
  fi
fi

# Reload the unit + drop-in now so the change is registered, but hold off
# on actually restarting until every other step below has succeeded --
# see the single restart_and_verify call at the very end of install mode.
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true

# REALITY's handshake validation is timestamp-sensitive -- clock drift
# causes intermittent, confusing failures. Confirm NTP sync is active
# rather than assuming the base image has it enabled.
if command -v timedatectl >/dev/null 2>&1; then
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
    sleep 2
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
      warn "System clock is not confirmed NTP-synchronized."
      echo "         REALITY handshakes are timestamp-sensitive; clock drift can cause" >&2
      echo "         intermittent failures. Check: timedatectl status" >&2
    fi
  fi
fi

step "6/10" "Configuring firewall (UFW)"
SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | head -n1)
SSH_PORT="${SSH_PORT:-22}"

# If SSH was ever reconfigured to a different port through some other means,
# an old rule for the previous port could still be sitting here, open
# forever. Detect and flag it -- but don't auto-delete: this script can't
# tell a genuinely stale rule apart from an intentional second SSH listener,
# and getting that wrong risks locking you out.
STALE_SSH_RULES=$(ufw status numbered 2>/dev/null | grep "SSH" | grep -v "${SSH_PORT}/tcp" || true)
if [[ -n "$STALE_SSH_RULES" ]]; then
  echo "NOTE: Found UFW rule(s) tagged 'SSH' for a port other than the current one (${SSH_PORT}):"
  echo "$STALE_SSH_RULES"
  echo "      If SSH used to run on a different port, this is probably stale and safe to"
  echo "      remove with: ufw delete <rule number>   (run 'ufw status numbered' to check)"
fi

# Make sure UFW actually enforces IPv6 too -- if IPV6=no here, the rules
# below only apply to IPv4 and a public IPv6 address (common on many VPS
# providers by default) would be left completely unfiltered.
if [[ -f /etc/default/ufw ]] && grep -qE '^IPV6=no' /etc/default/ufw; then
  sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
  echo "Enabled IPv6 support in UFW (was disabled; would have left IPv6 unfiltered)."
fi

# Pin the default policy explicitly rather than relying on whatever the
# base image shipped with.
ufw default deny incoming
ufw default allow outgoing

# These two rules are load-bearing (lose either one and you either can't
# SSH in or the proxy stops working), so a failure here should stop the
# script rather than be silently swallowed.
if ! ufw allow "${SSH_PORT}"/tcp comment 'SSH'; then
  err "Failed to add UFW rule for SSH port ${SSH_PORT}. Not enabling the firewall."
  echo "       Fix manually, then re-run: ufw allow ${SSH_PORT}/tcp && ufw --force enable" >&2
  exit 1
fi
if ! ufw allow "${LISTEN_PORT}"/tcp comment 'Xray REALITY'; then
  err "Failed to add UFW rule for Xray port ${LISTEN_PORT}. Not enabling the firewall."
  exit 1
fi

ufw --force enable
ufw reload

if ! ufw status | grep -q "Status: active"; then
  err "UFW did not report active after enabling. The firewall may not be"
  echo "       protecting this server. Check: ufw status verbose" >&2
  exit 1
fi

step "7/10" "Configuring fail2ban for SSH brute-force protection"
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
  warn "fail2ban did not come up after restart. SSH brute-force protection"
  echo "         is NOT active. Check: journalctl -u fail2ban -e" >&2
elif ! fail2ban-client status sshd >/dev/null 2>&1; then
  # The daemon can be "active" while a specific jail still failed to load
  # (e.g. a typo in the jail config) -- confirm the sshd jail itself is
  # actually there, not just that the fail2ban process started.
  warn "fail2ban is running, but the sshd jail did not load. SSH brute-force"
  echo "         protection is NOT active. Check: fail2ban-client status" >&2
fi

step "8/10" "Enabling BBR + basic kernel/network hardening"

# systemd-sysctl.service does NOT wait for or trigger on-demand kernel
# module loading -- confirmed via the official sysctl.d(5) manpage. A
# sysctl parameter that depends on a not-yet-loaded module (like
# tcp_congestion_control=bbr depending on the tcp_bbr module, which is
# built as a loadable module rather than compiled-in on most Debian/
# Ubuntu kernels) can silently fail to apply on every boot -- including
# our own daily reboot timer -- unless the module is loaded via
# modules-load.d BEFORE sysctl settings are processed at boot.
modprobe tcp_bbr 2>/dev/null || true
mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat > /etc/sysctl.d/99-xray-hardening.conf <<'EOF'
# Congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Basic network hardening (.all applies to existing interfaces, .default
# applies to interfaces that come up after this is set)
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

# Restrict ptrace to direct child processes only -- blunts a class of
# local privilege escalation via one process attaching a debugger to another
kernel.yama.ptrace_scope = 1

# Throughput/latency tuning for a proxy carrying real traffic
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF
sysctl --system >/dev/null

ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$ACTIVE_CC" != "bbr" ]]; then
  warn "Requested BBR but the kernel reports '${ACTIVE_CC}' as active."
  echo "         Likely cause: the tcp_bbr kernel module isn't available on this kernel." >&2
  echo "         Check: modprobe tcp_bbr && sysctl net.ipv4.tcp_congestion_control=bbr" >&2
  echo "         Not fatal -- proxy still works, just without BBR's throughput benefit." >&2
fi

# net.core.default_qdisc only governs qdisc assignment for interfaces that
# come up AFTER this sysctl takes effect -- it does NOT retroactively
# change the qdisc on an interface that was already up at boot, which is
# always the case for the primary interface on a running VPS. BBR relies
# on fq specifically for its internal pacing, so apply it live to the
# actual interface rather than assuming the sysctl default covers it.
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
if [[ -n "$PRIMARY_IFACE" ]]; then
  CURRENT_QDISC=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/root/ {print $2; exit}')
  if [[ "$CURRENT_QDISC" != "fq" ]]; then
    if tc qdisc replace dev "$PRIMARY_IFACE" root fq 2>/dev/null; then
      ok "Applied fq qdisc live to ${PRIMARY_IFACE} (was: ${CURRENT_QDISC:-unknown})."
    else
      warn "Could not apply fq qdisc live to ${PRIMARY_IFACE} (was: ${CURRENT_QDISC:-unknown})."
      echo "         BBR still works without it, just without full pacing benefit until next reboot" >&2
      echo "         (the daily reboot timer will pick up the sysctl default at that point)." >&2
    fi
  fi
fi

# Cap the systemd journal's disk usage explicitly rather than trusting
# whatever default the base image shipped with.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-xray-hardening.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald

# Prevent /var/log/xray/error.log from growing unbounded on a long-lived box.
# mkdir -p first: logrotate install is best-effort (see step 1) and warns
# rather than aborts if it's unavailable, so /etc/logrotate.d might not
# exist yet on a minimal image -- without this, writing straight into a
# missing directory would fail under `set -e`.
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

# The audit log ($AUDIT_LOG, appended to on every single run/timer tick via
# the EXIT trap) had no rotation -- low volume per entry, but unbounded
# over years of a --health-check firing every 10 minutes. Cap it the same
# way as Xray's own error log.
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

step "9/10" "Setting up daily reboot at midnight"
# RandomizedDelaySec below spreads the actual reboot over a ~30min window
# rather than firing at exactly 00:00:00 -- this script is public, so every
# install left at the default would otherwise reboot in lockstep, which is
# a free correlation signal for anyone trying to fingerprint REALITY
# servers running this setup at scale. Costs nothing functionally.
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

if command -v systemd-analyze >/dev/null 2>&1; then
  SYSTEMD_VERIFY_OUTPUT=$(systemd-analyze verify daily-reboot.service daily-reboot.timer 2>&1 || true)
  if [[ -n "$SYSTEMD_VERIFY_OUTPUT" ]]; then
    warn "systemd-analyze flagged potential issues with the reboot timer units:"
    echo "$SYSTEMD_VERIFY_OUTPUT" | sed 's/^/  /' >&2
  fi
fi

systemctl daemon-reload
systemctl enable --now daily-reboot.timer

# Install a short-name copy so this script can be run as 'reality' from
# anywhere, instead of needing to remember/find the original file path.
# Copies the content (not a symlink), so it keeps working even if the
# original downloaded copy is moved or deleted.
#
# If $0 isn't a real file (e.g. run via `bash <(curl -Ls ...)`, where $0
# points to a process-substitution pipe, not a regular file), fall back
# to re-downloading the script fresh from SCRIPT_SOURCE_URL instead.
REALITY_SHORTCUT="/usr/local/bin/reality"
SELF_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
REALITY_SHORTCUT_RESOLVED=$(readlink -f "$REALITY_SHORTCUT" 2>/dev/null || echo "$REALITY_SHORTCUT")

if [[ "$SELF_PATH" == "$REALITY_SHORTCUT_RESOLVED" ]]; then
  # Already running as the installed shortcut -- nothing to copy onto itself.
  chmod +x "$REALITY_SHORTCUT" 2>/dev/null || true
elif [[ -f "$SELF_PATH" ]]; then
  cp -f "$SELF_PATH" "$REALITY_SHORTCUT"
  chmod +x "$REALITY_SHORTCUT"
else
  REALITY_SHORTCUT_TMP=$(mktemp)
  if curl -fsSL --connect-timeout 10 --max-time 30 "$SCRIPT_SOURCE_URL" -o "$REALITY_SHORTCUT_TMP" 2>/dev/null \
     && bash -n "$REALITY_SHORTCUT_TMP" 2>/dev/null; then
    # Only install it once we've confirmed the download is complete and
    # syntactically valid -- a truncated/partial download would otherwise
    # silently replace a working shortcut with a broken one.
    mv -f "$REALITY_SHORTCUT_TMP" "$REALITY_SHORTCUT"
    chmod +x "$REALITY_SHORTCUT"
  else
    rm -f "$REALITY_SHORTCUT_TMP"
    warn "Could not install the 'reality' shortcut (this run wasn't from a"
    echo "         real file on disk, e.g. 'bash <(curl ...)', and re-downloading" >&2
    echo "         from ${SCRIPT_SOURCE_URL} also failed or returned an incomplete file)." >&2
    echo "         Everything else succeeded -- to add the shortcut manually:" >&2
    echo "           curl -fsSL ${SCRIPT_SOURCE_URL} -o ${REALITY_SHORTCUT} && chmod +x ${REALITY_SHORTCUT}" >&2
  fi
fi

step "10/10" "Setting up unattended reliability (watchdog, auto-update, drift check, login summary)"

# Only wire up timers that call `reality --health-check` / `--update-core-only`
# if the shortcut is actually present -- if it failed to install above (rare,
# only when both $0 wasn't a real file and re-downloading failed), don't
# create timers that would just fail every run.
if [[ -x "$REALITY_SHORTCUT" ]]; then
  REALITY_TIMERS_ENABLED=1

  # Watchdog: catches "process is technically active but not actually
  # serving REALITY correctly" between manual runs -- see --health-check
  # mode for what it checks. One self-heal restart attempt, then loud local
  # alerting (logger + wall) if that doesn't fix it.
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

  # Auto-update: keeps Xray-core current on a schedule, independent of
  # remembering to re-run the full script. RandomizedDelaySec spreads load
  # on the upstream installer and avoids every install checking in lockstep.
  cat > /etc/systemd/system/reality-autoupdate.service <<EOF
[Unit]
Description=Check for and apply Xray-core updates

[Service]
Type=oneshot
ExecStart=${REALITY_SHORTCUT} --update-core-only
EOF

  cat > /etc/systemd/system/reality-autoupdate.timer <<'EOF'
[Unit]
Description=Weekly Xray-core update check

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Backup maintenance: runs --dedupe-backups on a schedule instead of only
  # when someone remembers to run it by hand. Low-risk (only ever collapses
  # consecutive identical-content backups, never touches a genuinely
  # distinct one -- see --dedupe-backups itself), so safe to leave
  # unattended.
  cat > /etc/systemd/system/reality-backup-maintenance.service <<EOF
[Unit]
Description=Prune redundant duplicate Xray REALITY backups

[Service]
Type=oneshot
ExecStart=${REALITY_SHORTCUT} --dedupe-backups
EOF

  cat > /etc/systemd/system/reality-backup-maintenance.timer <<'EOF'
[Unit]
Description=Weekly backup deduplication

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now reality-watchdog.timer reality-autoupdate.timer reality-backup-maintenance.timer >/dev/null 2>&1 || \
    warn "Could not enable one or more timers. Check: systemctl list-timers 'reality-*'"
  ok "Watchdog (every 10min), auto-update (weekly), and backup maintenance (weekly) timers enabled."
else
  REALITY_TIMERS_ENABLED=0
  warn "Skipping watchdog/auto-update/backup-maintenance timers -- the 'reality' shortcut isn't in place (see above)."
fi

# Login summary: surfaces service/firewall/backup state passively on every
# SSH login (via --status, which already exists), rather than requiring
# someone to remember to run it. Purely informational -- never blocks login.
mkdir -p /etc/update-motd.d
cat > /etc/update-motd.d/99-xray-reality <<EOF
#!/bin/sh
${REALITY_SHORTCUT} --status 2>/dev/null | head -n 20
EOF
chmod +x /etc/update-motd.d/99-xray-reality

# Restrict unattended-upgrades to security updates only. A default install
# of unattended-upgrades applies non-security updates too, independently of
# and uncoordinated with this script's own apt runs and daily reboot timer
# -- on a proxy server, minimizing uncoordinated package churn is worth
# more than staying maximally up to date on non-security packages.
# Best-effort: only written if unattended-upgrades is actually present.
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

# Everything above (config, firewall, fail2ban, sysctl, reboot timer) is
# now in place. Print the client link/QR and all summary info first, and
# restart xray as the literal last action of the whole script.
save_state
output_client_info

echo ""
echo "Setup complete. Server will reboot daily at ~00:00 (+/-30min jitter, server local time)."
echo "Check timezone with: timedatectl   (change with: timedatectl set-timezone <Region/City>)"
echo "Cancel the daily reboot with: systemctl disable --now daily-reboot.timer"
if [[ "$REALITY_TIMERS_ENABLED" -eq 1 ]]; then
  echo ""
  echo "Unattended reliability timers are active:"
  echo "  reality-watchdog.timer     -> health check + self-heal restart every 10min"
  echo "  reality-autoupdate.timer   -> Xray-core update check, weekly"
  echo "  reality-backup-maintenance.timer -> dedupe redundant backups, weekly"
  echo "  (disable any of them with: systemctl disable --now <name>)"
fi
echo ""
echo "Re-run any time (works via either name, from any directory):"
echo "  reality                     -> re-apply full setup (backs up old config first)"
echo "  reality --rotate-uuid       -> revoke current client link, keep server identity"
echo "  reality --rotate-all        -> full credential reset (invalidates everything)"
echo "  reality --rotate-all --force -> same, but skips confirmation (for non-interactive use)"
echo "  reality --change-sni <domain> -> change only the SNI, keeps UUID/keys unchanged"
echo "  reality --show              -> reprint current client link + QR"
echo "  reality --status            -> consolidated health/config summary"
echo "  reality --health-check      -> run the watchdog check manually"
echo "  reality --update-core-only  -> check/apply an Xray-core update now"
echo "  reality --set-webhook <url> -> also send critical alerts to a webhook (Slack/ntfy/etc)"

step "final" "Restarting Xray"
SERVICE_CURRENTLY_ACTIVE=$(systemctl is-active --quiet "${SERVICE_NAME}" && echo 1 || echo 0)
if [[ "$CONFIG_CHANGED" == "0" ]] && [[ "$OVERRIDE_CONF_CHANGED" == "0" ]] && [[ "$BEFORE_XRAY_VERSION" == "$AFTER_XRAY_VERSION" ]] && [[ "$SERVICE_CURRENTLY_ACTIVE" == "1" ]]; then
  ok "Nothing changed (config identical, Xray-core unchanged, service already running) -- skipping restart."
  verify_handshake
else
  restart_and_verify
fi
