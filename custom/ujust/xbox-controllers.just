# vim: set ft=make :
############################
### xbox-controllers.just
############################
## Xbox controller kernel module helpers (xone + xpadneo).
## The modules themselves are installed at build time by
## build/41-xbox-controllers.sh.
## See .agents/skills/finpilot-custom.md for runtime layer guidance

# Enroll the ublue-os akmods signing key (required on Secure Boot systems)
[group('Hardware')]
enroll-akmods-key:
    #!/usr/bin/env bash
    set -euo pipefail
    CERT=/etc/pki/akmods/certs/akmods-ublue.der
    if [[ ! -f "${CERT}" ]]; then
        echo "Certificate not found at ${CERT}"
        echo "Is ublue-os-akmods-addons installed in this image?"
        exit 1
    fi
    echo "This enrolls the ublue-os akmods signing key so that signed kernel"
    echo "modules (xone, xpadneo) can load while Secure Boot is enabled."
    echo
    echo "You will be asked to set a one-time password. After rebooting, a blue"
    echo "MOK Manager screen appears: choose 'Enroll MOK' -> 'Continue' -> 'Yes'"
    echo "and enter that same password."
    echo
    sudo mokutil --import "${CERT}"
    echo
    echo "Key staged. Reboot to complete enrollment."

# Report the status of the Xbox controller modules (xone, xpadneo)
[group('Hardware')]
check-xbox-controllers:
    #!/usr/bin/env bash
    set -euo pipefail
    KERNEL="$(uname -r)"
    echo "Kernel: ${KERNEL}"
    echo
    for module in xone xpadneo; do
        MOD_DIR="/usr/lib/modules/${KERNEL}/extra/${module}"
        echo "${module}:"
        if [[ -d "${MOD_DIR}" ]]; then
            find "${MOD_DIR}" -name '*.ko*' -printf '  available: %f\n' | sort
        else
            echo "  no modules at ${MOD_DIR}"
            echo "  (the running kernel may not match the one they were built for)"
        fi
        if lsmod | grep -qE "^${module//-/_}"; then
            lsmod | grep -E "^${module//-/_}" | awk '{print "  loaded:    "$1}'
        else
            echo "  loaded:    none"
        fi
        echo
    done
    echo "Hints:"
    echo "  xone    - plug in a controller or the Xbox Wireless Dongle"
    echo "  xpadneo - pair a controller over Bluetooth"
    echo "  If nothing loads and Secure Boot is on: ujust enroll-akmods-key"
    echo
    echo "Secure Boot state:"
    mokutil --sb-state 2>/dev/null || echo "  unknown (mokutil unavailable)"
