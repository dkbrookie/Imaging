$outputLog = @()

# $installationAttemptCount should be provided by calling script
If (!$installationAttemptCount) {
    $installationAttemptCount = 0
}

<#
######################
## Output Helper Functions ##
######################
#>

function Invoke-Output {
    param ([string[]]$output, [string[]]$automateOutputParams)
    Write-Output "outputLog=$($output -join "`n")|installationAttemptCount=$installationAttemptCount|additionalOutput="
}

function Get-ErrorMessage {
    param ($Err, [string]$Message)
    Return "$Message $($Err.Exception.Message)"
}

<#
########################
## CW Automate Checks ##
########################

Check for a few values that should be set before entering this script. If this machine has an agent and a LocationID
set we want to make sure to put it back in that location after the win10 image is installed
#>

# Define build number this script will upgrade you to, should be like '20H2'
# This should be defined in the calling script
If (!$automateWin10Build) {
    $outputLog += "!ERROR: No Windows Build was defined! Please define the `$automateWin10Build variable to something like '20H2' and then run this again!"
    Invoke-Output $outputLog
    Return
}

$isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'

# Make sure a URL has been defined for the Win10 ISO on Enterprise versions
If ($isEnterprise -and !$automateURL) {
    $outputLog += "!ERROR: This is a Win10 Enterprise machine and no ISO URL was defined to download Windows 10 $automateWin10Build. This is required for Enterpise machines! Please define the `$automateURL variable with a URL to the ISO and then run this again!"
    Invoke-Output $outputLog
    Return
}

<#
########################
## Define File Hashes ##
########################
#>

If ($isEnterprise) {
    $hashArrays = @{
        '20H2' = @('3152C390BFBA3E31D383A61776CFB7050F4E1D635AAEA75DD41609D8D2F67E92')
        '21H1' = @('')
        '21H2' = @('')
    }
} Else {
    $hashArrays = @{
        '20H2' = @('6C6856405DBC7674EDA21BC5F7094F5A18AF5C9BACC67ED111E8F53F02E7D13D')
        '21H1' = @('6911E839448FA999B07C321FC70E7408FE122214F5C4E80A9CCC64D22D0D85EA')
        '21H2' = @('7F6538F0EB33C30F0A5CBBF2F39973D4C8DEA0D64F69BD18E406012F17A8234F')
    }
}

$acceptableHashes = $hashArrays[$automateWin10Build]

If (!$acceptableHashes) {
    $outputLog += "!ERROR: There is no HASH defined for $automateWin10Build in the script! Please edit the script and define an expected file hash for this build!"
    Invoke-Output $outputLog
    Return
}

<#
######################
## Define Constants ##
######################
#>

$workDir = "$env:windir\LTSvc\packages\OS"
$windowslogsDir = "$workDir\Win10-$automateWin10Build-Logs"
$downloadDir = "$workDir\Win10\$automateWin10Build"
$isoFilePath = "$downloadDir\$automateWin10Build.iso"
$regPath = "HKLM:\\SOFTWARE\LabTech\Service\Win10_$($automateWin10Build)_Upgrade"
$rebootInitiatedKey = "ExistingRebootInitiated"
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$windowsUpdateRebootPath1 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
$windowsUpdateRebootPath2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
$fileRenamePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
$winSetupErrorKey = 'WindowsSetupError'

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
function Get-RegistryValue {
    param([string]$Name)

    Try {
        Return Get-ItemPropertyValue -Path $regPath -Name $Name -ErrorAction Stop
    } Catch {
        Return
    }
}

function Remove-RegistryValue {
    param ([string]$Name)
    Remove-ItemProperty -Path $regPath -Name $Name -Force -EA 0 | Out-Null
}

function Test-RegistryValue {
    param([string]$Name)

    Try {
        Return [bool](Get-RegistryValue -Name $Name)
    } Catch {
        Return $false
    }
}

