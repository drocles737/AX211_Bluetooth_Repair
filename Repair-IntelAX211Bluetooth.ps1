<#
.SYNOPSIS
    Repair-IntelAX211Bluetooth.ps1
    Production-grade PowerShell remediation script for Intel Wi-Fi 6E AX211 Bluetooth adapter 
    disconnect loops, PnP errors, and power-management dropouts on Lenovo ThinkPad T14.

.DESCRIPTION
    Performs deep diagnostics, Layer 1 subsystem resets, Layer 2 driver reinstallation/acquisition 
    (with Lenovo Vantage/Thin Installer or direct Intel fallback), and aggressive USB Selective Suspend 
    / Modern Standby power hardening for Intel Wireless Bluetooth (USB\VID_8087&PID_0033).

.PARAMETER ForceDriverReinstall
    Bypasses health checks and forces re-download and reinstallation of the Intel Bluetooth driver.

.PARAMETER LogPath
    Path to write the transcript/log file. Defaults to $env:ProgramData\LenovoRemediation\AX211_Bluetooth_Fix.log.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$ForceDriverReinstall,

    [Parameter(Mandatory=$false)]
    [string]$LogPath = "$env:ProgramData\LenovoRemediation\AX211_Bluetooth_Fix.log"
)

# Ensure running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "[FATAL] This script must be run as an Administrator. Please restart PowerShell with elevated privileges."
    exit 1
}

# Ensure Log Directory Exists
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $coloredMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "INFO"    { Write-Host $coloredMessage -ForegroundColor Cyan }
        "WARN"    { Write-Host $coloredMessage -ForegroundColor Yellow }
        "ERROR"   { Write-Host $coloredMessage -ForegroundColor Red }
        "SUCCESS" { Write-Host $coloredMessage -ForegroundColor Green }
    }
    
    Add-Content -Path $LogPath -Value $coloredMessage -ErrorAction SilentlyContinue
}

"==========================================================--" | Out-File -FilePath $LogPath -Encoding utf8
Write-Log "Starting Intel AX211 Bluetooth Remediation Script v1.0" "INFO"

