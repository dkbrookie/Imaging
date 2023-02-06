$outputLog = @()

$outputObject = {
    outputLog = $outputLog
    installationAttemptCount = [int]$installationAttemptCount
}

# TODO: (for future PR, not now) After machine is successfully upgraded, new monitor for compliant machines to clean up registry entries and ISOs
# TODO: (for future PR, not now) Mark reboot pending in EDF. Once reboot is pending, don't run download script anymore.
# TODO: (for future PR, not now) create ticket or take some other action when error state is unknown and won't retry

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

<#
##########################
## Call in Dependencies ##
##########################
#>

# Call in Invoke-Output
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Invoke-Output.ps1') | Invoke-Expression
# Call in Registry-Helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Registry-Helpers.ps1') | Invoke-Expression
# Call in Get-DesktopWindowsVersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression
# Call in Get-IsDiskFull
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsDiskFull.ps1') | Invoke-Expression
# Call in Get-LogonStatus
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-LogonStatus.ps1') | Invoke-Expression
# Call in Read-PendingRebootStatus
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Read-PendingRebootStatus.ps1') | Invoke-Expression

# TODO: Switch these to master URLs before merging
# Call in Invoke-RebootIfNeeded
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/Invoke-RebootIfNeeded/Function.Invoke-RebootIfNeeded.ps1') | Invoke-Expression
# Call in Create-PendingReboot
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/Invoke-RebootIfNeeded/Function.Create-PendingReboot.ps1') | Invoke-Expression
# Call in Helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/add-maint-window-reboots/Windows_Build_Upgrade_Helpers.ps1') | Invoke-Expression
# Call in Constants
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/add-maint-window-reboots/Windows_Build_Upgrade_Function.Get-Constants.ps1') | Invoke-Expression

<#
################################################
## Check prereqs are met and check for intent ##
################################################
#>

# This errors sometimes. If it does, we want a clear and actionable error and we do not want to continue
Try {
    $isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'
} Catch {
    $outputLog = "There was an error in determining whether this is an Enterprise version of windows or not. The error was: $_" + $outputLog
    Invoke-Output $outputObject
    Return
}

$prerequisites = Get-ProcessPrerequisites $releaseChannel $targetBuild $targetVersion $windowsGeneration $isEnterprise $enterpriseIsoUrl

foreach ($category in $prerequisites.Keys) {
    foreach ($prerequisite in $prerequisites[$category]) {
        # If check fails return early with error message
        If (!$prerequisite.Check) {
            $outputLog = "!Error: [$category] $($prerequisite.Error)" + $outputLog
            Invoke-Output $outputObject
            Return
        }
    }
}

# We need $targetVersion, $targetBuild and $windowsGeneration in order to continue, so suss the missing values out of whatever options were provided
Try {
    $targetInfo = Get-RemainingTargetInfo $releaseChannel $targetBuild $targetVersion $windowsGeneration
    $targetBuild = $targetInfo.TargetBuild
    $targetVersion = $targetInfo.TargetVersion
    $windowsGeneration = $result.WindowsGeneration
} Catch {
    $outputLog = $_.Exception.Message + $outputLog
    Invoke-Output $outputObject
}

Try {
    $acceptableHashes = Get-Hashes $isEnterprise $targetBuild
} Catch {
    $outputLog = "!Error: " + $_ + $outputLog
    Invoke-Output $outputObject
    Return
}

$constants = Get-Constants $targetBuild

$LTSvc                            = $constants.LTSvc
$workDir                          = $constants.workDir
$isoFilePath                      = $constants.isoFilePath
$windowslogsDir                   = $constants.windowslogsDir
$downloadDir                      = $constants.downloadDir
$regPath                          = $constants.regPath
$pendingRebootForThisUpgradeKey   = $constants.pendingRebootForThisUpgradeKey
$rebootInitiatedForThisUpgradeKey = $constants.rebootInitiatedForThisUpgradeKey
$rebootInitiatedKey               = $constants.rebootInitiatedKey
$installationAttemptCountKey      = $constants.installationAttemptCountKey

# Ensure directories exist
@($workDir, $windowslogsDir, $downloadDir, $LTSvc) | ForEach-Object {
    If (!(Test-Path $_)) {
        New-Item -Path $_ -ItemType Directory | Out-Null
    }
}

