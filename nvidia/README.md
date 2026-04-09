# Ollama + NVIDIA on Ubuntu

Use this directory to install Ollama on Ubuntu with NVIDIA GPU support.

Files in this directory:

- `README.md`: installation instructions
- `install_ollama_nvidia.sh`: installer script

## Quick start

Change into this directory and run the installer:

```bash
cd /home/sch/Documents/ollama/nvidia
./install_ollama_nvidia.sh
```

Default behavior:

- keeps Ollama bound to `127.0.0.1:11434`
- exposes all visible NVIDIA GPUs to the Ollama service
- installs Ollama as a `systemd` service

## Common examples

Use specific GPU indexes and move model storage:

```bash
./install_ollama_nvidia.sh --gpu-indices 0,1 --models-dir /data/ollama
```

Use specific GPU UUIDs:

```bash
./install_ollama_nvidia.sh --gpu-uuids GPU-abc,GPU-def
```

Install the Ubuntu-recommended NVIDIA driver if `nvidia-smi` is missing:

```bash
./install_ollama_nvidia.sh --install-driver
```

Run a post-install test model:

```bash
./install_ollama_nvidia.sh --test-model gemma3:1b
```

Install a specific Ollama version:

```bash
./install_ollama_nvidia.sh --ollama-version 0.11.0
```

## Validate after install

Check the service:

```bash
systemctl status ollama
journalctl -u ollama -n 100 --no-pager
```

Check the API:

```bash
curl http://127.0.0.1:11434/api/version
```

Check GPUs:

```bash
nvidia-smi
nvidia-smi -L
watch -n 1 nvidia-smi
```

Run a model manually:

```bash
ollama run gemma3:1b
```

## Notes

- If the installer adds or upgrades the NVIDIA driver, reboot before rerunning it.
- If you want stable GPU pinning across reboots, prefer GPU UUIDs over `0,1`.
