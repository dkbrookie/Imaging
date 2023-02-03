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
# Grab Helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/add-maint-window-reboots/Windows_Build_Upgrade_Helpers.ps1') | Invoke-Expression
# Call in Install-WinBuild
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/add-maint-window-reboots/Windows_Build_Upgrade_Function.Install-WinBuild.ps1') | Invoke-Expression
# Grab Constants (this has to be after Get-RemainingTargetInfo because some of the constants depend on those values)
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/add-maint-window-reboots/Windows_Build_Upgrade_Function.Get-Constants.ps1') | Invoke-Expression

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
@($workDir, $windowslogsDir, $downloadDir) | ForEach-Object {
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

# TODO: move this up to the rest of the directory checks
## We're going to save some logs to $env:windir so just make sure it exists and create it if it doesn't.
If (!(Test-Path -Path $LTSvc)) {
    New-Item -Path $LTSvc -ItemType Directory | Out-Null
}

Try {
    # TODO: handle this function
    Invoke-RebootHandler
} Catch {
    $outputLog = "!Warning: " + $_ + $outputLog
    Invoke-Output $outputObject
    Return
}

<#
########################
####### Install ########
########################
#>

Invoke-Output $outputObject
Return