$installationAttemptCount = Get-RegistryValue -Name $installationAttemptCountKey
If (!$installationAttemptCount) {
    $installationAttemptCount = 0
}

<#
######################
## Check OS Version ##
######################

This script should only execute if this machine is a windows 10 machine that is on a version less than the requested version
#>

Try {
    $lessThanRequestedBuild = Get-DesktopWindowsVersionComparison -LessThan $targetBuild
} Catch {
    $outputLog = "!Error: There was an issue when comparing the current version of windows to the requested one." + $outputLog
    Invoke-Output $outputObject
    Return
}

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetBuild
If (!$lessThanRequestedBuild.Result) {
    $outputLog = $lessThanRequestedBuild.Output + $outputLog
    # If this update has already been installed, we can remove the pending reboot key that is set when the installation occurs
    Remove-RegistryValue -Name $pendingRebootForThisUpgradeKey
    Invoke-Output $outputObject
    Return
}

$outputLog += $lessThanRequestedBuild.Output

Try {
    Get-PreviousInstallationErrors
} Catch {
    $outputLog = "!Error: " + $_ + $outputLog
    Invoke-Output $outputObject
    # TODO: Alert here!!
    Return
}

# Check that this upgrade hasn't already occurred, if it has, see if we can reboot
Try {
    $previousInstallCheck = Invoke-PreviousInstallCheck @(
        $pendingRebootForThisUpgradeKey,
        $rebootInitiatedForThisUpgradeKey,
        $winSetupErrorKey,
        $winSetupExitCodeKey,
        $excludeFromReboot,
        $restartMessage,
        $regPath
    )

    If ($previousInstallCheck.Result) {
        # This installation has already run so exit early
        $outputLog = "!Warning: " + $previousInstallCheck.Message + $outputLog
        Invoke-Output $outputObject
        Return
    }
} Catch {
    $outputLog = "!Error: " + $_ + $outputLog
    Invoke-Output $outputObject
    Return
}

$installPrerequisites = Get-InstallationPrerequisites $acceptableHashes $isoFilePath
foreach ($category in $installPrerequisites.Keys) {
    foreach ($prerequisite in $installPrerequisites[$category]) {
        # If check fails return early with error message
        If (!$prerequisite.Check) {
            $outputLog = "!Error: [$category] $($prerequisite.Error)" + $outputLog
            Invoke-Output $outputObject
            Return
        }
    }
}

<#
##########################
## Reboot Pending Check ##
##########################

Reboots pending can be stored in multiple places. Check them all, if a reboot is pending, start a reboot
and record that the reboot was started in the LTSvc folder. This is to use to reference after the reboot
to confirm the reboot occured, then delete the registry keys if they still exist after the reboot. Windows
and/or apps that requested the reboot frequently fail to remove these keys so it's common to still show
"reboot pending" even after a successful reboot.

If a reboot is pending for any of the reasons below, the Windows upgrade will bomb out so it's important
to handle this issue before attempting the update.
#>

Try {
    $rebootHandler = Invoke-RebootHandler $excludeFromReboot $releaseChannel $targetBuild $targetVersion $windowsGeneration $rebootInitiatedKey
    $shouldCachePendingReboots = $rebootHandler.ShouldCachePendingReboots
    $outputLog += $rebootHandler.OutputLog
} Catch {
    $outputLog = "!Warning: " + $_ + $outputLog
    Invoke-Output $outputObject
    Return
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
    $outputLog = "!Warning: This is a laptop and it's on battery power. It would be unwise to install a new OS on battery power. Exiting Script." + $outputLog
    Invoke-Output $outputObject
    Return
}

<#
###########################
# Check if user logged in #
###########################
#>

$userLogonStatus = Get-LogonStatus

# If userLogonStatus equals 0, there is no user logged in. If it is 1 or 2, there is a user logged in and we shouldn't allow reboots.
$userIsLoggedOut = $userLogonStatus -eq 0

