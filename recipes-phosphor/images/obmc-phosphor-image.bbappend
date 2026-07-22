
# Ensure do_generate_static_tar waits for the FIT image to be deployed.
# image_types_phosphor.bbclass only adds this dependency to do_generate_static,
# not to do_generate_static_tar, so when do_generate_static is served from
# sstate without re-running do_deploy, image-kernel is missing at tar time.
do_generate_static_tar[depends] += "linux-yocto-fitimage:do_deploy"

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
"
