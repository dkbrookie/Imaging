$outputLog = @()

# cast $targetBuild into a string just in case it's an int
[string]$targetBuild = $targetBuild

# TODO: (for future PR, not now) make reboot handling more robust
# TODO: (for future PR, not now) After machine is successfully upgraded, new monitor for compliant machines to clean up registry entries and ISOs
# TODO: (for future PR, not now) Mark reboot pending in EDF. Once reboot is pending, don't run download script anymore.
# TODO: (for future PR, not now) create ticket or take some other action when error state is unknown and won't retry

<#
#############
## Fix TLS ##
#############
#>

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
# Call in Get-OsVersionDefinitions
$WebClient.DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/main/Get-OsVersionDefinitions.ps1') | Invoke-Expression
# Call in Registry-Helpers
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Registry-Helpers.ps1') | Invoke-Expression
# Call in Get-DesktopWindowsVersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression
# Call in Get-WindowsIsoUrlByBuild.ps1
$WebClient.DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/main/Get-WindowsIsoUrlByBuild.ps1') | Invoke-Expression
# Call in Get-IsDiskFull
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsDiskFull.ps1') | Invoke-Expression
# Call in Get-LogonStatus
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-LogonStatus.ps1') | Invoke-Expression
# TODO: Switch to master URLs after merge
# Call in Read-PendingRebootStatus
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/Invoke-RebootIfNeeded/Function.Read-PendingRebootStatus.ps1') | Invoke-Expression
# Call in Cache-AndRestorePendingReboots
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/Invoke-RebootIfNeeded/Function.Cache-AndRestorePendingReboots.ps1') | Invoke-Expression

<#
####################
## Output Helpers ##
####################
#>

function Get-ErrorMessage {
    param ($Err, [string]$Message)
    Return "$Message Error was: $($Err.Exception.Message)"
}

<#
##################################################
## Ensure some values are the correct data type ##
##################################################
#>

Try {
    # cast $targetBuild into a string just in case it's an int, we need to do some string operations later
    [string]$targetBuild = $targetBuild
} Catch {
    $outputLog += "Could not cast `$targetBuild of '$targetBuild' into a string. Error was: $_"
    Invoke-Output $outputLog
    Return
}

Try {
    # cast $excludeFromReboot into an int just in case it's a string, we need to check it as a bool later, so we don't want a string
    [int]$excludeFromReboot = $excludeFromReboot
} Catch {
    $outputLog += "Could not cast `$excludeFromReboot of '$excludeFromReboot' into an integer. Error was: $_"
    Invoke-Output $outputLog
    Return
}

<#
######################
## Check for intent ##
######################

Validate that the script isn't being used with an indeterminate configuration / intention

Define $releaseChannel which will define which build this script will upgrade you to, should be 'Alpha', 'Beta' or 'GA' This should be defined in the
calling script.

OR you can specify $targetBuild (i.e. '19041') which will download a specific build

OR you can specify $targetVersion (i.e '20H2') PLUS $windowsGeneration (i.e. '10' or '11') which will download a specific build
#>

