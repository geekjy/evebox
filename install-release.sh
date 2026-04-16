#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-geekjy/evebox}"
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
RELEASE_TAG="${RELEASE_TAG:-}"
ASSET_URL="${ASSET_URL:-}"
FETCH_MODE="${FETCH_MODE:-redirect}"
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

github_api_get() {
  local url="$1"
  local -a headers
  headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [ -n "$GITHUB_TOKEN" ]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${headers[@]}" "$url"
}

github_release_asset_url() {
  local api_url="$1"
  local regex="$2"
  local json errf errtxt
  errf="$(mktemp)"
  if ! json="$(github_api_get "$api_url" 2>"$errf")"; then
    errtxt="$(tr '[:upper:]' '[:lower:]' < "$errf" || true)"
    if [[ "$errtxt" == *"403"* || "$errtxt" == *"rate limit"* ]]; then
      die "GitHub API returned 403 (likely rate limit). Export GITHUB_TOKEN or pass ASSET_URL."
    fi
    die "Failed to query GitHub releases API (${api_url})."
  fi
  rm -f "$errf"
  printf '%s\n' "$json" | jq -r --arg re "$regex" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1
}

github_latest_tag_via_redirect() {
  local effective_url
  effective_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
  printf '%s\n' "${effective_url##*/}"
}

github_release_asset_url_via_html() {
  local tag="$1"
  local regex="$2"
  local html rel
  html="$(curl -fsSL "https://github.com/${REPO}/releases/expanded_assets/${tag}")"
  rel="$(printf '%s\n' "$html" \
    | sed -nE "s#.*href=\"([^\"]*/releases/download/${tag}/[^\"]+)\".*#\\1#p" \
    | sed 's/&amp;/\&/g' \
    | grep -E "${regex}" \
    | head -n1 || true)"
  [ -n "$rel" ] || return 1
  case "$rel" in
    http://*|https://*) printf '%s\n' "$rel" ;;
    /*) printf 'https://github.com%s\n' "$rel" ;;
    *) printf 'https://github.com/%s\n' "$rel" ;;
  esac
}

resolve_asset_url() {
  local arch="$1"
  local regex="evebox-.*-linux-${arch}\\.zip$"
  local tag
  if [ -n "$ASSET_URL" ]; then
    printf '%s\n' "$ASSET_URL"
    return
  fi
  if [ -n "$RELEASE_TAG" ]; then
    tag="$RELEASE_TAG"
  else
    tag="$(github_latest_tag_via_redirect)"
  fi
  case "$FETCH_MODE" in
    redirect)
      github_release_asset_url_via_html "$tag" "$regex"
      ;;
    api)
      if [ -n "$RELEASE_TAG" ]; then
        github_release_asset_url "https://api.github.com/repos/${REPO}/releases/tags/${tag}" "$regex"
      else
        github_release_asset_url "https://api.github.com/repos/${REPO}/releases/latest" "$regex"
      fi
      ;;
    auto)
      github_release_asset_url_via_html "$tag" "$regex" || {
        if [ -n "$RELEASE_TAG" ]; then
          github_release_asset_url "https://api.github.com/repos/${REPO}/releases/tags/${tag}" "$regex"
        else
          github_release_asset_url "https://api.github.com/repos/${REPO}/releases/latest" "$regex"
        fi
      }
      ;;
    *)
      die "Unsupported FETCH_MODE=${FETCH_MODE}. Use redirect, api, or auto."
      ;;
  esac
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
  need_cmd unzip
  need_cmd systemctl
  if [ -z "$ASSET_URL" ] && [ "$FETCH_MODE" != "redirect" ]; then
    need_cmd jq
  fi

  local arch asset_url tmp pkg_dir install_root install_dir
  arch="$(detect_arch_suffix)"
  asset_url="$(resolve_asset_url "$arch")"
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
