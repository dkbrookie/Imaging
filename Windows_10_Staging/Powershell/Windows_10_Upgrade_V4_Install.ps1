$outputLog = $()

<#
######################
## Output Helper Functions ##
######################
#>

function Invoke-Output {
    param ([string]$output)
    Write-Output ($output -join '`n')
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

If (!$token) {
    $outputLog += "!ERROR: No token was defined for the Automate agent. This isn't a problem for an upgrade installation, however for all complete machine wipes this WILL be required!"
}

If (!$locationID) {
    $locationID = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\LabTech\Service" -Name LocationID -EA 0
    If (!$locationID) {
        $outputLog += 'No LocationID found for this machine, no Automate agent was installed on this machine. Using the default location ID of 1.'
        $locationID = 1
    } Else {
        $outputLog += "Automate LocationdID is $locationID"
    }
} Else {
    $outputLog += "This machine will be added to LocationID $locationID after the OS install"
}

## Make sure an Automate server was defined so we know where to download the agent from
## and where to sign the agent up to after the OS install
If (!$server) {
    $outputLog = '!ERROR: No Automate server address was defined in the $server variable. Please define a server (https://automate.yourcompany.com) in the $server variable before calling this script!' + $outputLog
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
$regPath = 'HKLM:\\SOFTWARE\LabTech\Service\Win10Upgrade'
$hashKey = "Hash"

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
    Return Get-ItemPropertyValue -Path $regPath -Name $Name
}

function Test-RegistryValue {
    param([string]$Name)

    Try {
        Return [bool](Get-RegistryValue -Name $Name)
    } Catch {
        Return $false
    }
}

function Get-HashCheck {
    param ([string]$Path, [string]$Hash)
    Return (Get-FileHash -Algorithm SHA256 -Path $Path) -eq $Hash
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

# No need to continue if the ISO and hash don't exist
If (!(Test-Path -Path $isoFilePath)) {
    $outputLog += "ISO doesn't exist yet.. Still waiting on that. Exiting script."
    Invoke-Output $outputLog
    Return
}

If (!(Test-RegistryValue -Name $hashKey)) {
    $outputLog += "Somehow, the ISO exists, but the hash does not :'(. This should not have occurred. The ISO needs to be removed and redownloaded because there is no way to verify it's integrity. This script only handles installation. Exiting script."
    Invoke-Output $outputLog
    Return
}

$hash = Get-RegistryValue -Name $hashKey

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
## The following two reboot keys most commonly exist if a reboot is required for Windows Updates, but it is possible
## for an application to make an entry here too.
$windowsUpdateRebootPath1 = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
$windowsUpdateRebootPath2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
$fileRenamePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
$rbCheck1 = Get-ChildItem $windowsUpdateRebootPath1 -EA 0
$rbCheck2 = Get-Item $windowsUpdateRebootPath2 -EA 0
## This is often also the result of an update, but not specific to Windows update. File renames and/or deletes can be
## pending a reboot, and this key tells Windows to take these actions on the machine after a reboot to ensure the files
## aren't running so they can be renamed.
$rbCheck3 = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA 0

If ($rbCheck1) {
    $rebootReason += "Found a reboot pending for Windows Updates to complete at $windowsUpdateRebootPath1.`r`n"
}
If ($rbCheck2) {
    $rebootReason += "Found a reboot pending for Windows Updates to complete at $windowsUpdateRebootPath2.`r`n"
}
If ($rbCheck3) {
    $rebootReason += "Found a reboot pending for file renames/deletes on next system reboot.`r`n"
    $fileRenames = ($rbCheck3).PendingFileRenameOperations | Out-String
    $rebootReason += "`r`n`r`n===========List of files pending rename===========`r`n`r`n`r`n"
    $rebootReason += $fileRenames

}
If ($rbCheck1 -or $rbCheck2 -or $rbCheck3) {
    $rebootComplete = Get-Content -Path "$LTSvc\win10UpgradeReboot.txt" -ErrorAction Ignore
    If ($rebootComplete -eq 'True') {
        $outputLog += "Verified the reboot has already been peformed but Windows failed to clean out the proper registry keys. Manually deleting reboot pending registry keys..."
        ## Delete reboot pending keys
        Remove-Item $windowsUpdateRebootPath1 -Force -ErrorAction Ignore
        Remove-Item $windowsUpdateRebootPath2 -Force -ErrorAction Ignore
        Remove-ItemProperty -Path $fileRenamePath -Name PendingFileRenameOperations -Force -ErrorAction Ignore
        Remove-Item "$LTSvc\win10UpgradeReboot.txt" -Force -ErrorAction Ignore
        $outputLog += "Reboot registry key deletes completed."
    } Else {
        $outputLog += "This system is pending a reboot. Reboot reason: $rebootReason"
        $outputLog += "Reboot initiated, exiting script, but this script will run again shortly to pick up where this left off if triggered from CW Automate."
        shutdown /r /f /c "This machines requires a reboot to continue upgrading to Windows 10 $automateWin10Build."
        Set-Content -Path "$LTSvc\win10UpgradeReboot.txt" -Value 'True'
        $outputLog += "!REBOOT INITIATED:"
        Write-Output $outputLog
        Return
    }
} Else {
    $outputLog += "Verified there is no reboot pending"
}

<#
#################
## File Checks ##
#################
#>

$isoMountURL = "https://drive.google.com/uc?export=download&id=1XpZOQwH6BRwi8FpFZOr4rHlJMDi2HkLb"
$isoMountExe = "$downloadDir\mountIso.exe"
$SetupComplete = "$downloadDir\SetupComplete.cmd"
$SetupCompleteContent = "https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Bat/SetupComplete.cmd"

## This file contains all of our scripts to run POST install. It's slim right now but the idea is to
## add in app deployments / customizations all in here.
(New-Object System.Net.WebClient).DownloadFile($SetupCompleteContent, $SetupComplete)

## Here we're adding the agent install script to the file above. We're adding this to the file AFTER it's
## downloaded because we need to change the locationID to the current locationID of the machine to make
## sure the agent installs it back to the right client.
Add-Content -Path $SetupComplete -Value "
REM Install Automate agent
powershell.exe -ExecutionPolicy Bypass -Command ""& { (New-Object Net.WebClient).DownloadString('https://bit.ly/LTPoSh') | iex; Install-LTService -Server $server -LocationID $locationID -InstallerToken $token }"""

<#
########################
####### Install ########
########################
#>

## If the portable ISO mount EXE doesn't exist then download it
Try {
    If (!(Test-Path $isoMountExe -PathType Leaf)) {
        (New-Object System.Net.WebClient).DownloadFile($isoMountURL,$isoMountExe)
    }
} Catch {
    $outputLog += "Encountered a problem when trying to download the ISO Mount EXE"
    Write-Output $outputLog
    Return
}

Try {
    ##Install
    $outputLog += "The Windows 10 Upgrade Install has now been started silently in the background. No action from you is required, but please note a reboot will be reqired during the installation prcoess. It is highly recommended you save all of your open files!"
    ## The portable ISO EXE is going to mount our image as a new drive and we need to figure out which drive
    ## that is. So before we mount the image, grab all CURRENT drive letters
    $curLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
    $osVer = (Get-WmiObject -class Win32_OperatingSystem).Caption
    ## If the OS is Windows 10 or 8.1 we can mount the ISO native through Powershell
    If ($osVer -like '*10*' -or $osVer -like '*8.1*') {
        ## Mount the ISO with powershell
        Mount-DiskImage $isoFilePath
    } Else {
        ## Install the portable ISO mount driver
        cmd.exe /c "echo . | $isoMountExe /Install" | Out-Null
        ## Mount the ISO
        cmd.exe /c "echo . | $isoMountExe $isoFilePath" | Out-Null
    }
    ## Have to sleep it here for a second because the ISO takes a second to mount and if we go too quickly
    ## it will think no new drive letters exist
    Start-Sleep 30
    ## Now that the ISO is mounted we should have a new drive letter, so grab all drive letters again
    $newLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
    ## Compare the drive letters from before/after mounting the ISO and figure out which one is new.
    ## This will be our drive letter to work from
    $mountedLetter = (Compare-Object -ReferenceObject $curLetters -DifferenceObject $newLetters).InputObject + ':'
    ## Call setup.exe w/ all of our required install arguments
    Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList "/Auto Upgrade /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogsDir /Telemetry Disable /PostOOBE $setupComplete" -PassThru
} Catch {
    $outputLog += "Setup ran into an issue while attempting to install the $automateWin10Build upgrade."
    If ($osVer -like '*10*' -or $osVer -like '*8.1*') {
        ## Mount the ISO with powershell
        Dismount-DiskImage $isoFilePath
    } Else {
        ## Mount the ISO
        cmd.exe /c "echo . | $isoMountExe /unmountall" | Out-Null
    }
}
