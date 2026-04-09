# Install Ollama with ROCm on Ubuntu

Use this directory to install Ollama on Ubuntu with AMD ROCm support.

## Tested environment

ROCm installation is sensitive to the host OS, GPU model, and ROCm version. This machine is currently:

- OS: Ubuntu 24.04.4 LTS (`noble`)
- GPU: 2x Radeon RX 7900 XT (`gfx1100`)
- ROCm: 7.2.1

If your system differs, especially on Ubuntu release, GPU generation, or ROCm version, expect package names, support status, or install behavior to differ.

Files in this directory:

- `README.md`: installation instructions
- `install_rocm_ollama.sh`: installer script

## Quick start

```bash
cd /home/sch/Documents/ollama/rocm
chmod +x ./install_rocm_ollama.sh
./install_rocm_ollama.sh
sudo reboot
./install_rocm_ollama.sh --post-reboot
```

## Requirements

- Ubuntu with `systemd`
- An AMD Radeon GPU supported by the ROCm stack
- `sudo` access

## What the script does

The installer script:

- installs base packages needed for the setup flow
- checks that an AMD GPU is visible in `lspci`
- installs matching kernel headers and `linux-modules-extra` for the running kernel when available
- downloads and installs AMD's `amdgpu-install` package for Ubuntu `noble`
- runs `amdgpu-install --usecase=graphics,rocm --no-dkms` by default
- adds your user to the `render` and `video` groups if needed
- installs the Ollama core package and the AMD ROCm runtime bundle
- creates and enables `ollama.service`

After reboot, the same script can verify ROCm and start Ollama with:

```bash
./install_rocm_ollama.sh --post-reboot
```

## Install

Change into this directory:

```bash
cd /home/sch/Documents/ollama/rocm
```

Make sure the script is executable:

```bash
chmod +x ./install_rocm_ollama.sh
```

Run the install:

```bash
./install_rocm_ollama.sh
```

Reboot when it completes:

```bash
sudo reboot
```

After reboot, run the verification step:

```bash
./install_rocm_ollama.sh --post-reboot
```

## Optional: workstation graphics stack

The default profile is:

```bash
AMDGPU_USECASE=graphics,rocm
```

If you specifically want AMD's workstation graphics stack instead, run:

```bash
AMDGPU_USECASE=workstation,rocm ./install_rocm_ollama.sh
```

## Verify the installation

After the post-reboot step, check:

```bash
ollama -v
systemctl status ollama
```

To inspect ROCm visibility:

```bash
rocminfo | grep -Ei 'Agent|Marketing Name|gfx'
```

To run a quick model test:

```bash
ollama run llama3.2:3b
```

## Notes

- The script is written for Ubuntu and warns if the detected version is not `24.04`.
- The default install uses `graphics,rocm` with `--no-dkms`.
- Group membership changes for `render` and `video` do not apply to the current session until you log out and back in or reboot.
- If you want to limit Ollama to one AMD GPU later, use a systemd override with `ROCR_VISIBLE_DEVICES`.