# If none of the options are specified
If (!$releaseChannel -and !$targetBuild -and (!$targetVersion -or !$windowsGeneration)) {
    $outputLog = "!Error: No Release Channel was defined! Please define the `$releaseChannel variable to 'GA', 'Beta' or 'Alpha' and then run this again! Alternatively, you can provide `$targetBuild (i.e. '19041') or you can provide `$targetVersion (i.e. '20H2') AND `$windowsGeneration (i.e. '10' or '11')." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# If both $releaseChannel and $targetBuild are specified
If ($releaseChannel -and $targetBuild) {
    $outputLog = "!Error: `$releaseChannel of '$releaseChannel' and `$targetBuild of '$targetBuild' were both specified. You should specify only one of these." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# If both $releaseChannel and $targetVersion are specified
If ($releaseChannel -and ($targetVersion -or $windowsGeneration)) {
    If ($targetVersion) {
        $msg = "`$targetVersion of '$targetVersion'"
    } Else {
        $msg = "`$windowsGeneration of '$windowsGeneration'"
    }

    $outputLog = "!Error: `$releaseChannel of '$releaseChannel' and $msg were both specified. You should specify only one of these." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# If both $targetVersion and $targetBuild are specified
If ($targetBuild -and ($targetVersion -or $windowsGeneration)) {
    If ($targetVersion) {
        $msg = "`$targetVersion of '$targetVersion'"
    } Else {
        $msg = "`$windowsGeneration of '$windowsGeneration'"
    }

    $outputLog = "!Error: `$targetBuild of '$targetBuild' and $msg were both specified. You should specify only one of these." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# If $targetVersion OR $windowsGeneration is specified, the other must be as well. Version IDs overlap so the intent could be either 10 or 11
If (($targetVersion -and !$windowsGeneration) -or (!$targetVersion -and $windowsGeneration)) {
    If ($targetVersion) {
        $specified = "`$targetVersion of $targetVersion"
        $notSpecified = '$windowsGeneration'
    } Else {
        $specified = "`$windowsGeneration of $windows"
        $notSpecified = '$targetVersion'
    }

    $outputLog = "!Error: $specified was specified but $notSpecified was not specified. You must provide both." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
#########################
## Get Target Build ID ##
#########################

We need $targetVersion, $targetBuild and $windowsGeneration in order to continue, so suss the missing values out of whatever options were provided
#>

$windowsBuildToVersionMap = @{
    '19042' = '20H2'
    '19043' = '21H1'
    '19044' = '21H2'
    '19045' = '22H2'
    '22000' = '21H2'
    '22621' = '22H2'
}

# We only care about gathering the build ID based on release channel when $releaseChannel is specified, if it's not, targetVersion or targetBuild are specified
If ($releaseChannel) {
    $targetBuild = (Get-OsVersionDefinitions).Windows.Desktop[$releaseChannel]

    If (!$targetBuild) {
        $outputLog = "!Error: Target Build was not found! Please check the provided `$releaseChannel of $releaseChannel against the valid release channels in Get-OsVersionDefinitions in the Constants repository." + $outputLog
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Return
    }

    # If $targetVersion and $windowsGeneration have been specified instead of $releaseChannel, map the targetVersion to it's corresponding build ID
} ElseIf ($targetVersion) {
    # If $windowsGeneration is '10' remove all 11 versions from hash table
    If ($windowsGeneration -eq '10') {
        $windowsBuildToVersionMap = $windowsBuildToVersionMap.GetEnumerator() | Where-Object { $_.Name.substring(0, 2) -eq 19 }

        # If $windowsGeneration is '11' remove all 10 versions from hash table
    } ElseIf ($windowsGeneration -eq '11') {
        $windowsBuildToVersionMap = $windowsBuildToVersionMap.GetEnumerator() | Where-Object { $_.Name.substring(0, 2) -eq 22 }

        # If neither, that'd be an error state. Only windows 10 and 11 are supported
    } Else {
        $outputLog = "!Error: An unsupported `$windowsGeneration value of $windowsGeneration was provided. Please choose either '10' or '11'." + $outputLog
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Return
    }

    # Now grab the Build ID for the specified version
    $targetBuild = ForEach ($Key in ($windowsBuildToVersionMap.GetEnumerator() | Where-Object { $_.Value -eq $targetVersion })) { $Key.name }
}

# If $releaseChannel or $targetBuild were specified, we have $targetBuild but we don't have the $windowsGeneration or $targetVersion yet, so get those
If ($targetBuild) {
    # Set $windowsGeneration based on Build ID, need that later for Fido
    If ($targetBuild.substring(0, 2) -eq 19) {
        $windowsGeneration = '10'
    } ElseIf ($targetBuild.substring(0, 2) -eq 22) {
        $windowsGeneration = '11'
    } Else {
        $outputLog = "!Error: There was a problem with the script. `$targetBuild of $targetBuild does not appear to be supported. Please update script!" + $outputLog
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Return
    }

    $targetVersion = $windowsBuildToVersionMap[$targetBuild]

    If (!$targetVersion) {
        $outputLog += "No value for `$targetVersion could be determined from `$targetBuild. This script needs to be updated to handle $targetBuild! Please update script!"
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Return
    }
}

<#
########################
## Environment Checks ##
########################
#>

$Is64 = [Environment]::Is64BitOperatingSystem

If (!$Is64) {
    $outputLog = "!Error: This script only supports 64 bit operating systems! This is a 32 bit machine. Please upgrade this machine to $targetBuild manually!" + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# This errors sometimes. If it does, we want a clear and actionable error and we do not want to continue
Try {
    $isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'
} Catch {
    $outputLog += "There was an error in determining whether this is an Enterprise version of windows or not. The error was: $_"
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# Make sure a URL has been defined for the Win ISO on Enterprise versions
If ($isEnterprise -and !$enterpriseIsoUrl) {
    $outputLog = "!Error: This is a Windows Enterprise machine and no ISO URL was defined to download Windows $targetBuild. This is required for Enterprise machines! Please define the `$enterpriseIsoUrl variable with a URL where the ISO can be located and then run this again! The url should only be the base url where the ISO is located, do not include the ISO name or any trailing slashes (i.e. 'https://someurl.com'). The filename  of the ISO located here must be named 'Win_Ent_`$targetBuild.iso' like 'Win_Ent_19044.iso'" + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
######################
## Define Constants ##
######################
#>

$workDir = "$env:windir\LTSvc\packages\OS"
$windowslogsDir = "$workDir\Windows-$targetBuild-Logs"
$downloadDir = "$workDir\Windows\$targetBuild"
$isoFilePath = "$downloadDir\$targetBuild.iso"
$regPath = "HKLM:\SOFTWARE\LabTech\Service\Windows_$($targetBuild)_Upgrade"
$rebootInitiatedKey = "ExistingRebootInitiated"
$rebootInitiatedForThisUpgradeKey = "RebootInitiatedForThisUpgrade"
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$winSetupErrorKey = 'WindowsSetupError'
$winSetupExitCodeKey = 'WindowsSetupExitCode'
$installationAttemptCountKey = 'InstallationAttemptCount'
$retryInstallFailedWithoutErrorCountKey = 'RetryInstallFailedWithoutErrorCountKey'
$acceptableHashes = $hashArrays[$targetBuild]

Try {
    $isoUrl = Get-WindowsIsoUrlByBuild -Build $targetBuild
} Catch {
    $outputLog = "!Error: Could not get url for '$targetBuild' - Error: $($_.Exception.Message)" + $outputLog
    Invoke-Output $outputLog
    Return
}

# Suss the expected hash out of the URL
$acceptableHash = (($isoUrl -split '_')[1] -split '\.')[0]
If (!$acceptableHash) {
    $outputLog = "!Error: There is no HASH defined for build '$targetBuild' in the script! Please edit the script and define an expected file hash for this build!" + $outputLog
    Invoke-Output $outputLog
    Return
}

# This ends up strings instead of integers if we don't cast them
[Int32]$installationAttemptCount = Get-RegistryValue -Name $installationAttemptCountKey
[Int32]$retryInstallFailedWithoutErrorCount = Get-RegistryValue -Name $retryInstallFailedWithoutErrorCountKey

If (!$installationAttemptCount) {
    $installationAttemptCount = 0
}

<#
######################
## Ensure Directories Exist ##
######################
#>

If (!(Test-Path $workDir)) {
    New-Item -Path $workDir -ItemType Directory | Out-Null
}

If (!(Test-Path $windowslogsDir)) {
    New-Item -Path $windowslogsDir -ItemType Directory | Out-Null
}

If (!(Test-Path $downloadDir)) {
    New-Item -Path $downloadDir -ItemType Directory | Out-Null
}

<#
######################
## Helper Functions ##
######################
#>

function Get-HashCheck {
    param ([string]$Path)
    $hash = (Get-FileHash -Path $Path -Algorithm 'SHA256').Hash
    Return $acceptableHash -eq $hash
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
    $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one."
    $outputLog = "!Error: Exiting script." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetBuild
If ($lessThanRequestedBuild.Result) {
    $outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output
} Else {
    $outputLog += $lessThanRequestedBuild.Output
    $outputLog = "!Success: The requested windows build is already installed!" + $outputLog

    # If this update has already been installed, we can remove the pending reboot key that is set when the installation occurs
    Remove-RegistryValue -Name $pendingRebootForThisUpgradeKey
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# We don't want windows setup to repeatedly try if the machine is having an issue
If (Test-RegistryValue -Name $winSetupErrorKey) {
    $setupErr = Get-RegistryValue -Name $winSetupErrorKey
    $setupExitCode = Get-RegistryValue -Name $winSetupExitCodeKey
    $outputLog = "!Error: Windows setup experienced an error upon last installation. This should be manually assessed and you should delete $regPath\$winSetupErrorKey in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'" + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# There could also be an error at a location from a previous version of this script, identified by version ID 20H2
If (Test-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError') {
    $setupErr = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError'
    $setupExitCode = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupExitCode'
    $outputLog = "!Error: Windows setup experienced an error upon last installation. This should be manually assessed and you should delete HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade\WindowsSetupError in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'" + $outputLog
    Invoke-Output @{
        outputLog                = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

# TODO: Get rid of concept of "pendingrebootforthisupgrade" controlling reboots, use Create-PendingReboot for that, only use "pendingrebootforthisupgrade" to report that the upgrade has occurred
# Check that this upgrade hasn't already occurred, if it has, see if we can reboot
If ($pendingRebootForThisUpgrade) {

    # If the reboot for this upgrade has already occurred, the installation doesn't appear to have succeeded so the installer must have errored out without
    # actually throwing an error code? Let's set the error state for assessment.
    If ($rebootInitiatedForThisUpgrade) {
        $failMsg = "Windows setup appears to have succeeded (it didn't throw an error) but windows didn't actually complete the upgrade for some reason. This machine needs to be manually assessed. If you want to try again, delete registry values at '$rebootInitiatedForThisUpgradeKey', '$pendingRebootForThisUpgradeKey' and '$winSetupErrorKey'"
        $outputLog = "!Failure: $failMsg" + $outputLog
        Write-RegistryValue -Name $winSetupErrorKey -Value $failMsg
        Write-RegistryValue -Name $winSetupExitCodeKey -Value 'Unknown Error'
        Return
    }

    $userLogonStatus = Get-LogonStatus

    If (($userLogonStatus -eq 0) -and !$excludeFromReboot) {
        $outputLog = "!Warning: This machine has already been upgraded but is pending reboot. No user is logged in and machine has not been excluded from reboots, so rebooting now." + $outputLog
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Write-RegistryValue -Name $rebootInitiatedForThisUpgradeKey -Value 1

        # Mark a pending reboot manually to ensure that Invoke-RebootIfNeeded finds a reboot
        Create-PendingReboot

        # Trigger reboot
        Invoke-RebootIfNeeded

        Return
    } Else {
        If ($excludeFromReboot) {
            $reason = 'Machine has been excluded from automatic reboots'
        } Else {
            $reason = 'User is logged in'
        }

        $outputLog = "!Warning: This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. $reason, so not rebooting." + $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
    }

    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
########################
# Make sure ISO exists #
########################
#>

# No need to continue if the ISO doesn't exist
If (!(Test-Path -Path $isoFilePath)) {
    $outputLog = "!Warning: ISO doesn't exist yet.. Still waiting on that. Exiting script." + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
##############################
# Make sure the hash matches #
##############################
#>

# Ensure hash matches
If (!(Get-HashCheck -Path $isoFilePath)) {
    $outputLog = "!Error: The hash doesn't match!! This ISO file needs to be deleted via the cleanup script and redownloaded via the download script, OR a new hash needs to be added to this script!!" + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
############################
# Ensure enough disk space #
############################
#>

# Microsoft guidance states that 20Gb is needed for installation
$diskCheck = Get-IsDiskFull -MinGb 20

If ($diskCheck.DiskFull) {
    $outputLog = ('!Error: ' + $diskCheck.Output) + $outputLog
    Invoke-Output @{
        outputLog                = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
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

## We're going to save some logs to $env:windir so just make sure it exists and create it if it doesn't.
$LTSvc = "$env:windir\LTSvc"
If (!(Test-Path -Path $LTSvc)) {
    New-Item -Path $LTSvc -ItemType Directory | Out-Null
}

$pendingRebootCheck = Read-PendingRebootStatus

# If there is a pending reboot flag present on the system
If ($pendingRebootCheck.HasPendingReboots -and !$excludeFromReboot) {
    $rebootInitiated = Get-RegistryValue -Name $rebootInitiatedKey
    $outputLog += $pendingRebootCheck.Output

    # When the machine is force rebooted, this registry value is set to 1, if it's equal to or greater than 1, we know the machine has been rebooted
    If ($rebootInitiated -and ($rebootInitiated -ge 1)) {
        $outputLog += "Verified the reboot has already been performed but Windows failed to clean out the proper registry keys. Caching reboot pending registry keys and they will be put back after the next reboot."
        # If the machine still has reboot flags, just delete the flags because it is likely that Windows failed to remove them
        # TODO: cache pending reboots
        Try {
            Cache-AndRestorePendingReboots
        } Catch {
            $outputLog += "Could not cache pending reboots. The error was: $($_.Exception.Message)"
            Invoke-Output {
                outputLog = $outputLog
                installationAttemptCount = $installationAttemptCount
            }
            Return
        }
    } ElseIf ($userIsLoggedOut) {
        # Machine needs to be rebooted and there is no user logged in, go ahead and force a reboot now
        $outputLog = "!Warning: This system has a pending a reboot which must be cleared before installation. It has not been excluded from reboots, and no user is logged in. Rebooting. Reboot reason: $($pendingRebootCheck.Output)" + $outputLog
        # Mark registry with $rebootInitiatedKey so that on next run, we know that a reboot already occurred
        Write-RegistryValue -Name $rebootInitiatedKey -Value 1
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }

        # Trigger reboot
        Invoke-RebootIfNeeded
        Return
    } Else {
        $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetBuild installation, but a user is currently logged in. Will try again later." + $outputLog
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }
        Return
    }
} ElseIf ($pendingRebootCheck.HasPendingReboots -and $excludeFromReboot) {
    $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetBuild installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($pendingRebootCheck.Output)" + $outputLog
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
} Else {
    $outputLog += "Verified there is no reboot pending"
    Write-RegistryValue -Name $rebootInitiatedKey -Value 0
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
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

<#
########################
####### Install ########
########################
#>

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
    Invoke-Output @{
        outputLog = $outputLog
        installationAttemptCount = $installationAttemptCount
    }
    Return
}

If (($windowsGeneration -eq '11') -and ($forceInstallOnUnsupportedHardware)) {
    $outputLog += '$forceInstallOnUnsupportedHardware was specified, so setting HKLM:\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU to 1. This should avoid the installer erroring out due to TPM or CPU incompatibility.'

    Try {
        Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'DWORD' -Value 1
        Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassTPMCheck' -Type 'DWORD' -Value 1
        Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassRAMCheck' -Type 'DWORD' -Value 1
        Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\LabConfig' -Name 'BypassSecureBootCheck' -Type 'DWORD' -Value 1
    } Catch {
        $outputLog += "There was a problem, could net bypass Win11 compatibility checks. Installation will not succeed if hardware is not compatible."
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
        $setupErr = 'Hardware configuration unsupported'
    }

    If ($convertedExitCode -eq 'c1900204') {
        $outputLog += "Cannot install because Windows has stated 'selected install choice is not available' which may mean that this copy of windows is not licensed."
        $setupErr = 'Selected install choice is not available'
    }

    If (('' -eq $setupErr) -or ($Null -eq $setupErr)) {
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
        Invoke-Output @{
            outputLog = $outputLog
            installationAttemptCount = $installationAttemptCount
        }

        Write-RegistryValue -Name $rebootInitiatedForThisUpgradeKey -Value 1

        # Manually mark a pending reboot to ensure that Invoke-RebootIfNeeded finds a pending reboot and triggers reboot
        Create-PendingReboot

        # Trigger reboot
        Invoke-RebootIfNeeded
        Return
    } ElseIf ($excludeFromReboot) {
        $outputLog = "!Warning: This machine has been excluded from patching reboots so not rebooting. Marking pending reboot in registry." + $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
    } Else {
        $outputLog = "!Warning: User is logged in after setup completed successfully, so marking pending reboot in registry." + $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
        # Manually mark pending reboot just in case Windows installer didn't do a great job
        Create-PendingReboot
    }
}

Invoke-Output @{
    outputLog = $outputLog
    installationAttemptCount = $installationAttemptCount
}
Return