function Write-RegistryValue {
    param ([string]$Name, [string]$Value)
    $output = @()
    $propertyPath = "$regPath\$Name"

    If (!(Test-Path -Path $regPath)) {
        Try {
            New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
        } Catch {
            $output += Get-ErrorMessage $_ "Could not create registry key $regPath"
        }
    }

    If (Test-RegistryValue -Name $Name) {
        $output += "A value already exists at $propertyPath. Overwriting value."
    }

    Try {
        New-ItemProperty -Path $regPath -Name $Name -Value $Value -Force -ErrorAction Stop | Out-Null
    } Catch {
        $output += Get-ErrorMessage $_ "Could not create registry property $propertyPath"
    }

    Return $output
}

function Get-HashCheck {
    param ([string]$Path)
    $hash = (Get-FileHash -Path $Path -Algorithm 'SHA256').Hash
    $hashMatches = $acceptableHashes | ForEach-Object { $_ -eq $hash } | Where-Object { $_ -eq $true }
    Return $hashMatches.length -gt 0
}

function Read-PendingRebootStatus {
    $out = @()
    $rebootChecks = $()

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

This script should only execute if this machine is a windows 10 machine that is on a version less than the requested version
#>

# Call in Get-Win10VersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-Win10VersionComparison.ps1') | Invoke-Expression

Try {
    $lessThanRequestedBuild = Get-Win10VersionComparison -LessThan $automateWin10Build
} Catch {
    $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one."
    $outputLog = "!Error: Exiting script.", $outputLog
    Invoke-Output $outputLog
    Return
}

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $automateWin10Build
If ($lessThanRequestedBuild.Result) {
    $outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output
} Else {
    $outputLog += $lessThanRequestedBuild.Output
    $outputLog = "!Success: The requested windows build is already installed!", $outputLog

    # If this update has already been installed, we can remove the pending reboot key that is set when the installation occurs
    Remove-RegistryValue -Name $pendingRebootForThisUpgradeKey
    Invoke-Output $outputLog
    Return
}

# We don't want windows setup to repeatedly try if the machine is having an issue
If (Test-RegistryValue -Name $winSetupErrorKey) {
    $setupErr = Get-RegistryValue -Name $winSetupErrorKey
    $outputLog = "!Error: Windows setup experienced an error upon installation. This should be manually assessed and you should clear the value at $regPath\$winSetupErrorKey in order to make the script try again. The error output is $setupErr", $outputLog
    Invoke-Output $outputLog
    Return
}

# Check that this upgrade hasn't already occurred
If ((Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)) {
    $outputLog = "!Warning: This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. Exiting script.", $outputLog
    Invoke-Output $outputLog
    Return
}

<#
########################
# Make sure ISO exists #
########################
#>

# No need to continue if the ISO doesn't exist
If (!(Test-Path -Path $isoFilePath)) {
    $outputLog = "!Warning: ISO doesn't exist yet.. Still waiting on that. Exiting script.", $outputLog
    Invoke-Output $outputLog
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
    Invoke-Output $outputLog
    Return
}

<#
###########################
# Check if user logged in #
###########################
#>

# Call in Get-LogonStatus
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-LogonStatus.ps1') | Invoke-Expression

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
    $rebootInitiated = Get-RegistryValue -Name $rebootInitiatedKey
    $outputLog += $pendingRebootCheck.Output

    # When the machine is force rebooted, this registry value is set to 1, if it's equal to or greater than 1, we know the machine has been rebooted
    If ($rebootInitiated -and ($rebootInitiated -ge 1)) {
        $outputLog += "Verified the reboot has already been performed but Windows failed to clean out the proper registry keys. Manually deleting reboot pending registry keys..."
        # If the machine still has reboot flags, just delete the flags because it is likely that Windows failed to remove them
        Remove-Item $windowsUpdateRebootPath1 -Force -ErrorAction Ignore
        Remove-Item $windowsUpdateRebootPath2 -Force -ErrorAction Ignore
        Remove-ItemProperty -Path $fileRenamePath -Name PendingFileRenameOperations -Force -ErrorAction Ignore

        $outputLog += "Reboot registry key deletes completed. Checking one last time to ensure that deleting them worked."

        # Check again for pending reboots
        $pendingRebootCheck = Read-PendingRebootStatus
        # If there are still pending reboots at this point, increment the counter so we know how many retries have occurred without another forced reboot
        If ($pendingRebootCheck.Checks.Length) {
            $outputLog += "Was not able to remove some of the reboot flags. Exiting script. The flags still remaining are: $($pendingRebootCheck.Output)"

            # If the attempted deletion has occurred 3 or more times, deleting the flags is not working... We should probably try a real reboot again, so set value to 0
            If ($rebootInitiated -ge 3) {
                $outputLog += "This has been attempted $rebootInitiated times. Setting the counter back to 0 so that on next script run, a reboot will be attempted again."
                Write-RegistryValue -Name $rebootInitiatedKey -Value 0
            } Else {
                # Increment counter
                Write-RegistryValue -Name $rebootInitiatedKey -Value ($rebootInitiated + 1)
            }

            $outputLog = "!Warning: Still pending reboots.", $outputLog

            Invoke-Output $outputLog
            Return
        } Else {
            Write-RegistryValue -Name $rebootInitiatedKey -Value 0
            $outputLog += "Reboot flags are now clear. Continuing."
        }
    } ElseIf ($userIsLoggedOut) {
        # Machine needs to be rebooted and there is no user logged in, go ahead and force a reboot now
        $outputLog = "!Warning: This system has a pending a reboot which must be cleared before installation. It has not been excluded from reboots, and no user is logged in. Rebooting. Reboot reason: $($pendingRebootCheck.Output)", $outputLog
        # Mark registry with $rebootInitiatedKey so that on next run, we know that a reboot already occurred
        Write-RegistryValue -Name $rebootInitiatedKey -Value 1
        Invoke-Output $outputLog
        Restart-Computer -Force
        Return
    } Else {
        $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $automateWin10Build installation, but a user is currently logged in. Will try again later.", $outputLog
        Invoke-Output $outputLog
        Return
    }
} ElseIf ($pendingRebootCheck.Checks.Length -and $excludeFromReboot) {
    $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $automateWin10Build installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($pendingRebootCheck.Output)", $outputLog
    Invoke-Output $outputLog
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
    $outputLog = "!Warning: This is a laptop and it's on battery power. It would be unwise to install a new OS on battery power. Exiting Script.", $outputLog
    Invoke-Output $outputLog
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
    Invoke-Output $outputLog
    Return
}

