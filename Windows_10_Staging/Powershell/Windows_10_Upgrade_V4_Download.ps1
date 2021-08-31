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

# Make sure a URL has been defined for the Win10 ISO on Enterprise versions
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
$jobIdKey = "JobId"
$transferCompleteKey = "TransferComplete"

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

function Remove-RegistryValue {
    param ([string]$Name)
    Remove-ItemProperty -Path $regPath -Name $Name -Force | Out-Null
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

function Remove-Upgrade {
    Remove-Item -Path $isoFilePath -EA 0
    Remove-ItemProperty -Path $regPath -Name $hashKey -EA 0
    Remove-ItemProperty -Path $regPath -Name $jobIdKey -EA 0
    Remove-ItemProperty -Path $regPath -Name $transferCompleteKey -EA 0
}

function Get-PrequisitesExist {
    $hashExists = Test-RegistryValue -Name $hashKey
    $isoFileExists = Test-Path -Path $isoFilePath
    Return $hashExists -and $isoFileExists
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

    # Call in Get-IsDiskFull
    (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-IsDiskFull.ps1') | Invoke-Expression

    $diskCheck = Get-IsDiskFull -MinGb 10

    If ($diskCheck.DiskFull) {
        $out += $diskCheck.Output
        Return $diskCheck
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
######################
# Existing Downloads #
######################

Check for a pending or completed bits transfer.
If pending and transferred, complete transfer and continue.
If pending and transferring, exit script.
If hash check fails, remove files and continue.
If no existing file or pending download, continue.
#>

# Determine status of bits-transfer: Start one if doesn't exist, exit if still transferring, resume if suspended, start over if in bad state, continue if completed
$transferComplete = $false

# If the TransferComplete registry value exists...
If (Test-RegistryValue -Name $transferCompleteKey) {
    # ...and the value matches the requested build
    If ((Get-RegistryValue -Name $transferCompleteKey) -eq $automateWin10Build) {
        # ...and the iso exists
        If (Test-Path -Path $isoFilePath) {
            # Then the transfer is complete and we can skip the download handling
            $transferComplete = $true
        }
    } Else {
        # Looks like a previous version of windows was installed with this script. Let's clean that up.
        $outputLog += "Found a previous win10 upgrade in existence. Deleting previous ISO and also previous registry keys."
        Try {
            $oldBuild = Get-RegistryValue -Name $transferCompleteKey
            Remove-Item -Path "$downloadDir\$oldBuild" -Force | Out-Null
        } Catch {
            $outputLog += Get-ErrorMessage $_ "Tried to delete old windows ISO at $downloadDir\$oldBuild but experienced an error."
        }

        # And clean up the old registry values
        Remove-RegistryValue -Name $transferCompleteKey
        Remove-RegistryValue -Name $hashKey
        Remove-RegistryValue -Name $jobIdKey
    }
}

$jobIdExists = Test-RegistryValue -Name $jobIdKey
$hashExists = Test-RegistryValue -Name $hashKey

# If a jobId exists, but the transfer is not complete, attempt to get the transfer
If ($jobIdExists -and !$transferComplete) {
    $jobId = Get-RegistryValue -Name $jobIdKey
    $transfer = Get-BitsTransfer -JobId $jobId -EA 0

    # If there is an existing transfer
    If ($transfer) {
        $outputLog += "There is an existing transfer of $automateWin10Build."

        # Prefer the hash in the transfer description
        $hash = $transfer.Description

        If (!$hash) {
            # If the transfer doesn't have a hash on it's description somehow...
            If ($hashExists) {
                # ...and the hash exists, get it from there
                $hash = Get-RegistryValue -Name $hashKey
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

            If (!$hashExists) {
                # The hash should exist, but just in case it got deleted or something...
                $outputLog += "For some reason the hash is missing from the registry.. Creating it now."
                $outputLog += Write-RegistryValue -Name $hashKey
            } ElseIf ((Get-RegistryValue -Name $hashKey) -ne $hash) {
                # The hash exists, but the hash in the transfer doesn't match the hash in the registry. Replace registry value.
                $outputLog += Write-RegistryValue -Name $hashKey -Value $hash
            }
        }

        <# Removed probably unnecessary code relating to strange maaayybe potential states here. See bottom of script for removed code if it's necessary. #>

        # The transfer could have disappeared in the last step, so check again
        If ($transfer -and $transfer.JobState) {
            # There is an existing transfer...
            $jobState = $transfer.JobState

            Switch ($jobState) {
                # ...and that transfer is still transferring
                'Transferring' {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently 'Transferring'. Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Queued' {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently 'Queued'. Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # ...and that transfer is still transferring
                'Connecting' {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently 'Connecting'. Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # Might need to count transient errors and increase priority or transferpolicy after a certain number of errors
                'TransientError' {
                    $outputLog += "Win10 $automateWin10Build is still being transferred. It's state is currently TransientError. This is usually not a problem and it should correct itself. Exiting script."
                    Invoke-Output $outputLog
                    Return
                }

                # ...or that transfer is suspended
                'Suspended' {
                    $outputLog += "Win10 $automateWin10Build is still transferring, but the transfer was suspended. Attempting to resume."

                    Try {
                        $transfer | Resume-BitsTransfer -Asynchronous | Out-Null
                    } Catch {
                        $outputLog += Get-ErrorMessage $_ "Could not resume the suspended transfer."
                        Invoke-Output $outputLog
                        Return
                    }

                    $jobState = $transfer.JobState

                    If ($jobState -eq 'Suspended') {
                        $outputLog += "For some reason, the transfer is still suspended. Some other script or person may have interfered with this download. Sometimes it just takes a minute to restart. Exiting Script."
                        Invoke-Output $outputLog
                        Return
                    } ElseIf ($jobState -like '*Error*') {
                        $outputLog += "The Transfer has entered an error state. The error state is $jobState. Removing transfer and files and starting over."
                        $transfer | Remove-BitsTransfer | Out-Null
                        Remove-Upgrade
                    } Else {
                        $outputLog += "Successfully resumed transfer. Exiting script."
                        Invoke-Output $outputLog
                        Return
                    }
                }

                # ...or that transfer has completed
                'Transferred' {
                    # Grab the hash before we complete the transfer, just in case we need it. This is our last chance to grab it from the bitstransfer.
                    $hash = $transfer.Description

                    # The transfer has finished, but it must be "completed" before the ISO file exists
                    Try {
                        $transfer | Complete-BitsTransfer
                    } Catch {
                        $outputLog += (Get-ErrorMessage $_ "Win10 $automateWin10Build successfully finished downloading, but there was an error completing the transfer and saving the file to disk.")
                    }

                    $outputLog += "Win10 $automateWin10Build has finished downloading!"

                    Try {
                        Write-RegistryValue -Name $transferCompleteKey -Value $automateWin10Build
                    } Catch {
                        $outputLog += "Could not set TransferComplete registry value for some reason..."
                    }

                    $outputLog += "Checking hash of ISO file."

                    # If somehow the hash is missing from the description
                    If (!$hash) {
                        $hash = Get-RegistryValue -Name $hashKey
                    } ElseIf (!$hashExists) {
                        # If the hash exists and the hash registry value doesn't exist, create the hash registry value
                        $outputLog += Write-RegistryValue -Name $hashKey -Value $newTransfer.FileHash
                    }

                    If (!$hash -and $isEnterprise) {
                        $hash = $automateIsoHash
                        # Create the hash registry value
                        $outputLog += Write-RegistryValue -Name $hashKey -Value $hash
                    }

                    If (!(Get-HashCheck -Path $isoFilePath -Hash $hash)) {
                        $outputLog += "The hash doesn't match!! This is terrible! Deleting all files and will start over!"
                        Remove-Upgrade
                    } Else {
                        $outputLog += "The hash matches! The file is all good! Exiting Script!"
                    }

                    Invoke-Output $outputLog
                    Return
                }

                Default {
                    $outputLog += "The transfer job has entered an unexpected state of $($jobState) and the script can't continue. On this machine, check the job with JobId $jobId. Exiting Script."
                    Invoke-Output $outputLog
                    Return
                }
            }
        }
    } Else {

    }
}

# Files could have been deleted or created in the last step, so check to see if all the necessary files exist for installation. Only need ISO and hash files to continue.
If (!(Get-PrequisitesExist)) {
    # Just in case Complete-BitsTransfer takes a minute... It shouldn't, it's just a rename from a .tmp file, but juuust in case since we're about to potentially delete
    # the downloaded ISO!
    Start-Sleep -Seconds 10

    # Check again
    If (!(Get-PrequisitesExist)) {
        # We're missing the ISO and/or the hash file, and both are needed at this point.
        Remove-Upgrade
    }
}

<#
##########################
FIRST RUN - INIT DOWNLOAD
##########################
#>

If (!(Get-PrequisitesExist)) {
    # If hash and ISO don't exist at this point, we're in a fresh and clean state, and ready to start a transfer.
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
        $outputLog += 'Creating registry values to cache the BitsTransfer JobId and FileHash'
        $outputLog += Write-RegistryValue -Name $hashKey -Value $newTransfer.FileHash
        $outputLog += Write-RegistryValue -Name $jobIdKey -Value $NewTransfer.JobId
    } Catch {
        $outputLog += Get-ErrorMessage $_ 'Experienced an error when attempting to create JobId and FileHash files'
    }

    If (!(Test-RegistryValue -Name $jobIdKey)) {
        $outputLog += 'Could not create JobId registry entry! Cannot continue without JobId key! Cancelling transfer and removing any files that were created. Exiting script.'
        Get-BitsTransfer -JobId $newTransfer.JobId | Remove-BitsTransfer
        Remove-Upgrade
        Invoke-Output $outputLog
        Return
    }

    If (!(Test-RegistryValue -Name $hashKey)) {
        $outputLog += 'Could not create file hash registry entry. This is recoverable, there will be chances to grab this from the transfer once it has completed.'
    }

    # Finished starting up the transfer, can now exit script. Must have all necessary files ready to go before we move on from here.
    Invoke-Output $outputLog
    Return
} Else {
    $outputLog += "The ISO exists! Checking hash of downloaded file."

    $hash = Get-RegistryValue -Name $hashKey

    If (!$hash -and $isEnterprise) {
        $hash = $automateIsoHash
    }

    If (!(Get-HashCheck -Path $isoFilePath -Hash $hash)) {
        $outputLog += "The hash doesn't match!! This is terrible! Deleting all files and will start over!"
        Remove-Upgrade
    } Else {
        $outputLog += "The hash matches! The file is all good! Exiting Script!"
    }

    Invoke-Output $outputLog
    Return
}
