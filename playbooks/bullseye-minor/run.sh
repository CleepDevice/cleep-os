#!/bin/bash
# CleepOs minor upgrade playbook (same suite, e.g. bullseye → newer bullseye snapshot).
#
# Env:
#   TARGET_CLEEPOS_VERSION  required — value written to /etc/cleepos_version after success
#   CLEEPOS_VERSION_PATH    optional — default /etc/cleepos_version
#   CLEEPOS_DRY_RUN         optional — set to 1/true to simulate apt only (no package install,
#                           no cleepos_version stamp). Still remounts rw briefly for apt-get update.
#
# Exit codes:
#   0 success (caller may reboot — not for dry-run)
#   non-zero failure
#
# Phases emit lines: PHASE <name> <begin|end|fail>

set -eu

CLEEPOS_VERSION_PATH="${CLEEPOS_VERSION_PATH:-/etc/cleepos_version}"
PLAYBOOK_TMP="${PLAYBOOK_TMP:-/tmp/cleepos-playbook}"
LOG_TAG="[cleepos-playbook]"

is_dry_run() {
  case "${CLEEPOS_DRY_RUN:-0}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  echo "${LOG_TAG} $*"
}

phase_begin() {
  echo
  echo "======== PLAYBOOK PHASE: $1 (begin) ========"
  echo "PHASE $1 begin"
  log "phase $1: begin"
}

phase_end() {
  echo "PHASE $1 end"
  log "phase $1: end"
  echo "======== PLAYBOOK PHASE: $1 (end) ========"
  echo
}

phase_fail() {
  echo "PHASE $1 fail"
  log "phase $1: fail — $2"
  echo "======== PLAYBOOK PHASE: $1 (FAIL) ========"
  exit 1
}

require_target() {
  if [ -z "${TARGET_CLEEPOS_VERSION:-}" ]; then
    phase_fail preflight "TARGET_CLEEPOS_VERSION is not set"
  fi
}

phase_preflight() {
  phase_begin preflight
  require_target
  if [ ! -f "$CLEEPOS_VERSION_PATH" ]; then
    phase_fail preflight "$CLEEPOS_VERSION_PATH missing"
  fi
  current=$(tr -d ' \n' < "$CLEEPOS_VERSION_PATH")
  log "current=${current} target=${TARGET_CLEEPOS_VERSION}"
  if is_dry_run; then
    log "DRY-RUN mode: apt will be simulated; /etc/cleepos_version will not be written"
  fi
  if [ "$current" = "$TARGET_CLEEPOS_VERSION" ]; then
    log "already at target version"
    phase_end preflight
    exit 0
  fi
  # same suite only (letters prefix)
  current_suite=$(printf '%s' "$current" | sed 's/[0-9].*//')
  target_suite=$(printf '%s' "$TARGET_CLEEPOS_VERSION" | sed 's/[0-9].*//')
  if [ "$current_suite" != "$target_suite" ]; then
    phase_fail preflight "suite mismatch (${current_suite} -> ${target_suite}); major upgrades need another playbook"
  fi
  phase_end preflight
}

phase_prepare_rw() {
  phase_begin prepare-rw
  if mount | grep -q ' on / .*[(,]ro[,)]'; then
    mount -o remount,rw / || phase_fail prepare-rw "unable to remount / rw"
  fi
  if [ -d /boot ] && mount | grep -q ' on /boot .*[(,]ro[,)]'; then
    mount -o remount,rw /boot || phase_fail prepare-rw "unable to remount /boot rw"
  fi
  phase_end prepare-rw
}

