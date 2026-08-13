#!/usr/bin/env bash
# Shared secondmate-routing policy.
#
# config/secondmate-routing is a home-local opt-in switch for creating or
# assigning new work to persistent secondmates. Its only valid value is `on` or
# `off` on one line. An absent file is `off`, so direct crewmates remain the
# default. Existing secondmate routes remain available for recovery, supervision,
# completion, and retirement while the switch is off.
#
# FM_SECONDMATE_ROUTING is a one-invocation override for tests and an explicitly
# selected operator action. It has the same `on`/`off` value set and otherwise
# fails closed. This library owns parsing and the new-route refusal message;
# callers own which lifecycle operation counts as new.

fm_secondmate_routing_config_path() {
  local home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s/secondmate-routing\n' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

fm_secondmate_routing_state() {
  local path=${FM_SECONDMATE_ROUTING_CONFIG:-$(fm_secondmate_routing_config_path)} value extra
  if [ -n "${FM_SECONDMATE_ROUTING+x}" ]; then
    value=$FM_SECONDMATE_ROUTING
    case "$value" in
      on|off) printf '%s\n' "$value"; return 0 ;;
      *) printf 'invalid\n'; return 2 ;;
    esac
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'off\n'
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || {
    printf 'invalid\n'
    return 2
  }
  IFS= read -r value < "$path" || {
    printf 'invalid\n'
    return 2
  }
  if IFS= read -r extra < "$path"; then
    printf 'invalid\n'
    return 2
  fi
  case "$value" in
    on|off) printf '%s\n' "$value"; return 0 ;;
    *) printf 'invalid\n'; return 2 ;;
  esac
}

fm_secondmate_routing_enabled() {
  local state rc=0
  state=$(fm_secondmate_routing_state) || rc=$?
  [ "$rc" -eq 0 ] || {
    printf 'error: config/secondmate-routing is invalid; use exactly one line containing on or off\n' >&2
    return 2
  }
  [ "$state" = on ]
}

fm_secondmate_routing_require_enabled() {
  local rc=0
  fm_secondmate_routing_enabled || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      printf 'error: new secondmate routing is disabled; use direct crewmates, or explicitly enable config/secondmate-routing with on\n' >&2
      return 1
      ;;
    2) return 2 ;;
    *) return 2 ;;
  esac
}
