# meta-johnblue Architecture

This document covers the source code layout, design, and internals of the `meta-johnblue`
layer's QEMU-based MCTP/PLDM development environment. For getting started — build, run,
and verify — see [README.md](README.md).

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
│   │   └── obmc-phosphor-image.bbappend    # Adds mctp/pldm stack + dev tools to image
│   ├── mctp/
│   │   ├── files/
│   │   │   ├── mctpd.conf                     # bus-owner mode, 5s timeout
│   │   │   ├── mctp-setup-i2c.service          # Brings up mctpi2c1, adds BMC EID 8
│   │   │   └── mctp-discover-terminus.service  # Triggers real AssignEndpointStatic (EID 10) over I2C
│   │   └── mctp_%.bbappend
│   └── pldm/
│       ├── files/host_eid                  # EID 10 — the QEMU endpoint's assigned EID
│       └── pldm_%.bbappend
└── manifest/
    └── main.xml
```

> **Note:** an earlier iteration of this layer included a `recipes-phosphor/pldm-terminus/`
> loopback mock (`pldm-terminus.c` + `mctp-lo-setup.service`) that answered `pldmtool`
> queries directly over an `AF_MCTP` loopback socket, with **zero I2C bus interaction**.
> It has been removed: it never exercised the kernel's `aspeed_i2c` / `mctp-i2c` driver
> path at all, so it could not validate anything about the real device model. All PLDM
> traffic now goes over the real I2C wire path described below.

This structure enables modular development and easy integration with the OpenBMC build system.

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

This exercises the **complete real kernel driver path** — `aspeed_i2c.c`, `mctp-i2c.c`, `mctpd`, and `pldmd`/`pldmtool` — using a QEMU I2C device model that speaks the same wire protocol as real PLDM terminus hardware. The `mctpd`/discovery and `pldmtool` legs of this diagram are fully working today; `pldmd`'s own autonomous PDR-walk-to-D-Bus-sensor leg is not yet — see [Known Gaps](#known-gaps).

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
  - `mctp-discover-terminus.service` triggers the initial `AssignEndpointStatic` D-Bus call against `mctpd` so discovery happens automatically on boot
  - Responds to all PLDM Base (Type 0) and PLDM PMC (Type 2) commands actually implemented (see [Protocol Support](#protocol-support) below)

**Service startup chain:**

```
mctpd
  └─ mctp-setup-i2c.service         # brings up mctpi2c1, adds BMC EID 8
       └─ mctp-discover-terminus.service   # AssignEndpointStatic → EID 10 (real I2C SetEndpointID)
            └─ pldmd.service        # BMC PLDM daemon
```

**Service relation diagram:**

```
[ mctpd ]   ←──── mctp-discover-terminus.service calls AssignEndpointStatic,
    |             mctpd sends real SetEndpointID over I2C, assigns EID 10
    v
[ mctp-setup-i2c.service ]   ←── mctpi2c1 up, BMC EID 8
    |
    v
