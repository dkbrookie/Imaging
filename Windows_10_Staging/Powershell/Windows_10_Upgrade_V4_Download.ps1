$outputLog = @()

<#
######################
## Output Helper Functions ##
######################
#>

function Invoke-Output {
    param ([string[]]$output)
    Write-Output ($output -join "`n`n")
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
    Write-Output "!ERROR: No Windows Build was defined! Please define the `$automateWin10Build variable to something like '20H2' and then run this again!"
    Return
}

$Is64 = [Environment]::Is64BitOperatingSystem

If (!$Is64) {
    Write-Output "!ERROR: This script only supports 64 bit operating systems! This is a 32 bit machine. Please upgrade this machine to $automateWin10Build manually!"
    Return
}

$isEnterprise = (Get-WindowsEdition -Online).Edition -eq 'Enterprise'

# Make sure a URL has been defined for the Win10 ISO on Enterprise versions
If ($isEnterprise -and !$automateURL) {
    Write-Output "!ERROR: This is a Win10 Enterprise machine and no ISO URL was defined to download Windows 10 $automateWin10Build. This is required for Enterpise machines! Please define the `$automateURL variable with a URL to the ISO and then run this again!"
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
$jobIdKey = "JobId"

<#
########################
## Define File Hashes ##
########################
#>

If ($isEnterprise) {
    $hashArrays = @{
        '20H2' = @('3152C390BFBA3E31D383A61776CFB7050F4E1D635AAEA75DD41609D8D2F67E92')
        '21H1' = @('')
    }
} Else {
    $hashArrays = @{
        '20H2' = @('6C6856405DBC7674EDA21BC5F7094F5A18AF5C9BACC67ED111E8F53F02E7D13D')
        '21H1' = @('6911E839448FA999B07C321FC70E7408FE122214F5C4E80A9CCC64D22D0D85EA')
    }
}

$acceptableHashes = $hashArrays[$automateWin10Build]

If (!$acceptableHashes) {
    Write-Output "!ERROR: There is no HASH defined for $automateWin10Build in the script! Please edit the script and define an expected file hash for this build!"
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
    param ([string]$Path)
    $hash = (Get-FileHash -Path $Path -Algorithm 'SHA256').Hash
    $hashMatches = $acceptableHashes | ForEach-Object { $_ -eq $hash } | Where-Object { $_ -eq $true }
    Return $hashMatches.length -gt 0
}

function Get-PrequisitesExist {
    Return Test-Path -Path $isoFilePath
}

function Start-FileDownload {
    $out += @()

    # Get URL
    If ($isEnterprise) {
        $downloadUrl = $automateURL
    } Else {
        (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.GetWindowsIsoUrl.ps1') | Invoke-Expression
        $fido = Get-WindowsIsoUrl -Rel $automateWin10Build

        $downloadUrl = $fido.Link
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
        $transfer = Start-BitsTransfer -Source $downloadUrl -Destination $isoFilePath -TransferPolicy Standard -Asynchronous
    } Catch {
        $out += (Get-ErrorMessage $_ "!Error: Could not start the transfer!")
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


# TODO: !!!This is only commented out for testing, uncomment this before production!!!


## Call in Get-Win10VersionComparison
# (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Get-Win10VersionComparison.ps1') | Invoke-Expression

# Try {
#     $versionComparison = Get-Win10VersionComparison -LessThan $automateWin10Build
# } Catch {
#     $outputLog += Get-ErrorMessage $_ "There was an issue when comparing the current version of windows to the requested one. Cannot continue."
#     Invoke-Output $outputLog
#     Return
# }

# If ($versionComparison.Result) {
#     $outputLog += "Checked current version of windows and all looks good. " + $versionComparison.Output
# } Else {
#     $outputLog += "Cannot continue. The requested version should be less than the current version. " + $versionComparison.Output
#     Invoke-Output $outputLog
#     Return
# }

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
        $outputLog += "There is an existing transfer of $automateWin10Build."

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
                        Remove-ItemProperty -Path $regPath -Name $jobIdKey -EA 0
                    } Else {
                        $outputLog += "Successfully resumed transfer. Exiting script."
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

                    $outputLog += "Win10 $automateWin10Build has finished downloading!"

                    $outputLog += "Checking hash of ISO file."

                    If (!(Get-HashCheck -Path $isoFilePath)) {
                        $hash = (Get-FileHash -Path $isoFilePath -Algorithm 'SHA256').Hash
                        $outputLog += "The hash doesn't match!! You will need to collect the hash manually and add it to the script. The ISO's hash is -> $hash"
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
        $outputLog += "Transfer was started, there is JobId cached, but there is no ISO and there is no existing transfer. The transfer or the ISO must have gotten deleted somehow. Cleaning up and restarting from the beginning."
        Remove-ItemProperty -Path $regPath -Name $jobIdKey -EA 0
    }
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
    Remove-ItemProperty -Path $regPath -Name $jobIdKey -EA 0

    # We're in a fresh and clean state, and ready to start a transfer.
    $outputLog += "Did not find an existing ISO or transfer. Starting transfer of $automateWin10Build."
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
        $outputLog += 'Creating registry value to cache the BitsTransfer JobId'
        $outputLog += Write-RegistryValue -Name $jobIdKey -Value $NewTransfer.JobId
    } Catch {
        $outputLog += Get-ErrorMessage $_ 'Experienced an error when attempting to create JobId file'
    }

    If (!(Test-RegistryValue -Name $jobIdKey)) {
        $outputLog += 'Could not create JobId registry entry! Cannot continue without JobId key! Cancelling transfer and removing any files that were created. Exiting script.'
        Get-BitsTransfer -JobId $newTransfer.JobId | Remove-BitsTransfer
        Remove-ItemProperty -Path $regPath -Name $jobIdKey -EA 0
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
        $outputLog += "The hash doesn't match!! You will need to check this out manually or verify the hash manually and add a new hash to the script. The ISO's hash is -> $hash"
    } Else {
        $outputLog += "The hash matches! The file is all good! Exiting Script!"
    }

    Invoke-Output $outputLog
    Return
}
