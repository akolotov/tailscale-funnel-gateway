#!/bin/sh

set -u

TS_SOCKET=${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}
INTERVAL_SECONDS=${WATCHDOG_INTERVAL_SECONDS:-60}
FAILURE_THRESHOLD=${WATCHDOG_FAILURE_THRESHOLD:-3}
RECOVERY_ENABLED=${WATCHDOG_RECOVERY_ENABLED:-true}
RECOVERY_COOLDOWN_SECONDS=${WATCHDOG_RECOVERY_COOLDOWN_SECONDS:-3600}
SOFT_RECOVERY_WAIT_SECONDS=${WATCHDOG_SOFT_RECOVERY_WAIT_SECONDS:-120}
RECOVERY_WAIT_SECONDS=${WATCHDOG_RECOVERY_WAIT_SECONDS:-600}
RECOVERY_POLL_SECONDS=${WATCHDOG_RECOVERY_POLL_SECONDS:-15}
DNS_RESOLVERS=${WATCHDOG_DNS_RESOLVERS:-"1.1.1.1 8.8.8.8"}
LOCAL_URL=${WATCHDOG_LOCAL_URL:-http://127.0.0.1:8080/healthz}
PUBLIC_PATH=${WATCHDOG_PUBLIC_PATH:-/healthz}
FUNNEL_TARGET=${WATCHDOG_FUNNEL_TARGET:-http://127.0.0.1:8080}
FUNNEL_PORT=${WATCHDOG_FUNNEL_PORT:-443}
COMMAND_TIMEOUT_SECONDS=${WATCHDOG_COMMAND_TIMEOUT_SECONDS:-15}
STATE_DIR=${WATCHDOG_STATE_DIR:-/var/lib/funnel-watchdog}
LAST_RECOVERY_FILE="$STATE_DIR/last-recovery"
LAST_SUCCESS_FILE="$STATE_DIR/last-success"
FUNNEL_MANAGED_FILE="$STATE_DIR/funnel-managed"
RECOVERY_LOCK_DIR="$STATE_DIR/recovery.lock"

TS_OK=false
LOCAL_OK=false
RECOVERY_ELIGIBLE=false
PROBE_PENDING=false
PROBE_REASON=unknown
FUNNEL_FQDN=
DNS_IPS=
RECOVERY_LOCK_HELD=false
RECOVERY_ATTEMPT_ACTIVE=false

log() {
  printf '%s funnel-watchdog %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "level=error message=$*"
  exit 2
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_config() {
  for value in "$INTERVAL_SECONDS" "$FAILURE_THRESHOLD" \
    "$RECOVERY_COOLDOWN_SECONDS" "$SOFT_RECOVERY_WAIT_SECONDS" \
    "$RECOVERY_WAIT_SECONDS" "$RECOVERY_POLL_SECONDS" \
    "$FUNNEL_PORT" "$COMMAND_TIMEOUT_SECONDS"; do
    is_uint "$value" || die "invalid_numeric_configuration value=$value"
  done

  [ "$FAILURE_THRESHOLD" -gt 0 ] || die "failure_threshold_must_be_positive"
  [ "$INTERVAL_SECONDS" -gt 0 ] || die "interval_must_be_positive"
  [ "$RECOVERY_POLL_SECONDS" -gt 0 ] || die "recovery_poll_must_be_positive"
  case "$RECOVERY_ENABLED" in
    true|false) ;;
    *) die "WATCHDOG_RECOVERY_ENABLED_must_be_true_or_false" ;;
  esac
  case "$PUBLIC_PATH" in
    /*) ;;
    *) die "WATCHDOG_PUBLIC_PATH_must_start_with_slash" ;;
  esac
  [ -n "$DNS_RESOLVERS" ] || die "WATCHDOG_DNS_RESOLVERS_must_not_be_empty"
  mkdir -p "$STATE_DIR" || die "cannot_create_state_directory path=$STATE_DIR"
}

tailscale_cli() {
  timeout "$COMMAND_TIMEOUT_SECONDS" tailscale --socket="$TS_SOCKET" "$@"
}

append_dns_ip() {
  candidate=$1
  case " $DNS_IPS " in
    *" $candidate "*) ;;
    *) DNS_IPS="${DNS_IPS}${DNS_IPS:+ }$candidate" ;;
  esac
}

probe_dns() {
  DNS_IPS=
  dns_responses=0
  dns_nxdomain=0

  for resolver in $DNS_RESOLVERS; do
    output=$(dig +time=3 +tries=1 "@$resolver" "$FUNNEL_FQDN" A 2>&1) || output=${output:-}
    status=$(printf '%s\n' "$output" | sed -n 's/.*status: \([A-Z]*\),.*/\1/p' | head -n 1)
    case "$status" in
      NOERROR)
        dns_responses=$((dns_responses + 1))
        ips=$(printf '%s\n' "$output" | awk '$4 == "A" { print $5 }')
        for ip in $ips; do
          append_dns_ip "$ip"
        done
        ;;
      NXDOMAIN)
        dns_responses=$((dns_responses + 1))
        dns_nxdomain=$((dns_nxdomain + 1))
        ;;
      *)
        log "level=warn check=dns resolver=$resolver status=${status:-unreachable}"
        ;;
    esac
  done

  if [ -n "$DNS_IPS" ]; then
    return 0
  fi
  if [ "$dns_responses" -gt 0 ] && [ "$dns_responses" -eq "$dns_nxdomain" ]; then
    return 1
  fi
  return 2
}

