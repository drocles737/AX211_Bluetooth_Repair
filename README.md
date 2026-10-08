# Intel AX211 Bluetooth Repair & Power Hardening Automation

Production-grade PowerShell remediation suite designed for **Lenovo ThinkPad T14 (Intel Edition)** running **Windows 11 64-bit** to resolve continuous Bluetooth dropouts, PnP device disconnect loops, Device Manager flickering, and Code 10/43/28 errors associated with the **Intel Wi-Fi 6E AX211** adapter (`USB\VID_8087&PID_0033`).

---

## 🚀 Key Features

1. **Pre-flight & Hardware Identification**: Pinpoints the exact Intel Bluetooth USB device ID, status, error code, and currently installed driver version/date.
2. **Diagnostic & Event Log Health Assessment**: Queries Windows System Event Logs (last 60 minutes) for `BTHUSB` (Event IDs 17, 34) and `Kernel-PnP` crash loops.
3. **Layer 1 Remediation (Subsystem & Bus Cycle)**: Gracefully stops Bluetooth support services (`bthserv`, `BthHFSrv`), resets the PnP device via `Disable-PnpDevice` / `Enable-PnpDevice`, restarts services, and triggers a PnP bus rescan (`pnputil /scan-devices`).
4. **Layer 2 Remediation (Driver Reinstallation & Acquisition)**: Integrates with Lenovo System Update / Commercial Vantage CLI (`tvsu.exe`) or falls back to robust driver store staging and PnP re-association.
5. **Critical Root-Cause Fix (Intel LPM & USB Selective Suspend Hardening)**: Enforces registry overrides under `HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_8087*` (`DeviceSelectiveSuspended = 0`, `SelectiveSuspendEnabled = 0`, `EnhancedPowerManagementEnabled = 0`, `PnPCapabilities = 24`) and updates the active power scheme to disable USB selective suspend, preventing Modern Standby power state collapse.
6. **Robust Reporting & Resilience**: Writes colorized console output and comprehensive transcripts to `%ProgramData%\LenovoRemediation\AX211_Bluetooth_Fix.log`. Returns standard exit codes (`0` for success/resolved, `1` for requiring hardware service/board check).

---

## 📋 Prerequisites

- **OS**: Windows 11 64-bit.
- **Hardware**: Lenovo ThinkPad T14 with Intel AX211 Wi-Fi/Bluetooth CNVi.
- **Permissions**: Administrator privileges (elevated PowerShell).

---

## 🛠️ Usage

### Option A: Executable Launcher (Recommended)
Simply double-click `Repair-IntelAX211Bluetooth.exe`. It will automatically request Administrator elevation and launch the remediation logic.

```cmd
# Run via Command Prompt / Shortcut
Repair-IntelAX211Bluetooth.exe

# Run with arguments
Repair-IntelAX211Bluetooth.exe -ForceDriverReinstall
```

### Option B: PowerShell Script
Open PowerShell as **Administrator** and run:

```powershell
# Standard diagnostic & remediation run
.\Repair-IntelAX211Bluetooth.ps1

# Force driver reinstallation / refresh regardless of initial health status
.\Repair-IntelAX211Bluetooth.ps1 -ForceDriverReinstall
```

---

## 📊 Exit Codes

- `0`: Adapter successfully repaired, operational (`ConfigManagerErrorCode == 0`), and power-hardened.
- `1`: Remediation incomplete or hardware fault detected. Motherboard / M.2 slot re-seating or physical hardware replacement recommended.