Try {
    ## The portable ISO EXE is going to mount our image as a new drive and we need to figure out which drive
    ## that is. So before we mount the image, grab all CURRENT drive letters
    $curLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
    Mount-DiskImage $isoFilePath | Out-Null
    ## Have to sleep it here for a second because the ISO takes a second to mount and if we go too quickly
    ## it will think no new drive letters exist
    Start-Sleep 30
    ## Now that the ISO is mounted we should have a new drive letter, so grab all drive letters again
    $newLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
    ## Compare the drive letters from before/after mounting the ISO and figure out which one is new.
    ## This will be our drive letter to work from
    $mountedLetter = (Compare-Object -ReferenceObject $curLetters -DifferenceObject $newLetters).InputObject + ':'
    ## Call setup.exe w/ all of our required install arguments
} Catch {
    $outputLog += "Could not mount the ISO for some reason. Exiting script."
    Dismount-DiskImage $isoFilePath | Out-Null
    Invoke-Output $outputObject
    Return
}

If (($windowsGeneration -eq '11') -and ($forceInstallOnUnsupportedHardware)) {
    $outputLog += '$forceInstallOnUnsupportedHardware was specified, so setting HKLM:\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU to 1. This should avoid the installer erroring out due to TPM or CPU incompatibility.'

    Try {
        Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'DWORD' -Value 1
    } Catch {
        $outputLog += "There was a problem, could net set AllowUpgradesWithUnsupportedTPMOrCPU to 1. Installation will not succeed if hardware is not compatible."
    }
}

$setupArgs = "/Auto Upgrade /NoReboot /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogsDir /Telemetry Disable"

# If a user is logged in, we want setup to run with low priority and without forced reboot
If (!$userIsLoggedOut) {
    $outputLog += "A user is logged in upon starting setup. Will reassess after installation finishes."
    $setupArgs = $setupArgs + " /Priority Low"
}

# We're running the installer here, so we can go ahead and increment $installationAttemptCount
$installationAttemptCount++

Write-RegistryValue -Name $installationAttemptCountKey -Value $installationAttemptCount

# If we determined that we should cache pending reboots earlier, do that now just before installation
If ($shouldCachePendingReboots) {
    Cache-AndRestorePendingReboots
}

$outputLog += "Starting upgrade installation of $targetBuild"
$process = Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList $setupArgs -PassThru -Wait

$exitCode = $process.ExitCode

# If setup exited with a non-zero exit code, windows setup experienced an error
If ($exitCode -ne 0) {
    $setupErr = $process.StandardError
    $convertedExitCode = '{0:x}' -f $exitCode

    $outputLog += "Windows setup exited with a non-zero exit code. The exit code was: '$convertedExitCode'."

    If ($convertedExitCode -eq 'c1900200') {
        $outputLog += "Cannot install because this machine's hardware configuration does not meet the minimum requirements for the target Operating System 'Windows $windowsGeneration $targetBuild'. You may be able to force installation by setting `$forceInstallOnUnsupportedHardware to `$true."
        $setupErr = 'Hardware configuration unsupported.'
    }

    If ($setupErr -eq '') {
        $setupErr = 'Unknown Error - Windows Setup did not return an error message. Check the Exit Code.'
    }

    $outputLog += "This machine needs to be manually assessed. Writing error to registry at $regPath\$winSetupErrorKey. Clear this key before trying again. The error was: $setupErr"

    Write-RegistryValue -Name $winSetupErrorKey -Value $setupErr
    Write-RegistryValue -Name $winSetupExitCodeKey -Value $convertedExitCode
    Dismount-DiskImage $isoFilePath | Out-Null
} Else {
    $outputLog += "Windows setup completed successfully."

    # Setup took a long time, so check user logon status again
    $userLogonStatus = Get-LogonStatus

    If (($userLogonStatus -eq 0) -and !$excludeFromReboot) {
        $outputLog = "!Warning: No user is logged in and machine has not been excluded from reboots, so rebooting now." + $outputLog
        Invoke-Output $outputObject
        Write-RegistryValue -Name $rebootInitiatedForThisUpgradeKey -Value 1
        shutdown /r /c $restartMessage
        Return
    } ElseIf ($excludeFromReboot) {
        $outputLog = "!Warning: This machine has been excluded from patching reboots so not rebooting. Marking pending reboot in registry." + $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
    } Else {
        $outputLog = "!Warning: User is logged in after setup completed successfully, so marking pending reboot in registry." + $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
        Create-PendingReboot
    }
}
