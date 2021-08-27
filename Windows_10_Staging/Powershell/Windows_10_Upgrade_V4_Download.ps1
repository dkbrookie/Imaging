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

<# --------------------------------------------------- Step 1 ------------------------------------------------------- #>
# Determine status of bits-transfer: Start one if doesn't exist, exit if still transferring, resume if suspended, start over if in bad state, continue if completed
$jobIdFileExists = Test-Path -Path $jobIdFilePath
$hashFileExists = Test-Path -Path $hashFilePath
$isoFileExists = Test-Path -Path $isoFilePath
$transfer = $Null

# If a jobId and hash files exists, attempt to get the transfer
If ($jobIdFileExists) {
    $jobId = Get-Content -Path $jobIdFilePath
    $transfer = Get-BitsTransfer -JobId $jobId -EA 0

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
                New-Item -Path $hashFilePath -Value $hash -Force | Out-Null
            } ElseIf ((Get-Content -Path $hashFilePath) -ne $hash) {
                # The hash file exists, but the hash in the transfer doesn't match the hash in the file. Replace file.
                New-Item -Path $hashFilePath -Value $hash -Force | Out-Null
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
                        Remove-UpgradeFiles
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

                    $outputLog += "Win10 $automateWin10Build has finished downloading! Removing JobId file because it is no longer needed."

                    Try {
                        Remove-Item -Path $jobIdFilePath -Force
                    } Catch {
                        $outputLog += "Could not remove JobId file for some reason..."
                    }

                    $outputLog += "Checking hash of ISO file."

                    # If somehow the hash is missing from the description
                    If (!$hash) {
                        $hash = Get-Content -Path $hashFilePath
                    } ElseIf (!$hashFileExists) {
                        # If the hash exists and the hash file doesn't exist, create the hash file
                        New-Item -Path $hashFilePath -Value $newTransfer.FileHash -Force | Out-Null
                    }

                    If (!$hash -and $isEnterprise) {
                        $hash = $automateIsoHash
                    }

                    If (!(Get-HashCheck -Path $isoFilePath -Hash $hash)) {
                        $outputLog += "The hash doesn't match!! This is terrible! Deleting all files and will start over!"
                        Remove-UpgradeFiles
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
    } ElseIf ($transfer -and $isoFileExists) {
        $outputLog += "Somehow, there is an existing transfer and also an ISO file. This should not have been allowed to occurr. This machine needs manual intervention, or the script needs to be adjusted. You should assess the existing ISO either keep it and remove the transfer, or delete it and complete the transfer. Exiting Script."
        Invoke-Output $outputLog
        Return
    } ElseIf ($isoFileExists -and $jobIdFileExists) {
        $outputLog += "The ISO exists!! All good! Somehow, JobId file still exists. Going to try removing the jobId file. It should have been removed when the transfer was completed."

        Try {
            Remove-Item -Path $jobIdFilePath -Force
        } Catch {
            $outputLog += "Could not remove JobId file for some reason..."
        }

        Invoke-Output $outputLog
        Return
    } Else {
        # There is no existing transfer, but the jobId file exists, we shouldn't have ended up in this state, so remove existing files and start over
        $outputLog += "For some reason, it appears that the transfer has disappeared before completion. Deleting any files that were saved from the last attempt and will retry from the beginning."
        Remove-UpgradeFiles
    }
}

# Files could have been deleted or created in the last step, so check to see if all the necessary files exist for installation. Only need ISO and hash files to continue.
If (!(Get-NecessaryFilesExist)) {
    # Just in case Complete-BitsTransfer takes a minute... It shouldn't, it's just a rename from a .tmp file, but juuust in case since we're about to potentially delete
    # the downloaded ISO!
    Start-Sleep -Seconds 30

    # Check again
    If (!(Get-NecessaryFilesExist)) {
        # We're either missing the ISO or the hash file, and both are needed at this point.
        Remove-UpgradeFiles
    }
}

<#
##########################
FIRST RUN - INIT DOWNLOAD
##########################
#>

If (!(Get-NecessaryFilesExist)) {
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
        New-Item -Path $hashFilePath -Value $newTransfer.FileHash -Force | Out-Null
        New-Item -Path $jobIdFilePath -Value $NewTransfer.JobId -Force | Out-Null
    } Catch {
        $outputLog += Get-ErrorMessage $_ 'Experienced an error when attempting to create JobId and FileHash files'
    }

    If (!(Test-Path -Path $jobIdFilePath)) {
        $outputLog += 'Could not create JobId file! Cannot continue without JobId file! Cancelling transfer and removing any files that were created. Exiting script.'
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
} Else {
    $outputLog += "The ISO exists! Checking hash of downloaded file."

    $hash = Get-Content -Path $hashFilePath

    If (!$hash -and $isEnterprise) {
        $hash = $automateIsoHash
    }

    If (!(Get-HashCheck -Path $isoFilePath -Hash $hash)) {
        $outputLog += "The hash doesn't match!! This is terrible! Deleting all files and will start over!"
        Remove-UpgradeFiles
    } Else {
        $outputLog += "The hash matches! The file is all good! Exiting Script!"
    }

    Invoke-Output $outputLog
    Return
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
