#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-geekjy/evebox}"
STATE_DIR="/var/lib/geekjy-installer/evebox"
BACKUP_DIR="${STATE_DIR}/backup"
META_FILE="${STATE_DIR}/meta.env"
SERVICE_FILE="/etc/systemd/system/evebox.service"
ENV_FILE="/etc/default/evebox"

log() { echo "[evebox-install] $*"; }
die() { echo "[evebox-install] ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Please run as root."
  fi
}

detect_arch_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

github_latest_asset_url() {
  local arch="$1"
  local regex="evebox-.*-linux-${arch}\\.zip$"
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url' \
    | head -n1
}

backup_target() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "${BACKUP_DIR}$(dirname "$target")"
    cp -a "$target" "${BACKUP_DIR}${target}"
  fi
}

write_defaults() {
  cat > "$ENV_FILE" <<'EOF'
# Override EVEBOX_OPTIONS for your environment.
EVEBOX_OPTIONS='server -D /var/lib/evebox --datastore sqlite --input /var/log/suricata/eve.json --host 0.0.0.0 --port 5636'
EOF
}

write_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=EveBox event viewer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/evebox
User=evebox
Group=evebox
ExecStart=/bin/sh -lc '/usr/local/bin/evebox ${EVEBOX_OPTIONS}'
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  require_root
  need_cmd curl
  need_cmd jq
  need_cmd unzip
  need_cmd systemctl

  local arch asset_url tmp extract_dir pkg_dir install_root install_dir
  arch="$(detect_arch_suffix)"
  asset_url="$(github_latest_asset_url "$arch")"
  [ -n "$asset_url" ] || die "No release asset found for arch=${arch} in ${REPO}."

  log "Using release asset: $asset_url"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  mkdir -p "$STATE_DIR"
  rm -rf "$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"

  curl -fL "$asset_url" -o "$tmp/evebox.zip"
  mkdir -p "$tmp/extract"
  unzip -q "$tmp/evebox.zip" -d "$tmp/extract"

  pkg_dir="$(find "$tmp/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$pkg_dir" ] || die "Unexpected package format: top-level directory not found."
  [ -f "$pkg_dir/evebox" ] || die "evebox binary not found in package."

  install_root="/opt/evebox/releases"
  install_dir="${install_root}/$(basename "$pkg_dir")"
  mkdir -p "$install_root" /etc/evebox /var/lib/evebox /var/log/evebox

  backup_target "/usr/local/bin/evebox"
  backup_target "/opt/evebox/current"
  backup_target "$ENV_FILE"
  backup_target "$SERVICE_FILE"

  rm -rf "$install_dir"
  cp -a "$pkg_dir" "$install_dir"
  ln -sfn "$install_dir" /opt/evebox/current
  ln -sfn /opt/evebox/current/evebox /usr/local/bin/evebox
  chmod +x /opt/evebox/current/evebox

  if ! id evebox >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin evebox >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /bin/false evebox
  fi
  chown -R evebox:evebox /var/lib/evebox /var/log/evebox

  write_defaults
  write_service
  systemctl daemon-reload
  systemctl enable --now evebox.service

  cat > "$META_FILE" <<EOF
REPO=${REPO}
ASSET_URL=${asset_url}
INSTALL_DIR=${install_dir}
INSTALL_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  log "Installed successfully."
  log "Open: http://<your-host>:5636"
}

main "$@"
