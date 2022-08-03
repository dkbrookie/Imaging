$outputLog = @()
$outputObject = @{
  outputLog           = @()
  nonComplianceReason = ''
  compliant           = '0'
  targetWindowsBuild  = ''
  currentWindowsBuild = ''
}

If (!$releaseChannel) {
  $outputLog += '$releaseChannel was not specified! Defaulting to GA.'
  $releaseChannel = 'GA'
}

# Fix TLS
Try {
  # Oddly, this command works to enable TLS12 on even Powershellv2 when it shows as unavailable. This also still works for Win8+
  [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
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

# Call in Invoke-Output
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Invoke-Output.ps1') | Invoke-Expression

# Call in registry helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Registry-Helpers.ps1') | Invoke-Expression

# Call in Get-DesktopWindowsVersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression

# Call in Get-OsVersionDefinitions - $webClient is provided by calling script to access a private repo
($webClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/main/Get-OsVersionDefinitions.ps1') | Invoke-Expression

# Call in Get-IsOnBattery
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsOnBattery.ps1') | Invoke-Expression

# Call in Get-PendingReboot
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-PendingReboot.ps1') | Invoke-Expression

# Call in Get-WindowsVersion
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-WindowsVersion.ps1') | Invoke-Expression

# Determine target via release channel
Try {
  $targetBuild = (Get-OsVersionDefinitions).Windows.Desktop[$releaseChannel]
  $outputObject.targetWindowsBuild = $targetBuild
} Catch {
  $outputLog += Get-ErrorMessage $_ 'Function Get-OsVersionDefinitions errored out for some reason.'
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Not able to determine OS release channel for this machine. This must be manually assessed and corrected.'

  Invoke-Output $outputObject
  Return
}

If ($isEnterprise) {
  $hashArrays = @{
    '19042' = @('3152C390BFBA3E31D383A61776CFB7050F4E1D635AAEA75DD41609D8D2F67E92')
    '19043' = @('0FC1B94FA41FD15A32488F1360E347E49934AD731B495656A0A95658A74AD67F')
    '19044' = @('1323FD1EF0CBFD4BF23FA56A6538FF69DD410AD49969983FEE3DF936A6C811C5')
    '22000' = @('ACECC96822EBCDDB3887D45A5A5B69EEC55AE2979FBEAB38B14F5E7F10EEB488')
  }
}
Else {
  $hashArrays = @{
    '19042' = @('6C6856405DBC7674EDA21BC5F7094F5A18AF5C9BACC67ED111E8F53F02E7D13D')
    '19043' = @('6911E839448FA999B07C321FC70E7408FE122214F5C4E80A9CCC64D22D0D85EA')
    '19044' = @('7F6538F0EB33C30F0A5CBBF2F39973D4C8DEA0D64F69BD18E406012F17A8234F')
    '22000' = @('667BD113A4DEB717BC49251E7BDC9F09C2DB4577481DDFBCE376436BEB9D1D2F')
  }
}

Try {
  $acceptableHashes = $hashArrays[$targetBuild]
} Catch {
  $outputLog = "`$targetBuild of '$targetBuild' is not compatible with array of ISO hashes defined in script. Please check script."
}


function Get-HashCheck {
  param ([string]$Path)
  $hash = (Get-FileHash -Path $Path -Algorithm 'SHA256').Hash
  $hashMatches = $acceptableHashes | ForEach-Object { $_ -eq $hash } | Where-Object { $_ -eq $true }
  Return $hashMatches.length -gt 0
}

<#
######################
## Define Constants ##
######################
#>

$workDir = "$env:windir\LTSvc\packages\OS"
$downloadDir = "$workDir\Windows\$targetBuild"
$isoFilePath = "$downloadDir\$targetBuild.iso"
$regPath = "HKLM:\SOFTWARE\LabTech\Service\Windows_$($targetBuild)_Upgrade"
$rebootInitiatedForThisUpgradeKey = "RebootInitiatedForThisUpgrade"
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$winSetupErrorKey = 'WindowsSetupError'
$winSetupExitCodeKey = 'WindowsSetupExitCode'
$downloadErrorKey = 'BitsTransferError'

<#
######################
## Check OS Version ##
######################
#>

# Check current build against target
Try {
  $lessThanRequestedBuild = Get-DesktopWindowsVersionComparison -LessThan $targetBuild
} Catch {
  $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one."

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Could not determine if this machine is compliant or not. This machine may be on a brand new or otherwise unknown version of Windows. The table of Windows builds needs to be updated to include this version.'

  Invoke-Output $outputObject
  Return
}

# Grab current build for output/logging purposes
Try {
  $currentBuild = (Get-WindowsVersion).Build
  $outputObject.currentWindowsBuild = $currentBuild
} Catch {
  $outputLog += "Ran into an issue when attempting to get current build. Continuing as this value is only for informational purposes. The error was: $_"
}

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetBuild
If ($lessThanRequestedBuild.Result) {
  $outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output
} Else {
  $outputLog += $lessThanRequestedBuild.Output -join '`n`n'
  $outputLog = "!Success: The requested windows build (or higher) is already installed!", $outputLog

  $outputObject.compliant = '1'
  $outputObject.nonComplianceReason = ''
  $outputObject.outputLog = $outputLog

  Invoke-Output $outputObject
  Return
}

If (Test-RegistryValue -Name $downloadErrorKey) {
  $errorDescription = Get-RegistryValue -Name $downloadErrorKey

  $msg = 'ISO downloader has experienced an error. This '

  If ($errorDescription -like '*Range protocol*') {
    $msg += "is a known error and the script will automatically retry. This machine is likely behind a firewall or proxy that is stripping the 'Content-Range' header. Move this machine to a different network OR adjust firewall/proxy config to leave this header intact."
  } Else {
    $msg += "machine should be manually assessed. The transfer error is: $errorDescription"
  }

  $outputLog = "!Error: $msg", $outputLog
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = $msg

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

# There could also be an error at a location from a previous version of this script, identified by version ID 20H2
$previousRegPath = 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade'
If (Test-RegistryValue -Path $previousRegPath -Name 'WindowsSetupError') {
  $setupErr = Get-RegistryValue -Path $previousRegPath -Name 'WindowsSetupError'
  $setupExitCode = Get-RegistryValue -Path $previousRegPath -Name 'WindowsSetupExitCode'

  $outputLog = "!Error: Windows setup experienced an error upon last installation. This should be manually assessed and you should delete HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade\WindowsSetupError in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'" + $outputLog
  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'Windows setup experienced an error when attempting to install the new Windows build. This machine must be manually assessed.'

  Invoke-Output $outputObject
  Return
}

# The reboot could have already occurred
$rebootInitiatedForThisUpgrade = (Test-RegistryValue -Name $rebootInitiatedForThisUpgradeKey) -and ((Get-RegistryValue -Name $rebootInitiatedForThisUpgradeKey) -eq 1)

If ($rebootInitiatedForThisUpgrade) {
  # If the reboot for this upgrade has already occurred, the installation doesn't appear to have succeeded, so the installer must have errored out without
  # actually throwing an error code? Let's set the error state for assessment.
  $failMsg = "Windows setup appears to have succeeded (it didn't throw an error) but windows didn't actually complete the upgrade for some reason. This machine needs to be manually assessed. If you want to try again, delete registry values at '$rebootInitiatedForThisUpgradeKey', '$pendingRebootForThisUpgradeKey' and '$winSetupErrorKey'"
  $outputLog = "!Failure: $failMsg" + $outputLog

  Write-RegistryValue -Name $winSetupErrorKey -Value $failMsg
  Write-RegistryValue -Name $winSetupExitCodeKey -Value 'Unknown Error'

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = $failMsg

  Invoke-Output $outputObject
  Return
}

# Are we pending reboot?
$pendingRebootForThisUpgrade = (Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)
$pendingRebootForPreviousScript = (Test-RegistryValue -Path $previousRegPath -Name 'PendingRebootForThisUpgrade') -and ((Get-RegistryValue -Path $previousRegPath -Name 'PendingRebootForThisUpgrade') -eq 1)

# If pending reboot for this upgrade, OR pending reboot for 20H2 and target is 19042 (which are the same)
If ($pendingRebootForThisUpgrade -or ($pendingRebootForPreviousScript -and ($targetBuild -eq '19042'))) {
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
  $outputObject.nonComplianceReason = 'Still waiting on Windows installer to download.'

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
  $outputObject.nonComplianceReason = 'The Windows installer was downloaded, but it does not appear to be the file we were expecting. It was probably either corrupted during download, or a new ISO was released that we are unaware of. This needs to be manually assessed and corrected.'

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

$pendingRebootCheck = Get-PendingReboot
$pendingReboot = $pendingRebootCheck.PendingReboot

# If there is a pending reboot flag present on the system
If ($pendingReboot -and !$excludeFromReboot) {
  $outputLog += $pendingRebootCheck.Output

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'There are existing pending reboots on this system, so Windows setup cannot run. Either this machine needs to be rebooted, or Windows installer is experiencing an issue.'

  Invoke-Output $outputObject
  Return
}
ElseIf ($pendingReboot -and $excludeFromReboot) {
  $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetBuild installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($pendingRebootCheck.Output)", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'There are existing pending reboots on this system so Windows setup cannot run. This machine has been excluded from automatic reboots, so cannot reboot. Please reboot this machine.'

  Invoke-Output $outputObject
  Return
}
Else {
  $outputLog += "Verified there is no reboot pending"
}

<#
###########################
### Check if on battery ###
##########################

We don't want to run the install if on battery power.
#>

If (Get-IsOnBattery) {
  $outputLog = "!Warning: This is a laptop and it's on battery power. It would be unwise to install a new OS on battery power. Exiting Script.", $outputLog

  $outputObject.outputLog = $outputLog
  $outputObject.nonComplianceReason = 'This machine was on battery power when checked for compliance. Build upgrades cannot occur on battery power. Please try to keep this machine plugged in to allow the upgrade to occur.'

  Invoke-Output $outputObject
  Return
}

# Here we landed where the downloader has run twice and the ISO has finished downloading, but the install script hasn't run yet.
# Just give this machine some time
$outputLog += 'This machine is currently in progress. Give this machine a few days and check back. Please ensure the machine is online.'

$outputObject.outputLog = $outputLog
$outputObject.nonComplianceReason = 'This machine is currently in progress. Give this machine a few days and check back. Please ensure the machine is online.'

Invoke-Output $outputObject
Return
