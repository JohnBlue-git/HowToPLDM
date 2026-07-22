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

This layer uses a QEMU I2C device model as the PLDM terminus. This is **not a software loopback mock** — every byte of every PLDM/MCTP transaction actually crosses the QEMU-emulated `aspeed_i2c` bus and is processed by the real Linux kernel driver stack (`aspeed_i2c.c` → `mctp-i2c.c` → `AF_MCTP` → `mctpd`/`pldmtool`). See [How to Verify](README.md#how-to-verify) in the README for the exact commands that confirm this end-to-end.

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

## Source Code Walkthrough

The sections above describe *what* the device model does. This section explains *why*
it's built the way it is, function by function, assuming no prior QEMU device-model
experience. If you've never written a QEMU device before, read
[Background Concepts](#background-concepts) first — everything after it leans on those
ideas without re-explaining them.

### Background Concepts

**QOM (QEMU Object Model).** Every QEMU device — real or emulated — is a C "object"
with a type name, a state struct, and lifecycle callbacks (`realize`/`unrealize`)
that QEMU calls automatically when the device is created/destroyed. You don't call
these yourself; you register them in a `TypeInfo` and QEMU's object system invokes
them at the right time. This is why `mctp_i2c_ep_realize()` looks like it's never
called from anywhere in this file — it's wired up via `mctp_i2c_ep_class_init()` and
invoked by the QOM machinery when the machine file instantiates the device.

**The BQL (Big QEMU Lock).** QEMU's device emulation is fundamentally single-threaded:
one thread runs the emulated guest CPU *and* all device callbacks, one at a time, under
a single global lock. This means a device callback that loops or blocks stops the guest
CPU from running at all until the callback returns — there is no "meanwhile the guest
handles its interrupt" happening concurrently. Any device that needs to spread work out
over time (like sending bytes one at a time, waiting for the guest to react to each one)
has to give control back to the main loop between steps, rather than looping internally.
That's what bottom halves and timers (below) are for.

**Bottom halves (BH) and timers.** A QEMU bottom half (`QEMUBH`) is a "run this function
soon, but not right now, from the main loop" callback — it lets a device defer work
instead of doing it inline inside an interrupt-context callback. A `QEMUTimer` is the
same idea but scheduled for a specific point on a virtual clock instead of "as soon as
possible". This device uses a BH to *kick off* the response (right after processing a
request), then a timer to *pace* each subsequent byte of that response — see
[Response Mechanism](#response-mechanism-aspeed-ast2600-old-mode-i2c) for why the pacing
itself is necessary.

**I2C slave vs. master, and why bytes arrive one at a time.** On a real I2C bus, one
device (the "master") drives the clock and addresses another device (the "slave") to
either write bytes to it or read bytes from it. QEMU's I2C core delivers a slave device
every byte of an incoming write through one callback (`.send`) and asks it for the next
outgoing byte through another (`.recv`), with separate "event" callbacks marking the
start/end of a transaction. There is no "give me the whole frame at once" API — that's
why this device has to accumulate bytes into `rx_buf` as they arrive and only look at
the complete frame once a `I2C_FINISH` event says the transaction is done.

**EIDs, MCTP, and PLDM, in one sentence each.** An EID (Endpoint ID) is an 8-bit address
identifying one endpoint on an MCTP network — like an IP address, but for management
traffic. MCTP wraps a message in a small header (source/destination EID, a tag, and
start/end-of-message flags) so it can be split across multiple physical packets and
reassembled. PLDM is one specific *kind* of message that travels inside an MCTP payload,
identified by a "PLDM type" byte (Type 0 = Base/discovery, Type 2 = Platform Monitoring
in this repo) and further split into numbered commands within that type.

**PEC (Packet Error Code).** A single CRC-8 checksum byte appended to every DSP0237
frame, computed over the I2C address byte plus everything else in the frame. It's the
I2C-level equivalent of a network packet checksum: without it, a corrupted byte on the
wire (or, during development, a corrupted byte from a device-model bug) would be silently
accepted as valid data.

### `mctp_i2c_endpoint.h` — the device's state

Every QOM device needs a state struct holding everything that must persist between
callback invocations (QEMU calls your callbacks repeatedly with no memory of previous
calls except what you stored in this struct). `MCTPEndpointState` holds:

- `rx_buf` / `rx_len` — the incoming frame, built up one byte per `.send` callback
  invocation, since (as above) I2C delivers a write one byte at a time
- `resp_buf` / `resp_len` / `resp_pos` — the outgoing response frame and how much of
  it has been sent so far; needed because, symmetrically, the response also has to go
  out one byte at a time, spread across many timer callbacks, not in one shot
- `resp_addr_sent` — tracks whether the response's I2C address phase has already
  happened, so the timer-driven state machine knows whether its next step is "address
  the bus" or "send the next data byte"
- `bus_ref` — a handle to the I2C bus this device sits on, needed because sending a
  response means *this device* has to act as a bus master and address the BMC, which
  requires knowing which bus to drive
- `bh` / `resp_timer` — the bottom half and timer used to pace the response (see
  [Background Concepts](#background-concepts))
- `eid` / `tid` — this endpoint's current MCTP Endpoint ID (starts at 0, meaning
  "unassigned", until `mctpd` assigns one via `SetEndpointID`) and its PLDM Terminus ID

### `mctp_i2c_endpoint.c`, top to bottom

**Wire-level constants** (`TERMINUS_I2C_ADDR`, `BMC_I2C_SLAVE_ADDR`, `MCTP_HDR_VER`,
`MCTP_I2C_COMMANDCODE`, message type/command code enums). These exist because DSP0237/
DSP0236/DSP0240/DSP0248 are all fixed-format binary wire protocols — every field's
meaning and position is dictated by the spec, not by this code, so the constants are
just named versions of numbers a real PLDM terminus and a real MCTP-over-I2C kernel
driver both already agree on.

**`PDRHeader` / `PDRNumericSensor` / `PDRNumericRecord` structs, and `pdr_repo[]`.**
A PDR (Platform Data Record) is how a PLDM platform tells a requester "here is a sensor,
here's its ID, its unit, its normal/warning/critical thresholds, etc." Real firmware
would generate these at runtime or store them in flash; this device model hard-codes two
of them (`pdr_repo[]`) because there's no real hardware behind these sensors — the *data
model* is real (`pldmtool`/`pldmd` parse it with the exact same code they'd use against
real hardware), only the *values* are canned. The struct layout matters more than it
might look: it has to match libpldm's real `struct pldm_numeric_sensor_value_pdr`
byte-for-byte (field widths, field order, no extra or missing fields), because a real
PLDM requester decodes the raw bytes using that exact structure — if a field is the wrong
width, every field after it in the struct shifts and decoding falls apart, even though
each individual value would have been "correct" in isolation.

**`crc8_smbus()`.** A standalone implementation of the CRC-8/SMBUS polynomial (0x07)
used to compute the PEC byte described above. It's a small, self-contained function
because the PEC calculation is identical regardless of which command produced the frame
being checksummed — every response, whatever its content, goes through the same
checksum step.

**`build_mctp_frame()`.** Every single response this device sends — whether it's an
MCTP Control reply, a PLDM Base reply, or a PLDM PMC reply — needs the exact same
envelope wrapped around it: an I2C command byte, a byte count, a source address field,
a 4-byte MCTP transport header, and a trailing PEC. Rather than duplicating that framing
logic in three different handler functions, all three call this one function at the end
and just hand it their protocol-specific payload bytes. This is the mirror image of
`process_mctp_frame()` below: one function strips the envelope off an incoming frame,
one function puts it back on an outgoing one.

**`handle_mctp_control()` / `handle_pldm_base()` / `handle_pldm_pmc()`.** These three
handlers exist because the protocols they implement are genuinely layered and
independent: MCTP Control (Type 0 *message*) is about identity and addressing at the
transport level (`SetEndpointID`, `GetEndpointID`, ...), PLDM Base (Type 0 *PLDM type*,
carried inside an MCTP Type 1 message) is about discovering what a PLDM terminus
supports (`GetTID`, `GetPLDMTypes`, ...), and PLDM PMC (Type 2) is the actual
sensor/effecter data model (`GetPDR`, `GetSensorReading`, ...). `process_mctp_frame()`
looks at the message type (and, for PLDM, the PLDM type) and routes to whichever handler
owns that layer — the three-way split in code reflects a three-way split that already
exists in the specs, not an arbitrary code-organization choice.

**`process_mctp_frame()`.** The counterpart to `build_mctp_frame()`: given the raw bytes
accumulated in `rx_buf`, this validates the DSP0237 envelope (command code, declared
byte count vs. actual bytes received) and pulls out the destination/source EID and tag
from the MCTP transport header, then looks at the message type byte to decide which of
the three handlers above should see the rest of the payload. This validation has to
happen here, before any handler runs, because a malformed or truncated frame (dropped
bytes, wrong command code) is meaningless to interpret as MCTP/PLDM content — there's no
point asking "what PLDM command is this" if the envelope around it isn't even valid.

**`mctp_i2c_resp_bh()`.** The timer-driven state machine that actually gets the response
onto the wire. See [Response Mechanism](#response-mechanism-aspeed-ast2600-old-mode-i2c)
for the detailed reasoning; in short, this function exists (rather than simply looping
over `resp_buf` and calling `i2c_send_async()` for every byte in one go) because of the
BQL constraint described in [Background Concepts](#background-concepts) — the guest's
interrupt handler needs a turn to run *between* every single byte, which only happens if
this device gives control back to the main loop and gets called again later for the next
byte.

**`mctp_i2c_ep_send()` / `mctp_i2c_ep_event()`.** These are the actual QOM callbacks
QEMU's I2C core invokes on this device — `.send` once per incoming byte (append it to
`rx_buf`), `.event` on transaction boundaries (`I2C_START_SEND` resets `rx_len` for a
fresh frame; `I2C_FINISH` means a complete frame has arrived, so this is where
`process_mctp_frame()` gets called and, if it produced a response, the BH gets scheduled
to start sending it). There is deliberately no `.recv` callback — this device never has
data pulled out of it by a master read; all of its responses go out via *it* acting as a
master (through `i2c_start_send_async`/`i2c_send_async`), matching how the real
`mctp-i2c` kernel driver's slave-receive path expects to receive responses.

**`mctp_i2c_ep_realize()` / `mctp_i2c_ep_unrealize()` / `mctp_i2c_ep_class_init()`.**
The QOM lifecycle functions from [Background Concepts](#background-concepts): `realize`
initializes all the state-struct fields to their startup values and allocates the BH and
timer this device needs; `unrealize` frees them again when the device is destroyed (QEMU
timers and bottom halves are tracked in global lists — forgetting to free them here would
leak a callback pointing at a device that no longer exists). `class_init` is where the
`.send`/`.event` function pointers actually get wired into the `I2CSlaveClass`, which is
how QEMU's generic I2C bus code knows which functions belong to *this* device type.

### `aspeed_ast2600_johnblue.c` — the machine file

QEMU's board-level configuration (which devices exist, on which buses, at which
addresses) is defined per-"machine" (the thing you select with `-machine <name>`), not
per-device. The upstream `ast2600-evb` machine has no idea this MCTP endpoint device
exists, so rather than modifying upstream EVB code, this file defines a new machine,
`ast2600-johnblue`, that reuses everything from EVB and adds one extra line —
`i2c_slave_create_simple(..., TYPE_MCTP_I2C_ENDPOINT, TERMINUS_I2C_ADDR)` — placing the
device on I2C bus 1 at address `0x0f`. `johnblue.conf`'s `QB_MACHINE` override is what
tells `runqemu` to boot this machine instead of the stock EVB one.

### Why the Kconfig / meson.build changes are needed

QEMU's build system needs to be told about a new source file in two independent places,
and this project touches both `hw/i2c` (where the device lives) and `hw/arm` (where the
machine lives):

- **`hw/i2c/Kconfig`** declares a `MCTP_I2C_ENDPOINT` feature symbol so the device can be
  selected/deselected like any other optional QEMU feature
- **`hw/i2c/meson.build`** is what actually adds `mctp_i2c_endpoint.c` to the list of
  files compiled, conditional on that Kconfig symbol being enabled
- **`hw/arm/Kconfig`**'s `select MCTP_I2C_ENDPOINT` on `ASPEED_SOC` turns that feature on
  automatically for any Aspeed machine, so you don't have to enable it by hand
- **`hw/arm/meson.build`** adds `aspeed_ast2600_johnblue.c` to the list of files compiled
  for ARM targets — without this, the new machine type would never even be registered

This four-file pattern (device Kconfig + device meson.build + SoC Kconfig select + arch
meson.build) is the same pattern QEMU's own upstream device patches use, which is why
it's mirrored here rather than inventing a different build-integration approach.
