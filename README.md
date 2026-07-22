# Project Documentation

This is a Yocto/OpenBMC layer that builds a QEMU-emulated AST2600 BMC (`ast2600-johnblue`)
with a real MCTP-over-I2C PLDM terminus device model. It's a development environment for
exercising the full real kernel MCTP/PLDM driver stack — `aspeed_i2c`, `mctp-i2c`, `mctpd`,
`pldmd`/`pldmtool` — without needing physical hardware.

This document covers repo setup, building, running, and verifying the environment. For
the architecture, service flow, implementation status, and QEMU device-model internals,
see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Project Structure

```
meta-johnblue/
├── README.md                               # Setup, build, run, verify, and repository overview
├── ARCHITECTURE.md                         # Architecture and QEMU device-model internals
├── conf/
│   ├── layer.conf                          # Layer metadata, priorities, dependencies
│   ├── machine/
│   │   └── johnblue.conf                   # Machine definition (AST2600, QB_MACHINE override)
│   └── templates/default/
│       ├── bblayers.conf.sample            # Ready-to-use bblayers configuration
│       └── local.conf.sample               # Ready-to-use local.conf with MACHINE=johnblue
├── manifest/
│   ├── main.xml                            # repo manifest (main branch)
│   └── mocking.xml                         # repo manifest (mocking branch)
├── recipes-devtools/
│   ├── nodejs/
│   │   ├── gcc12-wrapper/{gcc,g++}         # Host GCC 12 wrappers for the native nodejs build
│   │   └── nodejs_24.18.0.bbappend         # Puts the wrappers on PATH (Ubuntu 22.04 has GCC 11)
│   └── qemu/
│       ├── files/
│       │   └── 0001-hw-add-mctp-i2c-endpoint-and-ast2600-johnblue-machine.patch
│       │       # All QEMU changes: device model + machine + build glue
│       └── qemu-system-native_%.bbappend   # Applies the QEMU patch
├── recipes-kernel/
│   └── linux/
│       ├── files/
│       │   ├── 0001-aspeed-evb-add-mctp-controller-to-i2c1.patch  # DTS: mctp-controller on &i2c1
│       │   └── i2c-slave-dev.cfg           # Kernel config fragment: I2C slave support
│       ├── linux-aspeed_%.bbappend         # Applies the DTS patch and config fragment
│       └── linux-yocto-fitimage.bbappend   # No-op; documents that the default FIT image is enough
└── recipes-phosphor/
    ├── images/
    │   └── obmc-phosphor-image.bbappend    # Adds the MCTP/PLDM stack and dev tools to the image
    ├── mctp/
    │   ├── files/
    │   │   ├── mctpd.conf                     # bus-owner mode, 5 s timeout
    │   │   ├── mctp-setup-i2c.service         # Creates mctpi2c1 (I2C slave 0x10), adds BMC EID 8
    │   │   └── mctp-discover-terminus.service # AssignEndpointStatic -> EID 10 over I2C
    │   └── mctp_%.bbappend
    └── pldm/
        ├── files/host_eid                  # "10": read by pldmd's host-firmware path
        └── pldm_%.bbappend
```

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

## What are MCTP and PLDM?

### MCTP (Management Component Transport Protocol) — DSP0236

MCTP is the transport layer for platform management traffic between components (BMC,
host CPU, NICs, PSUs, add-in cards, etc.). It defines addressing, packet framing, and
transport bindings over physical buses, independent of whatever protocol rides on top.

**Common / baseline support** — present in essentially any conformant MCTP stack:
- A single physical transport binding (this repo: I2C/SMBus per **DSP0237**)
- Packetization and reassembly: message fragmentation across packets using the
  SOM (start-of-message) / EOM (end-of-message) / packet-sequence / message-tag fields
  in the 4-byte MCTP transport header
- Endpoint addressing via 8-bit Endpoint IDs (EIDs) — every message is framed with a
  source and destination EID
