$outputLog = @()
$outputObject = @{
  outputLog = @()
  nonComplianceReason = ''
  compliant = '0'
}

# Fix TLS
Try {
  # Oddly, this command works to enable TLS12 on even Powershellv2 when it shows as unavailable. This also still works for Win8+
  [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
  $outputLog += "Successfully enabled TLS1.2 to ensure successful file downloads."
} Catch {
  $outputLog += "Encountered an error while attempting to enable TLS1.2 to ensure successful file downloads. This can sometimes be due to dated Powershell. Checking Powershell version..."
  # Generally enabling TLS1.2 fails due to dated Powershell so we're doing a check here to help troubleshoot failures later
  $psVers = $PSVersionTable.PSVersion

  If ($psVers.Major -lt 3) {
    $outputLog += "Powershell version installed is only $psVers which has known issues with this script directly related to successful file downloads. Script will continue, but may be unsuccessful."
  }
}

function Get-ErrorMessage {
  param ($Err, [string]$Message)
  Return "$Message The error was: $($Err.Exception.Message)"
}

# TODO: Switch this to master branch
# Call in Invoke-Output
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/Flatten-arrays-in-invoke-output/Function.Invoke-Output.ps1') | Invoke-Expression

# Call in registry helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Registry-Helpers.ps1') | Invoke-Expression

# TODO: swap this to the Master URL
# Call in Get-Win10VersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/swap-windows-build-IDs-from-20H2-to-19042/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression

# Call in Version Definitions
# TODO: need to use an access token for this
# (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/main/Get-OsVersionDefinitions.ps1') | Invoke-Expression

# Determine target via release channel
Try {
  $targetWindowsBuild = (Get-OsVersionDefinitions).Windows.Desktop[$releaseChannel]
} Catch {
  $outputLog += 'Function Get-OsVersionDefinitions errored out for some reason.'
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Not able to determine OS release channel for this machine. This must be manually assessed and corrected.'

  Invoke-Output $outputObject
  Return
}

<#
######################
## Define Constants ##
######################
#>

$workDir = "$env:windir\LTSvc\packages\OS"
$downloadDir = "$workDir\Win10\$targetWindowsBuild"
$isoFilePath = "$downloadDir\$targetWindowsBuild.iso"
$regPath = "HKLM:\\SOFTWARE\LabTech\Service\Win10_$($targetWindowsBuild)_Upgrade"
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$windowsUpdateRebootPath1 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
$windowsUpdateRebootPath2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
$winSetupErrorKey = 'WindowsSetupError'
$winSetupExitCodeKey = 'WindowsSetupExitCode'

function Read-PendingRebootStatus {
  $out = @()
  $rebootChecks = @()

  ## The following two reboot keys most commonly exist if a reboot is required for Windows Updates, but it is possible
  ## for an application to make an entry here too.
  $rbCheck1 = Get-ChildItem $windowsUpdateRebootPath1 -EA 0
  $rbCheck2 = Get-Item $windowsUpdateRebootPath2 -EA 0

  ## This is often also the result of an update, but not specific to Windows update. File renames and/or deletes can be
  ## pending a reboot, and this key tells Windows to take these actions on the machine after a reboot to ensure the files
  ## aren't running so they can be renamed.
  $rbCheck3 = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA 0

  If ($rbCheck1) {
    $out += "Found a reboot pending for Windows Updates to complete at $windowsUpdateRebootPath1.`r`n"
    $rebootChecks += $rbCheck1
  }

  If ($rbCheck2) {
    $out += "Found a reboot pending for Windows Updates to complete at $windowsUpdateRebootPath2.`r`n"
    $rebootChecks += $rbCheck2
  }

  If ($rbCheck3) {
    $out += "Found a reboot pending for file renames/deletes on next system reboot.`r`n"
    $out += "`r`n`r`n===========List of files pending rename===========`r`n`r`n`r`n"
    $out = ($rbCheck3).PendingFileRenameOperations | Out-String
    $rebootChecks += $rbCheck3
  }

  Return @{
    Checks = $rebootChecks
    Output = ($out -join "`n")
  }
}

<#
######################
## Check OS Version ##
######################
#>

Try {
  $lessThanRequestedBuild = Get-DesktopWindowsVersionComparison -LessThan $targetWindowsBuild
} Catch {
  # $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one."
  # $outputLog = "!Error: Exiting script.", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Could not determine if this machine is compliant or not. This machine may be on a brand new or otherwise unknown version of Windows. The table of Windows builds needs to be updated to include this version.'

  # Write-Host 'teessssttter', (Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one.")

  Invoke-Output $outputObject
  Return
}

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetWindowsBuild
If ($lessThanRequestedBuild.Result) {
  $outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output
} Else {
  $outputLog += $lessThanRequestedBuild.Output -join '`n`n'
  $outputLog = "!Success: The requested windows build (or higher) is already installed!", $outputLog

  $outputObject.compliant = '1'
  $outputObject.outputLog = $outputLog

  Invoke-Output $outputObject
  Return
}

# Check to see if machine is Enterprise
# This errors sometimes. If it does, we want a clear and actionable error and we do not want to continue
Try {
  $isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'
} Catch {
  $outputLog += Get-ErrorMessage $_ "There was an error in determining whether this is an Enterprise version of windows or not."

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Not able to determine Windows Edition. There may be an issue with this machine and it must be manually assessed.'

  Invoke-Output $outputObject
  Return
}

If ($isEnterprise) {
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Enterprise versions of Windows are not currently supported by automated build upgrades. This capability is coming soon.'

  Invoke-Output $outputObject
  Return
}

# Windows setup may have thrown an error
If (Test-RegistryValue -Name $winSetupErrorKey) {
  $setupErr = Get-RegistryValue -Name $winSetupErrorKey
  $setupExitCode = Get-RegistryValue -Name $winSetupExitCodeKey

  $outputLog = "!Error: Windows setup experienced an error upon installation. This should be manually assessed and you should clear the value at $regPath\$winSetupErrorKey in order to make the script try again. The exit code was $setupExitCode and the error output was $setupErr", $outputLog
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Windows setup experienced an error when attempting to install the new Windows build. This machine must be manually assessed.'

  Invoke-Output $outputObject
  Return
}

# Check that this upgrade hasn't already occurred
If ((Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)) {
  $outputLog = "!Warning: This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. Exiting script.", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'This machine has already been upgraded, but it is pending reboot. Reboot this machine to finish installation. Installation usually only takes 5-7 minutes.'

  Invoke-Output $outputObject
  Return
}

<#
########################
# Make sure ISO exists #
########################
#>

# ISO may not be downloaded yet
If (!(Test-Path -Path $isoFilePath)) {
  $outputLog = "!Warning: ISO doesn't exist yet.. Still waiting on that. Exiting script.", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Still waiting on Windows ISO to download completely.'

  Invoke-Output $outputObject
  Return
}

<#
##############################
# Make sure the hash matches #
##############################
#>

# Ensure hash matches
If (!(Get-HashCheck -Path $isoFilePath)) {
  $outputLog = "!Error: The hash doesn't match!! This ISO file needs to be deleted via the cleanup script and redownloaded via the download script, OR a new hash needs to be added to this script!!", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'The Windows ISO was downloaded, but it does not appear to be the correct file. It was either corrupted during download, or a new ISO was released by Microsoft that we were are unaware of. This needs to be manually assessed and corrected.'

  Invoke-Output $outputObject
  Return
}

<#
##########################
## Reboot Pending Check ##
##########################

Reboots pending can be stored in multiple places. Check them all, if a reboot is pending, start a reboot
and record that the reboot was started in the LTSvc folder. This is to use to reference after the reboot
to confirm the reboot occured, then delete the registry keys if they still exist after the reboot. Windows
and/or apps that requested the reboot frequently fail to remove these keys so it's common to still show
"reboot pending" even after a successful reboot. Re-running this script to check for the "win10UpgradeReboot.txt"
file is handled on the CW Automate side, or by just running this script a second time after the reboot.

If a reboot is pending for any of the reasons below, the Windows 10 upgrade will bomb out so it's important
to handle this issue before attempting the update.
#>

## We're going to save some logs to $env:windir so just make sure it exists and create it if it doesn't.
$LTSvc = "$env:windir\LTSvc"
If (!(Test-Path -Path $LTSvc)) {
  New-Item -Path $LTSvc -ItemType Directory | Out-Null
}

$pendingRebootCheck = Read-PendingRebootStatus

# If there is a pending reboot flag present on the system
If ($pendingRebootCheck.Checks.Length -and !$excludeFromReboot) {
  $outputLog += $pendingRebootCheck.Output

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'There are existing pending reboots on this system, so Windows setup cannot run. This machine needs to be rebooted, or Windows installer is experiencing an issue.'

  Invoke-Output $outputObject
  Return
} ElseIf ($pendingRebootCheck.Checks.Length -and $excludeFromReboot) {
    $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetWindowsBuild installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($pendingRebootCheck.Output)", $outputLog

    $outputObject.outputLog = $outputLog
    $outputObject.nonComplianceReason = 'There are existing pending reboots on this system so Windows setup cannot run. This machine has been excluded from automatic reboots, so cannot try to reboot. Please reboot this machine.'

    Invoke-Output $outputObject
    Return
} Else {
  $outputLog += "Verified there is no reboot pending"
}

<#
###########################
### Check if on battery ###
##########################

We don't want to run the install if on battery power.
#>

$battery = Get-WmiObject -Class Win32_Battery | Select-Object -First 1
$hasBattery = $null -ne $battery
$batteryInUse = $battery.BatteryStatus -eq 1

If ($hasBattery -and $batteryInUse) {
  $outputLog = "!Warning: This is a laptop and it's on battery power. It would be unwise to install a new OS on battery power. Exiting Script.", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'This machine was on battery power when checked for compliance. Build upgrades cannot occur on battery power. Please try to keep this machine plugged in to allow the upgrade to occur.'

  Invoke-Output $outputObject
  Return
}

# Here we landed where the downloader has run twice and the ISO has finished downloading, but the install script hasn't run yet.
# Just give this machine some time
$outputLog += 'This machine is currently in progress. Give this machine a few days and check back.'

$outputObject.outputLog = $outputLog
$outputObject.nonComplianceReason = 'This machine is currently in progress. Give this machine a few days and check back.'

Invoke-Output $outputObject
Return
