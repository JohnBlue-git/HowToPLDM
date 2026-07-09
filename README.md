# meta-johnblue Project Documentation

## Project Structure

```
meta-johnblue/
├── conf/
│   ├── layer.conf                          # Layer metadata, priorities, dependencies
│   ├── machine/
│   │   └── johnblue.conf                   # Machine definition (AST2600, QB_MACHINE override)
│   └── templates/default/
│       ├── bblayers.conf.sample            # Ready-to-use bblayers configuration
│       └── local.conf.sample               # Ready-to-use local.conf with MACHINE=johnblue
├── recipes-devtools/
│   └── qemu/
│       ├── files/
│       │   ├── 0001-hw-i2c-add-mctp-i2c-endpoint-device.patch
│       │   │   # Standalone draft patch — mctp_i2c_endpoint.c only (reference, not used by build)
│       │   └── 0001-hw-add-mctp-i2c-endpoint-and-ast2600-johnblue-machine.patch
│       │       # Comprehensive Yocto patch — all QEMU changes (used by bbappend)
│       └── qemu-system-native_%.bbappend   # Injects the QEMU patch into qemu-system-native build
├── recipes-kernel/
│   └── linux/
│       ├── files/
│       │   └── i2c-slave-dev.cfg           # Kernel config fragment: I2C slave support
│       ├── linux-aspeed_%.bbappend         # Applies DTS patch (mctp-controller on i2c1)
│       └── linux-yocto-fitimage.bbappend
├── recipes-phosphor/
│   ├── images/
│   │   └── obmc-phosphor-image.bbappend    # Adds pldm-terminus to image
│   ├── mctp/
│   │   ├── files/
│   │   │   ├── mctpd.conf                  # bus-owner mode, 5s timeout
│   │   │   └── mctp-setup-i2c.service      # Brings up mctpi2c1, adds BMC EID 8
│   │   └── mctp_%.bbappend
│   ├── pldm/
│   │   ├── files/host_eid                  # EID 10 — the QEMU endpoint's assigned EID
│   │   └── pldm_%.bbappend
│   └── pldm-terminus/
│       ├── files/
│       │   ├── pldm-terminus.c             # Loopback-only mock (superseded; kept for reference)
│       │   ├── pldm-terminus.service
│       │   └── mctp-lo-setup.service
│       └── pldm-terminus_1.0.bb
└── manifest/
    └── main.xml
```

This structure enables modular development and easy integration with the OpenBMC build system.

## Repo initialization

To sync this repository into the project root, use a manifest that places the OpenBMC checkout at `.` and keeps the layer checkout relative to the repo root.

Example `manifest/main.xml` settings:

```xml
<manifest>
  <remote name="openbmc" fetch="https://github.com/" />
  <remote name="johnblue" fetch="https://github.com/JohnBlue-git/" />

  <default remote="johnblue" revision="main" sync-j="4" />

  <project remote="openbmc" name="openbmc/openbmc" revision="master" path="." />
  <project remote="johnblue" name="HowToPLDM" revision="main" path="meta-johnblue" />
</manifest>
```

Download repo binary:

```bash
mkdir -p ~/.bin
PATH="${HOME}/.bin:${PATH}"
curl https://googleapis.com > ~/.bin/repo
chmod a+rx ~/.bin/repo
```

From an empty workspace root, run:

```bash
# Install repo if needed
mkdir -p ~/.bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+rx ~/.bin/repo

# Initialize and sync the manifest
repo init -u <manifest-repo-url> -m manifest/main.xml -b "$OPENBMC_BRANCH"
repo sync
```

This creates `.repo/` in the current root and checks out the OpenBMC repository directly into the project root. The `meta-johnblue` layer is then checked out under `meta-johnblue`.

If you use `repo init -u https://github.com/openbmc/openbmc.git`, that only works when the target repo contains the expected repo manifest metadata. For a normal manifest workflow, point `-u` at the manifest repository or use a manifest file with `-m`.

## Design Flow Introduction

The data flow in this project follows the full real-hardware path through the kernel's MCTP-over-I2C driver stack:

