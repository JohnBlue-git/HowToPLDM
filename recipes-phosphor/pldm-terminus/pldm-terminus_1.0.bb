SUMMARY = "Minimal PLDM base terminus responder for QEMU loopback testing"
DESCRIPTION = "Binds to MCTP EID 10 via AF_MCTP and responds to PLDM base \
commands (GetTID, GetPLDMTypes, GetPLDMVersion) so that pldmd can complete \
its discovery sequence in a QEMU environment without real hardware."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://pldm-terminus.c \
    file://pldm-terminus.service \
    file://mctp-lo-setup.service \
"

inherit systemd

# QEMU development tool: debug binary embeds build paths, skip the check.
INSANE_SKIP:${PN}-dbg = "buildpaths"

SYSTEMD_SERVICE:${PN} = "mctp-lo-setup.service pldm-terminus.service"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${UNPACKDIR}/pldm-terminus.c \
        -o ${UNPACKDIR}/pldm-terminus
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/pldm-terminus ${D}${bindir}/pldm-terminus

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/mctp-lo-setup.service \
        ${D}${systemd_system_unitdir}/mctp-lo-setup.service
    install -m 0644 ${UNPACKDIR}/pldm-terminus.service \
        ${D}${systemd_system_unitdir}/pldm-terminus.service
}
