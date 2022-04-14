$outputLog = @()

# TODO: (for future PR, not now) Research/test what happens when a machine is still pending reboot for 20H2 and then you try to install 21H1.
# TODO: (for future PR, not now) Add reboot handling
# TODO: (for future PR, not now) After machine is successfully upgraded, new monitor for compliant machines to clean up registry entries and ISOs

<#
#############
## Fix TLS ##
#############
#>

Try {
    # Oddly, this command works to enable TLS12 on even Powershellv2 when it shows as unavailable. This also still works for Win8+
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    $outputLog += "Successfully enabled TLS1.2 to ensure successful file downloads."
}
Catch {
    $outputLog += "Encountered an error while attempting to enable TLS1.2 to ensure successful file downloads. This can sometimes be due to dated Powershell. Checking Powershell version..."
    # Generally enabling TLS1.2 fails due to dated Powershell so we're doing a check here to help troubleshoot failures later
    $psVers = $PSVersionTable.PSVersion

    If ($psVers.Major -lt 3) {
        $outputLog += "Powershell version installed is only $psVers which has known issues with this script directly related to successful file downloads. Script will continue, but may be unsuccessful."
    }
}

<#
######################
## Output Helper Functions ##
######################
#>

# Call in Invoke-Output
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Invoke-Output.ps1') | Invoke-Expression

function Get-ErrorMessage {
    param ($Err, [string]$Message)
    Return "$Message $($Err.Exception.Message)"
}

<#
########################
## CW Automate Checks ##
########################

Check for a few values that should be set before entering this script.
#>

# Define build number this script will upgrade you to, should be like '19043'
# This should be defined in the calling script
If (!$targetBuild) {
    $outputLog = "!Error: No Windows Build was defined! Please define the `$targetBuild variable to something like '19043' and then run this again!", $outputLog
    Invoke-Output $outputLog
    Return
}

$Is64 = [Environment]::Is64BitOperatingSystem

If (!$Is64) {
    $outputLog = "!Error: This script only supports 64 bit operating systems! This is a 32 bit machine. Please upgrade this machine to $targetBuild manually!", $outputLog
    Invoke-Output $outputLog
    Return
}

# This errors sometimes. If it does, we want a clear and actionable error and we do not want to continue
Try {
    $isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'
} Catch {
    $outputLog += "There was an error in determining whether this is an Enterprise version of windows or not. The error was: $_"
    Invoke-Output $outputLog
    Return
}

# Make sure a URL has been defined for the Win ISO on Enterprise versions
If ($isEnterprise -and !$automateURL) {
    $outputLog = "!Error: This is a Windows Enterprise machine and no ISO URL was defined to download Windows $targetBuild. This is required for Enterpise machines! Please define the `$automateURL variable with a URL where the ISO can be located and then run this again! The filename must be named like Win_Ent_19044.iso.", $outputLog
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
$regPath = "HKLM:\\SOFTWARE\LabTech\Service\Windows_$($targetBuild)_Upgrade"
$pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
$winSetupErrorKey = 'WindowsSetupError'
$jobIdKey = "JobId"

$windowsBuildToVersionMap = @{
    '19042' = '20H2'
    '19043' = '21H1'
    '19044' = '21H2'
    '22000' = '21H2'
}

$targetVersion = $windowsBuildToVersionMap[$targetBuild]

If (!$targetVersion) {
    $outputLog += "This script needs to be updated to handle $targetBuild! Please update script!"
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
        '19042' = @('3152C390BFBA3E31D383A61776CFB7050F4E1D635AAEA75DD41609D8D2F67E92')
        '19043' = @('0FC1B94FA41FD15A32488F1360E347E49934AD731B495656A0A95658A74AD67F')
        '19044' = @('1323FD1EF0CBFD4BF23FA56A6538FF69DD410AD49969983FEE3DF936A6C811C5')
        '22000' = @('ACECC96822EBCDDB3887D45A5A5B69EEC55AE2979FBEAB38B14F5E7F10EEB488')
    }
} Else {
    $hashArrays = @{
        '19042' = @('6C6856405DBC7674EDA21BC5F7094F5A18AF5C9BACC67ED111E8F53F02E7D13D')
        '19043' = @('6911E839448FA999B07C321FC70E7408FE122214F5C4E80A9CCC64D22D0D85EA')
        '19044' = @('7F6538F0EB33C30F0A5CBBF2F39973D4C8DEA0D64F69BD18E406012F17A8234F')
        '22000' = @('667BD113A4DEB717BC49251E7BDC9F09C2DB4577481DDFBCE376436BEB9D1D2F')
    }
}