```
QEMU I2C device (mctp-i2c-endpoint @ bus1/0x0f)
        ↓  DSP0237 MCTP-over-SMBus frames over virtual I2C
Kernel: aspeed_i2c → mctp-i2c master driver → AF_MCTP socket
        ↓
mctpd (bus owner, EID discovery via SetEndpointID)
        ↓
pldmd / platform-mc (PLDM PDR walk, GetSensorReading polling)
        ↓
OpenBMC D-Bus / Redfish sensor objects
```

This exercises the **complete real kernel driver path** — `aspeed_i2c.c`, `mctp-i2c.c`, `mctpd`, and `pldmd` — using a QEMU I2C device model that speaks the same wire protocol as real PLDM terminus hardware.

## What are MCTP and PLDM?

- **MCTP (Management Component Transport Protocol)** is the transport layer for platform management traffic. It carries management messages between endpoints and provides addressing, packet framing, and transport services over underlying buses such as I2C, PCIe, SMBus, or loopback.
- **PLDM (Platform Level Data Model)** is a higher-layer protocol that runs on top of MCTP. PLDM defines standard platform management commands, discovery, sensor readouts, firmware update procedures, and other data model semantics.
- In this repo, PLDM messages are transported over MCTP using AF_MCTP sockets. `mctpd`, `mctp-setup-i2c.service`, and `mctp-lo-setup.service` establish the MCTP transport, while `pldmd.service` and `pldm-terminus.service` exchange PLDM payloads over that transport.

## MCTP / PLDM Device and Service Relationship

With the QEMU I2C device model, the full service chain exercises the real kernel MCTP-over-I2C driver path.

- **QEMU I2C device** (`mctp-i2c-endpoint` at bus 1 / address `0x0f`)
  - Handles all MCTP framing (DSP0237), MCTP Control (DSP0236), and PLDM protocols
  - Visible to the Linux kernel as a real I2C slave via the `aspeed_i2c` virtual bus
- **BMC side (EID 8)**
  - `mctpd`: MCTP bus owner daemon — performs EID discovery (SetEndpointID → assigns EID 10 to the QEMU device)
  - `mctp-setup-i2c.service`: brings up `mctpi2c1` (created automatically by the kernel `mctp-i2c` driver when the DTS `mctp-controller` property is present), adds BMC EID 8
  - `pldmd.service`: PLDM daemon on the BMC
- **Terminus side (EID 10)** — the QEMU I2C device model
  - EID is assigned by `mctpd` at runtime via `SetEndpointID` (no static `mctp addr add` needed for terminus)
  - Responds to all PLDM Base (Type 0) and PLDM PMC (Type 2) commands
  - `pldm-terminus.service` (loopback mock) is still installed but no longer drives the I2C sensor path

**Service startup chain:**

```
mctpd
  └─ mctp-setup-i2c.service   # brings up mctpi2c1, adds BMC EID 8
       └─ pldmd.service        # BMC PLDM daemon; mctpd discovers QEMU device as EID 10
```

**Service relation diagram:**

```
[ mctpd ]   ←──── discovers QEMU I2C device, assigns EID 10
    |
    v
[ mctp-setup-i2c.service ]   ←── mctpi2c1 up, BMC EID 8
    |
    v
[ pldmd.service ]            ←── queries QEMU device: GetPDR, GetSensorReading
```

- `mctpd` performs real EID assignment via the `mctp-i2c` kernel driver.
- `mctp-setup-i2c.service` creates the `mctpi2c1` network device (via kernel DT `mctp-controller` property on `&i2c1`) and adds BMC EID 8.
- `pldmd.service` (platform-mc component) walks the PDR repository and polls `GetSensorReading`.
- The QEMU I2C device model at `bus1/0x0f` handles all terminus-side PLDM logic.

---

## Implementation Status: QEMU Device Model

This layer uses a QEMU I2C device model as the PLDM terminus. This is **not a pure software loopback mock** — it exercises the real kernel MCTP-over-I2C driver path while the terminus logic runs inside QEMU's device model infrastructure.

