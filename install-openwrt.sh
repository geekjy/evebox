#!/bin/sh
set -eu

REPO="${REPO:-geekjy/evebox}"
STATE_DIR="/etc/geekjy-installer/evebox"
BACKUP_DIR="${STATE_DIR}/backup"
META_FILE="${STATE_DIR}/meta.env"
INIT_FILE="/etc/init.d/evebox-geekjy"
CONF_FILE="/etc/evebox/evebox.conf"

log() { echo "[evebox-openwrt-install] $*"; }
die() { echo "[evebox-openwrt-install] ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Please run as root."
}

detect_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    die "Need curl or wget to fetch remote files."
  fi
}

download_file() {
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$2" "$1"
  else
    die "Need curl or wget to download files."
  fi
}

github_latest_asset_url() {
  arch="$1"
  regex="evebox-.*-linux-${arch}\\.zip$"
  json="$(fetch_url "https://api.github.com/repos/${REPO}/releases/latest")"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1
  else
    echo "$json" | sed -n "s/.*\"browser_download_url\": \"\\([^\"]*evebox-[^\"]*-linux-${arch}\\.zip\\)\".*/\\1/p" | sed 's#\\/#/#g' | head -n1
  fi
}

backup_target() {
  target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "${BACKUP_DIR}$(dirname "$target")"
    cp -a "$target" "${BACKUP_DIR}${target}"
  fi
}

write_defaults() {
  mkdir -p /etc/evebox
  cat > "$CONF_FILE" <<'EOF'
# OpenWrt EveBox runtime options.
EVEBOX_OPTIONS='server -D /var/lib/evebox --datastore sqlite --input /var/log/suricata/eve.json --host 0.0.0.0 --port 5636'
EOF
}

write_init_script() {
  cat > "$INIT_FILE" <<'EOF'
#!/bin/sh /etc/rc.common
START=96
STOP=10
USE_PROCD=1

PROG="/usr/bin/evebox"
CONF="/etc/evebox/evebox.conf"

start_service() {
  [ -x "$PROG" ] || return 1
  EVEBOX_OPTIONS='server -D /var/lib/evebox --datastore sqlite --input /var/log/suricata/eve.json --host 0.0.0.0 --port 5636'
  [ -f "$CONF" ] && . "$CONF"
  procd_open_instance
  procd_set_param command /bin/sh -c "$PROG $EVEBOX_OPTIONS"
  procd_set_param respawn 5 10 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  chmod +x "$INIT_FILE"
}

main() {
  require_root
  need_cmd unzip

  ARCH="$(detect_arch_suffix)"
  ASSET_URL="$(github_latest_asset_url "$ARCH")"
  [ -n "$ASSET_URL" ] || die "No release asset found for arch=${ARCH} in ${REPO}."

  log "Using release asset: $ASSET_URL"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  mkdir -p "$STATE_DIR"
  rm -rf "$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  download_file "$ASSET_URL" "$TMP_DIR/evebox.zip"
  mkdir -p "$TMP_DIR/extract"
  unzip -q "$TMP_DIR/evebox.zip" -d "$TMP_DIR/extract"

  PKG_DIR="$(find "$TMP_DIR/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$PKG_DIR" ] || die "Unexpected package format: top-level directory not found."
  [ -f "$PKG_DIR/evebox" ] || die "evebox binary not found in package."

  INSTALL_ROOT="/opt/evebox/releases"
  INSTALL_DIR="${INSTALL_ROOT}/$(basename "$PKG_DIR")"
  mkdir -p "$INSTALL_ROOT" /var/lib/evebox /var/log/evebox

  backup_target "/usr/bin/evebox"
  backup_target "/opt/evebox/current"
  backup_target "$INIT_FILE"
  backup_target "$CONF_FILE"

  rm -rf "$INSTALL_DIR"
  cp -a "$PKG_DIR" "$INSTALL_DIR"
  ln -sfn "$INSTALL_DIR" /opt/evebox/current
  ln -sfn /opt/evebox/current/evebox /usr/bin/evebox
  chmod +x /opt/evebox/current/evebox

  write_defaults
  write_init_script
  "$INIT_FILE" enable || true
  "$INIT_FILE" restart || "$INIT_FILE" start || true

  cat > "$META_FILE" <<EOF
REPO=${REPO}
ASSET_URL=${ASSET_URL}
INSTALL_DIR=${INSTALL_DIR}
INIT_FILE=${INIT_FILE}
CONF_FILE=${CONF_FILE}
INSTALL_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  log "Installed successfully."
  log "Open: http://<your-openwrt-ip>:5636"
}

main "$@"
