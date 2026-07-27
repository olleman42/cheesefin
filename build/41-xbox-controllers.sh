#!/usr/bin/bash

set -euo pipefail

###############################################################################
# Xbox controller kernel modules (prebuilt akmods)
###############################################################################
# Installs prebuilt xone + xpadneo kernel modules from @ublue-os/akmods, staged
# into the ctx stage at /ctx/oci/akmods by Containerfile. Because the modules
# are prebuilt there is no DKMS, no build-on-boot, and no kernel-devel in the
# image.
#
#   xone    - wired controllers, Xbox Wireless Dongle (firmware included),
#             headsets, Chatpad. Does NOT do Bluetooth.
#   xpadneo - Bluetooth controllers, with force feedback and correct axis
#             mapping. Ships udev rules and HID quirks.
#
# The two are complementary, not alternatives: xone drives the proprietary
# wireless dongle, xpadneo drives plain Bluetooth pairing.
#
# Secure Boot: modules are signed with the ublue-os akmods key, which each user
# must enroll once per machine. See `ujust enroll-akmods-key`.
#
# Neither module is boot-critical, so no initramfs regeneration is needed.
###############################################################################

shopt -s nullglob

echo "::group:: Install Xbox controller akmods (xone, xpadneo)"

AKMODS_DIR="/ctx/oci/akmods"

# Kernel modules to install. Each needs a kmod-<name> and a <name>-kmod-common
# RPM present in the akmods image.
MODULES=(xone xpadneo)

# Resolve a glob to exactly one file, or fail the build with context.
# Callers pass the already-expanded glob as arguments, so an empty expansion
# (nullglob) arrives as zero arguments.
resolve_one() {
    local description="$1"
    shift
    if [[ $# -ne 1 ]]; then
        echo "ERROR: expected exactly 1 RPM for ${description}, found $#" >&2
        if [[ $# -gt 0 ]]; then
            printf '       %s\n' "$@" >&2
        fi
        return 1
    fi
    printf '%s\n' "$1"
}

RUNNING_KERNEL="$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
echo "Base image kernel: ${RUNNING_KERNEL}"

# ublue-os-akmods-addons ships the Secure Boot module-signing certificate at
# /etc/pki/akmods/certs/akmods-ublue.der, which `ujust enroll-akmods-key` reads.
RPMS=()
RPMS+=("$(resolve_one "ublue-os-akmods-addons" \
    "${AKMODS_DIR}/ublue-os/ublue-os-akmods-addons-"*.rpm)")

# Prebuilt kmods are compiled against exactly one kernel version. The akmods
# image and the base image are pinned independently and Renovate bumps them in
# separate PRs, so they can drift. Fail loudly here rather than shipping a
# module that silently refuses to load at boot.
for module in "${MODULES[@]}"; do
    if ! kmod_rpm="$(resolve_one "kmod-${module} for kernel ${RUNNING_KERNEL}" \
        "${AKMODS_DIR}/kmods/kmod-${module}-${RUNNING_KERNEL}-"*.rpm)"; then
        echo "       The akmods and base image pins have drifted apart." >&2
        echo "       kmod-${module} builds available in this akmods image:" >&2
        ls -1 "${AKMODS_DIR}/kmods/kmod-${module}-"* >&2 2>/dev/null \
            || echo "       (none)" >&2
        exit 1
    fi
    RPMS+=("${kmod_rpm}")
    RPMS+=("$(resolve_one "${module}-kmod-common" \
        "${AKMODS_DIR}/common/${module}-kmod-common-"*.rpm)")
done

# akmods RPMs are signed by the ublue-os/akmods COPR key. This key stays in the
# image's RPM database on purpose, so the packages remain verifiable and users
# can re-enable the repo coherently.
rpm --import "https://download.copr.fedorainfracloud.org/results/ublue-os/akmods/pubkey.gpg"

echo "Installing:"
printf '  %s\n' "${RPMS[@]##*/}"
dnf5 install -y "${RPMS[@]}"

# CLEANUP: ublue-os-akmods-addons leaves the akmods COPR enabled, and shipping
# enabled third-party repos is against this repo's rules. Disable it via config
# rather than deleting the file, which would break RPM file ownership.
# clean-stage.sh does not touch /etc/yum.repos.d, so this is ours to do.
# The negativo17 repos from the same package already ship enabled=0.
dnf5 config-manager setopt "copr:copr.fedorainfracloud.org:ublue-os:akmods.enabled=0"

# Verify the modules actually landed where depmod will find them. /lib is a
# symlink to /usr/lib, but address /usr/lib directly since that is the only
# writable-at-build, shipped-in-image location for a bootc system.
for module in "${MODULES[@]}"; do
    module_dir="/usr/lib/modules/${RUNNING_KERNEL}/extra/${module}"
    if [[ ! -d "${module_dir}" ]]; then
        echo "ERROR: expected ${module} modules at ${module_dir}" >&2
        exit 1
    fi
    echo "${module} modules:"
    find "${module_dir}" -name '*.ko*' -printf '  %f\n' | sort
done

# Pass the version explicitly: a bare `depmod -a` would target the build host's
# kernel, not the image's.
depmod -a "${RUNNING_KERNEL}"

echo "::endgroup::"
