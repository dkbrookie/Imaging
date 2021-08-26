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

# Make sure a URL has been defined for the Win10 ISO on Enterprise versions
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
$isoFilePath = "$downloadDir\$isoHash.iso"
$hashFilePath = "$downloadDir\filehash.txt"
$jobIdFilePath = "$downloadDir\jobId.txt"

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
    param ([string]$Path, [string]$Hash)
    Return (Get-FileHash -Algorithm SHA256 -Path $Path) -eq $Hash
}

function Remove-UpgradeFiles {
    Remove-Item -Path $isoFilePath -EA 0
    Remove-Item -Path $hashFilePath -EA 0
    Remove-Item -Path $jobIdFilePath -EA 0
}

function Get-NecessaryFilesExist {
    $hashFileExists = Test-Path -Path $hashFilePath
    $isoFileExists = Test-Path -Path $isoFilePath
    Return $hashFileExists -and $isoFileExists
}

function Start-FileDownload {
    $out += @()

    # Get URL
    If ($isEnterprise) {
        $downloadUrl = $automateURL
        $fileHash = $automateIsoHash
    } Else {
        (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.GetWindowsIsoUrl.ps1') | Invoke-Expression
        $fido = Get-WindowsIsoUrl -Rel $automateWin10Build

        $downloadUrl = $fido.Link
        $fileHash = $fido.FileHash
    }

    <#
    Check total disk space, make sure there's at least 10GBs free. If there's not then run the disk cleanup script to see
    if we can get enough space. The image is only 4.6GBs but once it starts installing / unpacking things it gets quite a
    bit bigger. 10 GBs is more than we need but just playing it safe.
    #>

    $transfer = $Null
    $spaceAvailable = [math]::round((Get-PSDrive C | Select-Object -ExpandProperty Free) / 1GB, 0)

    If ($spaceAvailable -lt 10) {
        $out += "You only have a total of $spaceAvailable GBs available, this upgrade needs 10GBs or more to complete successfully. Starting disk cleanup script to attempt clearing enough space to continue the update..."

        ## Run the disk cleanup script
        (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Automate-Public/master/Maintenance/Disk%20Cleanup/Powershell/Disk_Cleanup.ps1') | Invoke-Expression

        $spaceAvailable = [math]::round((Get-PSDrive C | Select-Object -ExpandProperty Free) / 1GB,0)

        If ($spaceAvailable -lt 10) {
            # Disk is still too full :'(
            $out = "!Error: After disk cleanup the available space is now $spaceAvailable GBs, still under 10GBs. Please manually clear at least 10GBs and try this script again." + $out
            Return @{
                Output = $out
                DiskFull = $True
            }
        }
    }

    Try {
        $transfer = Start-BitsTransfer -Source $downloadUrl -Destination $isoFilePath -TransferPolicy Standard -Asynchronous -Description $fileHash
    } Catch {
        $out += (Get-ErrorMessage $_ "!Error: Could not start the transfer!")
        Return @{
            Output = $out
            TransferError = $True
        }
    }

    Return @{
        FileHash = $fileHash
        JobId = $transfer.JobId
        Output = $out
        DiskFull = $False
        TransferError = $False
    }
}

<#
######################
## Check OS Version ##
######################

This script should only execute if this machine is a windows 10 machine that is on a version less than the requested version
#>

# Call in Get-WindowsVersion
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-WindowsVersion.ps1') | Invoke-Expression
$windowsVersion = Get-WindowsVersion
$osName = $windowsVersion.SimplifiedName
$orderOfWin10Versions = $windowsVersion.OrderOfWin10Versions
$version = $windowsVersion.Version
$currentVersionIndex = $orderOfWin10Versions.IndexOf($version)
$wantedVersionIndex = $orderOfWin10Versions.IndexOf($automateWin10Build)

If ($osName -ne 'Windows 10') {
    $outputLog += "This does not appear to be a Windows 10 machine. This script only supports Windows 10 machines. This is: $osName"
    Invoke-Output $outputLog
    Return
}

# If the current version is not in the list of win 10 versions, it's not supported
If ($currentVersionIndex -eq -1) {
    $outputLog += "Something went wrong determining the current version of windows, it does not appear to be in the list.. Maybe a new version of windows 10? This script supports up to $($orderOfWin10Versions[-1]) This is: $version. If you need to add a new version of windows, edit this: https://github.com/dkbrookie/PowershellFunctions/blob/master/Function.Get-WindowsVersion.ps1"
    Invoke-Output
    Return
}

# If the wanted version is not in the list of win 10 versions, it's not supported
If ($wantedVersionIndex -eq -1) {
    $outputLog += "Something went wrong determining the wanted version of windows, it does not appear to be in the supported list.. Maybe a new version of windows 10? This script supports up to $($orderOfWin10Versions[-1]) You requested: $automateWin10Build. If you need to add a new version of windows, edit this: https://github.com/dkbrookie/PowershellFunctions/blob/master/Function.Get-WindowsVersion.ps1"
    Invoke-Output
    Return
}

If ($currentVersionIndex -ge $wantedVersionIndex) {
    $outputLog += "The current version on this machine, $version, is less than or equal to the requested version, $automateWin10Build, so it doesn't make sense to continue. Exiting Script."
    Invoke-Output $outputLog
    Return
}

<#
######################
# Existing Downloads #
######################

Check for a pending or completed bits transfer.
If pending and transferred, complete transfer and continue.
If pending and transferring, exit script.
If hash check fails, remove files and continue.
If no existing file or pending download, continue.
#>

<# --------------------------------------------------- Step 1 ------------------------------------------------------- #>
# Determine status of bits-transfer: Start one if doesn't exist, exit if still transferring, resume if suspended, start over if in bad state, continue if completed
$jobIdFileExists = Test-Path -Path $jobIdFilePath
$hashFileExists = Test-Path -Path $hashFilePath
$isoFileExists = Test-Path -Path $isoFilePath
$transfer = $Null

# If a jobId and hash files exists, attempt to get the transfer
If ($jobIdFileExists) {
    $jobId = Get-Content -Path $jobIdFilePath
    $transfer = Get-BitsTransfer -JobId $jobId

    # If there is an existing transfer
    If ($transfer -and !$isoFileExists) {
        $outputLog += "There is an existing transfer of $automateWin10Build."

        $hash = $transfer.Description

        If (!$hash) {
            # If the transfer doesn't have a hash on it's description somehow...
            If ($hashFileExists) {
                # ...and the hash file exists, get it from there
                $hash = Get-Content -Path $hashFilePath
            } ElseIf ($isEnterprise) {
                # ...or if the machine is Enterprise, we can probably trust the hash from $automateIsoHash
                $hash = $automateIsoHash
            } Else {
                # Can't get the hash from anywhere.. Can't verify integrity of file... must abort transfer and start over
                $outputLog += "No hash is available to check the integrity of the file once download. Aborting transfer and starting over."

                Try {
                    $transfer | Remove-BitsTransfer
                    # Null out the variable so that the next checks correctly identify that there is no transfer
                    $transfer = $Null
                } Catch {
                    $outputLog += (Get-ErrorMessage $_ 'For some reason there was an error when attempting to remove the existing transfer. This transfer may need to be removed manually. Continuing.')
                }
            }
        } Else {
            $outputLog += "Successfully retrieved ISO hash."

            If (!$hashFileExists) {
                # The hash file should exist, but just in case it got deleted or something...
                $outputLog += "For some reason the hash file is missing.. Creating it now."
                New-Item -Path $hashFilePath -Value $hash
            } ElseIf ((Get-Content -Path $hashFilePath) -ne $hash) {
                # The hash file exists, but the hash in the transfer doesn't match the hash in the file. Replace file.
                New-Item -Path $hashFilePath -Value $hash -Force
            }
        }

        <# Removed probably unnecessary code relating to strange maaayybe potential states here. See bottom of script for removed code if it's necessary. #>

        # The transfer could have disappeared in the last step, so check again
        If ($transfer -and $transfer.JobState) {
            # There is an existing transfer...
            Switch ($transfer.JobState) {
                # ...and that transfer is still transferring
                ('Transferring' -or 'Queued' -or 'Connecting') {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently $($transfer.JobState). Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # Might need to count transient errors and increase priority or transferpolicy after a certain number of errors
                'TransientError' {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently $($transfer.JobState). This is usually not a problem and it should correct itself. Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # ...or that transfer is suspended
                'Suspended' {
                    $outputLog += "Win10 $automateWin10Build is still transferring, but the transfer was suspended. Attempting to resume."

                    Try {
                        $transfer | Resume-BitsTransfer -Asynchronous
                    } Catch {
                        $outputLog += Get-ErrorMessage $_ "Could not resume the suspended transfer."
                        Invoke-Output $outputLog
                        Return
                    }

                    If ($transfer.JobState -eq 'Suspended') {
                        $outputLog += "For some reason, the transfer is still suspended. Some other script or person may have interfered with this download. Exiting Script."
                        Invoke-Output $outputLog
                        Return
                    }
                }

                # ...or that transfer has completed
                'Transferred' {
                    # The transfer has finished, but it must be "completed" before the ISO file exists
                    Try {
                        $transfer | Complete-BitsTransfer
                    } Catch {
                        $outputLog += (Get-ErrorMessage $_ "Win10 $automateWin10Build successfully finished downloading, but there was an error completing the transfer and saving the file to disk.")
                    }

                    $outputLog += "Win10 $automateWin10Build has finished downloading. Will attempt installation now!"
                }

                Default {
                    $outputLog += "The transfer job has entered an unexpected state of $($transfer) and the script can't continue. On this machine, check the job with JobId $jobId"
                    Invoke-Output $outputLog
                    Return
                }
            }
        }
    } ElseIf ($isoFileExists) {
        $outputLog += "Somehow, there is an existing transfer and also an ISO file. This should not have been allowed to occurr. This machine needs manual intervention, or the script needs to be adjusted. Exiting Script."
        Invoke-Output $outputLog
        Return
    } Else {
        # There is no existing transfer, but the jobId file exists, we shouldn't have ended up in this state, so remove existing files and start over
        $outputLog += "For some reason, it appears that the transfer has disappeared before completion. Deleting any files that were saved from the last attempt and will retry from the beginning."
        Remove-UpgradeFiles
    }
}

# Files could have been deleted or created in the last step, so check to see if all the necessary files exist for installation. Only need ISO and hash files to continue.
If (!Get-NecessaryFilesExist) {
    # Just in case Complete-BitsTransfer takes a minute... It shouldn't, it's just a rename from a .tmp file, but juuust in case since we're about to potentially delete
    # the downloaded ISO!
    Start-Sleep -Seconds 30

    # Check again
    If (!Get-NecessaryFilesExist) {
        # We're either missing the ISO or the hash file, and both are needed at this point.
        Remove-UpgradeFiles
    }
}

<#
##########################
FIRST RUN - INIT DOWNLOAD
##########################
#>

If (!Get-NecessaryFilesExist) {
    # And if the necessary files don't exist at this point, that means we're probably just starting, and we're in a fresh and clean state!
    $outputLog += "Did not find any existing files. Starting transfer of $automateWin10Build"
    $newTransfer = Start-FileDownload

    # Disk might be full
    If ($newTransfer.DiskFull) {
        $outputLog = $newTransfer.Output + $outputLog
        Invoke-Output $outputLog
        Return
    }

    # Starting the bits transfer might have errored out
    If ($newTransfer.TransferError) {
        $outputLog = $newTransfer.Output + $outputLog
        Invoke-Output $outputLog
        Return
    }

    Try {
        $outputLog += 'Creating new files to cache the BitsTransfer JobId and FileHash'
        New-Item -Path $hashFilePath -Value $newTransfer.FileHash -Force
        New-Item -Path $jobIdFilePath -Value $NewTransfer.JobId -Force
    } Catch {
        $outputLog += Get-ErrorMessage $_ 'Experienced an error when attempting to create JobId and FileHash files'
    }

    If (!(Test-Path -Path $jobIdFilePath)) {
        $outputLog += 'Could not create JobId file! Cannot continue without JobId file! Removing Transfer and any files.'
        Get-BitsTransfer -JobId $newTransfer.JobId | Remove-BitsTransfer
        Remove-UpgradeFiles
        Invoke-Output $outputLog
        Return
    }

    If (!(Test-Path -Path $hashFilePath)) {
        $outputLog += 'Could not create FileHash file. This is recoverable, there will be chances to grab this from the transfer once it has completed.'
    }

    # Finished starting up the transfer, can now exit script. Must have all necessary files ready to go before we move on from here.
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

## Check to see if the ISO file is already present
If (Test-Path $isoFilePath -PathType Leaf) {
    ## If the ISO hash does not match the expected hash, delete the downloaded file and start over.
    If ($servFile -gt (Get-Item $isoFilePath).Length) {
        Remove-Item -Path $isoFilePath -Force
        ## We're setting $status to Download for a step further down so we know we still need the ISO downloaded
        ## and it's not ready to install yet. You'll see $status set a few times below and it's all for the same reason.
        $status = 'Download'
        $outputLog += "The existing installation files for the $automateWin10Build update were incomplete or corrupt. Deleted existing files and started a new download."
    } Else {
        $outputLog += "Verified the installation package downloaded successfully!"
        $status = 'Install'
    }
} Else {
    $status = 'Download'
    $outputLog += "The required files to install Windows 10 $automateWin10Build are not present, downloading required files now. This download is 4.6GBs so may take awhile (depending on your connection speed)."
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

        ## Again check the downloaded file size vs the server file size
        # If ($servFile -gt (Get-Item $isoFilePath).Length) {
        #     $outputLog += "The downloaded size of $isoFilePath does not match the server version, unable to install Windows 10 $automateWin10Build."
        #     $status = 'Failed'
        # } Else {
        #     $outputLog += "Successfully downloaded the $automateWin10Build Windows 10 ISO!"
        #     $status = 'Install'
        # }
    } Catch {
        $outputLog += "Encountered a problem when trying to download the Windows 10 $automateWin10Build ISO"
        Write-Output $outputLog
        Return
    }
}

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
    If ($status -eq 'Install') {
        $outputLog += "The Windows 10 Upgrade Install has now been started silently in the background. No action from you is required, but please note a reboot will be reqired during the installation prcoess. It is highly recommended you save all of your open files!"
        $localFolder = (Get-Location).path
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
    } ElseIf ($status -eq 'Failed') {
        $outputLog += "Windows 10 Build $automateWin10Build install has failed"
    } ElseIf ($status -eq 'Download') {
        $outputLog += '$status still equals Downlaod but should have been changed to Install or Failed by this point. Please check the script.'
    } Else {
        $outputLog += "Could not find a known status of the var Status. Output: $status"
    }
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


        <#
        Commenting this next bit out for now.. It's complex and I don't think it's necessary.. I don't think we'll ever end up in a state where the transfer still exists and
        the resulting ISO exists simultaneously, due to the way BitsTransfer works. Leaving it here just in case that situation pops up. If this does ever end up in-use,
        make sure to wrap the switch statement below it in an `If ($skipTransferSwitch) {}`

        Moved to bottom of script and put this in it's place:
        <# Removed probably unnecessary code relating to strange maaayybe potential states here. See bottom of script for removed code if it's necessary. #>
        #>

        # Check to make sure there's not an existing ISO. There shouldn't be an existing ISO AND and an ongoing transfer, so we should never hit this, but you never know..
        # We could have started a transfer with one ISO, and then swapped ISO and hash, then the script runs again and finishes the download but fails to install.
        # In that case, the ISO would exist but might not match the provided hash. Microsoft has been known to slipstream rollups into existing builds without issuing
        # a new build ID.
        # If (!$hash -and $hashFileExists) {
        #     # Hash is missing from the transfer for some reason. Attempt to get hash from file if it exists.
        #     $hash = Get-Content -Path $hashFilePath
        #     $hashCameFromFile = $true
        # }
        # If ($isoFileExists) {
        #     # The iso exists...
        #     $outputLog += "Somehow, there is an existing transfer job for this download, and also an existing ISO file that this transfer job would replace. Checking ISO hash."

        #     If ($hash -and (Get-HashCheck -Path $isoFilePath -Hash $hash)) {
        #         # ...and the hash exists, and the hash check matches, iso download is already complete, so we don't need the transfer handling at all
        #         $skipTransferSwitch = $True

        #         $outputLog += "Win10 $automateWin10Build has already been downloaded and the hash matches! Cancelling transfer!"

        #         Try {
        #             $transfer | Remove-BitsTransfer
        #         } Catch {
        #             $outputLog += (Get-ErrorMessage $_ 'For some reason there was an error when attempting to remove the existing transfer. This transfer may need to be removed manually. Continuing.')
        #         }
        #     } ElseIf (!$isEnterprise) {
        #         # If machine is not an enterprise machine, the hash changes per download link, so we need to be a little more thorough
        #         If (!$hashCameFromFile) {
        #             # Hash check came from transfer, not description.. maybe there's a different hash in the file? If that one matches, cancel transfer and use the file
        #             $hash = Get-Content -Path $hashFilePath
        #             If ($hash -and (Get-HashCheck -Path $isoFilePath -Hash $hash)) {
        #                 # The hash exists, and the hash check matches, iso download is already complete, so we don't need the transfer handling at all
        #                 $outputLog += "Win10 $automateWin10Build has already been downloaded and the hash matches! Cancelling transfer!"
        #                 $skipTransferSwitch = $True

        #                 Try {
        #                     $transfer | Remove-BitsTransfer
        #                 } Catch {
        #                     $outputLog += (Get-ErrorMessage $_ 'For some reason there was an error when attempting to remove the existing transfer. This transfer may need to be removed manually. Continuing.')
        #                 }
        #             } Else {

        #             }
        #         }
        #     } Else {
        #         # ISO exists and machine is Enterprise, so we can be reasonably sure that the hash SHOULD BE the one provided in $automateIsoHash
        #         $hash = $automateIsoHash

        #         If (Get-HashCheck -Path $isoFilePath -Hash $hash) {
        #             # The hash exists, and the hash check matches, iso download is already complete, so we don't need the transfer handling at all
        #             $outputLog += "Win10 $automateWin10Build has already been downloaded and the hash matches! Cancelling transfer!"
        #             $skipTransferSwitch = $True

        #             Try {
        #                 $transfer | Remove-BitsTransfer
        #             } Catch {
        #                 $outputLog += (Get-ErrorMessage $_ 'For some reason there was an error when attempting to remove the existing transfer. This transfer may need to be removed manually. Continuing.')
        #             }
        #         } Else {
        #             # ISO exists, machine is enterprise, and hash does not match. Remove ISO and leave transfer going. Write new hash to file and to transfer description
        #             # for easier decision next time.
        #             Remove-UpgradeFiles
        #             New-Item -Path $hashFilePath -Value $hash
        #             Set-BitsTransfer -Description $hash
        #         }
        #     }
        # }