[ pldmd.service ] / pldmtool  ←── queries QEMU device: GetTID, GetPDR, GetSensorReading
```

- `mctpd` performs real EID assignment via the `mctp-i2c` kernel driver, triggered by `mctp-discover-terminus.service`'s `AssignEndpointStatic` D-Bus call.
- `mctp-setup-i2c.service` creates the `mctpi2c1` network device (via kernel DT `mctp-controller` property on `&i2c1`) and adds BMC EID 8.
- `pldmtool` (manual queries) fully succeeds end-to-end over the real path: `GetTID`, `GetPLDMTypes`, `GetPDR`, `GetSensorReading` all return correct values from the QEMU device.
- `pldmd`'s own autonomous `platform-mc` PDR-walk/D-Bus-sensor-exposure pipeline is **not yet functional** — it additionally requires `GetPLDMCommands` (PLDM Base command 0x05), which the device model does not implement yet. See [Known Gaps](#known-gaps).
- The QEMU I2C device model at `bus1/0x0f` handles all terminus-side PLDM logic.

---

## Implementation Status: QEMU Device Model

This layer uses a QEMU I2C device model as the PLDM terminus. This is **not a software loopback mock** — every byte of every PLDM/MCTP transaction actually crosses the QEMU-emulated `aspeed_i2c` bus and is processed by the real Linux kernel driver stack (`aspeed_i2c.c` → `mctp-i2c.c` → `AF_MCTP` → `mctpd`/`pldmtool`). This was verified end-to-end (see [Verification History](#verification-history) below).

### What is real

- **`aspeed_i2c` driver**: the QEMU AST2600 I2C master/slave emulation is the real upstream code
- **`mctp-i2c` kernel driver**: the Linux kernel's `drivers/net/mctp/mctp-i2c.c` handles all DSP0237 framing, PEC validation, and skb delivery for both directions
- **`mctpd` EID assignment**: `SetEndpointID` flows over the real I2C path (`AssignEndpointStatic` → real I2C write → QEMU device parses it → real I2C response → kernel validates PEC/framing → `mctpd` completes discovery), not a static `mctp addr add`
- **`pldmtool` queries**: `GetTID`, `GetPLDMTypes`, `GetPDR` (both sensor records fully decode), and `GetSensorReading` all succeed over the real wire path with correct values

### What is simulated

- **Sensor values**: CPU temp is statically 42 °C, 12V rail is statically 11.98 V — there is no actual hwmon driver behind these; only the *values* are canned, the transport and protocol handling around them are real
- **PDR data**: `record_change_num`, CRC-32 in `GetPDR` responses, and a few other rarely-checked fields are zero/placeholder

### Known Gaps

- **`pldmd`'s autonomous `platform-mc` manager does not yet complete its own discovery.** On startup it calls `GetPLDMCommands` (PLDM Base command 0x05) as part of building its internal terminus model; the device model does not implement that command, so `pldmd` logs `Error : GetPLDMCommands for terminus ID 1, complete code 5` and does not proceed to expose the sensors as D-Bus objects automatically. This does **not** affect manual `pldmtool` queries (which don't require `GetPLDMCommands`) — only `pldmd`'s own internal PDR-walk-and-poll pipeline. Extending `handle_pldm_base()` in `mctp_i2c_endpoint.c` with `GetPLDMCommands` (and whatever else `platform-mc` needs post-discovery) would close this gap but was out of scope for this pass.

### Data flow

```
pldmtool / pldmd (BMC EID 8)
    ↓  AF_MCTP socket → mctp-i2c.c → aspeed_i2c.c
    ↓  I2C master write (DSP0237 MCTP-over-SMBus frame)
mctp-i2c-endpoint QEMU device (bus1/addr 0x0f, EID 10)
    ↓  processes frame, builds response
    ↓  i2c_start_send_async → Aspeed old-mode slave-receive ISR (byte-paced, see below)
mctp-i2c.c → AF_MCTP → pldmtool (JSON output) / pldmd
    ↓
D-Bus sensor objects / Redfish   (pldmd leg: see Known Gaps)
```

---

## QEMU I2C Device Model

The core of this layer is a custom QEMU I2C slave device (`mctp-i2c-endpoint`) that replaces the AF_MCTP loopback mock with a proper in-QEMU terminus that exercises the real Linux kernel driver path.

### Architecture

```
QEMU userspace
  ┌──────────────────────────────────────────────────────────┐
  │  aspeed_i2c master (I2C bus 1)                           │
  │       ↕  I2C master writes/slave reads (QEMU I2C API)    │
  │  mctp-i2c-endpoint (addr 0x0f)                           │
  │       - DSP0237 MCTP-over-SMBus framing + PEC CRC-8      │
  │       - MCTP Control (DSP0236): SetEID/GetEID            │
  │       - PLDM Base (DSP0240, Type 0)                      │
  │       - PLDM PMC (DSP0248, Type 2) + static PDR repo     │
  └──────────────────────────────────────────────────────────┘
         ↕  virtual I2C
  ┌──────────────────────────────────────────────────────────┐
  │  Linux kernel (in QEMU guest)                            │
  │       aspeed_i2c.c  →  mctp-i2c.c  →  AF_MCTP socket     │
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

