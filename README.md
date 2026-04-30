# meta-johnblue Project Documentation

## Project Structure

The `meta-johnblue` layer is organized as follows:

- **conf/**: Layer configuration files.
- **meta-common/**: Common metadata shared across platforms.
- **meta-daytonax/**, **meta-ethanolx/**: Platform-specific metadata.
- **recipes-phosphor/**: Recipes for OpenBMC phosphor components, including PLDM terminus.
- **Other directories**: Support for additional platforms and features.

This structure enables modular development and easy integration with the OpenBMC build system.

## Design Flow Introduction

The data flow in this project typically follows these steps:

1. **Sensor (or Terminus)**: Hardware sensors or terminus devices collect data or events.
2. **MCTP (Management Component Transport Protocol)**: Sensors communicate with the BMC using MCTP, a transport protocol for platform management.
3. **PLDM (Platform Level Data Model)**: Data is encapsulated in PLDM messages, which standardize platform management and monitoring.

**Flow Diagram:**

```
Sensor/Terminus → MCTP → PLDM → BMC/OpenBMC Services
```

This design allows for scalable, interoperable platform management using industry standards.

## How to Verify

To verify the functionality of the `meta-johnblue` layer and its PLDM terminus implementation:

1. **Build the Image**
   - Set up the OpenBMC build environment.
   - Add `meta-johnblue` to your `bblayers.conf`.
   - Run `bitbake <image-name>` to build the firmware image.

2. **Deploy and Boot**
   - Flash the built image to your target hardware or use QEMU for emulation.
   - Boot the system and access the BMC console.

3. **Check PLDM Terminus**
   - Verify that the PLDM terminus service is running (e.g., using `systemctl status pldm-terminus`).
   - Use MCTP tools or logs to confirm MCTP communication.
   - Use PLDM tools or logs to confirm PLDM message handling.

4. **Sensor Data Verification**
   - Check sensor readings via PLDM commands or OpenBMC web/API interfaces.
   - Confirm correct data flow from sensor to BMC.

5. **Detailed Verification in QEMU**

   After `runqemu` boots, inside the BMC shell:

   ```bash
   # List all I2C buses (AST2600 QEMU exposes 16 buses: i2c-0 to i2c-15)
   ls /sys/bus/i2c/devices/

   # Scan bus 1 for any devices (0x03-0x77)
   i2cdetect -y 1

   # Dump all registers of a device at address 0x50 on bus 1
   i2cdump -y 1 0x50

   # Read a single byte from register 0x00 of device at 0x50
   i2cget -y 1 0x50 0x00

   # Check which MCTP-I2C netdev was created
   mctp link show

   # Check if mctpi2c1 came up
   ip link show mctpi2c1

   # Check MCTP neighbours (discovered endpoints)
   mctp neigh show

   # Verify pldmd is running and connected
   busctl status xyz.openbmc_project.PLDM
   ```

   **If `mctp link show` only shows `lo` (loopback):**
   This means the `mctp-i2c` kernel driver hasn't been bound to I2C bus 1 yet — so `mctpi2c1` was never created. The service is supposed to handle this, but let's check if it ran:

   ```bash
   # Check the setup service status
   systemctl status mctp-setup-i2c.service
   journalctl -u mctp-setup-i2c.service
   ```

   **Check if the kernel module is loaded:**
   ```bash
   cat /sys/bus/i2c/devices/i2c-1/new_device 2>/dev/null || ls /sys/bus/i2c/devices/
   ```

   **Possible causes and further checks:**

   1. **Service didn't run** — `BindTo=mctpd.service` means if `mctpd` failed, the setup service was skipped too.

   2. **`echo "mctp-i2c 0x0f" > .../new_device` failed** — the `mctp-i2c` driver may not be loaded or the sysfs path doesn't exist. Check:
      ```bash
      ls /sys/bus/i2c/devices/i2c-1/
      echo "mctp-i2c 0x0f" > /sys/bus/i2c/devices/i2c-1/new_device
      mctp link show
      ```

   3. **Kernel config missing** — `CONFIG_MCTP_TRANSPORT_I2C` may not be enabled. Check:
      ```bash
      zcat /proc/config.gz | grep MCTP
      ```

   Try `modprobe mctp-i2c` manually first — if that succeeds and then `mctp link show` shows `mctpi2c1`, the issue is just that the driver isn't auto-loading.

   ```bash
   # Check if mctp-i2c driver actually bound to 1-000f
   readlink /sys/bus/i2c/devices/1-000f/driver

   # Full relevant dmesg (not just mctp filter)
   dmesg | grep -iE "mctp|i2c-1|slave|1-000f|mctpi2c|eopnotsupp"

   # Check kernel config for slave support
   zcat /proc/config.gz | grep -E "I2C_SLAVE|MCTP_TRANSPORT"

   # 1. Confirm the DTS patch made it in
   find /sys/firmware/devicetree/base -name "mctp-controller"

   # Verify the full stack is healthy:
   mctp addr show
   systemctl status mctpd
   ```

---

For more details, refer to the README files in each subdirectory and the OpenBMC documentation.