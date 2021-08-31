$outputLog = $()

<#
######################
## Output Helper Functions ##
######################
#>

function Invoke-Output {
    param ([string]$output)
    Write-Output ($output -join "`n")
}

function Get-ErrorMessage {
    param ($Err, [string]$Message)
    Return "$Message | Error! -> $($Err.Exception.Message)"
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
    Write-Output "!ERROR: No Windows Build was defined! Please define the `$automateWin10Build variable to something like '20H2' and then run this again!"
    Return
}

$isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'

# Make sure a URL has been defined for the Win10 ISO on Enterprise versions
If ($isEnterprise -and !$automateURL) {
    Write-Output "!ERROR: This is a Win10 Enterprise machine and no ISO URL was defined to download Windows 10 $automateWin10Build. This is required for Enterpise machines! Please define the `$automateURL variable with a URL to the ISO and then run this again!"
    Return
}

# Make sure a hash has been defined for the Win10 ISO on Enterprise versions
If ($isEnterprise -and !$automateIsoHash) {
    Write-Output "!ERROR: This is a Win10 Enterprise machine and no ISO Hash was defined to check the intregrity of the file download. Please define the `$automateIsoHash variable with SHA256 hash for ISO defined in `$automateURL!"
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
$regPath = 'HKLM:\\SOFTWARE\LabTech\Service\Win10Upgrade'
$hashKey = "Hash"
$rebootInitiatedKey = "RebootInitiated"
$windowsUpdateRebootPath1 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
$windowsUpdateRebootPath2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
$fileRenamePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"

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
        Return Get-ItemPropertyValue -Path $regPath -Name $Name
    } Catch {
        Return
    }
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
    param ([string]$Path, [string]$Hash)
    Return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash -eq $Hash
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
    $versionComparison = Get-Win10VersionComparison -LessThan $automateWin10Build
} Catch {
    $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one. Cannot continue."
    Invoke-Output $outputLog
    Return
}

If ($versionComparison.Result) {
    $outputLog += "Checked current version of windows and all looks good. " + $versionComparison.Output
} Else {
    $outputLog += "Cannot continue. The requested version should be less than the current version. " + $versionComparison.Output
    Invoke-Output $outputLog
    Return
}

<#
#################
# Prereq Checks #
#################
#>

# No need to continue if the ISO doesn't exist
If (!(Test-Path -Path $isoFilePath)) {
    $outputLog += "ISO doesn't exist yet.. Still waiting on that. Exiting script."
    Invoke-Output $outputLog
    Return
}

# No need to continue if the hash doesn't exist
If (!(Test-RegistryValue -Name $hashKey)) {
    $outputLog += "Somehow, the ISO exists, but the hash does not :'(. This should not have occurred. The ISO needs to be removed and redownloaded because there is no way to verify it's integrity. This script only handles installation. Exiting script."
    Invoke-Output $outputLog
    Return
}

$hash = Get-RegistryValue -Name $hashKey

# Definitely don't want to continue if the hash doesn't match
If (!(Get-HashCheck -Path $isoFilePath -Hash $hash)) {
    $outputLog += "An ISO file exists, but the hash does not match!! The hash must match! This ISO should be deleted and redownloaded. Exiting script."
    Invoke-Output $outputLog
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

If ($pendingRebootCheck.Checks.Length) {
    $rebootInitiated = Get-RegistryValue -Name $rebootInitiatedKey
    $outputLog += $pendingRebootCheck.Output

    If ($rebootInitiated -and ($rebootInitiated -ge 1)) {
        $outputLog += "Verified the reboot has already been performed but Windows failed to clean out the proper registry keys. Manually deleting reboot pending registry keys..."
        ## Delete reboot pending keys
        Remove-Item $windowsUpdateRebootPath1 -Force -ErrorAction Ignore
        Remove-Item $windowsUpdateRebootPath2 -Force -ErrorAction Ignore
        Remove-ItemProperty -Path $fileRenamePath -Name PendingFileRenameOperations -Force -ErrorAction Ignore

        $outputLog += "Reboot registry key deletes completed. Checking one last time to ensure that deleting them worked."

        # Check again for pending reboots
        $pendingRebootCheck = Read-PendingRebootStatus
        If ($pendingRebootCheck.Checks.Length) {
            $outputLog += "Was not able to remove some of the reboot flags. Exiting script. The flags still remaining are: $($pendingRebootCheck.Output)"

            # If the attempted deletion has occurred 3 or more times, it's not working... We should probably try a real reboot again, so set value to 0
            If ($rebootInitiated -ge 3) {
                $outputLog += "This has been attempted $rebootInitiated times. Setting the counter back to 0 so that on next script run, a reboot will be attempted again."
                Write-RegistryValue -Name $rebootInitiatedKey -Value 0
            } Else {
                # Increment counter
                Write-RegistryValue -Name $rebootInitiatedKey -Value ($rebootInitiated + 1)
            }

            Invoke-Output $outputLog
            Return
        } Else {
            Write-RegistryValue -Name $rebootInitiatedKey -Value 0
            $outputLog += "Reboot flags are now clear. Continuing."
        }
    } Else {
        $outputLog += "This system is pending a reboot. Reboot reason: $($pendingRebootCheck.Output)"
        $outputLog += "Reboot initiated, exiting script, but this script will run again shortly to pick up where this left off if triggered from CW Automate."
        shutdown /r /f /c "This machines requires a reboot to continue upgrading to Windows 10 $automateWin10Build."

        # Mark registry with $rebootInitiatedKey so that on next run, we know that a reboot already occurred
        Write-RegistryValue -Name $rebootInitiatedKey -Value 1
        $outputLog += "!REBOOT INITIATED:"
        Invoke-Output $outputLog
        Return
    }
} Else {
    $outputLog += "Verified there is no reboot pending"
    Write-RegistryValue -Name $rebootInitiatedKey -Value 0
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

Try {
    $outputLog += "The Windows 10 Upgrade Install has now been started silently in the background. No action from you is required, but please note a reboot will be reqired during the installation prcoess. It is highly recommended you save all of your open files!"
    Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList "/Auto Upgrade /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogsDir /Telemetry Disable" -PassThru
} Catch {
    $outputLog += "Setup ran into an issue while attempting to install the $automateWin10Build upgrade."
    Dismount-DiskImage $isoFilePath | Out-Null
}

Invoke-Output $outputLog