phase_apt() {
  phase_begin apt
  export DEBIAN_FRONTEND=noninteractive
  # Transient mirror drops are common on Raspbian; retry fetch a few times.
  APT_GET=(
    apt-get
    -o Acquire::Retries=3
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
  )
  apt_tries="${CLEEPOS_APT_TRIES:-3}"
  apt_log=$(mktemp)
  attempt=1
  while true; do
    : > "$apt_log"
    log "apt attempt ${attempt}/${apt_tries}: update"
    set -o pipefail
    if ! "${APT_GET[@]}" update -qq 2>&1 | tee -a "$apt_log"; then
      set +o pipefail
      log "apt-get update failed on attempt ${attempt}"
    else
      if is_dry_run; then
        log "apt attempt ${attempt}/${apt_tries}: dist-upgrade (simulate)"
        if "${APT_GET[@]}" -s dist-upgrade 2>&1 | tee -a "$apt_log"; then
          set +o pipefail
          break
        fi
      else
        log "apt attempt ${attempt}/${apt_tries}: dist-upgrade"
        if "${APT_GET[@]}" -y dist-upgrade 2>&1 | tee -a "$apt_log"; then
          set +o pipefail
          break
        fi
      fi
      set +o pipefail
      log "apt dist-upgrade failed on attempt ${attempt}; last lines:"
      tail -n 20 "$apt_log" || true
    fi
    if [ "$attempt" -ge "$apt_tries" ]; then
      log "apt failed after ${apt_tries} attempts; last lines:"
      tail -n 40 "$apt_log" || true
      rm -f "$apt_log"
      if is_dry_run; then
        phase_fail apt "apt-get -s dist-upgrade failed after ${apt_tries} attempts"
      else
        phase_fail apt "apt-get dist-upgrade failed after ${apt_tries} attempts"
      fi
    fi
    attempt=$((attempt + 1))
    log "retrying apt in 5s..."
    sleep 5
  done
  set +o pipefail
  # Parse classic apt summary: "X upgraded, Y newly installed, ..."
  summary=$(grep -E '[0-9]+ upgraded,' "$apt_log" | tail -n1 || true)
  if [ -z "$summary" ]; then
    summary="(no apt summary line — check log above)"
  fi
  log "apt result: $summary"
  mkdir -p "$PLAYBOOK_TMP"
  printf '%s\n' "$summary" > "$PLAYBOOK_TMP/apt-summary.txt"
  if is_dry_run; then
    # Keep full simulate log for post-analysis (disk size, errors, Remv…)
    cp -f "$apt_log" "$PLAYBOOK_TMP/apt-simulate.log" || true
    {
      echo "CleepOs dry-run preview"
      echo "target=${TARGET_CLEEPOS_VERSION}"
      echo "mode=apt-get -s dist-upgrade (no packages changed, version not stamped)"
      echo
      echo "=== apt summary ==="
      echo "$summary"
      grep -E '^(Need to get |After this operation,)' "$apt_log" || true
      echo
      echo "=== packages (Inst / Conf / Remv lines) ==="
      grep -E '^(Inst |Conf |Remv )' "$apt_log" || echo "(none)"
      echo
      echo "=== notes ==="
      echo "- Leftover .dpkg-* / .ucf-* files cannot be predicted without a real dpkg run."
      echo "- After Apply, use the OS conf leftover report for path-only review."
      echo "- Assessment (OK/KO + findings) is computed by the Update module after this preview."
    } > "$PLAYBOOK_TMP/dry-run-preview.txt"
    log "dry-run preview written to $PLAYBOOK_TMP/dry-run-preview.txt"
  fi
  if echo "$summary" | grep -Eq '^0 upgraded, 0 newly installed, 0 to remove'; then
    if is_dry_run; then
      log "note: simulation shows no package changes vs apt mirrors"
    else
      log "note: no packages changed — image already current vs apt mirrors; only cleepos_version will be stamped"
    fi
  fi
  rm -f "$apt_log"
  if ! is_dry_run; then
    "${APT_GET[@]}" -y autoremove --purge -qq || true
    "${APT_GET[@]}" -y autoclean -qq || true
  fi
  phase_end apt
}

phase_finalize_version() {
  phase_begin finalize-version
  if is_dry_run; then
    log "DRY-RUN: would write $CLEEPOS_VERSION_PATH=$TARGET_CLEEPOS_VERSION"
    phase_end finalize-version
    return
  fi
  echo "$TARGET_CLEEPOS_VERSION" > "$CLEEPOS_VERSION_PATH" \
    || phase_fail finalize-version "unable to write $CLEEPOS_VERSION_PATH"
  log "wrote $CLEEPOS_VERSION_PATH=$(cat "$CLEEPOS_VERSION_PATH")"
  phase_end finalize-version
}

phase_prepare_ro() {
  phase_begin prepare-ro
  sync || true
  if [ -d /boot ]; then
    mount -o remount,ro /boot || log "warning: could not remount /boot ro"
  fi
  mount -o remount,ro / || log "warning: could not remount / ro (ok if tmpfs writes pending)"
  phase_end prepare-ro
}

phase_preflight
phase_prepare_rw
phase_apt
phase_finalize_version
phase_prepare_ro
if is_dry_run; then
  log "playbook dry-run completed successfully (no reboot needed)"
else
  log "playbook completed successfully"
fi
exit 0