### What is real

- **`aspeed_i2c` driver**: the QEMU AST2600 I2C master emulation is the real upstream code
- **`mctp-i2c` kernel driver**: the Linux kernel's `drivers/net/mctp/mctp-i2c.c` handles all framing
- **`mctpd` EID assignment**: `SetEndpointID` flows over the real I2C path, not a static `mctp addr add`
- **`pldmd` PDR walk and polling**: `pldmd`'s `platform-mc` component performs a real PDR repository walk and calls `GetSensorReading` periodically

### What is simulated

- **Sensor values**: CPU temp is statically 42 °C, 12V rail is statically 11.98 V — there is no actual hwmon driver behind these
- **`pldm-terminus.service`**: the loopback-based userspace mock is still installed but is superseded by the I2C device model for actual I2C PLDM traffic

### Data flow

```
pldmd / platform-mc (BMC EID 8)
    ↓  AF_MCTP socket → mctp-i2c.c → aspeed_i2c.c
    ↓  I2C master write (DSP0237 MCTP-over-SMBus frame)
mctp-i2c-endpoint QEMU device (bus1/addr 0x0f, EID 10)
    ↓  processes frame, builds response
    ↓  i2c_start_send_async → Aspeed DMA slave ISR
mctp-i2c.c → AF_MCTP → pldmd
    ↓
D-Bus sensor objects / Redfish
```

---

## QEMU I2C Device Model

The core of this layer is a custom QEMU I2C slave device (`mctp-i2c-endpoint`) that replaces the AF_MCTP loopback mock with a proper in-QEMU terminus that exercises the real Linux kernel driver path.

### Architecture

```
QEMU userspace
  ┌──────────────────────────────────────────────────────────┐
  │  aspeed_i2c master (I2C bus 1)                           │
  │       ↕  I2C master writes/slave reads (QEMU I2C API)   │
  │  mctp-i2c-endpoint (addr 0x0f)                           │
  │       - DSP0237 MCTP-over-SMBus framing + PEC CRC-8      │
  │       - MCTP Control (DSP0236): SetEID/GetEID             │
  │       - PLDM Base (DSP0240, Type 0)                      │
  │       - PLDM PMC (DSP0248, Type 2) + static PDR repo     │
  └──────────────────────────────────────────────────────────┘
         ↕  virtual I2C
  ┌──────────────────────────────────────────────────────────┐
  │  Linux kernel (in QEMU guest)                            │
  │       aspeed_i2c.c  →  mctp-i2c.c  →  AF_MCTP socket   │
  │       mctpd (EID discovery, SetEndpointID)               │
  │       pldmd / platform-mc (PDR walk, GetSensorReading)   │
  └──────────────────────────────────────────────────────────┘
```

### Device Details

| Property | Value |
|---|---|
| QEMU type name | `mctp-i2c-endpoint` |
| I2C bus | bus 1 (`mctpi2c1` in kernel) |
| I2C address | `0x0f` (7-bit) |
| Machine name | `ast2600-johnblue` |
| Source file | `hw/i2c/mctp_i2c_endpoint.c` |
| Header file | `include/hw/i2c/mctp_i2c_endpoint.h` |

### Protocol Support

| Protocol | Spec | Commands |
|---|---|---|
| MCTP-over-SMBus framing | DSP0237 | Full frame encode/decode, PEC CRC-8 |
| MCTP Control | DSP0236 | `SetEndpointID`, `GetEndpointID`, `GetMCTPVersionSupport`, `GetMessageTypeSupport` |
| PLDM Base | DSP0240 Type 0 | `GetTID`, `GetPLDMTypes`, `GetPLDMVersion` |
| PLDM PMC | DSP0248 Type 2 | `GetPDRRepositoryInfo`, `GetPDR`, `GetSensorReading` |

### Simulated Sensors

| Sensor ID | Description | Type | Unit | Simulated Value |
|---|---|---|---|---|
| `0x0001` | CPU Temperature | `NumericSensorPDR` | °C (base_unit=2) | 42 °C |
| `0x0002` | 12V Rail Voltage | `NumericSensorPDR` | V (base_unit=5, unitModifier=-2) | 11.98 V (reading=1198) |