probe_public_https() {
  for ip in $DNS_IPS; do
    if curl --fail --silent --show-error \
      --connect-timeout "$COMMAND_TIMEOUT_SECONDS" \
      --max-time "$COMMAND_TIMEOUT_SECONDS" \
      --resolve "$FUNNEL_FQDN:$FUNNEL_PORT:$ip" \
      "https://$FUNNEL_FQDN:$FUNNEL_PORT$PUBLIC_PATH" >/dev/null; then
      return 0
    fi
  done
  return 1
}

probe() {
  TS_OK=false
  LOCAL_OK=false
  RECOVERY_ELIGIBLE=false
  PROBE_PENDING=false
  PROBE_REASON=unknown
  FUNNEL_FQDN=
  DNS_IPS=

  status_json=$(tailscale_cli status --json 2>/dev/null) || {
    PROBE_REASON=tailscale_unavailable
    return 1
  }
  TS_OK=true

  backend_state=$(printf '%s' "$status_json" | jq -r '.BackendState // ""' 2>/dev/null)
  FUNNEL_FQDN=$(printf '%s' "$status_json" | jq -r '.Self.DNSName // ""' 2>/dev/null | sed 's/\.$//')
  if [ "$backend_state" != Running ] || [ -z "$FUNNEL_FQDN" ]; then
    PROBE_REASON=tailscale_not_running
    return 1
  fi

  if ! curl --fail --silent --show-error \
    --connect-timeout "$COMMAND_TIMEOUT_SECONDS" \
    --max-time "$COMMAND_TIMEOUT_SECONDS" "$LOCAL_URL" >/dev/null; then
    PROBE_REASON=local_proxy_unavailable
    return 1
  fi
  LOCAL_OK=true

  funnel_json=$(tailscale_cli funnel status --json 2>/dev/null) || funnel_json=
  if ! printf '%s' "$funnel_json" | jq -e --arg target "$FUNNEL_TARGET" '
    ([((.AllowFunnel // {}) | to_entries[]) | select(.value == true)] | length > 0)
    and
    ([((.Web // {}) | to_entries[]) as $site
      | (($site.value.Handlers // {}) | to_entries[])
      | select(.value.Proxy == $target)] | length > 0)
  ' >/dev/null 2>&1; then
    if [ ! -f "$FUNNEL_MANAGED_FILE" ]; then
      PROBE_REASON=awaiting_initial_funnel_configuration
      PROBE_PENDING=true
      return 1
    fi
    PROBE_REASON=funnel_configuration_missing
    RECOVERY_ELIGIBLE=true
    return 1
  fi

  if [ ! -f "$FUNNEL_MANAGED_FILE" ]; then
    printf '%s\n' "$(date +%s)" > "$FUNNEL_MANAGED_FILE"
    log "level=info event=initial_funnel_configuration_observed fqdn=$FUNNEL_FQDN target=$FUNNEL_TARGET"
  fi

  probe_dns
  dns_result=$?
  case "$dns_result" in
    0) ;;
    1)
      PROBE_REASON=public_dns_nxdomain
      RECOVERY_ELIGIBLE=true
      return 1
      ;;
    *)
      PROBE_REASON=public_dns_unreachable
      return 1
      ;;
  esac

  if ! probe_public_https; then
    PROBE_REASON=public_https_unavailable
    RECOVERY_ELIGIBLE=true
    return 1
  fi

  PROBE_REASON=healthy
  printf '%s\n' "$(date +%s)" > "$LAST_SUCCESS_FILE"
  return 0
}

cooldown_active() {
  [ -f "$LAST_RECOVERY_FILE" ] || return 1
  last_recovery=$(sed -n '1p' "$LAST_RECOVERY_FILE" 2>/dev/null)
  is_uint "$last_recovery" || return 1
  now=$(date +%s)
  age=$((now - last_recovery))
  [ "$age" -lt "$RECOVERY_COOLDOWN_SECONDS" ]
}

acquire_recovery_lock() {
  now=$(date +%s)
  if mkdir "$RECOVERY_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$now" > "$RECOVERY_LOCK_DIR/created-at"
    RECOVERY_LOCK_HELD=true
    return 0
  fi

  created_at=$(sed -n '1p' "$RECOVERY_LOCK_DIR/created-at" 2>/dev/null)
  stale_after=$((SOFT_RECOVERY_WAIT_SECONDS + RECOVERY_WAIT_SECONDS + 300))
  if is_uint "$created_at" && [ $((now - created_at)) -le "$stale_after" ]; then
    return 1
  fi

  rm -f "$RECOVERY_LOCK_DIR/created-at"
  rmdir "$RECOVERY_LOCK_DIR" 2>/dev/null || return 1
  mkdir "$RECOVERY_LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$now" > "$RECOVERY_LOCK_DIR/created-at"
  RECOVERY_LOCK_HELD=true
  rm -f "$LAST_RECOVERY_FILE"
  log "level=warn event=stale_recovery_lock_reclaimed"
}

release_recovery_lock() {
  rm -f "$RECOVERY_LOCK_DIR/created-at"
  rmdir "$RECOVERY_LOCK_DIR" 2>/dev/null || true
  RECOVERY_LOCK_HELD=false
}

abort_recovery() {
  rm -f "$LAST_RECOVERY_FILE"
  RECOVERY_ATTEMPT_ACTIVE=false
  release_recovery_lock
}

finish_recovery() {
  RECOVERY_ATTEMPT_ACTIVE=false
  release_recovery_lock
}

handle_signal() {
  signal_name=$1
  exit_code=$2
  trap - HUP INT TERM
  if [ "$RECOVERY_ATTEMPT_ACTIVE" = true ]; then
    log "level=warn event=recovery_interrupted signal=$signal_name"
    abort_recovery
  elif [ "$RECOVERY_LOCK_HELD" = true ]; then
    release_recovery_lock
  fi
  exit "$exit_code"
}

trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

enable_funnel() {
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if tailscale_cli funnel --https="$FUNNEL_PORT" --bg "$FUNNEL_TARGET" >/dev/null; then
      return 0
    fi
    log "level=error event=recovery_command_failed command=on attempt=$attempt"
    attempt=$((attempt + 1))
    sleep 2
  done
  return 1
}

wait_for_recovery() {
  wait_seconds=$1
  elapsed=0
  while [ "$elapsed" -lt "$wait_seconds" ]; do
    sleep_for=$RECOVERY_POLL_SECONDS
    remaining=$((wait_seconds - elapsed))
    [ "$sleep_for" -le "$remaining" ] || sleep_for=$remaining
    sleep "$sleep_for"
    elapsed=$((elapsed + sleep_for))
    if probe; then
      log "level=info event=recovered stage=$2 elapsed_seconds=$elapsed fqdn=$FUNNEL_FQDN"
      return 0
    fi
    log "level=warn event=recovery_wait stage=$2 elapsed_seconds=$elapsed reason=$PROBE_REASON"
  done
  return 1
}

recover() {
  if [ "$RECOVERY_ENABLED" != true ]; then
    log "level=warn event=recovery_skipped reason=disabled failure=$PROBE_REASON"
    return 1
  fi
  if [ "$TS_OK" != true ] || [ "$LOCAL_OK" != true ] || [ "$RECOVERY_ELIGIBLE" != true ]; then
    log "level=warn event=recovery_skipped reason=unsafe failure=$PROBE_REASON"
    return 1
  fi
  if ! acquire_recovery_lock; then
    log "level=warn event=recovery_skipped reason=already_running failure=$PROBE_REASON"
    return 1
  fi
  if cooldown_active; then
    log "level=warn event=recovery_skipped reason=cooldown failure=$PROBE_REASON"
    release_recovery_lock
    return 1
  fi

  RECOVERY_ATTEMPT_ACTIVE=true
  printf '%s\n' "$(date +%s)" > "$LAST_RECOVERY_FILE"
  log "level=warn event=recovery_started failure=$PROBE_REASON action=reapply"
  if ! enable_funnel; then
    log "level=error event=recovery_failed stage=reapply"
    abort_recovery
    return 1
  fi
  if wait_for_recovery "$SOFT_RECOVERY_WAIT_SECONDS" reapply; then
    finish_recovery
    return 0
  fi

  log "level=warn event=recovery_started failure=$PROBE_REASON action=off_on"
  if ! tailscale_cli funnel --https="$FUNNEL_PORT" off >/dev/null; then
    log "level=error event=recovery_failed stage=off"
    abort_recovery
    return 1
  fi
  if ! enable_funnel; then
    log "level=error event=recovery_failed stage=on"
    abort_recovery
    return 1
  fi
  if wait_for_recovery "$RECOVERY_WAIT_SECONDS" off_on; then
    finish_recovery
    return 0
  fi

  log "level=error event=recovery_exhausted reason=$PROBE_REASON"
  finish_recovery
  return 1
}

run_once() {
  if probe; then
    log "level=info check=complete status=healthy fqdn=$FUNNEL_FQDN ips=\"$DNS_IPS\""
    return 0
  fi
  if [ "$PROBE_PENDING" = true ]; then
    log "level=info check=complete status=pending reason=$PROBE_REASON"
    return 0
  fi
  log "level=warn check=complete status=unhealthy reason=$PROBE_REASON"
  recover
}

run_loop() {
  failures=0
  last_reason=
  while true; do
    if probe; then
      if [ "$failures" -gt 0 ] || [ "$last_reason" = awaiting_initial_funnel_configuration ]; then
        log "level=info check=complete status=healthy previous_failures=$failures previous_state=${last_reason:-none} fqdn=$FUNNEL_FQDN"
      fi
      failures=0
      last_reason=healthy
    elif [ "$PROBE_PENDING" = true ]; then
      failures=0
      if [ "$last_reason" != "$PROBE_REASON" ]; then
        log "level=info check=complete status=pending reason=$PROBE_REASON action=wait"
      fi
      last_reason=$PROBE_REASON
    else
      failures=$((failures + 1))
      log "level=warn check=complete status=unhealthy reason=$PROBE_REASON consecutive_failures=$failures threshold=$FAILURE_THRESHOLD"
      if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
        recover || true
        failures=0
      fi
      last_reason=$PROBE_REASON
    fi
    sleep "$INTERVAL_SECONDS"
  done
}

validate_config

case "${1:-run}" in
  check)
    if probe; then
      log "level=info check=complete status=healthy fqdn=$FUNNEL_FQDN ips=\"$DNS_IPS\""
      exit 0
    fi
    if [ "$PROBE_PENDING" = true ]; then
      log "level=info check=complete status=pending reason=$PROBE_REASON"
      exit 1
    fi
    log "level=warn check=complete status=unhealthy reason=$PROBE_REASON"
    exit 1
    ;;
  run-once) run_once ;;
  run) run_loop ;;
  *) die "usage: funnel-watchdog [check|run-once|run]" ;;
esac
