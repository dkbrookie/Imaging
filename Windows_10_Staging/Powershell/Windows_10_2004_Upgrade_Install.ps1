<#
########################
## CW Automate Checks ##
########################

Check for an Automate LocationID. If this machine has an agent and a LocationID set we want to make sure to put 
it back in that location after the win10 image is installed
#>

## Make sure a URL has been defined for the Win10 ISO
If (!$automate2004URL) {
    Write-Warning '!ERROR: No ISO URL was defined to download Windows 10 2004. Please define the $automate2004URL variable with a URL to the ISO and then run this again!'
    Break
}

If (!$locationID) {
    $locationID = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\LabTech\Service" -Name LocationID -EA 0
    If (!$locationID) {
        Write-Warning 'No LocationID found for this machine, no Automate agent was installed on this machine. Using the default location ID of 1.'
        $locationID = 1
    } Else {
        Write-Output "Automate LocationdID is $locationID"
    }
} Else {
    Write-Output "This machine will be added to LocationID $locationID after the OS install"
}

## Make sure an Automate server was defined so we know where to download the agent from
## and where to sign the agent up to after the OS install
If (!$server) {
    Write-Warning '!ERROR: No Automate server address was defined in the $server variable. Please define a server (https://automate.yourcompany.com) in the $server variable before calling this script!'
    Break
}


<#
######################
## Disk Space Check ##
######################

Check total disk space, make sure there's at least $($diskSpaceNeeded)GBs free. If there's not then run the disk cleanup script to see
if we can get enough space. The image is only 4.6GBs but once it starts unpacking / installing it gets quite a bit bigger.
#>

