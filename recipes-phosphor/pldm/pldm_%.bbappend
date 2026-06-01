FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Use af-mctp socket transport (preferred for newer OpenBMC).
# This is already enabled via pldm_git.bb's PACKAGECONFIG:append:df-mctp
# when DISTRO_FEATURES contains "mctp" (set by pldm.inc -> mctp.inc).
# Listed here explicitly for documentation clarity.
PACKAGECONFIG:append = " transport-af-mctp"

# Install the PLDM host EID file.
# EID 10 is the simulated PLDM terminus reachable via mctpi2c1 in QEMU.
SRC_URI:append = " file://host_eid"

do_install:append() {
    install -d ${D}/usr/share/pldm
    install -m 0644 ${UNPACKDIR}/host_eid ${D}/usr/share/pldm/host_eid
}
