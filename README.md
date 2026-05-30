# meta-johnblue Project Documentation

## Project Structure

The `meta-johnblue` layer is organized as follows:

- **conf/**: Layer configuration files.
- **meta-common/**: Common metadata shared across platforms.
- **meta-daytonax/**, **meta-ethanolx/**: Platform-specific metadata.
- **recipes-phosphor/**: Recipes for OpenBMC phosphor components, including PLDM terminus.
- **Other directories**: Support for additional platforms and features.

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

The data flow in this project typically follows these steps:

1. **Sensor (or Terminus)**: Hardware sensors or terminus devices collect data or events.
2. **MCTP (Management Component Transport Protocol)**: Sensors communicate with the BMC using MCTP, a transport protocol for platform management.
3. **PLDM (Platform Level Data Model)**: Data is encapsulated in PLDM messages, which standardize platform management and monitoring.

**Flow Diagram:**

```
Sensor/Terminus → MCTP → PLDM → BMC/OpenBMC Services
```

This design allows for scalable, interoperable platform management using industry standards.

---

## ⚠️ Important: MOCKING IMPLEMENTATION FOR TESTING ONLY

**This meta-johnblue layer contains a PURE MOCKING implementation of MCTP and PLDM services. It is designed for QEMU testing and demonstration purposes only, NOT for production use or real hardware integration.**

### Mocking Components Overview

#### 1. **PLDM Terminus Mock** (`recipes-phosphor/pldm-terminus/`)
The `pldm-terminus` is a minimal mock PLDM responder that simulates a remote terminus device. **It is entirely non-functional in terms of real platform management:**

- **Location**: `pldm-terminus.c` - A 200-line mock responder program
- **Binding**: Binds to **MCTP loopback interface** (`lo`), NOT real hardware
- **EID**: Runs on EID 10 (mock terminus)
- **Functionality**: Only responds to **3 PLDM base discovery commands**:
  - `GetTID` → Returns hard-coded TID = 1
  - `GetPLDMTypes` → Returns hard-coded type bitmap (only base type supported)
  - `GetPLDMVersion` → Returns hard-coded version 1.1.0
- **What it does NOT do**:
  - Does NOT read any sensors or platform data
  - Does NOT provide any real commands (only discovery)
  - Does NOT interface with actual hardware drivers
  - Does NOT send or receive real platform management data
  - Responses are entirely hard-coded with no dynamic content

**Service**: `pldm-terminus.service`
- Type: `simple` (runs as a background daemon)
- Bound to: `mctp-lo-setup.service` (loopback setup)
- Restart: On failure with 2-second delay
- When running, it simply listens on loopback and echoes hard-coded responses to pldmd requests

#### 2. **MCTP Transport Mock** (`recipes-phosphor/mctp/`)
The MCTP layer is configured for loopback testing only:

- **mctpd.conf**: Sets BMC as "bus-owner" with basic timeout configuration
  - No real MCTP message processing
  - Just configuration parameters
- **mctp-setup-i2c.service**: 
  - Attempts to create `mctpi2c1` network interface (fails silently in pure QEMU without kernel module)
  - Falls back to loopback interface
  - Only sets up interface addresses: BMC EID=8 on loopback
  - Does NOT communicate with real I2C hardware drivers
  - Does NOT handle real sensor communication

#### 3. **MCTP Loopback Setup** (`mctp-lo-setup.service`)
- Adds mock addresses to loopback interface only:
  - BMC EID 8 on `lo`
  - Terminus EID 10 on `lo`
  - Static neighbor route to EID 10 via loopback (all traffic is local)
- **This is purely virtual routing for testing**, not connected to any real transport

### Why This Mocking Design?

This approach allows you to:
1. **Test PLDM discovery flow** without real hardware
2. **Verify pldmd startup** and PLDM client connectivity in QEMU
3. **Develop and debug** PLDM applications without hardware dependencies
4. **Demonstrate** the MCTP/PLDM stack architecture

### Data Flow (Mocking vs Real)

**Current Mocking Flow:**
```
pldmd (on BMC EID 8)
    ↓
    [sends PLDM discovery request via loopback]
    ↓
pldm-terminus (on loopback EID 10)
    ↓
    [returns hard-coded discovery response]
    ↓
pldmd (receives response, marks discovery complete)

❌ NO REAL SENSOR DATA
❌ NO REAL PLATFORM MANAGEMENT COMMANDS
❌ NO HARDWARE DRIVER PARTICIPATION
```

**Future Production Flow (NOT implemented here):**
```
Real Sensors/Platform Hardware
    ↓
    [MCTP over real I2C / Ethernet transport]
    ↓
Real PLDM Terminus (with actual sensor polling)
    ↓
    [Real PLDM commands: GetSensorReading, GetEventMessages, etc.]
    ↓
pldmd (processes real platform data)
    ↓
OpenBMC Services (logging, monitoring, etc.)
```

### Transitioning from Mock to Real Hardware

To adapt this layer for real hardware:

1. **Replace pldm-terminus**: Instead of mocking responses, implement a real terminus that:
   - Polls actual sensors via hardware drivers
   - Implements full PLDM platform/sensor/event management commands
   - Handles real I2C/Ethernet MCTP transport

2. **Enable real MCTP transport**: Configure MCTP over actual I2C bus (e.g., i2c-1)
   - Enable `CONFIG_MCTP_TRANSPORT_I2C` in kernel
   - Modify `mctp-setup-i2c.service` to use real hardware adapters
   - Remove loopback-only services

3. **Sensor integration**: Connect the terminus to real sensor driver interfaces
   - Implement hwmon driver integration
   - Add real PLDM command handlers for sensor/event data

### Testing Limitations

Due to the mocking nature, **do NOT expect**:
- Real sensor readings from pldmd/pldmtool
- Real platform management capabilities
- Event logging from hardware
- System state monitoring
- Any actual interaction with platform hardware

This is a **demonstration and testing framework only**.

## How to Verify

⚠️ **IMPORTANT**: Due to the mocking design, these verification steps test the PLDM discovery and loopback stack only, NOT real platform management or sensor data.

To verify the functionality of the `meta-johnblue` layer and its PLDM terminus mock implementation:

### Build and Deploy
1. **Build the Image**
   - Set up the OpenBMC build environment.
   - Add `meta-johnblue` to your `bblayers.conf`.
   - Run `bitbake <image-name>` to build the firmware image.

2. **Deploy and Boot**
   - Flash the built image to your target hardware or use QEMU for emulation.
   - Boot the system and access the BMC console.

### Verify Mock Services Are Running
3. **Check PLDM Terminus Mock**
   - Verify that the PLDM terminus mock service is running:
     ```bash
     systemctl status pldm-terminus.service
     ```
   - Check logs to confirm it bound to loopback EID 10:
     ```bash
     journalctl -u pldm-terminus.service -n 20
     # Expected output: "pldm-terminus: bound to EID 10, type PLDM"
     ```

4. **Verify MCTP Setup**
   - Check both setup services:
     ```bash
     systemctl status mctp-setup-i2c.service
     systemctl status mctp-lo-setup.service
     ```
   - Verify loopback addresses were added:
     ```bash
     mctp addr show
     # Expected: EID 8 on lo, EID 10 on lo
     mctp neigh show
     # Expected: EID 10 reachable via loopback
     ```

### Verify Discovery Flow (Mock Stack)
5. **Check pldmd Discovery Completes**
   - Verify pldmd is running and connected:
     ```bash
     busctl status xyz.openbmc_project.PLDM
     systemctl status pldmd.service
     ```
   - Check pldmd logs for discovery completion:
     ```bash
     journalctl -u pldmd.service -n 50 | grep -i "discover\|tid\|type"
     ```
   - Expected behavior: pldmd discovers the mock terminus and completes initialization
   - **Expected limitation**: Discovery may show mock EID 10 but NO real sensor data

### What NOT to Expect (Mock Limitations)
6. **⚠️ Mock Testing Limitations**
   - **No sensor data**: pldmtool will NOT show any real sensors
     ```bash
     pldmtool platform GetStateSensorReadings
     # Will likely return empty or error (mock doesn't implement sensor commands)
     ```
   - **No I2C device communication**: In pure QEMU, `mctpi2c1` interface will NOT be created (no real mctp-i2c driver)
   - **Loopback only**: All MCTP traffic is on `lo`, not real hardware
   - **Discovery only**: The mock terminus only responds to discovery commands
   - **Hard-coded responses**: No dynamic data from the mock

### Detailed Verification in QEMU (Mock Environment)

After `runqemu` boots, inside the BMC shell:

```bash
# 1. Verify MCTP loopback stack is up
mctp addr show
# Expected: 8 (BMC) and 10 (mock terminus) on device "lo"

# 2. Verify neighbor routing for mock terminus
mctp neigh show
# Expected: 10 dev lo with all-zeros lladdr

# 3. Check pldm-terminus process is running
ps aux | grep pldm-terminus
# Expected: /usr/bin/pldm-terminus running

# 4. Verify pldmd bound to BMC EID 8
busctl status xyz.openbmc_project.PLDM
systemctl status pldmd.service

# 5. Test pldmtool discovery (will work via mock)
pldmtool base GetTID -t 1 -d 10
# Expected: Returns TID=1 (mock response)

pldmtool base GetPLDMTypes -t 1 -d 10
# Expected: Returns types bitmap showing only base type (mock response)

pldmtool base GetPLDMVersion -t 1 -d 10
# Expected: Returns version 1.1.0 (mock response)

# 6. ❌ Do NOT expect real sensor data
pldmtool platform GetSensorReadings
# Will likely error or return empty (not implemented in mock)
```

### If Issues Occur

**If mctpi2c1 doesn't appear:**
- This is expected in pure QEMU if `mctp-i2c` driver isn't available
- Loopback interface `lo` is used instead for testing
- This is normal for the mocking environment

**If pldm-terminus fails to bind:**
```bash
journalctl -u pldm-terminus.service
# Check for AF_MCTP socket errors
dmesg | grep -i mctp
```

**If pldmd discovery fails:**
```bash
journalctl -u pldmd.service | tail -50
systemctl status mctpd.service
```

---

For more details, refer to the README files in each subdirectory and the OpenBMC documentation.