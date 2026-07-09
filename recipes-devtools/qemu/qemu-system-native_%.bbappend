# meta-johnblue: QEMU patching for MCTP-over-SMBus endpoint + johnblue machine
#
# Applies a single patch that:
#   - adds hw/i2c/mctp_i2c_endpoint.c  (DSP0237 framing + MCTP Control + PLDM)
#   - adds hw/arm/aspeed_ast2600_johnblue.c  (new "ast2600-johnblue" machine)
#   - patches hw/i2c/Kconfig + meson.build  (new CONFIG_MCTP_I2C_ENDPOINT)
#   - patches hw/arm/Kconfig + meson.build  (select MCTP_I2C_ENDPOINT in ASPEED_SOC)
#   - adds include/hw/i2c/mctp_i2c_endpoint.h
#
# After rebuilding qemu-system-native, the machine is available as:
#   runqemu ast2600-johnblue
# and the QEMU command line in johnblue.conf uses:
#   QB_MACHINE = "-M ast2600-johnblue"
#
# The endpoint device sits at I2C bus 1 / address 0x0f and responds to:
#   - MCTP Control (SetEndpointID / GetEndpointID)  — for mctpd discovery
#   - PLDM Base GetTID / GetPLDMTypes / GetPLDMVersion
#   - PLDM PMC GetPDRRepositoryInfo / GetPDR / GetSensorReading
#     (2 sensors: CPU temp = 42°C, 12V rail = 11.98V)

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://0001-hw-add-mctp-i2c-endpoint-and-ast2600-johnblue-machine.patch \
"
