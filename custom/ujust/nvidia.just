# vim: set ft=make :
##################
### nvidia.just
##################
## NVIDIA driver helpers. The driver is installed at build time by
## build/40-nvidia.sh. Secure Boot enrollment uses the same akmods key as the
## Xbox controller modules - see `ujust enroll-akmods-key`.
## See .agents/skills/finpilot-custom.md for runtime layer guidance

# Report NVIDIA driver, module and container GPU passthrough status
[group('Hardware')]
check-nvidia:
    #!/usr/bin/env bash
    set -uo pipefail
    KERNEL="$(uname -r)"
    echo "Kernel: ${KERNEL}"
    echo
    echo "Driver:"
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-gpu=name,driver_version --format=csv,noheader \
            | sed 's/^/  /' || echo "  nvidia-smi failed (is an NVIDIA GPU present?)"
    else
        echo "  nvidia-smi not found"
    fi
    echo
    echo "Kernel module:"
    if lsmod | grep -q '^nvidia'; then
        lsmod | grep '^nvidia' | awk '{print "  loaded: "$1}'
    else
        echo "  not loaded"
        echo "  If Secure Boot is on, run: ujust enroll-akmods-key"
    fi
    echo
    echo "Kernel args:"
    grep -o 'nvidia[^ ]*' /proc/cmdline | sed 's/^/  /' || echo "  no nvidia kargs"
    echo
    echo "Container GPU passthrough (CDI):"
    systemctl is-enabled ublue-nvctk-cdi.service 2>/dev/null | sed 's/^/  service: /'
    if [[ -f /etc/cdi/nvidia.yaml || -f /var/run/cdi/nvidia.yaml ]]; then
        echo "  CDI spec: present"
    else
        echo "  CDI spec: not generated yet (reboot, or start ublue-nvctk-cdi.service)"
    fi
    echo
    echo "Secure Boot state:"
    mokutil --sb-state 2>/dev/null || echo "  unknown (mokutil unavailable)"

# Smoke-test GPU access from inside a container via CDI
[group('Hardware')]
test-nvidia-container:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running nvidia-smi inside a container using CDI..."
    podman run --rm --device nvidia.com/gpu=all \
        --security-opt=label=disable \
        docker.io/nvidia/cuda:12.6.0-base-ubi9 nvidia-smi
