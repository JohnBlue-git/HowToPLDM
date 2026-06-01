FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Enable I2C slave mode in kernel for loopback testing under QEMU.
# Note: MCTP over I2C (CONFIG_MCTP_TRANSPORT_I2C) is already enabled
# by meta-phosphor's linux-%.bbappend via mctp/mctp.scc when
# DISTRO_FEATURES contains "mctp" (set via evb-ast2600.conf -> mctp.inc).
# This bbappend only adds the i2c-slave fragment for development extras.
SRC_URI:append = " file://i2c-slave-dev.cfg"

# Add "mctp-controller" property to the ast2600-evb i2c1 DT node.
# The mctp-i2c driver checks for this property (via both its i2c_add_driver
# probe path and its i2c bus notifier) before creating the mctpi2cN netdev.
# Without it, mctpi2c1 is never created regardless of new_device tricks.
SRC_URI:append = " file://0001-aspeed-evb-add-mctp-controller-to-i2c1.patch"
