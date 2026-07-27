# shellcheck shell=bash
# Shared /tmp usage-threshold helpers. Usage: . bin/fm-tmp-alert-lib.sh
#
# fm_tmp_alert_threshold reads config/tmp-alert-threshold (local, gitignored,
# same shape as config/critical-services and config/autodeploy-logs - one
# value, first non-empty non-comment line, an integer percent 0-100).
# fm_tmp_alert_usage_pct reports /tmp's current usage percent via df. Both
# readers of this file - the periodic sweep (bin/fm-watch.sh's tmp_alert_scan)
# and the session-start bootstrap check (bin/fm-bootstrap.sh's
# tmp_alert_check) - source this so the threshold parse and the usage read
# have exactly one definition.

# Prints the configured threshold (0-100) from <file>, or nothing (and
# returns 1) when the file is absent, empty, or has no valid integer line -
# callers treat that as "the feature is off", matching config/critical-services
# and config/autodeploy-logs's own absent-file no-op behavior.
fm_tmp_alert_threshold() {
  local file=$1 line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    case "$line" in ''|*[!0-9]*) return 1 ;; esac
    [ "$line" -le 100 ] || return 1
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 1
}

# True (0) when df is available to read /tmp's usage percentage. Mirrors
# fm-autodeploy-lib.sh's fm_autodeploy_read_timeout_available: bootstrap uses
# this to warn once when the config asks for a check this host cannot run.
fm_tmp_alert_df_available() {
  command -v df >/dev/null 2>&1
}

# Prints /tmp's current usage percent (an integer, no trailing %), or returns
# 1 when df fails or its output cannot be parsed.
fm_tmp_alert_usage_pct() {
  local line pct
  line=$(df -P /tmp 2>/dev/null | awk 'NR==2') || return 1
  [ -n "$line" ] || return 1
  pct=$(printf '%s\n' "$line" | awk '{print $5}' | tr -d '%')
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pct"
}
