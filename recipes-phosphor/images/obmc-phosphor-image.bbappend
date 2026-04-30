# Additional packages for johnblue QEMU development image.
# The base obmc-phosphor-image already includes D-Bus, systemd, bmcweb etc.
# We add the full MCTP/PLDM stack plus development tools here.

IMAGE_INSTALL:append = " \
    mctp \
    pldm \
    pldm-libs \
    pldmtool \
    libmctp \
    i2c-tools \
    strace \
    gdbserver \
    pldm-terminus \
"
