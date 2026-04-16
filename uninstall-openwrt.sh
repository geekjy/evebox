#!/bin/sh
set -eu

STATE_DIR="/etc/geekjy-installer/evebox"
BACKUP_DIR="${STATE_DIR}/backup"
META_FILE="${STATE_DIR}/meta.env"
INIT_FILE="/etc/init.d/evebox-geekjy"
CONF_FILE="/etc/evebox/evebox.conf"

log() { echo "[evebox-openwrt-uninstall] $*"; }
die() { echo "[evebox-openwrt-uninstall] ERROR: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

restore_target() {
  target="$1"
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

  if [ -x "$INIT_FILE" ]; then
    "$INIT_FILE" stop >/dev/null 2>&1 || true
    "$INIT_FILE" disable >/dev/null 2>&1 || true
  fi

  INSTALL_DIR=""
  if [ -f "$META_FILE" ]; then
    # shellcheck disable=SC1090
    . "$META_FILE"
  fi

  restore_target "/usr/bin/evebox"
  restore_target "/opt/evebox/current"
  restore_target "$INIT_FILE"
  restore_target "$CONF_FILE"

  if [ -n "${INSTALL_DIR:-}" ]; then
    rm -rf "$INSTALL_DIR"
  fi

  rm -rf "$STATE_DIR"
  log "Uninstall complete."
}

main "$@"
