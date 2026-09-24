<#
.SYNOPSIS
    Deploys a lightweight Alpine Linux VM on Hyper-V from a template VHDX image.

.DESCRIPTION
    Supports both:
    1. Independent clone (full copy of the template VHDX)
    2. Differencing clone (instant, thin-provisioned copy pointing to the base image)
    Configures UEFI Secure Boot (Microsoft UEFI CA) and Dynamic Memory.

.EXAMPLE
    # Instant differencing clone with default name
    .\New-AlpineVM.ps1 -VMName "alpine-lite-01"

.EXAMPLE
    # Full independent copy with specific RAM and Switch
    .\New-AlpineVM.ps1 -VMName "alpine-test" -Mode FullCopy -StartupMemoryMB 1024 -SwitchName "Default Switch"
#>

function New-AlpineVM {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [string]$VMName = "alpine-lite-01",

        [Parameter()]
        [ValidateSet("Differencing", "FullCopy")]
        [string]$Mode = "Differencing",

        [Parameter()]
        [string]$TemplateDir = "$env:UserProfile\vm-images\alpine-lite",

        [Parameter()]
        [string]$DestDir = "C:\Hyper-V\Virtual Hard Disks",

        [Parameter()]
        [int]$StartupMemoryMB = 512,

        [Parameter()]
        [int]$MinMemoryMB = 128,

        [Parameter()]
        [int]$MaxMemoryMB = 1024,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [string]$SwitchName = ""
    )

    $ErrorActionPreference = 'Stop'

    # Elevate / verify administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "This script requires Administrator privileges. Please run PowerShell as Administrator."
        return
    }

    # Locate the template VHDX
    $TemplateVhdx = Get-ChildItem "$TemplateDir\*.vhdx" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $TemplateVhdx) {
        # Check for legacy double extension if present
        $TemplateVhdx = Get-ChildItem "$TemplateDir\*.vhdx*" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $TemplateVhdx -or -not (Test-Path $TemplateVhdx)) {
        Write-Error "Template VHDX image not found in '$TemplateDir'. Please verify the image exists."
        return
    }

    Write-Host "==> Using base template: $TemplateVhdx" -ForegroundColor Cyan

    # Resolve Hyper-V Switch
    if (-not $SwitchName) {
        $foundSwitch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($foundSwitch) {
            $SwitchName = $foundSwitch.Name
        } else {
            $SwitchName = "Default Switch"
        }
    }

    # Ensure destination directory exists
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $DestVhdx = Join-Path $DestDir "$VMName.vhdx"

    # Check if VM already exists
    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) {
        if ($Force) {
            Write-Host "==> Removing existing VM '$VMName'..." -ForegroundColor Yellow
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $VMName -Force
        } else {
            Write-Error "A virtual machine named '$VMName' already exists! Use -Force to overwrite."
            return
        }
    }

    # Clean up stale or broken destination disk if present
    if (Test-Path $DestVhdx) {
        if ($Force -or -not $existingVM) {
            Write-Host "==> Removing stale virtual hard disk: $DestVhdx" -ForegroundColor Yellow
            Remove-Item -Path $DestVhdx -Force
        } else {
            Write-Error "Virtual disk '$DestVhdx' already exists! Use -Force to overwrite."
            return
        }
    }

    # Create disk based on mode
    if ($Mode -eq "Differencing") {
        Write-Host "==> Creating differencing disk: $DestVhdx" -ForegroundColor Cyan
        New-VHD -Path $DestVhdx -ParentPath $TemplateVhdx -Differencing | Out-Null
    } else {
        Write-Host "==> Performing full copy to: $DestVhdx" -ForegroundColor Cyan
        Copy-Item -Path $TemplateVhdx -Destination $DestVhdx -Force
    }

# Create Generation 2 VM
Write-Host "==> Creating Gen 2 VM '$VMName'..." -ForegroundColor Cyan
New-VM -Name $VMName `
       -Generation 2 `
       -MemoryStartupBytes ([int64]$StartupMemoryMB * 1MB) `
       -VHDPath $DestVhdx `
       -SwitchName $SwitchName | Out-Null

# Configure UEFI Secure Boot with Microsoft UEFI CA template (required for Linux GRUB/kernel)
Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

# Configure Dynamic Memory
Set-VMMemory -VMName $VMName `
             -DynamicMemoryEnabled $true `
             -MinimumBytes ([int64]$MinMemoryMB * 1MB) `
             -MaximumBytes ([int64]$MaxMemoryMB * 1MB)

    # Start VM
    Write-Host "==> Starting VM '$VMName'..." -ForegroundColor Cyan
    Start-VM -Name $VMName

    Write-Host "==> Success! VM '$VMName' is up and running." -ForegroundColor Green
    Get-VM -Name $VMName | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime
}

# If executed directly with arguments rather than dot-sourced, call the function
if ($MyInvocation.InvocationName -ne '.') {
    New-AlpineVM @args
}
