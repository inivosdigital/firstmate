# shellcheck shell=bash
# Shared autodeploy-log failure-detection predicate. Usage: . bin/fm-autodeploy-lib.sh
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
