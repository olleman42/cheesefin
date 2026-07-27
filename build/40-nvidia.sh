#!/usr/bin/bash

set -euo pipefail

###############################################################################
# NVIDIA GPU driver + CDI container passthrough
###############################################################################
# Provisions NVIDIA support directly into the base image using the prebuilt
# driver and akmod RPMs from @ublue-os/akmods-nvidia-open, staged into the ctx
# stage at /ctx/oci/akmods-nvidia by Containerfile.
#
# HARDWARE REQUIREMENT: open kernel modules need Turing or newer
# (GTX 16xx / RTX 20xx and up). Pre-Turing cards are NOT supported. The
# proprietary akmods-nvidia image publishes no main-* tags, so on a stock
# Fedora base the open driver is the only available option.
#
# Most of the heavy lifting is done by nvidia-install.sh, shipped inside the
# akmods artifact. It installs the driver, enables and then re-disables the
# repos it needs, installs nvidia-container-toolkit, enables the CDI generator
# service, installs the SELinux policy for container GPU access, and patches
# dracut to force-load the driver.
#
# Secure Boot: kmod-nvidia is signed with the ublue-os akmods key, the same key
# the xbox controller modules use. See `ujust enroll-akmods-key`.
###############################################################################

shopt -s nullglob

echo "::group:: ===$(basename "$0")==="

AKMODS_NVIDIA_DIR="/ctx/oci/akmods-nvidia"
RUNNING_KERNEL="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"

echo "Base image kernel: ${RUNNING_KERNEL}"

# -----------------------------------------------------------------------
# 1. Assert the akmod matches this kernel
# -----------------------------------------------------------------------
# The nvidia akmods image and the base image are pinned independently, so they
# can drift. nvidia-install.sh would eventually fail on a missing glob, but
# with a far less obvious error than this.
KMOD_RPM=("${AKMODS_NVIDIA_DIR}/kmods/kmod-nvidia-${RUNNING_KERNEL}-"*.rpm)
if [[ ${#KMOD_RPM[@]} -ne 1 ]]; then
    echo "ERROR: expected exactly 1 kmod-nvidia for kernel ${RUNNING_KERNEL}, found ${#KMOD_RPM[@]}" >&2
    echo "       The akmods-nvidia-open and base image pins have drifted apart." >&2
    echo "       Available kmod-nvidia builds in this akmods image:" >&2
    ls -1 "${AKMODS_NVIDIA_DIR}/kmods/kmod-nvidia-"* >&2 2>/dev/null \
        || echo "       (none)" >&2
    exit 1
fi
echo "Found $(basename "${KMOD_RPM[0]}")"

# -----------------------------------------------------------------------
# 2. Keep Fedora's Go container toolkit out of the dependency solution
# -----------------------------------------------------------------------
# NVIDIA's own C toolkit is what nvidia-install.sh pulls in; the Fedora Go
# package conflicts with it. Scoped to this script and cleared in step 6 so the
# exclusion does not leak into the shipped image's dnf config.
dnf5 config-manager setopt excludepkgs=golang-github-nvidia-container-toolkit

# -----------------------------------------------------------------------
# 3. Import the ublue-os/staging COPR key
# -----------------------------------------------------------------------
# nvidia-install.sh enables the staging COPR to pull supergfxctl on
# silverblue/kinoite, and disables it again afterwards. Importing the key up
# front avoids an interactive GPG prompt mid-install.
rpm --import "https://download.copr.fedorainfracloud.org/results/ublue-os/staging/pubkey.gpg"

# -----------------------------------------------------------------------
# 4. Run the vendored installer
# -----------------------------------------------------------------------
# IMAGE_NAME must be the *base* image name ("silverblue"), not this image's
# name: nvidia-install.sh switches on it to decide which variant packages to
# add. AKMODNV_PATH is only ever read from, so the read-only /ctx mount is fine.
#
# MULTILIB=0 skips the i686 mesa/nvidia libraries. Flatpak Steam supplies its
# own 32-bit GL stack, so this is the right default. Set MULTILIB=1 if you
# intend to run *native* 32-bit games or a non-Flatpak Steam.
IMAGE_NAME="${BASE_IMAGE_NAME}" \
    AKMODNV_PATH="${AKMODS_NVIDIA_DIR}" \
    MULTILIB=0 \
    "${AKMODS_NVIDIA_DIR}/ublue-os/nvidia-install.sh"

# -----------------------------------------------------------------------
# 5. Post-install fixups
# -----------------------------------------------------------------------
# Nouveau's Vulkan ICD confuses the loader once the proprietary stack is in.
rm -f /usr/share/vulkan/icd.d/nouveau_icd.*.json

# Some container runtimes dlopen the unversioned name.
ln -sf libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so

# Rootless Podman cannot manage cgroups for the container CLI. nvidia-ctk comes
# from nvidia-container-toolkit, installed by nvidia-install.sh.
if command -v nvidia-ctk >/dev/null; then
    nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
else
    echo "ERROR: nvidia-ctk not found; nvidia-container-toolkit did not install" >&2
    exit 1
fi

# Blacklist nouveau and enable DRM modeset so Wayland comes up on NVIDIA.
tee /usr/lib/bootc/kargs.d/00-nvidia.toml <<EOF
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1", "initcall_blacklist=simpledrm_platform_driver_init"]
EOF

# Mutter needs kms-modifiers for correct rendering on NVIDIA under Wayland.
if [[ -f /usr/share/glib-2.0/schemas/zz0-bluefin-modifications.gschema.override ]]; then
    sed -i "/experimental-features/ s/\]/, 'kms-modifiers'&/" \
        /usr/share/glib-2.0/schemas/zz0-bluefin-modifications.gschema.override
fi

# -----------------------------------------------------------------------
# 6. Cleanup
# -----------------------------------------------------------------------
# nvidia-install.sh already re-disables the negativo17 nvidia repos, the
# nvidia-container-toolkit repo and the staging COPR. clean-stage.sh does not
# touch dnf config, so clear our own exclusion here.
dnf5 config-manager setopt excludepkgs=""

# Fail loudly if any enabled third-party repo leaked into the image.
if dnf5 repolist --enabled 2>/dev/null | grep -iE "nvidia|negativo17|staging"; then
    echo "ERROR: an NVIDIA-related repo is still enabled in the final image" >&2
    exit 1
fi

# -----------------------------------------------------------------------
# 7. Verify
# -----------------------------------------------------------------------
NV_PACKAGES=(
    kmod-nvidia
    nvidia-driver
    nvidia-driver-cuda
    nvidia-container-toolkit
)
for pkg in "${NV_PACKAGES[@]}"; do
    if ! rpm -q "${pkg}" >/dev/null; then
        echo "ERROR: missing NVIDIA package: ${pkg}" >&2
        exit 1
    fi
done

# nvidia-install.sh compares kmod and driver versions itself, but assert the
# module actually landed for the right kernel.
NVIDIA_MOD_DIR="/usr/lib/modules/${RUNNING_KERNEL}/extra/nvidia"
if [[ ! -d "${NVIDIA_MOD_DIR}" ]]; then
    echo "ERROR: expected NVIDIA modules at ${NVIDIA_MOD_DIR}" >&2
    exit 1
fi
echo "NVIDIA modules:"
find "${NVIDIA_MOD_DIR}" -name '*.ko*' -printf '  %f\n' | sort

echo "NVIDIA setup complete (driver $(rpm -q --queryformat '%{VERSION}' nvidia-driver))"
echo "::endgroup::"