Note: `GetPLDMCommands` (PLDM Base command 0x05) is **not** implemented — see [Known Gaps](#known-gaps).

### Simulated Sensors

| Sensor ID | Description | Type | Unit | Simulated Value |
|---|---|---|---|---|
| `0x0001` | CPU Temperature | `NumericSensorPDR` | °C (base_unit=2) | 42 °C |
| `0x0002` | 12V Rail Voltage | `NumericSensorPDR` | V (base_unit=5, unitModifier=-2) | 11.98 V (reading=1198) |

### Response Mechanism (Aspeed AST2600 Old-Mode I2C)

The BMC's kernel here runs the AST2600 I2C controller in **old mode**: a byte-at-a-time,
interrupt-driven slave-receive path (not the DMA-based new mode — there's no
`I2C_CTRL_GLOBAL`/`REG_MODE` switch to new mode in this configuration). Each byte the
QEMU device sends as a master-write arrives as a single-byte hardware register
(`I2CD_BYTE_BUF`) that the guest's ISR must service before the next byte overwrites it.

When the QEMU device receives an MCTP frame (`I2C_FINISH` event), it:

1. Parses the DSP0237 frame in `process_mctp_frame()`
2. Dispatches to the appropriate handler (`handle_mctp_control`, `handle_pldm_base`, `handle_pldm_pmc`)
3. Builds the response frame (prepends DSP0237 header, appends PEC CRC-8) via `build_mctp_frame()`
4. Schedules a QEMU bottom half (`qemu_bh_schedule`), which drives a `QEMUTimer`-paced
   state machine (`mctp_i2c_resp_bh()`): address phase, then one `i2c_send_async()` per
   timer tick, then `i2c_end_transfer()` a full tick after the last byte

**Why the pacing is necessary:** QEMU device callbacks run with the BQL held, so a tight
loop that pushes every byte in one invocation never lets the guest vCPU run in between —
the kernel's ISR only ever observes the last byte and the rest of the frame is silently
lost. Kernel-side dynamic-debug tracing on `aspeed_i2c_slave_irq()` confirmed this
directly: at 100µs/byte spacing, the guest's interrupt handler only actually fired 3 times
for a 15-byte response — most bytes were overwritten in the single-byte register before
the guest's ISR was even scheduled. The response bytes are now spaced 20ms apart on
`QEMU_CLOCK_VIRTUAL`, which reliably lets the guest service every interrupt (this adds well
under a second even for the largest frames, far inside `mctpd`'s 5s per-message timeout).

The address phase (`i2c_start_send_async`) is paced as its own separate timer tick,
not sent back-to-back with byte 0 — both phases write the same single-byte hardware
register, so with no delay in between, the address-phase value gets overwritten by
byte 0 before the guest's ISR ever reads it (misclassifying the transaction).

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
| `hw/i2c/mctp_i2c_endpoint.c` | new | Core device model (~965 lines): DSP0237 framing, MCTP Control, PLDM Base, PLDM PMC, 2 sensors, timer-paced BH response path |
| `include/hw/i2c/mctp_i2c_endpoint.h` | new | `MCTPEndpointState` struct, `TYPE_MCTP_I2C_ENDPOINT` constant |
| `hw/arm/aspeed_ast2600_johnblue.c` | new | Machine `"ast2600-johnblue"`: clones EVB, places `mctp-i2c-endpoint` on bus 1 / addr `0x0f` |
| `hw/i2c/Kconfig` | modified | Adds `config MCTP_I2C_ENDPOINT` (bool, selects I2C) |
| `hw/i2c/meson.build` | modified | Conditionally compiles `mctp_i2c_endpoint.c` under `CONFIG_MCTP_I2C_ENDPOINT` |
| `hw/arm/Kconfig` | modified | Adds `select MCTP_I2C_ENDPOINT` to `config ASPEED_SOC` |
| `hw/arm/meson.build` | modified | Adds `aspeed_ast2600_johnblue.c` to the aspeed machine list |

The patch is in standard `git format-patch` format with unified diffs. New files use `/dev/null` as the `a/` side.

Key implementation notes:
- `qemu/main-loop.h` must be included explicitly for `qemu_bh_new` / `qemu_bh_schedule` / `qemu_bh_delete` — these are not pulled in by `qemu/osdep.h`
- The response is sent as a master-write to `BMC_I2C_SLAVE_ADDR=0x10` (not as a slave-read), matching the Aspeed old-mode slave ISR path

### `0001-hw-i2c-add-mctp-i2c-endpoint-device.patch`

This is a **standalone draft** of `mctp_i2c_endpoint.c` only (~857 lines). It was generated during an early iteration before the Kconfig, meson.build, machine file, and header were finalized.

- Contains only the device `.c` file (no Kconfig, no meson.build changes, no machine file, no header)
- Missing the `#include "qemu/main-loop.h"` line (would fail to compile as-is)
- **NOT referenced by the bbappend** — kept as a reference artifact

For actual Yocto builds, only the comprehensive patch above is used.

---

## Verification History

The real device-model path (as opposed to the removed loopback mock) did not work
out of the box. Getting `mctp neigh show` to show a genuine, wire-verified EID 10 and
`pldmtool` to return correct sensor values required finding and fixing 11 distinct bugs,
each confirmed via kernel dynamic-debug / temporary `dev_info` tracing rather than
guesswork:

1. **I2C address collision** between the BMC's own slave address and the terminus address
2. **Frame-parsing offset bug** in `process_mctp_frame()` — fields read from the wrong byte offsets
3. **Un-paced response bytes** — see [Response Mechanism](#response-mechanism-aspeed-ast2600-old-mode-i2c) above
4. **STOP-event timing** — `i2c_end_transfer()` called synchronously instead of a tick after the last byte
5. **Address-phase byte overwrite** — address phase and byte 0 shared one hardware register with no delay between them
6. **`byte_count` incorrectly included the PEC byte**, causing the kernel to reject every otherwise-correct frame on a length mismatch
7. **Missing `MCTP_I2C_COMMANDCODE` definition** causing a build/logic bug in frame validation
8. **CRC-8 PEC computed over the wrong length** (`crc8_smbus(pec_buf, 1 + idx - 1)` excluded the final byte from the checksum), failing PEC validation on content that was otherwise byte-perfect
9. **MCTP transport header fields transposed** in `build_mctp_frame()` — the SOM/EOM/TO/tag byte and the header-version byte were swapped, so every response passed the I2C-layer framing/PEC check but was silently dropped by the kernel's MCTP core, which is why `mctpd`'s `AssignEndpointStatic` timed out even after bug #8 was fixed
10. **`PDRNumericSensor` struct didn't byte-match libpldm's real DSP0248 layout** — `container_id` was 1 byte instead of 2, two fields (`rel`, `aux_oem_unit_handle`) were missing entirely, and `hysteresis`/`max_readable`/`min_readable` were 4 bytes instead of 2 (they're sized per `sensor_data_size`, not fixed `uint32_t`) — this caused `pldmtool platform GetPDR` to decode the header but fail body decoding
11. **Wrong PLDM enum values** for sensor operational/present/previous/event state (`0x00`/`0x01` swapped), which made `GetSensorReading` report "Sensor Disabled" / "Sensor Unknown" instead of "Sensor Enabled" / "Sensor Normal" even though `presentReading` was already correct

After all 11 fixes, a clean rebuild (kernel + FIT image + full `obmc-phosphor-image`,
with no debug instrumentation) was booted fresh and re-verified: `mctp neigh show` shows
EID 10, `pldmtool base GetTID/GetPLDMTypes`, `platform GetPDR` (both records fully
decode), and `platform GetSensorReading` (42 / 1198) all succeed over the real wire path
with zero failed systemd units.