$setupArgs = "/Auto Upgrade /NoReboot /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogsDir /Telemetry Disable"

# If a user is logged in, we want setup to run with low priority and without forced reboot
If (!$userIsLoggedOut) {
    $outputLog += "A user is logged in upon starting setup. Will not allow reboot, but will continue."
    $setupArgs = $setupArgs + " /Priority Low"
}

# We're running the installer here, so we can go ahead and increment $installationAttemptCount
$installationAttemptCount++
$outputLog += "Starting upgrade installation of $automateWin10Build"
$process = Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList $setupArgs -PassThru -Wait

$exitCode = $process.ExitCode

# If setup exited with a non-zero exit code, windows setup experienced an error
If ($exitCode -ne 0) {
    $outputLog += Get-ErrorMessage $_ "Windows setup exited with a non-zero exit code. The exit code was: $exitCode. This machine needs to be manually assessed. Writing error to registry at $regPath\$winSetupErrorKey. Clear this key before trying again."
    Write-RegistryValue -Name $winSetupErrorKey -Value $process.StandardError
    Dismount-DiskImage $isoFilePath | Out-Null
} Else {
    $outputLog += "Windows setup completed successfully."

    # Setup took a long time, so check user logon status again
    $userLogonStatus = Get-LogonStatus

    If (($userLogonStatus -eq 0) -and !$excludeFromReboot) {
        $outputLog = "!Warning: No user is logged in and machine has not been excluded from reboots, so rebooting now.", $outputLog
        Invoke-Output $outputLog
        Restart-Computer -Force
        Return
    } ElseIf ($excludeFromReboot) {
        $outputLog = "!Warning: This machine has been excluded from patching reboots so not rebooting. Marking pending reboot in registry.", $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
    } Else {
        $outputLog = "!Warning: User is logged in after setup completed successfully, so marking pending reboot in registry.", $outputLog
        Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
    }
}

Invoke-Output $outputLog
Return