### Response Mechanism (Aspeed AST2600 New-Mode I2C)

The AST2600 uses the "new mode" DMA slave path for I2C. When the QEMU device receives an MCTP frame (`I2C_FINISH` event), it:

1. Parses the DSP0237 frame in `process_mctp_frame()`
2. Dispatches to the appropriate handler (`handle_mctp_control`, `handle_pldm_base`, `handle_pldm_pmc`)
3. Builds the response frame (prepends DSP0237 header, appends PEC CRC-8)
4. Schedules a QEMU bottom half (`qemu_bh_schedule`)
5. In the BH callback: calls `i2c_start_send_async(bus, BMC_I2C_SLAVE_ADDR=0x10)` then `i2c_send_async()` per byte

This correctly triggers the Aspeed DMA slave ISR on the kernel side, making `mctp-i2c` see a properly-framed response.

### QEMU Machine: `ast2600-johnblue`

`aspeed_ast2600_johnblue.c` defines a new QEMU machine that clones `ast2600-evb` and adds the MCTP endpoint:

```c
// Places mctp-i2c-endpoint at I2C bus 1 / address 0x0f
i2c_slave_create_simple(aspeed_i2c_get_bus(&soc->i2c, 1),
                        TYPE_MCTP_I2C_ENDPOINT, 0x0f);
```

`johnblue.conf` overrides the inherited QEMU machine:

```bitbake
QB_MACHINE = "-machine ast2600-johnblue"
```

---

## QEMU Patch Files

### `0001-hw-add-mctp-i2c-endpoint-and-ast2600-johnblue-machine.patch`

This is the **active patch** applied by `qemu-system-native_%.bbappend`. It covers all 7 files needed to integrate the device model into QEMU 10.2.0:

| File | Type | Description |
|---|---|---|
| `hw/i2c/mctp_i2c_endpoint.c` | new | Core device model (~855 lines): DSP0237 framing, MCTP Control, PLDM Base, PLDM PMC, 2 sensors, BH response path |
| `include/hw/i2c/mctp_i2c_endpoint.h` | new | `MCTPEndpointState` struct, `TYPE_MCTP_I2C_ENDPOINT` constant |
| `hw/arm/aspeed_ast2600_johnblue.c` | new | Machine `"ast2600-johnblue"`: clones EVB, places `mctp-i2c-endpoint` on bus 1 / addr `0x0f` |
| `hw/i2c/Kconfig` | modified | Adds `config MCTP_I2C_ENDPOINT` (bool, selects I2C) |
| `hw/i2c/meson.build` | modified | Conditionally compiles `mctp_i2c_endpoint.c` under `CONFIG_MCTP_I2C_ENDPOINT` |
| `hw/arm/Kconfig` | modified | Adds `select MCTP_I2C_ENDPOINT` to `config ASPEED_SOC` |
| `hw/arm/meson.build` | modified | Adds `aspeed_ast2600_johnblue.c` to the aspeed machine list |

The patch is in standard `git format-patch` format with unified diffs. New files use `/dev/null` as the `a/` side.

Key implementation notes:
- `qemu/main-loop.h` must be included explicitly for `qemu_bh_new` / `qemu_bh_schedule` / `qemu_bh_delete` — these are not pulled in by `qemu/osdep.h`
- The response is sent as a master-write to `BMC_I2C_SLAVE_ADDR=0x10` (not as a slave-read), matching the Aspeed DMA slave ISR path

### `0001-hw-i2c-add-mctp-i2c-endpoint-device.patch`

This is a **standalone draft** of `mctp_i2c_endpoint.c` only (~857 lines). It was generated during an early iteration before the Kconfig, meson.build, machine file, and header were finalized.

- Contains only the device `.c` file (no Kconfig, no meson.build changes, no machine file, no header)
- Missing the `#include "qemu/main-loop.h"` line (would fail to compile as-is)
- **NOT referenced by the bbappend** — kept as a reference artifact

