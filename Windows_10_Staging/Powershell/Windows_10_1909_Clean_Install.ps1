#region functions
Function Get-Tree($Path,$Include='*') {
    @(Get-Item $Path -Include $Include -Force) +
    (Get-ChildItem $Path -Recurse -Include $Include -Force) | Sort PSPath -Descending -Unique
}

Function Remove-Tree($Path,$Include='*') {
    Get-Tree $Path $Include | Remove-Item -Force -Recurse
}

Function Install-withProgress {
    $localFolder= (Get-Location).path
    $process = Start-Process -FilePath "$localFolder\Installer.exe" -ArgumentList "/silent /accepteula" -PassThru
    For($i = 0; $i -le 100; $i = ($i + 1) % 100) {
        Write-Progress -Activity "Installer" -PercentComplete $i -Status "Installing"
        Start-Sleep -Milliseconds 100
        If ($process.HasExited) {
            Write-Progress -Activity "Installer" -Completed
            Break
        }
    }
}
#endregion functions

## Make sure a URL has been defined for the Win10 ISO
If (!$automate1909URL) {
    Write-Warning '!ERROR: No ISO URL was defined to download Windows 10 1909. Please define the $automate1909URL variable with a URL to the ISO and then run this again!'
    Break
}

## Check for an Automate LocaitonID. If this machine has an agent and a LocationID set
## we want to make sure to put it back in that location after the win10 image is installed
If (!$locationID) {
    $locationID = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\LabTech\Service" -Name LocationID
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

#region checkDisk
## Check total disk space, make sure there's at least 10GBs free. If there's not then exit. The
## image is only 4.6GBs but once it starts installing / unpacking things it gets a bit bigger.
## 10 is more than we need but just playing it safe.
$spaceAvailable = [math]::round((Get-PSDrive C | Select -ExpandProperty Free) / 1GB,0)
If ($spaceAvailable -lt 10) {
    Write-Warning "You only have a total of $spaceAvailable GBs available, this upgrade needs 10GBs or more to complete successfully"
    Break
}
#region checkDisk


#region checkOSInfo
## Reboots pending can be stored in multiple places. Check them all, if a reboto is pending, exit
## the script. The upgrade will fail anyway w/ a reboot pending.
$rbCheck1 = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore
$rbCheck2 = Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore
$rbCheck3 = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore
If ($rbCheck1 -ne $Null -or $rbCheck2 -ne $Null -or $rbCheck3 -ne $Null){
    Write-Output "This system is pending a reboot, unable to proceed. Please restart your computer and try again."
    Break
} Else {
    Write-Output "Automation has verified there is no reboot pending"
}

## Determine if the machine is x86 or x64
Try {
    If ((Get-WmiObject win32_operatingsystem | Select-Object -ExpandProperty osarchitecture) -eq '64-bit') {
        ## This is the size of the 64-bit file once downloaded so we can compare later and make sure it's complete
        $servFile = 4827807744
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
#endregion checkOSInfo


#region fileChecks
$windowslogs = "$env:windir\LTSvc\packages\OS\Win10-1909-Logs"
$1909Dir = "$env:windir\LTSvc\packages\OS\Win10\1909"
$1909ISO = "$1909Dir\Pro$osArch.1909.iso"
$isoMountURL = "https://drive.google.com/uc?export=download&id=1XpZOQwH6BRwi8FpFZOr4rHlJMDi2HkLb"
$isoMountExe = "$1909Dir\mountIso.exe"
$SetupComplete = "$1909Dir\SetupComplete.cmd"
$SetupCompleteContent = "https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Bat/SetupComplete.cmd"
## Check for the main directory we're going to work from, create it if it doesn't exist
If (!(Test-Path $1909Dir)) {
    New-Item -Path $1909Dir -ItemType Directory | Out-Null
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
$checkISO = Test-Path $1909ISO -PathType Leaf
If ($checkISO) {
    ## If the source ISO size is larger than the downloaded ISO size, nuke the download and start over.
    ## This means the download was interrupted so if we continue the install will fail
    If ($servFile -gt (Get-Item $1909ISO).Length) {
        Remove-Item -Path $1909ISO -Force
        ## We're setting $status to Download for a step further down so we know we still need the ISO downloaded and it's
        ## not ready to install yet. You'll see $status set a few times below and it's all for the same reason.
        $status = 'Download'
        Write-Output "The existing installation files for the 1909 update were incomplete or corrupt. Deleted existing files and started a new download."
    } Else {
        Write-Output "Verified the installation package downloaded successfully!"
        $status = 'Install'
    }
} Else {
    $status = 'Download'
    Write-Output "The required files to install Windows 10 1909 are not present, downloading required files now. This download is 4.6GBs so may take awhile (depending on your connection speed)."
}
#endregion fileChecks


#region download/install
## Now we take that $status we set above and figure out if it needs to be downloaded. If $status
## does -eq Download then run thi section
If ($status -eq 'Download') {
    Try {
        (New-Object System.Net.WebClient).DownloadFile($automate1909URL,$1909ISO)
        ## Again check the downloaded file size vs the server file size
        If ($servFile -gt (Get-Item $1909ISO).Length) {
        Write-Warning "The downloaded size of $1909ISO does not match the server version, unable to install Windows 10 1909."
        } Else {
        Write-Output "Successfully downloaded the 1909 Windows 10 ISO!"
        $status = 'Install'
        }
    } Catch {
        Write-Warning "Encountered a problem when trying to download the Windows 10 1909 ISO"
    }
}

## If the portable ISO mount EXE doesn't exist then download it
Try {
    If (!(Test-Path $isoMountExe -PathType Leaf)) {
        (New-Object System.Net.WebClient).DownloadFile($isoMountURL,$isoMountExe)
    }
} Catch {
    Write-Warning "Encountered a problem when trying to download the ISO Mount EXE"
}

Try {
    ##Install
    If ($status -eq 'Install') {
        Write-Output "The Windows 10 Clean Install has now been started silently in the background. No action from you is required, but please note a reboot will be reqired during the installation prcoess. It is highly recommended you save all of your open files!"
        $localFolder= (Get-Location).path
        ## The portable ISO EXE is going to mount our image as a new drive and we need to figure out which drive
        ## that is. So before we mount the image, grab all CURRENT drive letters
        $curLetters = (Get-PSDrive).Name -match '^[a-z]$'
        $osVer = (Get-WmiObject -class Win32_OperatingSystem).Caption
        ## If the OS is Windows 10 or 8.1 we can mount the ISO native through Powershell
        If ($osVer -like '*10*' -or $osVer -like '*8.1*') {
            ## Mount the ISO with powershell
            Mount-DiskImage $1909ISO
        } Else {
            ## Install the portable ISO mount driver
            cmd.exe /c "echo . | $isoMountExe /Install" | Out-Null
            ## Mount the ISO
            cmd.exe /c "echo . | $isoMountExe $1909ISO" | Out-Null
        }
        ## Have to sleep it here for a second because the ISO takes a second to mount and if we go too quickly
        ## it will think no new drive letters exist
        Start-Sleep 30
        ## Now that the ISO is mounted we should have a new drive letter, so grab all drive letters again
        $newLetters = (Get-PSDrive).Name -match '^[a-z]$'
        ## Compare the drive letters from before/after mounting the ISO and figure out which one is new.
        ## This will be our drive letter to work from
        $mountedLetter = (Compare-Object -ReferenceObject $curLetters -DifferenceObject $newLetters).InputObject + ':'
        ## Call setup.exe w/ all of our required install arguments
        $process = Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList "/Auto Clean /Quiet /Compat IgnoreWarning /ShowOOBE None /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogs /PostOOBE $setupComplete" -PassThru
        ## This is an attempt to show the install status w/ a progress bar for a GUI...it doesn't really work as intended
        ## but it also doesn't break anything so it's just left here for now
        For($i = 0; $i -le 100; $i = ($i + 1) % 100) {
        Write-Progress -Activity "Installer" -PercentComplete $i -Status "Installing"
        Start-Sleep -Milliseconds 100
        If ($process.HasExited) {
            Write-Progress -Activity "Installer" -Completed
            Write-Output "Windows 10 Install process complete!"
            Break
        }
        }
    } Else {
        Write-Warning "Could not find a known status of the var Status. Output: $status"
    }
} Catch {
    Write-Warning "Setup ran into an issue while attempting to install the 1909 upgrade."
}
#endregion download/install