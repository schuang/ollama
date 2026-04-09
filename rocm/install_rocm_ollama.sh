#!/usr/bin/env bash
set -Eeuo pipefail

AMDGPU_INDEX_URL="https://repo.radeon.com/amdgpu-install/latest/ubuntu/noble/"
AMDGPU_DEB_FALLBACK="amdgpu-install_7.2.1.70201-1_all.deb"
AMDGPU_USECASE="${AMDGPU_USECASE:-graphics,rocm}"
OLLAMA_SERVICE_PATH="/etc/systemd/system/ollama.service"
POST_REBOOT=0

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_sudo() {
  sudo -v
}

disable_stale_amdgpu_proprietary_repo() {
  local repo_file
  repo_file="/etc/apt/sources.list.d/amdgpu-proprietary.list"

  if sudo test -f "$repo_file"; then
    log "Disabling stale AMD proprietary repository: $repo_file"
    sudo sed -i 's/^deb /#deb /' "$repo_file"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./install_rocm_ollama.sh
  ./install_rocm_ollama.sh --post-reboot

Environment overrides:
  AMDGPU_USECASE=graphics,rocm     Default install profile

Notes:
  - The default profile is intended for Radeon GPUs used for both display/media and ROCm.
  - If you specifically need AMD's workstation graphics stack, set:
      AMDGPU_USECASE=workstation,rocm
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --post-reboot)
        POST_REBOOT=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

preflight_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "Cannot read /etc/os-release"
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script currently targets Ubuntu only."

  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "This script was built for Ubuntu 24.04. Detected ${VERSION_ID:-unknown}."
  fi

  log "Detected OS: ${PRETTY_NAME:-Ubuntu}"
  log "Detected kernel: $(uname -r)"
}

preflight_gpu() {
  need_cmd lspci
  local amd_gpus
  amd_gpus="$(lspci | grep -Ei 'AMD/ATI.*(VGA|Display|3D)|Navi 31|Radeon RX 79' || true)"
  [[ -n "$amd_gpus" ]] || die "No supported AMD Radeon GPU was detected in lspci output."

  log "Detected GPU adapters:"
  printf '%s\n' "$amd_gpus"

  if ! grep -qi 'Navi 31\|Radeon RX 79' <<<"$amd_gpus"; then
    warn "The GPU list does not explicitly mention a known RX 7900/Navi 31 string. Continue only if this host is still the intended target."
  fi
}

install_apt_prereqs() {
  disable_stale_amdgpu_proprietary_repo
  log "Installing base prerequisites..."
  sudo apt update
  sudo apt install -y \
    ca-certificates \
    curl \
    gpg \
    pciutils \
    python3-minimal \
    tar \
    wget \
    zstd
}

install_kernel_prereqs() {
  local kernel_rel headers_pkg modules_pkg
  kernel_rel="$(uname -r)"
  headers_pkg="linux-headers-$kernel_rel"
  modules_pkg="linux-modules-extra-$kernel_rel"

  log "Checking kernel prerequisite packages for $kernel_rel..."

  if apt-cache show "$headers_pkg" >/dev/null 2>&1; then
    sudo apt install -y "$headers_pkg"
  else
    die "Required package $headers_pkg was not found. Fix your kernel packaging before continuing."
  fi

  if apt-cache show "$modules_pkg" >/dev/null 2>&1; then
    sudo apt install -y "$modules_pkg"
  else
    warn "Package $modules_pkg was not found. Continuing, but ROCm or media support may be incomplete on this kernel."
  fi
}

resolve_amdgpu_deb_name() {
  local deb_name
  deb_name="$(curl -fsSL "$AMDGPU_INDEX_URL" | grep -Eo 'amdgpu-install_[^"]+_all\.deb' | head -n1 || true)"
  if [[ -z "$deb_name" ]]; then
    warn "Could not resolve the latest amdgpu-install package name from AMD's index."
    deb_name="$AMDGPU_DEB_FALLBACK"
  fi
  printf '%s\n' "$deb_name"
}

install_amdgpu_installer() {
  local tmp_dir deb_name deb_url
  deb_name="$(resolve_amdgpu_deb_name)"
  deb_url="${AMDGPU_INDEX_URL}${deb_name}"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  log "Downloading AMD installer package: $deb_name"
  curl -fL "$deb_url" -o "$tmp_dir/$deb_name"

  log "Installing AMD installer package..."
  sudo apt install -y "$tmp_dir/$deb_name"
}

