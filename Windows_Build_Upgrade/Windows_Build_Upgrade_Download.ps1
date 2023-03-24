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
# TODO: Switch this to master URL after merge
# Call in Get-WindowsIsoUrlByBuild.ps1
$WebClient.DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/add-iso-urls/Get-WindowsIsoUrlByBuild.ps1') | Invoke-Expression
# Call in Get-IsDiskFull
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsDiskFull.ps1') | Invoke-Expression
# Call in Get-DesktopWindowsVersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression

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
    Invoke-Output $outputLog
    Return
}

# If both $releaseChannel and $targetBuild are specified
If ($releaseChannel -and $targetBuild) {
    $outputLog = "!Error: `$releaseChannel of '$releaseChannel' and `$targetBuild of '$targetBuild' were both specified. You should specify only one of these." + $outputLog
    Invoke-Output $outputLog
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
    Invoke-Output $outputLog
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
    Invoke-Output $outputLog
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
    Invoke-Output $outputLog
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
        Invoke-Output $outputLog
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
        Invoke-Output $outputLog
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
        Invoke-Output $outputLog
        Return
    }

    $targetVersion = $windowsBuildToVersionMap[$targetBuild]

    If (!$targetVersion) {
        $outputLog += "No value for `$targetVersion could be determined from `$targetBuild. This script needs to be updated to handle $targetBuild! Please update script!"
        Invoke-Output $outputLog
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
    Invoke-Output $outputLog
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
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$winSetupErrorKey = 'WindowsSetupError'
$downloadErrorKey = 'BitsTransferError'
$jobIdKey = "JobId"

Try {
    $isoUrl = Get-WindowsIsoUrlByBuild -Build $targetBuild
} Catch {
    $outputLog = (Get-ErrorMessage $_ "!Error: Could not get url for '$targetBuild'") + $outputLog
    Invoke-Output $outputLog
    Return
}

# Suss out the expected hash from the isos URL
$acceptableHash = (($isoUrl -split '_')[1] -split '\.')[0]
If (!$acceptableHash) {
    $outputLog = (Get-ErrorMessage $_ "!Error: There is no HASH defined for build '$targetBuild' in the script! Please edit the script and define an expected file hash for this build!") + $outputLog
    Invoke-Output $outputLog
    Return
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

function Start-FileDownload {
    $out += @()
    $transfer = $Null

    # Check total disk space, make sure there's at least 27GBs free.
    $diskCheck = Get-IsDiskFull -MinGb 27

    If ($diskCheck.DiskFull) {
        $out += $diskCheck.Output
        Return $diskCheck
    }

    Try {
        $transfer = Start-BitsTransfer -Source $isoUrl -Destination $isoFilePath -TransferPolicy Standard -Asynchronous
    } Catch {
        $out += Get-ErrorMessage $_ "!Error: Could not start the transfer!"
        Return @{
            Output = $out
            TransferError = $True
        }
    }

    Return @{
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

This script should only execute if this machine is a desktop windows machine that is on a version less than the requested version
#>

Try {
    $lessThanRequestedBuild = Get-DesktopWindowsVersionComparison -LessThan $targetBuild
} Catch {
    $outputLog = (Get-ErrorMessage $_ "!Error: There was an issue when comparing the current version of windows to the requested one. Cannot continue.") + $outputLog
    Invoke-Output $outputLog
    Return
}

$outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetBuild
If (!$lessThanRequestedBuild.Result) {
    If (Test-Path -Path $isoFilePath -PathType Leaf) {
        $outputLog += "An ISO for the requested version exists but it is unnecessary. Cleaning up to reclaim disk space."
        Remove-Item -Path $isoFilePath -Force -EA 0 | Out-Null
    }

    $outputLog = "!Success: This upgrade is unnecessary." + $outputLog
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
If no existing file or pending download, continue.
#>

# If a jobId exists in the registry
$jobIdExists = Test-RegistryValue -Name $jobIdKey

# If a jobId exists, but ISO doesn't exist, attempt to get the transfer
If ($jobIdExists -and !(Test-Path -Path $isoFilePath -PathType Leaf)) {
    $jobId = Get-RegistryValue -Name $jobIdKey
    $transfer = Get-BitsTransfer -JobId $jobId -EA 0

    # If there is an existing transfer
    If ($transfer) {
        $outputLog += "There is an existing transfer of $targetBuild."

        # The transfer could have disappeared in the last step, so check again
        If ($transfer -and $transfer.JobState) {
            # There is an existing transfer...
            $jobState = $transfer.JobState

            Switch ($jobState) {
                # ...and that transfer is still transferring
                'Transferring' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Transferring'. Exiting script." + $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Queued' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Queued'. Exiting script." + $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Connecting' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Connecting'. Exiting script." + $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # Might need to count transient errors and increase priority or transferpolicy after a certain number of errors
                'TransientError' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently TransientError. This is usually not a problem and it should correct itself. Exiting script." + $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                'Error' {
                    $description = $transfer.ErrorDescription
                    Write-RegistryValue -Name $downloadErrorKey $description

                    If ($description -like '*Range protocol*') {
                        # We know this error and unfortunately, it can be environment specific as firewalls are capable of stripping the 'Content-Range' header
                        # which is required for bitstransfer to work. Windows won't auto-retry this one but it should, so let's force a retry
                        $outputLog = "!Warning: The Transfer has entered an error state. We know this error and unfortunately, it can be environment specific (subject to change) as firewalls are capable of stripping the 'Content-Range' header which is required for bitstransfer to work. Retrying." + $outputLog
                        $transfer | Remove-BitsTransfer | Out-Null
                        Remove-RegistryValue -Name $jobIdKey
                    } Else {
                        # Not retrying as we want this machine to stand out so we can assess
                        $outputLog = "!Error: The transfer job has experienced and unknown error and the script can't continue. This machine should be checked out manually. Remove the existing job and assess the reason. Check the job with JobId '$jobId'. Exiting Script. The error description is: $description" + $outputLog
                        Invoke-Output $outputLog
                        Return
                    }
                }

                # ...or that transfer is suspended
                'Suspended' {
                    $outputLog += "Windows $targetBuild is still transferring, but the transfer is suspended. Attempting to resume."

                    Try {
                        $transfer | Resume-BitsTransfer -Asynchronous | Out-Null
                    } Catch {
                        $outputLog = (Get-ErrorMessage $_ "!Error: Could not resume the suspended transfer.") + $outputLog
                        Invoke-Output $outputLog
                        Return
                    }

                    $jobState = $transfer.JobState

                    If ($jobState -eq 'Suspended') {
                        $outputLog = "!Warning: For some reason, the transfer is still suspended. Some other script or person may have interfered with this download. Sometimes it just takes a minute to restart. Exiting Script." + $outputLog
                        Invoke-Output $outputLog
                        Return
                    } ElseIf ($jobState -like '*Error*') {
                        $outputLog += "The Transfer has entered an error state. The error state is $jobState. Removing transfer and files and starting over."
                        $transfer | Remove-BitsTransfer | Out-Null
                        Remove-RegistryValue -Name $jobIdKey
                    } Else {
                        $outputLog = "!Warning: Successfully resumed transfer. The transfer's state is currently '$jobState.' Exiting script." + $outputLog
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
                        $outputLog += Get-ErrorMessage $_ "Windows $targetBuild successfully finished downloading, but there was an error completing the transfer and saving the file to disk."
                    }

                    $outputLog += "Windows $targetBuild has finished downloading!"

                    $outputLog += "Checking hash of ISO file."

                    If (!(Get-HashCheck -Path $isoFilePath)) {
                        $hash = (Get-FileHash -Path $isoFilePath -Algorithm 'SHA256').Hash
                        $outputLog = "!Error: The hash doesn't match!! The ISO's hash is -> $hash" + $outputLog
                    } Else {
                        $outputLog = "!Success: The hash matches! The file is all good! Removing cached JobId from registry, changing LastWriteTime to NOW (so that disk cleanup doesn't delete it), and exiting Script!" + $outputLog
                        Remove-RegistryValue -Name $jobIdKey
                        # We can remove any download errors we experienced along the way as they aren't important anymore
                        Remove-RegistryValue -Name $downloadErrorKey
                        # Change the LastWriteTime to now b/c otherwise, the disk cleanup script will wipe it out
                        (Get-Item -Path $isoFilePath).LastWriteTime = Get-Date
                    }

                    Invoke-Output $outputLog
                    Return
                }

                Default {
                    $description = $transfer.ErrorDescription
                    $msg = "The ISO transfer job has entered an unexpected state of '$jobState' and the script can't continue. This machine should be checked out manually."

                    If ($description) {
                        $msg += " Error Description: $description"
                        Write-RegistryValue -Name $downloadErrorKey $description
                    } Else {
                        Write-RegistryValue -Name $downloadErrorKey $msg
                    }

                    # Not retrying as we want this machine to stand out so we can assess
                    $outputLog = "!Error: $msg Remove the existing job and assess the reason. Check the job with JobId '$jobId'. Exiting Script." + $outputLog
                    Invoke-Output $outputLog
                    Return
                }
            }
        }
    } Else {
        $outputLog += "Transfer was started, there is JobId cached, but there is no ISO and there is no existing transfer. The transfer or the ISO must have gotten deleted somehow. Cleaning up and restarting from the beginning."
        Remove-RegistryValue -Name $jobIdKey
    }
}

<#
########################################
4 last checks before triggering download
########################################
#>

# We don't want this to repeatedly download if the machine is having an issue, so check for existence of setup errors
If (Test-RegistryValue -Name $winSetupErrorKey) {
    $setupErr = Get-RegistryValue -Name $winSetupErrorKey
    $outputLog = "!Error: Windows setup experienced an error upon installation. This should be manually assessed and you should clear the value at $regPath\$winSetupErrorKey in order to make the script try again. The error output is $setupErr" + $outputLog
    Invoke-Output $outputLog
    Return
}

# There could also be an error at a location from a previous version of this script, identified by version ID 20H2
If (Test-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError') {
    $setupErr = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError'
    $setupExitCode = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupExitCode'
    $outputLog = "!Error: Windows setup experienced an error upon last installation. This should be manually assessed and you should delete HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade\WindowsSetupError in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'" + $outputLog
    Invoke-Output $outputLog
    Return
}

# Check that this upgrade hasn't already occurred. No need to download iso if installation has already occurred
If ((Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)) {
    $outputLog = "!Warning: This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. Exiting script." + $outputLog
    Invoke-Output $outputLog
    Return
}

# ISO file could have been deleted or created in the last step, so check again.
If (!(Test-Path -Path $isoFilePath -PathType Leaf)) {
    # Just in case Complete-BitsTransfer takes a minute... It shouldn't, it's just a rename from a .tmp file, but juuust in case
    Start-Sleep -Seconds 10
}

<#
##########################
FIRST RUN - INIT DOWNLOAD
##########################
#>

# If the ISO doesn't exist at this point, let's just start fresh.
If (!(Test-Path -Path $isoFilePath -PathType Leaf)) {
    Remove-RegistryValue -Name $jobIdKey

    # We're in a fresh and clean state, and ready to start a transfer.
    $outputLog += "Did not find an existing ISO or transfer. Starting transfer of $targetBuild."
    $newTransfer = Start-FileDownload

    # Disk might be full
    If ($newTransfer.DiskFull) {
        $outputLog = ("!Error: " + $newTransfer.Output) + $outputLog
        Invoke-Output $outputLog
        Return
    }

    # Starting the bits transfer might have errored out
    If ($newTransfer.TransferError) {
        $outputLog = ("!Error: " + $newTransfer.Output) + $outputLog
        Invoke-Output $outputLog
        Return
    }

    Try {
        $outputLog += 'Creating registry value to cache the BitsTransfer JobId'
        $outputLog += Write-RegistryValue -Name $jobIdKey -Value $NewTransfer.JobId
    } Catch {
        $outputLog += Get-ErrorMessage $_ 'Experienced an error when attempting to create JobId in registry'
    }

    If (!(Test-RegistryValue -Name $jobIdKey)) {
        $outputLog = '!Error: Could not create JobId registry entry! Cannot continue without JobId key! Cancelling transfer and removing any files that were created. Exiting script.' + $outputLog
        Get-BitsTransfer -JobId $newTransfer.JobId | Remove-BitsTransfer
        Remove-RegistryValue -Name $jobIdKey
        Invoke-Output $outputLog
        Return
    }

    # Finished starting up the transfer, can now exit script. Must have all necessary files ready to go before we move on from here.
    Invoke-Output $outputLog
    Return
} Else {
    $outputLog += "The ISO exists! Checking hash of downloaded file."

    If (!(Get-HashCheck -Path $isoFilePath)) {
        $hash = (Get-FileHash -Path $isoFilePath -Algorithm 'SHA256').Hash
        $outputLog = "!Error: The hash doesn't match!! The ISO's hash is -> $hash" + $outputLog
    } Else {
        $outputLog = "!Success: The hash matches! The file is all good! The download is complete! Exiting Script!" + $outputLog
    }

    Invoke-Output $outputLog
}