For actual Yocto builds, only the comprehensive patch above is used.

---

## Build and Run with QEMU

Follow these steps to build the OpenBMC image with the meta-johnblue layer and run it in QEMU.

### 0. Rebuild qemu-system-native first

Because `meta-johnblue` patches QEMU source, you must rebuild `qemu-system-native` before (or as part of) the image build. If your `sstate-cache` has a pre-patch binary, force a rebuild:

```bash
bitbake -c cleanall qemu-system-native && bitbake qemu-system-native
```

Then build the full image:

```bash
bitbake obmc-phosphor-image
```

### 1. Setup johnblue Layer

After syncing the manifest with `repo sync`, the `meta-johnblue` layer is checked out at `meta-johnblue/`.

The `meta-johnblue` layer is already included in the provided configuration sample. To set it up:

#### Option A: Use the Provided Configuration Sample (Recommended)

```bash
# Copy the provided bblayers.conf.sample to your build configuration
cp meta-johnblue/conf/templates/default/bblayers.conf.sample build/conf/bblayers.conf

# Also copy local.conf.sample if you haven't set it up yet
cp meta-johnblue/conf/templates/default/local.conf.sample build/conf/local.conf
```

The `bblayers.conf.sample` file already includes the `meta-johnblue` layer:

```bash
# From meta-johnblue/conf/templates/default/bblayers.conf.sample
BBLAYERS ?= " \
  ##OEROOT##/meta \
  ##OEROOT##/meta-openembedded/meta-oe \
  ##OEROOT##/meta-openembedded/meta-networking \
  ##OEROOT##/meta-openembedded/meta-python \
  ##OEROOT##/meta-phosphor \
  ##OEROOT##/meta-aspeed \
  ##OEROOT##/meta-evb/meta-evb-aspeed/meta-evb-ast2600 \
  ##OEROOT##/meta-johnblue \
  "
```

Set the machine in local.conf:

```bash
# build/conf/local.conf
MACHINE = "johnblue"
```

#### Option B: Manual Setup

If you already have `build/conf/bblayers.conf`, add the layer manually:

```bash
# Edit build/conf/bblayers.conf
# Add to BBLAYERS:
BBLAYERS += "${TOPDIR}/../meta-johnblue"
```

Or use `bitbake-layers`:

```bash
cd build
bitbake-layers add-layer ../meta-johnblue
```

### 2. Build the OpenBMC Image

From the OpenBMC root directory, set up the build environment and build the firmware image:

```bash
# Initialize build environment (if not already done)
. setup johnblue

# Build the phosphor image with the meta-johnblue layer
bitbake obmc-phosphor-image
```

This will:
- Compile OpenBMC with the meta-johnblue layer's PLDM terminus mock
- MCTP loopback services
- All necessary dependencies

**Build time**: This can take 30 minutes to an hour depending on system performance. 

**Output**: The built image will be located in:
```
build/tmp/deploy/images/johnblue/
```

Look for files like:
- `obmc-phosphor-image-johnblue.rootfs.mtdimage`
- `obmc-phosphor-image-johnblue.rootfs.tar.bz2`
- `zImage-*`

### 3. Run QEMU

Once the build completes, run QEMU with the built image:

```bash
# From the OpenBMC build directory
runqemu johnblue slirp nographic
```

**QEMU Options** (optional - runqemu handles defaults):

```bash
# Run with TCP serial console (easier to use)
runqemu johnblue serial tcp nographic

# Run with more verbose output
runqemu johnblue kvm nographic

# Run with USB networking (if needed)
runqemu johnblue net nic,model=e1000
```

### 4. Access the QEMU BMC Console

Once QEMU starts, you'll see boot messages. Wait for the login prompt:

```
johnblue login:
```

**Default credentials:**
- Username: `root`
- Password: `0penBmc` (or no password if configured)

**Or use SSH** (after QEMU boots):

```bash
# From your host machine (in another terminal)
ssh root@192.168.7.2
# Replace IP if different - check QEMU network config
```

### 5. Verify Services in QEMU

Once logged into the QEMU BMC, do a quick sanity check:

