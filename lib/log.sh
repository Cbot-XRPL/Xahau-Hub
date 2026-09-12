# shellcheck shell=bash
# lib/log.sh — consistent output + alerting. Source, do not execute.

: "${XAH_LOG_TAG:=xahau-hub}"
: "${XAH_COLOR:=auto}"

if [ "$XAH_COLOR" = auto ]; then
  if [ -t 2 ]; then XAH_COLOR=1; else XAH_COLOR=0; fi
fi
if [ "$XAH_COLOR" = 1 ]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
  _C_DIM=$'\033[2m';  _C_BLD=$'\033[1m';  _C_OFF=$'\033[0m'
else
  _C_RED=""; _C_YEL=""; _C_GRN=""; _C_DIM=""; _C_BLD=""; _C_OFF=""
fi

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log()   { printf '%s%s%s %s\n' "$_C_DIM" "$(_ts)" "$_C_OFF" "$*" >&2; }
info()  { printf '%s%s%s %s\n' "$_C_DIM" "$(_ts)" "$_C_OFF" "$*" >&2; }
ok()    { printf '%s%s%s %sOK%s   %s\n' "$_C_DIM" "$(_ts)" "$_C_OFF" "$_C_GRN" "$_C_OFF" "$*" >&2; }
warn()  { printf '%s%s%s %sWARN%s %s\n' "$_C_DIM" "$(_ts)" "$_C_OFF" "$_C_YEL" "$_C_OFF" "$*" >&2
          command -v logger >/dev/null 2>&1 && logger -t "$XAH_LOG_TAG" -p user.warning "WARN $*" || true; }
err()   { printf '%s%s%s %sFAIL%s %s\n' "$_C_DIM" "$(_ts)" "$_C_OFF" "$_C_RED" "$_C_OFF" "$*" >&2
          command -v logger >/dev/null 2>&1 && logger -t "$XAH_LOG_TAG" -p user.err "FAIL $*" || true; }
die()   { trap - ERR 2>/dev/null || true; err "$*"; exit 1; }
hdr()   { printf '\n%s── %s %s%s\n' "$_C_BLD" "$*" "$(printf '─%.0s' $(seq 1 $((60 - ${#1} > 0 ? 60 - ${#1} : 3))))" "$_C_OFF" >&2; }

# Ask before doing something that changes state. XAH_YES=1 (or -y) skips.
confirm() {
  local prompt="${1:-Proceed?}"
  if [ "${XAH_YES:-0}" = 1 ]; then info "auto-confirmed: $prompt"; return 0; fi
  if [ ! -t 0 ]; then die "refusing to '$prompt' non-interactively without XAH_YES=1"; fi
  printf '%s%s%s [y/N] ' "$_C_BLD" "$prompt" "$_C_OFF" >&2
  local a; read -r a
  case "$a" in y|Y|yes|YES) return 0 ;; *) die "aborted by operator" ;; esac
}

# alert LEVEL MESSAGE — syslog always; webhook/telegram when configured.
# Configure in secrets/alerts.env (gitignored):
#   XAH_ALERT_WEBHOOK=https://...        (POSTs {"level","host","text"})
#   XAH_TELEGRAM_TOKEN=...  XAH_TELEGRAM_CHAT=...
alert() {
  local level="$1"; shift
  local text="[$level] $(hostname -s): $*"
  command -v logger >/dev/null 2>&1 && logger -t "$XAH_LOG_TAG" -p user.warning "$text" || true
  printf '%s\n' "$text" >&2
  if [ -n "${XAH_ALERT_WEBHOOK:-}" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 10 -X POST "$XAH_ALERT_WEBHOOK" \
      -H 'content-type: application/json' \
      --data "$(printf '{"level":"%s","host":"%s","text":"%s"}' \
                 "$level" "$(hostname -s)" "$(printf '%s' "$*" | tr '"' "'" | tr -d '\n')")" \
      >/dev/null 2>&1 || true
  fi
  if [ -n "${XAH_TELEGRAM_TOKEN:-}" ] && [ -n "${XAH_TELEGRAM_CHAT:-}" ] && command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 10 \
      "https://api.telegram.org/bot${XAH_TELEGRAM_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${XAH_TELEGRAM_CHAT}" \
      --data-urlencode "text=${text}" >/dev/null 2>&1 || true
  fi
}
