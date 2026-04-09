#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
HOST="127.0.0.1:11434"
MODELS_DIR=""
GPU_SELECTION=""
OLLAMA_VERSION=""
TEST_MODEL=""
INSTALL_DRIVER=0
SKIP_MODEL_TEST=0

usage() {
  cat <<'EOF'
Usage:
  install_ollama_nvidia.sh [options]

Options:
  --host HOSTPORT           Ollama listen address. Default: 127.0.0.1:11434
  --models-dir PATH         Store models in PATH and configure OLLAMA_MODELS
  --gpu-indices IDS         GPU indexes to expose, for example: 0,1
  --gpu-uuids UUIDS         GPU UUIDs to expose, for example: GPU-xxx,GPU-yyy
  --ollama-version VERSION  Install a specific Ollama version
  --test-model MODEL        Pull and run a post-install test model
  --install-driver          Run ubuntu-drivers autoinstall if nvidia-smi is missing
  --skip-model-test         Do not run a model after installation
  -h, --help                Show this help text

Examples:
  ./install_ollama_nvidia.sh
  ./install_ollama_nvidia.sh --gpu-indices 0,1 --models-dir /data/ollama
  ./install_ollama_nvidia.sh --gpu-uuids GPU-abc,GPU-def --test-model gemma3:1b
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_sudo() {
  sudo "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        [[ $# -ge 2 ]] || die "--host requires a value"
        HOST="$2"
        shift 2
        ;;
      --models-dir)
        [[ $# -ge 2 ]] || die "--models-dir requires a value"
        MODELS_DIR="$2"
        shift 2
        ;;
      --gpu-indices)
        [[ $# -ge 2 ]] || die "--gpu-indices requires a value"
        [[ -z "$GPU_SELECTION" ]] || die "Use only one of --gpu-indices or --gpu-uuids"
        GPU_SELECTION="$2"
        shift 2
        ;;
      --gpu-uuids)
        [[ $# -ge 2 ]] || die "--gpu-uuids requires a value"
        [[ -z "$GPU_SELECTION" ]] || die "Use only one of --gpu-indices or --gpu-uuids"
        GPU_SELECTION="$2"
        shift 2
        ;;
      --ollama-version)
        [[ $# -ge 2 ]] || die "--ollama-version requires a value"
        OLLAMA_VERSION="$2"
        shift 2
        ;;
      --test-model)
        [[ $# -ge 2 ]] || die "--test-model requires a value"
        TEST_MODEL="$2"
        shift 2
        ;;
      --install-driver)
        INSTALL_DRIVER=1
        shift
        ;;
      --skip-model-test)
        SKIP_MODEL_TEST=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

assert_ubuntu() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu. Detected: ${ID:-unknown}"
}

install_base_packages() {
  log "Installing base packages"
  run_sudo apt-get update
  run_sudo apt-get install -y curl ca-certificates pciutils
  if [[ "$INSTALL_DRIVER" -eq 1 ]]; then
    run_sudo apt-get install -y ubuntu-drivers-common
  fi
}

maybe_install_driver() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_DRIVER" -ne 1 ]]; then
    die "nvidia-smi is not installed. Install the Ubuntu NVIDIA driver first, or rerun with --install-driver."
  fi

  log "nvidia-smi not found; installing the Ubuntu-recommended NVIDIA driver"
  run_sudo ubuntu-drivers autoinstall
  log "NVIDIA driver installation completed. Reboot the machine, then rerun this script."
  exit 20
}

check_nvidia_driver() {
  need_cmd nvidia-smi

  local raw_driver major_driver gpu_count
  raw_driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1 | tr -d ' ')"
  [[ -n "$raw_driver" ]] || die "Unable to determine NVIDIA driver version from nvidia-smi"

  major_driver="${raw_driver%%.*}"
  if [[ "$major_driver" =~ ^[0-9]+$ ]] && (( major_driver < 531 )); then
    die "NVIDIA driver version $raw_driver is too old for current Ollama GPU support. Upgrade to 531 or newer."
  fi

  gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')"
  (( gpu_count >= 1 )) || die "No NVIDIA GPUs detected by nvidia-smi"

  log "Detected NVIDIA driver $raw_driver with $gpu_count GPU(s)"
  nvidia-smi -L
}

validate_gpu_selection() {
  [[ -z "$GPU_SELECTION" ]] && return 0

  local visible
  visible="$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader)"

  IFS=',' read -r -a requested <<< "$GPU_SELECTION"
  for item in "${requested[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -n "$item" ]] || die "Empty value in GPU selection"
    if ! grep -Fq "$item" <<< "$visible"; then
      die "GPU selection value not found in nvidia-smi output: $item"
    fi
  done
}

install_ollama() {
  log "Installing Ollama from the official Linux installer"
  if [[ -n "$OLLAMA_VERSION" ]]; then
    curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
}

configure_ollama_service() {
  local override_dir override_file
  override_dir="/etc/systemd/system/ollama.service.d"
  override_file="${override_dir}/override.conf"

  log "Configuring the Ollama systemd service"
  run_sudo mkdir -p "$override_dir"

  if id ollama >/dev/null 2>&1; then
    getent group video >/dev/null 2>&1 && run_sudo usermod -aG video ollama || true
    getent group render >/dev/null 2>&1 && run_sudo usermod -aG render ollama || true
  fi

  if [[ -n "$MODELS_DIR" ]]; then
    run_sudo mkdir -p "$MODELS_DIR"
    if id ollama >/dev/null 2>&1; then
      run_sudo chown -R ollama:ollama "$MODELS_DIR"
    fi
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  {
    echo "[Service]"
    echo "Environment=\"OLLAMA_HOST=${HOST}\""
    if [[ -n "$MODELS_DIR" ]]; then
      echo "Environment=\"OLLAMA_MODELS=${MODELS_DIR}\""
    fi
    if [[ -n "$GPU_SELECTION" ]]; then
      echo "Environment=\"CUDA_VISIBLE_DEVICES=${GPU_SELECTION}\""
    fi
    echo "SupplementaryGroups=video render"
  } >"$tmp_file"

  run_sudo cp "$tmp_file" "$override_file"
  rm -f "$tmp_file"

  run_sudo systemctl daemon-reload
  run_sudo systemctl enable --now ollama
}

wait_for_ollama() {
  local attempts=20
  local i

  for (( i=1; i<=attempts; i++ )); do
    if curl -fsS "http://${HOST}/api/version" >/dev/null 2>&1; then
      log "Ollama API is responding on ${HOST}"
      return 0
    fi
    sleep 1
  done

  run_sudo systemctl status ollama --no-pager || true
  run_sudo journalctl -u ollama -n 100 --no-pager || true
  die "Ollama service did not become ready on ${HOST}"
}

run_model_test() {
  [[ "$SKIP_MODEL_TEST" -eq 1 ]] && return 0
  [[ -n "$TEST_MODEL" ]] || return 0

  log "Running post-install model test with ${TEST_MODEL}"
  ollama run "$TEST_MODEL" "Reply with exactly: GPU test OK"
}

print_summary() {
  cat <<EOF

Installation complete.

Service endpoint:
  http://${HOST}

GPU selection:
  ${GPU_SELECTION:-all NVIDIA GPUs visible to the service}

Models directory:
  ${MODELS_DIR:-Ollama default}

Useful commands:
  systemctl status ollama
  journalctl -u ollama -n 100 --no-pager
  ollama -v
  curl http://${HOST}/api/version
  nvidia-smi -L

If you want to confirm runtime GPU activity while a model is running:
  watch -n 1 nvidia-smi
EOF
}

main() {
  parse_args "$@"
  assert_ubuntu
  need_cmd sudo
  install_base_packages
  maybe_install_driver
  check_nvidia_driver
  validate_gpu_selection
  install_ollama
  configure_ollama_service
  wait_for_ollama
  run_model_test
  print_summary
}

main "$@"