```bash
# Verify the MCTP I2C interface came up (created by mctp-i2c kernel driver)
mctp link show
# Expected: mctpi2c1 listed as UP

mctp addr show
# Expected: EID 8 (BMC) on mctpi2c1

mctp neigh show
# Expected: EID 10 (QEMU terminus) reachable via mctpi2c1

# Check services
systemctl status mctpd.service mctp-setup-i2c.service pldmd.service

# View logs
journalctl -u pldmd.service -n 30
```

### 6. Exit QEMU

To stop QEMU:

```bash
# Inside QEMU BMC shell, run:
poweroff

# Or from host machine (if running in background), use Ctrl+C or:
pkill qemu
```

### Troubleshooting Build Issues

**If `bitbake` fails:**
```bash
# Clear previous build state
bitbake -c cleanall obmc-phosphor-image

# Retry build
bitbake obmc-phosphor-image
```

**If `runqemu` cannot find the image:**
```bash
# Verify image exists
ls -la build/tmp/deploy/images/johnblue/

# Check if johnblue machine configuration is found
find . -name "johnblue.conf"
```

**If QEMU fails to boot:**
```bash
# Check for kernel/dtb issues
ls -la build/tmp/deploy/images/johnblue/

# Try with different QEMU options
runqemu qemuarm johnblue nographic
```

## How to Verify

After `runqemu johnblue slirp nographic` boots to the login prompt, log in as `root` and run the following checks.

### 1. Verify MCTP I2C transport is up

```bash
# mctpi2c1 is created by the kernel mctp-i2c driver via the DTS mctp-controller property
mctp link show
# Expected: mctpi2c1 is listed as UP

mctp addr show
# Expected: EID 8 (BMC) on mctpi2c1
```

### 2. Verify mctpd discovered the QEMU endpoint

```bash
mctp neigh show
# Expected: EID 10 reachable via mctpi2c1 (assigned by mctpd SetEndpointID)

journalctl -u mctpd.service -n 30 | grep -i "eid\|endpoint\|assign"
```

### 3. Test PLDM Base commands (Type 0)

```bash
pldmtool base GetTID -m 10
# Expected: TID = 1

pldmtool base GetPLDMTypes -m 10
# Expected: Supported types include Type 0 (Base) and Type 2 (Platform Monitoring)

pldmtool base GetPLDMVersion -m 10 -t 0
# Expected: PLDM Base version 1.1.0
```

### 4. Test PLDM PMC commands (Type 2) — sensors

```bash
# Walk the PDR repository
pldmtool platform GetPDRRepositoryInfo -m 10
# Expected: 2 records in repo

pldmtool platform GetPDR -m 10 --record-handle 0
# Expected: First NumericSensorPDR (CPU temp, sensor ID 1, unit °C)

# Read sensor values
pldmtool platform GetSensorReading -m 10 --sensor-id 1
# Expected: sensorDataSize=1, presentReading=42 (CPU temp 42°C)

pldmtool platform GetSensorReading -m 10 --sensor-id 2
# Expected: presentReading=1198, unitModifier=-2 → 11.98 V (12V rail)
```

### 5. Verify pldmd service is running

```bash
systemctl status pldmd.service
busctl status xyz.openbmc_project.PLDM
journalctl -u pldmd.service -n 50 | grep -i "sensor\|pdr\|discover"
```

### Troubleshooting

**If `mctpi2c1` does not appear:**

```bash
dmesg | grep -i "mctp\|i2c"
# Check the DTS patch was applied: &i2c1 should have mctp-controller property
cat /proc/device-tree/ahb/apb/i2c@1e78a080/mctp-controller 2>/dev/null && echo present
```

**If mctpd does not assign EID 10:**
```bash
journalctl -u mctpd.service | tail -30
# Verify mctpd.conf: mode = "bus-owner"
```

**If pldmd discovery fails:**
```bash
journalctl -u pldmd.service | tail -50
systemctl status mctpd.service mctp-setup-i2c.service
```

---

For more details, refer to the README files in each subdirectory and the OpenBMC documentation.
