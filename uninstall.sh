#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/geekjy-installer/evebox"
BACKUP_DIR="${STATE_DIR}/backup"
META_FILE="${STATE_DIR}/meta.env"
SERVICE_FILE="/etc/systemd/system/evebox.service"
ENV_FILE="/etc/default/evebox"

log() { echo "[evebox-uninstall] $*"; }
die() { echo "[evebox-uninstall] ERROR: $*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run as root."
  fi
}

restore_target() {
  local target="$1"
  if [ -e "${BACKUP_DIR}${target}" ] || [ -L "${BACKUP_DIR}${target}" ]; then
    mkdir -p "$(dirname "$target")"
    rm -rf "$target"
    cp -a "${BACKUP_DIR}${target}" "$target"
  else
    rm -rf "$target"
  fi
}

main() {
  require_root

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now evebox.service >/dev/null 2>&1 || true
  fi

  local install_dir=""
  if [ -f "$META_FILE" ]; then
    # shellcheck disable=SC1090
    . "$META_FILE"
    install_dir="${INSTALL_DIR:-}"
  fi

  restore_target "/usr/local/bin/evebox"
  restore_target "/opt/evebox/current"
  restore_target "$ENV_FILE"
  restore_target "$SERVICE_FILE"

  if [ -n "$install_dir" ]; then
    rm -rf "$install_dir"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -rf "$STATE_DIR"
  log "Uninstall complete."
}

main "$@"