install_rocm_and_graphics() {
  need_cmd amdgpu-install
  log "Installing AMD Radeon graphics + ROCm using use case: $AMDGPU_USECASE"
  sudo amdgpu-install -y --usecase="$AMDGPU_USECASE" --no-dkms
}

ensure_group_membership() {
  local groups_to_add missing_groups
  groups_to_add=(render video)
  missing_groups=()

  for group_name in "${groups_to_add[@]}"; do
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$group_name"; then
      missing_groups+=("$group_name")
    fi
  done

  if ((${#missing_groups[@]} > 0)); then
    log "Adding $USER to groups: ${missing_groups[*]}"
    sudo usermod -a -G "$(IFS=,; echo "${missing_groups[*]}")" "$USER"
    warn "Group membership changed. You must log out and back in, or reboot, before the new groups apply."
  else
    log "User $USER already has render/video access."
  fi
}

ensure_service_group_membership() {
  local service_user groups_to_add missing_groups
  service_user="ollama"
  groups_to_add=(render video)
  missing_groups=()

  if ! id "$service_user" >/dev/null 2>&1; then
    return 0
  fi

  for group_name in "${groups_to_add[@]}"; do
    if ! id -nG "$service_user" | tr ' ' '\n' | grep -qx "$group_name"; then
      missing_groups+=("$group_name")
    fi
  done

  if ((${#missing_groups[@]} > 0)); then
    log "Adding $service_user to groups: ${missing_groups[*]}"
    sudo usermod -a -G "$(IFS=,; echo "${missing_groups[*]}")" "$service_user"
  else
    log "User $service_user already has render/video access."
  fi
}

install_ollama() {
  log "Installing Ollama core package..."
  curl -fsSL https://ollama.com/download/ollama-linux-amd64.tar.zst | sudo tar --zstd -x -C /usr

  log "Installing Ollama AMD ROCm runtime bundle..."
  curl -fsSL https://ollama.com/download/ollama-linux-amd64-rocm.tar.zst | sudo tar --zstd -x -C /usr
}

install_ollama_service() {
  log "Creating ollama service account if needed..."
  if ! id ollama >/dev/null 2>&1; then
    sudo useradd -r -s /usr/sbin/nologin -U -m -d /usr/share/ollama ollama
  fi

  if ! getent group ollama >/dev/null 2>&1; then
    sudo groupadd ollama
  fi

  sudo usermod -a -G ollama "$USER"
  ensure_service_group_membership

  log "Writing systemd unit: $OLLAMA_SERVICE_PATH"
  sudo tee "$OLLAMA_SERVICE_PATH" >/dev/null <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable ollama
}

verify_rocm() {
  if ! command -v rocminfo >/dev/null 2>&1; then
    die "rocminfo is not installed or not on PATH. ROCm installation is incomplete."
  fi

  log "Checking ROCm GPU visibility..."
  rocminfo | grep -Ei 'Agent|Marketing Name|gfx' || true
}

verify_ollama() {
  if ! command -v ollama >/dev/null 2>&1; then
    die "ollama binary not found after installation."
  fi

  log "Starting Ollama service..."
  sudo systemctl start ollama
  sleep 3

  log "Ollama version:"
  ollama -v

  log "Ollama service status:"
  systemctl --no-pager --full status ollama || true
}

main_install() {
  preflight_os
  require_sudo
  install_apt_prereqs
  preflight_gpu
  install_kernel_prereqs
  install_amdgpu_installer
  install_rocm_and_graphics
  ensure_group_membership
  install_ollama
  install_ollama_service

  log "Install phase complete."
  warn "Reboot is required before ROCm and Ollama GPU verification."
  cat <<'EOF'

Next steps:
  1. Reboot:
       sudo reboot
  2. Re-run this script after the reboot:
       ./install_rocm_ollama.sh --post-reboot

Optional:
  - To use AMD's workstation graphics stack instead of the open graphics stack:
       AMDGPU_USECASE=workstation,rocm ./install_rocm_ollama.sh
EOF
}

main_post_reboot() {
  preflight_os
  preflight_gpu
  require_sudo
  verify_rocm
  verify_ollama

  cat <<'EOF'

Verification finished.

Suggested next checks:
  ollama run llama3.2:3b

If you want to limit Ollama to one GPU, create a systemd override:
  sudo systemctl edit ollama

Then add:
  [Service]
  Environment="ROCR_VISIBLE_DEVICES=0"
EOF
}

parse_args "$@"

need_cmd sudo
need_cmd grep

if ((POST_REBOOT)); then
  main_post_reboot
else
  main_install
fi