$diskSpaceNeeded = 10
$spaceAvailable = [math]::round((Get-PSDrive C | Select-Object -ExpandProperty Free) / 1GB,0)
If ($spaceAvailable -lt $diskSpaceNeeded) {
    Write-Warning "You only have a total of $spaceAvailable GBs available, this upgrade needs $($diskSpaceNeeded)GBs or more to complete successfully. Starting disk cleanup script to attempt clearing enough space to continue the update..."
    ## Run the disk cleanup script
    (new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Automate-Public/master/Maintenance/Disk%20Cleanup/Powershell/Disk_Cleanup.ps1') | Invoke-Expression
    $spaceAvailable = [math]::round((Get-PSDrive C | Select-Object -ExpandProperty Free) / 1GB,0)
    If ($spaceAvailable -lt $diskSpaceNeeded) {
        Write-Warning "After disk cleanup the available space is now $spaceAvailable GBs, still under $($diskSpaceNeeded)GBs. Please manually clear at least $($diskSpaceNeeded)GBs and try this script again."
        Break
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
        Write-Output "Verified the reboot has already been peformed but Windows failed to clean out the proper registry keys. Manually deleting reboot pending registry keys..."
        ## Delete reboot pending keys
        Remove-Item $windowsUpdateRebootPath1 -Force -ErrorAction Ignore
        Remove-Item $windowsUpdateRebootPath2 -Force -ErrorAction Ignore
        Remove-ItemProperty -Path $fileRenamePath -Name PendingFileRenameOperations -Force -ErrorAction Ignore
        Remove-Item "$LTSvc\win10UpgradeReboot.txt" -Force -ErrorAction Ignore
        Write-Output "Reboot registry key deletes completed."
    } Else {
        Write-Output "This system is pending a reboot. Reboot reason: $rebootReason"
        Write-Output "Reboot initiated, exiting script, but this script will run again shortly to pick up where this left off if triggered from CW Automate."
        shutdown /r /f /c "This machines requires a reboot to continue upgrading to Windows 10 2004."
        Set-Content -Path "$LTSvc\win10UpgradeReboot.txt" -Value 'True'
        Write-Output "!REBOOT INITIATED:"
        Break
    }
} Else {
    Write-Output "Verified there is no reboot pending"
    Remove-Item "$LTSvc\win10UpgradeReboot.txt" -Force -ErrorAction Ignore
}


<#
##############
## OS Check ##
##############
#>

Try {
    If ((Get-WmiObject win32_operatingsystem | Select-Object -ExpandProperty osarchitecture) -eq '64-bit') {
        ## This is the size of the 64-bit file once downloaded so we can compare later and make sure it's complete
        $servFile = 5201768448
        $osArch = 'x64'
    } Else {
        ## This is the size of the 32-bit file once downloaded so we can compare later and make sure it's complete
        $servFile = 3266728252
        $osArch = 'x86'
    }
} Catch {
    Write-Warning 'Unable to determine OS architecture'
    Return
}


<#
#################
## File Checks ##
#################
#>

$windowslogs = "$env:windir\LTSvc\packages\OS\Win10-2004-Logs"
$2004Dir = "$env:windir\LTSvc\packages\OS\Win10\2004"
$2004ISO = "$2004Dir\Pro$osArch.2004.iso"
$isoMountURL = "https://drive.google.com/uc?export=download&id=1XpZOQwH6BRwi8FpFZOr4rHlJMDi2HkLb"
$isoMountExe = "$2004Dir\mountIso.exe"
$SetupComplete = "$2004Dir\SetupComplete.cmd"
$SetupCompleteContent = "https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Bat/SetupComplete.cmd"
## Check for the main directory we're going to work from, create it if it doesn't exist
If (!(Test-Path $2004Dir)) {
    New-Item -Path $2004Dir -ItemType Directory | Out-Null
}

## This file contains all of our scripts to run POST install. It's slim right now but the idea is to 
## add in app deployments / customizations all in here.
(New-Object System.Net.WebClient).DownloadFile($SetupCompleteContent,$SetupComplete)

## Here we're adding the agent install script to the file above. We're adding this to the file AFTER it's
## downloaded because we need to change the locationID to the current locationID of the machine to make
## sure the agent installs it back to the right client.
Add-Content -Path $SetupComplete -Value "
REM Install Automate agent
powershell.exe -ExecutionPolicy Bypass -Command ""& { (new-object Net.WebClient).DownloadString('https://bit.ly/LTPoSh') | iex; Install-LTService -Server $server -LocationID $locationID }"""

## Check to see if the ISO file is already present
$checkISO = Test-Path $2004ISO -PathType Leaf
If ($checkISO) {
    ## If the source ISO size is larger than the downloaded ISO size, nuke the download and start over.
    ## This means the download was interrupted so if we continue the install will fail
    If ($servFile -gt (Get-Item $2004ISO).Length) {
        Remove-Item -Path $2004ISO -Force
        ## We're setting $status to Download for a step further down so we know we still need the ISO downloaded 
        ## and it's not ready to install yet. You'll see $status set a few times below and it's all for the same reason.
        $status = 'Download'
        Write-Output "The existing installation files for the 2004 update were incomplete or corrupt. Deleted existing files and started a new download."
    } Else {
        Write-Output "Verified the installation package downloaded successfully!"
        $status = 'Install'
    }
} Else {
    $status = 'Download'
    Write-Output "The required files to install Windows 10 2004 are not present, downloading required files now. This download is 4.6GBs so may take awhile (depending on your connection speed)."
}


<#
########################
## Download & Install ##
########################

Now we take that $status we set above and figure out if it needs to be downloaded. If $status does -eq Download 
then run this section
#>

If ($status -eq 'Download') {
    Try {
        (New-Object System.Net.WebClient).DownloadFile($automate2004URL,$2004ISO)
        ## Again check the downloaded file size vs the server file size
        If ($servFile -gt (Get-Item $2004ISO).Length) {
            Write-Warning "The downloaded size of $2004ISO does not match the server version, unable to install Windows 10 2004."
            $status = 'Failed'
        } Else {
            Write-Output "Successfully downloaded the 2004 Windows 10 ISO!"
            $status = 'Install'
        }
    } Catch {
        Write-Warning "Encountered a problem when trying to download the Windows 10 2004 ISO"
        Break
    }
}

## If the portable ISO mount EXE doesn't exist then download it
Try {
    If (!(Test-Path $isoMountExe -PathType Leaf)) {
        (New-Object System.Net.WebClient).DownloadFile($isoMountURL,$isoMountExe)
    }
} Catch {
    Write-Warning "Encountered a problem when trying to download the ISO Mount EXE"
    Break
}

Try {
    ##Install
    If ($status -eq 'Install') {
        Write-Output "The Windows 10 Upgrade Install has now been started silently in the background. No action from you is required, but please note a reboot will be reqired during the installation process. It is highly recommended you save all of your open files!"
        $localFolder = (Get-Location).path
        ## The portable ISO EXE is going to mount our image as a new drive and we need to figure out which drive
        ## that is. So before we mount the image, grab all CURRENT drive letters
        $curLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
        $osVer = (Get-WmiObject -class Win32_OperatingSystem).Caption
        ## If the OS is Windows 10 or 8.1 we can mount the ISO native through Powershell
        If ($osVer -like '*10*' -or $osVer -like '*8.1*') {
            ## Mount the ISO with powershell
            Mount-DiskImage $2004ISO
        } Else {
            ## Install the portable ISO mount driver
            cmd.exe /c "echo . | $isoMountExe /Install" | Out-Null
            ## Mount the ISO
            cmd.exe /c "echo . | $isoMountExe $2004ISO" | Out-Null
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
        Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList "/Auto Upgrade /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogs /Telemetry Disable /PostOOBE $setupComplete" -PassThru
        Write-Output "Setup.exe executed with the follow arguments: /Auto Upgrade /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogs /Telemetry Disable /PostOOBE $setupComplete -PassThru"
    } ElseIf ($status -eq 'Failed') {
        Write-Warning 'Windows 10 Build 2004 install has failed'
    } ElseIf ($status -eq 'Download') {
        Write-Warning '$status still equals Downlaod but should have been changed to Install or Failed by this point. Please check the script.'
    } Else {
        Write-Warning "Could not find a known status of the var Status. Output: $status"
    }
} Catch {
    Write-Warning "Setup ran into an issue while attempting to install the 2004 upgrade."
    If ($osVer -like '*10*' -or $osVer -like '*8.1*') {
        ## Mount the ISO with powershell
        Dismount-DiskImage $2004ISO
    } Else {
        ## Mount the ISO
        cmd.exe /c "echo . | $isoMountExe /unmountall" | Out-Null
    }
}