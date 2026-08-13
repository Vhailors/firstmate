#!/usr/bin/env bash
# Shared secondmate-routing policy.
#
# config/secondmate-routing is a home-local opt-in switch for creating or
# assigning new work to persistent secondmates. Its only valid value is `on` or
# `off` on one line. An absent file is `off`, so direct crewmates remain the
# default. Existing secondmate routes remain available for recovery, supervision,
# completion, and retirement while the switch is off.
#
# FM_SECONDMATE_ROUTING is an internal one-invocation override for tests and for
# continuing a parent-authorized route across the bounded remote-control boundary.
# It is not an operator configuration surface. It has the same `on`/`off` value
# set and otherwise fails closed. This library owns parsing and the new-route
# refusal message; callers own which lifecycle operation counts as new.

fm_secondmate_routing_config_dir() {
  local home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s/config\n' "$home"
}

fm_secondmate_routing_config_path() {
  printf '%s/secondmate-routing\n' "$(fm_secondmate_routing_config_dir)"
}

fm_secondmate_routing_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_secondmate_routing_state() {
  local config_dir path value extra links
  if [ -n "${FM_SECONDMATE_ROUTING+x}" ]; then
    value=$FM_SECONDMATE_ROUTING
    case "$value" in
      on|off) printf '%s\n' "$value"; return 0 ;;
      *) printf 'invalid\n'; return 2 ;;
    esac
  fi
  config_dir=$(fm_secondmate_routing_config_dir)
  path=$(fm_secondmate_routing_config_path)
  if [ ! -e "$config_dir" ] && [ ! -L "$config_dir" ]; then
    printf 'off\n'
    return 0
  fi
  [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || {
    printf 'invalid\n'
    return 2
  }
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'off\n'
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || {
    printf 'invalid\n'
    return 2
  }
  links=$(fm_secondmate_routing_link_count "$path") || {
    printf 'invalid\n'
    return 2
  }
  [ "$links" = 1 ] || {
    printf 'invalid\n'
    return 2
  }
  {
    if ! IFS= read -r value; then
      printf 'invalid\n'
      return 2
    fi
    extra=
    if IFS= read -r extra || [ -n "$extra" ]; then
      printf 'invalid\n'
      return 2
    fi
  } < "$path"
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
