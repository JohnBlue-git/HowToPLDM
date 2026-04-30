FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Install a custom mctpd.conf and a startup service that configures MCTP
# over the AST2600 I2C bus exposed by QEMU (bus 1 -> mctpi2c1, BMC EID 8).
SRC_URI:append = " \
    file://mctpd.conf \
    file://mctp-setup-i2c.service \
"

do_install:append() {
    install -d ${D}/etc
    install -m 0644 ${UNPACKDIR}/mctpd.conf ${D}/etc/mctpd.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/mctp-setup-i2c.service \
        ${D}${systemd_system_unitdir}/mctp-setup-i2c.service
}

SYSTEMD_SERVICE:${PN} += "mctp-setup-i2c.service"