$acceptableHashes = $hashArrays[$targetBuild]

If (!$acceptableHashes) {
    $outputLog = "!Error: There is no HASH defined for $targetBuild in the script! Please edit the script and define an expected file hash for this build!", $outputLog
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

function Start-FileDownload {
    $out += @()

    # Get URL
    If ($isEnterprise) {
        $downloadUrl = "$automateURL/Win_Ent_$targetBuild.iso"
    } Else {
        (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-WindowsIsoUrl.ps1') | Invoke-Expression

        # If target build
        If ($targetBuild -ge '22000') {
            $fido = Get-WindowsIsoUrl -Rel $targetVersion -Win 11
        } Else {
            $fido = Get-WindowsIsoUrl -Rel $targetVersion -Win 10
        }

        $downloadUrl = $fido.Link
    }

    $transfer = $Null

    # Call in Get-IsDiskFull
    (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsDiskFull.ps1') | Invoke-Expression

    # Check total disk space, make sure there's at least 16GBs free. If there's not then run the disk cleanup script to see if we can get enough space.
    $diskCheck = Get-IsDiskFull -MinGb 16

    If ($diskCheck.DiskFull) {
        $out += $diskCheck.Output
        Return $diskCheck
    }

    Try {
        $transfer = Start-BitsTransfer -Source $downloadUrl -Destination $isoFilePath -TransferPolicy Standard -Asynchronous
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

This script should only execute if this machine is a windows 10 machine that is on a version less than the requested version
#>

# Call in Get-DesktopWindowsVersionComparison
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-DesktopWindowsVersionComparison.ps1') | Invoke-Expression

Try {
    $lessThanRequestedBuild = Get-DesktopWindowsVersionComparison -LessThan $targetBuild
} Catch {
    $outputLog = (Get-ErrorMessage $_ "!Error: There was an issue when comparing the current version of windows to the requested one. Cannot continue."), $outputLog
    Invoke-Output $outputLog
    Return
}

$outputLog += "Checked current version of windows. " + $lessThanRequestedBuild.Output

# $lessThanRequestedBuild.Result will be $true if current version is -LessThan $targetBuild
If (!$lessThanRequestedBuild.Result) {
    If (Test-Path -Path $isoFilePath) {
        $outputLog += "An ISO for the requested version exists but it is unnecessary. Cleaning up to reclaim disk space."
        Remove-Item -Path $isoFilePath -Force -EA 0 | Out-Null
    }

    $outputLog = "!Success: This upgrade is unnecessary.", $outputLog
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
If ($jobIdExists -and !(Test-Path -Path $isoFilePath)) {
    $jobId = Get-RegistryValue -Name $jobIdKey
    $transfer = Get-BitsTransfer -JobId $jobId -EA 0

    # If there is an existing transfer
    If ($transfer) {
        $outputLog += "There is an existing transfer of $targetBuild."

        <# Removed probably unnecessary code relating to strange maaayybe potential states here. See bottom of script for removed code if it's necessary. #>

        # The transfer could have disappeared in the last step, so check again
        If ($transfer -and $transfer.JobState) {
            # There is an existing transfer...
            $jobState = $transfer.JobState

            Switch ($jobState) {
                # ...and that transfer is still transferring
                'Transferring' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Transferring'. Exiting script.", $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Queued' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Queued'. Exiting script.", $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Connecting' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently 'Connecting'. Exiting script.", $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # Might need to count transient errors and increase priority or transferpolicy after a certain number of errors
                'TransientError' {
                    $outputLog = "!Warning: Windows $targetBuild is still being transferred. It's state is currently TransientError. This is usually not a problem and it should correct itself. Exiting script.", $outputLog
                    Invoke-Output $outputLog
                    Return
                }

                # ...or that transfer is suspended
                'Suspended' {
                    $outputLog += "Windows $targetBuild is still transferring, but the transfer is suspended. Attempting to resume."

                    Try {
                        $transfer | Resume-BitsTransfer -Asynchronous | Out-Null
                    } Catch {
                        $outputLog = (Get-ErrorMessage $_ "!Error: Could not resume the suspended transfer."), $outputLog
                        Invoke-Output $outputLog
                        Return
                    }

                    $jobState = $transfer.JobState

                    If ($jobState -eq 'Suspended') {
                        $outputLog = "!Warning: For some reason, the transfer is still suspended. Some other script or person may have interfered with this download. Sometimes it just takes a minute to restart. Exiting Script.", $outputLog
                        Invoke-Output $outputLog
                        Return
                    } ElseIf ($jobState -like '*Error*') {
                        $outputLog += "The Transfer has entered an error state. The error state is $jobState. Removing transfer and files and starting over."
                        $transfer | Remove-BitsTransfer | Out-Null
                        Remove-RegistryValue -Name $jobIdKey
                    } Else {
                        $outputLog = "!Warning: Successfully resumed transfer. The transfer's state is currently '$jobState.' Exiting script.", $outputLog
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
                        $outputLog = "!Error: The hash doesn't match!! You will need to collect the hash manually and add it to the script. The ISO's hash is -> $hash", $outputLog
                    } Else {
                        $outputLog = "!Success: The hash matches! The file is all good! Removing cached JobId from registry, changing LastWriteTime to NOW (so that disk cleanup doesn't delete it), and exiting Script!", $outputLog
                        Remove-RegistryValue -Name $jobIdKey
                        # Change the LastWriteTime to now b/c otherwise, the disk cleanup script will wipe it out
                        (Get-Item -Path $isoFilePath).LastWriteTime = Get-Date
                    }

                    Invoke-Output $outputLog
                    Return
                }

                Default {
                    $outputLog = "!Error: The transfer job has entered an unexpected state of $($jobState) and the script can't continue. On this machine, check the job with JobId $jobId. Exiting Script.", $outputLog
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
3 last checks before triggering download
########################################
#>

# We don't want this to repeatedly download if the machine is having an issue, so check for existence of setup errors
If (Test-RegistryValue -Name $winSetupErrorKey) {
    $setupErr = Get-RegistryValue -Name $winSetupErrorKey
    $outputLog = "!Error: Windows setup experienced an error upon installation. This should be manually assessed and you should clear the value at $regPath\$winSetupErrorKey in order to make the script try again. The error output is $setupErr", $outputLog
    Invoke-Output $outputLog
    Return
}

# Check that this upgrade hasn't already occurred. No need to download iso if installation has already occurred
If ((Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)) {
    $outputLog = "!Warning: This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. Exiting script.", $outputLog
    Invoke-Output $outputLog
    Return
}

# ISO file could have been deleted or created in the last step, so check again.
If (!(Test-Path -Path $isoFilePath)) {
    # Just in case Complete-BitsTransfer takes a minute... It shouldn't, it's just a rename from a .tmp file, but juuust in case
    Start-Sleep -Seconds 10
}

<#
##########################
FIRST RUN - INIT DOWNLOAD
##########################
#>

# If the ISO doesn't exist at this point, let's just start fresh.
If (!(Test-Path -Path $isoFilePath)) {
    Remove-RegistryValue -Name $jobIdKey

    # We're in a fresh and clean state, and ready to start a transfer.
    $outputLog += "Did not find an existing ISO or transfer. Starting transfer of $targetBuild."
    $newTransfer = Start-FileDownload

    # Disk might be full
    If ($newTransfer.DiskFull) {
        $outputLog = ("!Error: " + $newTransfer.Output), $outputLog
        Invoke-Output $outputLog
        Return
    }

    # Starting the bits transfer might have errored out
    If ($newTransfer.TransferError) {
        $outputLog = ("!Error: " + $newTransfer.Output), $outputLog
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
        $outputLog = '!Error: Could not create JobId registry entry! Cannot continue without JobId key! Cancelling transfer and removing any files that were created. Exiting script.', $outputLog
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
        $outputLog = "!Error: The hash doesn't match!! You will need to check this out manually or verify the hash manually and add a new hash to the script. The ISO's hash is -> $hash", $outputLog
    } Else {
        $outputLog = "!Success: The hash matches! The file is all good! The download is complete! Exiting Script!", $outputLog
    }

    Invoke-Output $outputLog
    Return
}