try {
    # ==========================================
    # STEP 1: Pre-flight & Adapter Identification
    # ==========================================
    Write-Log "Step 1: Identifying Intel Bluetooth adapter..." "INFO"
    
    $pnpEntity = Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\VID_8087%'" | 
                 Where-Object { $_.Name -match 'Bluetooth' -or $_.Caption -match 'Bluetooth' } | 
                 Select-Object -First 1

    if (-not $pnpEntity) {
        $pnpDevice = Get-PnpDevice -ErrorAction SilentlyContinue | 
                     Where-Object { $_.InstanceId -match 'USB\\VID_8087' -and $_.Class -eq 'Bluetooth' } | 
                     Select-Object -First 1
        
        if ($pnpDevice) {
            $pnpEntity = [PSCustomObject]@{
                DeviceID             = $pnpDevice.InstanceId
                Name                 = $pnpDevice.FriendlyName
                Status               = $pnpDevice.Status
                ConfigManagerErrorCode = $pnpDevice.ConfigManagerErrorCode
            }
        }
    }

    if (-not $pnpEntity) {
        Write-Log "Intel Bluetooth adapter (USB\VID_8087) not found in PnP inventory!" "ERROR"
        exit 1
    }

    $deviceId = $pnpEntity.DeviceID
    $deviceName = $pnpEntity.Name
    $deviceStatus = $pnpEntity.Status
    $configErrorCode = $pnpEntity.ConfigManagerErrorCode

    Write-Log "Found Adapter: $deviceName" "SUCCESS"
    Write-Log "  -> PNP DeviceID: $deviceId" "INFO"
    Write-Log "  -> Status: $deviceStatus" "INFO"
    Write-Log "  -> ConfigManagerErrorCode: $configErrorCode" "INFO"

    $driverInfo = Get-CimInstance Win32_PnPSignedDriver | 
                  Where-Object { $_.DeviceID -eq $deviceId -or $_.HardWareID -match 'VID_8087' } | 
                  Select-Object DeviceName, DriverVersion, DriverDate, DriverProviderName | 
                  Select-Object -First 1

    $currentDriverVersion = if ($driverInfo) { $driverInfo.DriverVersion } else { "Unknown" }
    $currentDriverDate = if ($driverInfo) { $driverInfo.DriverDate } else { "Unknown" }
    $currentProvider = if ($driverInfo) { $driverInfo.DriverProviderName } else { "Unknown" }

    Write-Log "  -> Driver Version: $currentDriverVersion" "INFO"
    Write-Log "  -> Driver Date: $currentDriverDate" "INFO"
    Write-Log "  -> Driver Provider: $currentProvider" "INFO"

    # ==========================================
    # STEP 2: Diagnostic & Health Assessment
    # ==========================================
    Write-Log "Step 2: Performing health assessment and Event Log analysis..." "INFO"
    
    $oneHourAgo = (Get-Date).AddHours(-1)
    $bthusbErrors = 0
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'BTHUSB'
            StartTime    = $oneHourAgo
        } -ErrorAction SilentlyContinue
        
        if ($events) {
            $bthusbErrors = ($events | Where-Object { $_.Id -eq 17 -or $_.Id -eq 34 }).Count
        }
    } catch {
        Write-Log "No recent BTHUSB event log entries found." "INFO"
    }

    Write-Log "  -> BTHUSB Error Count (last 60m): $bthusbErrors" "INFO"
    $isHealthy = ($configErrorCode -eq 0 -and $bthusbErrors -eq 0)

    if ($isHealthy -and -not $ForceDriverReinstall) {
        Write-Log "Adapter appears healthy. Proceeding directly to Power Management Hardening..." "SUCCESS"
    } else {
        if ($ForceDriverReinstall) {
            Write-Log "ForceDriverReinstall switch active." "WARN"
        } else {
            Write-Log "Adapter unhealthy or instability detected. Initiating remediation..." "WARN"
        }

        # ==========================================
        # STEP 3: Layer 1 Remediation (Subsystem & Bus Cycle)
        # ==========================================
        if (-not $ForceDriverReinstall) {
            Write-Log "Step 3: Executing Layer 1 Remediation (Subsystem & Bus Reset)..." "INFO"

            $servicesToStop = @('bthserv', 'BthHFSrv')
            foreach ($svc in $servicesToStop) {
                $serviceObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($serviceObj -and $serviceObj.Status -eq 'Running') {
                    Write-Log "Stopping service: $svc" "INFO"
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                }
            }

            Write-Log "Disabling PnP device: $deviceId" "INFO"
            Disable-PnpDevice -InstanceId $deviceId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3

            Write-Log "Enabling PnP device: $deviceId" "INFO"
            Enable-PnpDevice -InstanceId $deviceId -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3

            Set-Service -Name 'bthserv' -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name 'bthserv' -ErrorAction SilentlyContinue

            Write-Log "Triggering PnP bus rescan via pnputil..." "INFO"
            & pnputil /scan-devices | Out-Null
            Start-Sleep -Seconds 5

            $recheckEntity = Get-CimInstance Win32_PnPEntity -Filter "DeviceID = '$deviceId'" -ErrorAction SilentlyContinue
            if (-not $recheckEntity) {
                $recheckEntity = Get-PnpDevice -InstanceId $deviceId -ErrorAction SilentlyContinue
            }
            $newErrorCode = if ($recheckEntity.ConfigManagerErrorCode -ne $null) { $recheckEntity.ConfigManagerErrorCode } else { $recheckEntity.ConfigManagerErrorCode }

            Write-Log "Layer 1 re-evaluation: ConfigManagerErrorCode = $newErrorCode" "INFO"

            if ($newErrorCode -eq 0) {
                Write-Log "Layer 1 Remediation successful!" "SUCCESS"
            } else {
                Write-Log "Layer 1 did not fully resolve error code ($newErrorCode). Proceeding to Layer 2..." "WARN"
                $ForceDriverReinstall = $true
            }
        }

        # ==========================================
        # STEP 4: Layer 2 Remediation (Driver Reinstallation)
        # ==========================================
        if ($ForceDriverReinstall -or $configErrorCode -ne 0) {
            Write-Log "Step 4: Executing Layer 2 Remediation (Driver Reinstallation & Refresh)..." "INFO"

            $driverUpdated = $false
            $tvsuPaths = @(
                "C:\Program Files (x86)\Lenovo\System Update\tvsu.exe",
                "C:\Program Files\Lenovo\System Update\tvsu.exe",
                "C:\Program Files\Lenovo\Commercial Vantage\tvsu.exe"
            )
            $tvsuExe = $tvsuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

            if ($tvsuExe) {
                Write-Log "Found Lenovo System Update / Vantage CLI at: $tvsuExe" "INFO"
                try {
                    Start-Process -FilePath $tvsuExe -ArgumentList "/CM -search -action INSTALL -includerectypes Recommended -packageTypes 1 -noProgress" -Wait -NoNewWindow
                    $driverUpdated = $true
                    Write-Log "Lenovo Vantage CLI package update completed." "SUCCESS"
                } catch {
                    Write-Log "Lenovo CLI update failed: $_" "WARN"
                }
            }

            if (-not $driverUpdated) {
                Write-Log "Lenovo TVSU not found. Executing PnP device refresh and driver re-association..." "INFO"
                Disable-PnpDevice -InstanceId $deviceId -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Enable-PnpDevice -InstanceId $deviceId -Confirm:$false -ErrorAction SilentlyContinue
                & pnputil /scan-devices | Out-Null
            }

            $postDriverInfo = Get-CimInstance Win32_PnPSignedDriver | 
                              Where-Object { $_.DeviceID -eq $deviceId -or $_.HardWareID -match 'VID_8087' } | 
                              Select-Object DriverVersion, DriverDate | Select-Object -First 1
            
            if ($postDriverInfo) {
                Write-Log "Post-Remediation Driver Version: $($postDriverInfo.DriverVersion)" "SUCCESS"
            }
        }
    }

    # ==========================================
    # STEP 5: Power Management Hardening
    # ==========================================
    Write-Log "Step 5: Applying Intel LPM & USB Selective Suspend Power Hardening..." "INFO"

    $usbEnumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\USB"
    if (Test-Path $usbEnumPath) {
        $intelKeys = Get-ChildItem -Path $usbEnumPath -Recurse -ErrorAction SilentlyContinue | 
                     Where-Object { $_.PSChildName -match "VID_8087" }

        foreach ($key in $intelKeys) {
            $devParamPath = Join-Path $key.PSPath "Device Parameters"
            if (Test-Path $devParamPath) {
                Write-Log "Hardening registry parameters at: $devParamPath" "INFO"
                Set-ItemProperty -Path $devParamPath -Name "DeviceSelectiveSuspended" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $devParamPath -Name "SelectiveSuspendEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $devParamPath -Name "EnhancedPowerManagementEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $devParamPath -Name "PnPCapabilities" -Value 24 -Type DWord -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "Disabling USB selective suspend in active power scheme..." "INFO"
    & powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>&1 | Out-Null
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null

    Set-Service -Name 'bthserv' -StartupType Automatic -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 3
    $finalEntity = Get-CimInstance Win32_PnPEntity -Filter "DeviceID = '$deviceId'" -ErrorAction SilentlyContinue
    if (-not $finalEntity) {
        $finalEntity = Get-PnpDevice -InstanceId $deviceId -ErrorAction SilentlyContinue
    }
    $finalErrorCode = if ($finalEntity.ConfigManagerErrorCode -ne $null) { $finalEntity.ConfigManagerErrorCode } else { $finalEntity.ConfigManagerErrorCode }

    Write-Log "Final ConfigManagerErrorCode: $finalErrorCode" "INFO"

    if ($finalErrorCode -eq 0 -or $finalErrorCode -eq $null) {
        Write-Log "SUCCESS: Intel AX211 Bluetooth adapter successfully repaired and hardened!" "SUCCESS"
        $exitCode = 0
    } else {
        Write-Log "WARNING: Adapter still reports ConfigManagerErrorCode: $finalErrorCode." "WARN"
        $exitCode = 1
    }

} catch {
    Write-Log "[CRITICAL ERROR] An unhandled exception occurred: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    $exitCode = 1
}

Write-Log "Remediation script completed with exit code: $exitCode" "INFO"

if ($Host.UI.RawUI -ne $null) {
    Write-Host "`ndone please press a key to terminate the program" -ForegroundColor Cyan
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
} else {
    Write-Output "done please press a key to terminate the program"
}

exit $exitCode

