# shellcheck shell=bash
# Shared autodeploy-log helpers. Usage: . bin/fm-autodeploy-lib.sh
#
# fm_autodeploy_line_failed tests a status log's last line against firstmate's
# fleet-sync line convention (bin/fm-fleet-sync.sh): a healthy run ends in an
# "ok ..." rollup, a failed one in an "ALERT ..." rollup or a STUCK:/FAILED:/
# needs-attention line. Both readers of config/autodeploy-logs - the periodic
# sweep (bin/fm-watch.sh's autodeploy_scan) and the session-start bootstrap
# check (bin/fm-bootstrap.sh's autodeploy_logs_check) - source this so the
# match set has exactly one definition.

# True (0) when <line> reports an autodeploy failure.
fm_autodeploy_line_failed() {
  printf '%s' "$1" | grep -Eq 'STUCK:|FAILED:|needs attention|(^|[[:space:]])ALERT([[:space:]]|$)'
}

# True (0) when a read-timeout mechanism fm_autodeploy_read_last_line can use
# (timeout, gtimeout, or perl) is on PATH. fm-bootstrap.sh's autodeploy_logs_check
# uses this to warn the captain once when config/autodeploy-logs is configured but
# the whole feature would otherwise go silently inert on this host.
fm_autodeploy_read_timeout_available() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1
}

fm_autodeploy_read_last_line() {
  local log=$1 timeout_secs=${FM_AUTODEPLOY_LOG_READ_TIMEOUT:-5}
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_secs" tail -n 1 "$log" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_secs" tail -n 1 "$log" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" tail -n 1 "$log" 2>/dev/null
  else
    return 1
  fi
}
