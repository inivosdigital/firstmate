#!/usr/bin/env bash
# Install or remove the user-level systemd timer that runs fm-tmp-sweep.sh
# once a day. Not meant to be run directly - fm-tmp-sweep.sh's own --install
# and --uninstall flags call this; see that script's header for the full
# contract and docs/configuration.md "/tmp sweep and cleanup" for why a user
# timer was chosen over the watcher heartbeat or a system-wide cron/timer.
#
# Usage: fm-tmp-sweep-install.sh install|uninstall
#
# install is idempotent: safe to re-run, e.g. after the primary checkout
# moves. It also enables lingering for the current user
# (`loginctl enable-linger`) when not already on - without it, a user
# systemd instance (and therefore this timer) only runs while a login
# session is open, so a headless reboot with nobody logged in would silently
# stop sweeping /tmp, defeating the whole point. Lingering is a standard,
# reversible per-user systemd setting (`loginctl disable-linger` undoes it)
# and is scoped to the calling user only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UNIT_DIR="${FM_TMP_SWEEP_UNIT_DIR:-$HOME/.config/systemd/user}"
SERVICE_NAME=fm-tmp-sweep.service
TIMER_NAME=fm-tmp-sweep.timer

usage() {
  echo "usage: fm-tmp-sweep-install.sh install|uninstall" >&2
}

[ $# -eq 1 ] || { usage; exit 2; }

require_systemctl_user() {
  command -v systemctl >/dev/null 2>&1 || { echo "error: systemctl not found; cannot manage a user timer on this host" >&2; return 1; }
  command -v loginctl >/dev/null 2>&1 || { echo "error: loginctl not found; cannot verify/enable lingering on this host" >&2; return 1; }
}

case "$1" in
  install)
    require_systemctl_user

    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=firstmate /tmp sweep (bin/fm-tmp-sweep.sh --apply)

[Service]
Type=oneshot
ExecStart=$FM_ROOT/bin/fm-tmp-sweep.sh --apply
Environment="PATH=/home/$(id -un)/.local/bin:/home/$(id -un)/go/bin:/home/$(id -un)/.cargo/bin:/home/$(id -un)/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
EOF

    cat > "$UNIT_DIR/$TIMER_NAME" <<EOF
[Unit]
Description=Run firstmate /tmp sweep daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER_NAME"

    current_user=$(id -un)
    linger_state=$(loginctl show-user "$current_user" --property=Linger --value 2>/dev/null || echo unknown)
    if [ "$linger_state" != yes ]; then
      if loginctl enable-linger "$current_user" 2>/dev/null; then
        echo "fm-tmp-sweep-install: enabled lingering for $current_user (loginctl disable-linger $current_user to undo) - without it this timer would stop running whenever no login session is open, including after a headless reboot"
      else
        echo "warning: could not enable lingering for $current_user; this timer will only run while a login session is open (loginctl enable-linger $current_user to fix)" >&2
      fi
    fi

    echo "fm-tmp-sweep-install: installed and enabled $TIMER_NAME ($UNIT_DIR); next runs: $(systemctl --user list-timers "$TIMER_NAME" --no-legend 2>/dev/null | awk '{print $1, $2, $3, $4}')"
    ;;
  uninstall)
    require_systemctl_user
    systemctl --user disable --now "$TIMER_NAME" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME"
    systemctl --user daemon-reload
    echo "fm-tmp-sweep-install: removed $TIMER_NAME and $SERVICE_NAME. Lingering (if this script enabled it) was left as-is; run 'loginctl disable-linger $(id -un)' to also undo that."
    ;;
  *)
    usage
    exit 2
    ;;
esac