- **MCTP Control Protocol** (Type 0 messages): the mandatory discovery/setup command
  set — `SetEndpointID`, `GetEndpointID`, `GetEndpointUUID`, `GetMCTPVersionSupport`,
  `GetMessageTypeSupport`. A bus owner (`mctpd` here) uses these to discover and assign
  EIDs to endpoints on the bus before any higher-layer protocol can run.

**Advanced / optional support** — part of the wider MCTP spec surface, not all of which
is exercised by this repo:
- Multiple physical transport bindings bridged into one logical MCTP network, with EIDs
  routed across buses rather than confined to a single point-to-point link
- Additional bindings beyond I2C: PCIe VDM (**DSP0238**), USB (**DSP0283**),
  KCS (**DSP0254**), Serial/UART (**DSP0253**)
- Endpoint Context / multi-key routing for endpoints reachable via more than one bus
- Vendor Defined Messages (MCTP message types `0x7E`/`0x7F`) carrying vendor/OEM payloads
- Security extensions layered on top of the base control protocol for authenticated/
  encrypted MCTP traffic over networked transports

This repo implements exactly the common/baseline set: one I2C transport binding, packet
framing (see [ARCHITECTURE.md § Figure 2](ARCHITECTURE.md#figure-2-one-frame-byte-by-byte)),
and the four MCTP Control commands needed for real `SetEndpointID` discovery.

### PLDM (Platform Level Data Model) — DSP0240 family

PLDM is a higher-layer data/command model that runs as MCTP message Type 1 on top of the
transport above. Each PLDM "Type" below is an independently defined command set for a
specific management domain. PLDM types and MCTP message types are numbered separately, so
PLDM Type 0 (Base) has nothing to do with MCTP message type 0 (Control).

**Common / baseline support:**
- **PLDM Base (Type 0, DSP0240)** — the mandatory command set every PLDM terminus must
  implement: `GetTID`, `SetTID`, `GetPLDMTypes`, `GetPLDMVersion`, `GetPLDMCommands`.
  This is the discovery layer a PLDM requester (`pldmd`/`platform-mc`, or `pldmtool`)
  uses to learn what a terminus supports before issuing any type-specific commands.

**Advanced / type-specific support** — each is its own optional PLDM Type, advertised
via `GetPLDMTypes`:

| Type | Name | Spec | Purpose |
|---|---|---|---|
| 0 | Base | DSP0240 | Discovery, versioning, command enumeration (mandatory) |
| 1 | SMBIOS Transfer | DSP0246 | Retrieve SMBIOS structures over PLDM |
| **2** | **Platform Monitoring and Control (PMC)** | **DSP0248** | **Sensors/effecters, PDR repository, `GetSensorReading` — implemented in this repo** |
| 3 | BIOS Control and Configuration | DSP0247 | BIOS attribute table read/write |
| 4 | FRU Data | DSP0257 | FRU record table discovery and retrieval |
| 5 | Firmware Update | DSP0267 | Component-based firmware update state machine |
| 6 | Redfish Device Enablement (RDE) | DSP0218 | Exposing Redfish resources through PLDM |
| 7 | File Transfer | DSP0264 | Bulk file transfer over PLDM |
| 63 | OEM | — | Vendor-defined extensions |

This repo's QEMU terminus advertises exactly Type 0 (Base) and Type 2 (PMC) via
`GetPLDMTypes`, and implements a subset of each type's commands — see
[ARCHITECTURE.md § Protocol Support](ARCHITECTURE.md#protocol-support) for the exact
command list and [Known Gaps](ARCHITECTURE.md#known-gaps) for what's intentionally not
implemented (e.g. `GetPLDMCommands`).

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

Nothing to copy by hand. `. setup johnblue` (step 2) finds
`meta-johnblue/conf/machine/johnblue.conf`, and on first run creates the build
directory `build/johnblue/` with its `conf/` generated from
`meta-johnblue/conf/templates/default/`.

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

and `local.conf.sample` already sets the machine:

```bash
# build/johnblue/conf/local.conf
MACHINE ??= "johnblue"
```

#### Option B: Manual Setup

If you already have a build directory (say `build/johnblue/`) that was created without
this layer, add the layer manually:

```bash
# Edit build/johnblue/conf/bblayers.conf
# Add to BBLAYERS (TOPDIR is build/johnblue, so the layer is two levels up):
BBLAYERS += "${TOPDIR}/../../meta-johnblue"
```

Or use `bitbake-layers`:

```bash
cd build/johnblue
bitbake-layers add-layer ../../meta-johnblue
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
- Rebuild `qemu-system-native` and `qemu-helper-native` with the custom `mctp-i2c-endpoint` device model patch
- Compile the kernel with the `mctp-controller` DTS patch and I2C-slave config fragment
- Install the MCTP/PLDM stack and discovery services (`mctpd`, `mctp-setup-i2c.service`, `mctp-discover-terminus.service`, `pldmd`)

**Build time**: This can take 30 minutes to an hour depending on system performance. 

**Output**: The built image will be located in:
```
build/johnblue/tmp/deploy/images/johnblue/
```

Look for files like:
- `obmc-phosphor-image-johnblue.static.mtd` (also linked as `image-bmc`): the 64 MB
  flash image that `runqemu` boots
- `obmc-phosphor-image-johnblue.static.mtd.tar`: the firmware update tarball
- `fitImage`, `zImage`: the kernel

### 3. Run QEMU

Once the build completes, run QEMU with the built image:

```bash
# From the OpenBMC build directory
runqemu johnblue slirp nographic
```

**QEMU Options** (optional - runqemu handles defaults):

```bash
# Print runqemu's debug output, including the full QEMU command line
runqemu johnblue slirp nographic -d

# Log guest errors (qemu_log_mask LOG_GUEST_ERROR) to a file instead of the console.
# Other QEMU models (ftgmac100, PHY, SCU) log harmless noise here too, so filter for
# the device model, e.g. "mctp-i2c-endpoint: bad command code"
runqemu johnblue slirp nographic qemuparams="-d guest_errors -D /tmp/qemu-guest-errors.log"
grep mctp-i2c-endpoint /tmp/qemu-guest-errors.log
```

`kvm` is not available: this machine sets no `QB_CPU_KVM`, and an ARM guest cannot use
KVM on an x86 host.

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
# From your host machine (in another terminal). With slirp, johnblue.conf's
# QB_SLIRP_OPT forwards host port 2222 -> BMC 22 and host 4433 -> BMC 443 (HTTPS).
# If a TCP port is busy, runqemu picks another one and prints it at startup
# ("Port forward changed: 2222 -> 2223").
ssh -p 2222 root@localhost
```

### 5. Verify Services in QEMU

Once logged into the QEMU BMC, do a quick sanity check:

```bash
# Verify the MCTP I2C interface came up (created by mctp-setup-i2c.service)
mctp link show
# Expected: mctpi2c1 listed as UP

mctp addr show
# Expected: EID 8 (BMC) on mctpi2c1

mctp neigh show
# Expected: EID 10 (QEMU terminus) reachable via mctpi2c1

# Check services
systemctl status mctpd.service mctp-setup-i2c.service mctp-discover-terminus.service pldmd.service

# View logs
journalctl -u pldmd.service -n 30
```

### 6. Exit QEMU

To stop QEMU:

```bash
# Inside QEMU BMC shell, run:
poweroff

# Or, in the QEMU console, press Ctrl+A then X
# (with nographic, Ctrl+C goes to the guest, not to QEMU)

# Or from another host terminal:
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
ls -la build/johnblue/tmp/deploy/images/johnblue/

# Check if johnblue machine configuration is found
find . -name "johnblue.conf"
```

**If QEMU fails to boot:**
```bash
# Check for kernel/dtb issues
ls -la build/johnblue/tmp/deploy/images/johnblue/

# Check which QEMU command runqemu builds (machine should be ast2600-johnblue)
runqemu johnblue slirp nographic -d
```

**If QEMU exits with `Could not set up host forwarding rule 'udp::6233-:623'`:** another
QEMU on the host already forwards UDP 6233. runqemu only checks TCP ports when looking
for free ones, so it does not move this UDP (IPMI) forward. Stop the other QEMU, or
change the UDP port in `QB_SLIRP_OPT` in `conf/machine/johnblue.conf` and rebuild the
image, which regenerates the `.qemuboot.conf` that runqemu reads.

## How to Verify

After `runqemu johnblue slirp nographic` boots to the login prompt, log in as `root` and run the following checks.

### 1. Verify MCTP I2C transport is up

```bash
# mctpi2c1 is created when mctp-setup-i2c.service instantiates the mctp-i2c client at
# 0x10 on i2c-1; the DTS mctp-controller property is what lets it attach to that bus
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

Note: this `pldmtool` build has no `GetPDRRepositoryInfo` subcommand — `GetPDR` covers
individual records (`-d`), a PDR type (`-t`), a terminus (`-i`), or the whole repo (`-a`).
`GetSensorReading` takes `-i <sensor_id> -r <rearm>` (both required).

```bash
# Retrieve individual PDR records (0 = first record in the repository)
pldmtool platform GetPDR -m 10 -d 0
# Expected: NumericSensorPDR, sensorID=1, baseUnit="Degrees C(2)", dataLength=71

pldmtool platform GetPDR -m 10 -d 2
# Expected: NumericSensorPDR, sensorID=2, baseUnit="Volts(5)", unitModifier=-2

# Read sensor values (rearm=0)
pldmtool platform GetSensorReading -m 10 -i 1 -r 0
# Expected: sensorOperationalState="Sensor Enabled", presentState="Sensor Normal",
#           presentReading=42 (CPU temp 42°C)

pldmtool platform GetSensorReading -m 10 -i 2 -r 0
# Expected: presentReading=1198 → unitModifier=-2 means 11.98 V (12V rail)
```

### 5. Verify pldmd service is running

```bash
systemctl status pldmd.service
journalctl -u pldmd.service -n 50 | grep -i "sensor\|pdr\|discover"
```

Note: `pldmd` does not expose the sensors as D-Bus objects yet. The device does not
implement `GetPLDMCommands`, so pldmd logs `GetPLDMCommands ... complete code 5`, treats
every command as unsupported, and skips the PDR walk (see
[ARCHITECTURE.md § Figure 7](ARCHITECTURE.md#figure-7-where-pldmd-stops-today)). This does
not affect the manual `pldmtool` commands above, which talk to the device directly.

### Troubleshooting

**If `mctpi2c1` does not appear:**

```bash
systemctl status mctp-setup-i2c.service
dmesg | grep -i "mctp\|i2c"
# Check the DTS patch was applied: &i2c1 should have mctp-controller property
[ -e /sys/bus/i2c/devices/i2c-1/of_node/mctp-controller ] && echo present
```

**If `mctp neigh show` does not show EID 10:**
```bash
journalctl -u mctpd.service | tail -30
# Verify mctpd.conf: mode = "bus-owner"

systemctl status mctp-discover-terminus.service
# This service calls AssignEndpointStatic against mctpd; if it failed, retry manually:
busctl call au.com.codeconstruct.MCTP1 \
    /au/com/codeconstruct/mctp1/interfaces/mctpi2c1 \
    au.com.codeconstruct.MCTP.BusOwner1 AssignEndpointStatic ayy 1 0x0f 10
```

**If `pldmd` logs `GetPLDMCommands` errors:** this is expected, as are the
`query device identifiers` timeout and `Failed to config event receiver` lines. See
[ARCHITECTURE.md § Figure 7](ARCHITECTURE.md#figure-7-where-pldmd-stops-today), which
explains each line pldmd logs at boot.
It does not affect manual `pldmtool` queries; use those to verify the real path instead:
```bash
journalctl -u pldmd.service | tail -50
systemctl status mctpd.service mctp-setup-i2c.service mctp-discover-terminus.service
```

---

For how all of this fits together, see [ARCHITECTURE.md](ARCHITECTURE.md). For more
details, refer to the OpenBMC documentation.
