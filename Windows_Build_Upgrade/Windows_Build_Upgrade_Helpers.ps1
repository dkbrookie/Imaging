# Helper functions and prerequisite checks for windows build upgrade

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

# Call in Get-OsVersionDefinitions
$WebClient.DownloadString('https://raw.githubusercontent.com/dkbrookie/Constants/main/Get-OsVersionDefinitions.ps1') | Invoke-Expression

Function Get-ErrorMessage {
  <#
  .SYNOPSIS
  Formats an error message and an error into a nice string
  #>
  param ($Err, [string]$Message)
  Return "$Message Error was: $($Err.Exception.Message)"
}

function Get-HashCheck {
  param ([string]$Path, [string[]]$AcceptableHashes)
  $hash = (Get-FileHash -Path $Path -Algorithm 'SHA256').Hash
  $hashMatches = $acceptableHashes | ForEach-Object { $_ -eq $hash } | Where-Object { $_ -eq $true }
  Return $hashMatches.length -gt 0
}

Function Get-ProcessPrerequisites (
    [string]$releaseChannel,
    [string]$targetBuild,
    [string]$targetVersion,
    [string]$windowsGeneration,
    [bool]$isEnterprise,
    [string]$enterpriseIsoUrl
  ) {
  <#
  .SYNOPSIS
  Returns a hashtable that can be parsed for various prerequisites checks
  .DESCRIPTION
  These checks validate that the script isn't being used with an indeterminate configuration / intention

  Define $releaseChannel which will define which build this script will upgrade you to, should be 'Alpha', 'Beta' or 'GA' This should be defined in the
  calling script.

  OR you can specify $targetBuild (i.e. '19041') which will download a specific build

  OR you can specify $targetVersion (i.e '20H2') PLUS $windowsGeneration (i.e. '10' or '11') which will download a specific build
  #>

  # These checks should return $true upon desirable state (should continue), $false is a failed check
  Return @{
    MinimumRequired = @(
      @{
        # We need either releaseChannel or targetBuild, OR targetVersion and windowsGeneration together
        Check = (($releaseChannel -or $targetBuild) -or ($targetVersion -and $windowsGeneration))
        Error = "No Release Channel was defined! Please define the `$releaseChannel variable to 'GA', 'Beta' or 'Alpha' and then run this again! " +
        "Alternatively, you can provide `$targetBuild (i.e. '19041') or you can provide `$targetVersion (i.e. '20H2') AND " +
        "`$windowsGeneration (i.e. '10' or '11')."
      }
    )

    VerifyIntent    = @(
      @{
        # If both $releaseChannel and any of the others are specified, we don't know the intention of the user because we can't count on them to match
        Check = !($releaseChannel -and ($targetBuild -or $targetVersion -or $windowsGeneration))
        Error = "`$releaseChannel of '$releaseChannel' and `$targetBuild|`$targetVersion|`$windowsGeneration were specified. You should not " +
        "use `$releaseChannel along with the others because intention is unclear."
      },
      @{
        # If both $releaseChannel and any of the others are specified, we don't know the intention of the user because we can't count on them to match
        Check = !($targetBuild -and ($targetVersion -or $windowsGeneration))
        Error = "`$releaseChannel of '$releaseChannel' and `$targetBuild|`$targetVersion|`$windowsGeneration were specified. You should not " +
        "use `$releaseChannel along with the others because intention is unclear."
      },
      @{
        # If both $targetBuild and any of the others are specified, we don't know the intention of the user because we can't count on them to match
        Check = !($targetBuild -and ($targetVersion -or $windowsGeneration))
        Error = "`$targetBuild of '$targetBuild' and `$targetVersion|`$windowsGeneration were specified. You should not " +
        "use `$targetBuild along with the others because intention is unclear."
      }
    )

    Environment   = @(
      @{
        # We only support 64 bit
        Check = [Environment]::Is64BitOperatingSystem
        Error = "This script only supports 64 bit operating systems! This is a 32 bit machine. Please upgrade this machine manually!"
      },
      @{
        # Make sure a URL has been defined for the Win ISO on Enterprise versions
        Check = ($isEnterprise -and $enterpriseIsoUrl)
        Error = "This is a Windows Enterprise machine and no ISO URL was defined to download Windows for this target. This is required for Enterprise machines! Please define the `$enterpriseIsoUrl variable with a URL where the ISO can be located and then run this again! The url should only be the base url where the ISO is located, do not include the ISO name or any trailing slashes (i.e. 'https://someurl.com'). The filename  of the ISO located here must be named 'Win_Ent_`$targetBuild.iso' like 'Win_Ent_19044.iso'"
      }
    )
  }
}

Function Get-RemainingTargetInfo (
  [string]$releaseChannel,
  [string]$targetBuild,
  [string]$targetVersion,
  [string]$windowsGeneration
) {
  $windowsBuildToVersionMap = @{
    '19042' = '20H2'
    '19043' = '21H1'
    '19044' = '21H2'
    '22000' = '21H2'
    '19045' = '22H2'
    '22621' = '22H2'
  }

  # We only care about gathering the build ID based on release channel when $releaseChannel is specified, if it's not, targetVersion or targetBuild are specified
  If ($releaseChannel) {
    $targetBuild = (Get-OsVersionDefinitions).Windows.Desktop[$releaseChannel]

    If (!$targetBuild) {
      $outputLog = "!Error: Target Build was not found! Please check the provided `$releaseChannel of $releaseChannel against the valid release channels in Get-OsVersionDefinitions in the Constants repository." + $outputLog
      Invoke-Output @{
        outputLog                = $outputLog
        installationAttemptCount = $installationAttemptCount
      }
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
      Throw "An unsupported `$windowsGeneration value of $windowsGeneration was provided. Please choose either '10' or '11'"; Return
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
      Throw "There was a problem with the script. `$targetBuild of $targetBuild does not appear to be supported. Please update script!"; Return
    }

    $targetVersion = $windowsBuildToVersionMap[$targetBuild]

    If (!$targetVersion) {
      Throw "No value for `$targetVersion could be determined from `$targetBuild. This script needs to be updated to handle $targetBuild! Please update script!"; Return
    }
  }

  Return @{
    TargetBuild = $targetBuild
    TargetVersion = $targetVersion
    WindowsGeneration = $windowsGeneration
  }
}

Function Get-Hashes ([bool]$isEnterprise, [string]$targetBuild) {
  If ($isEnterprise) {
    $hashes = @{
      '19042' = @('3152C390BFBA3E31D383A61776CFB7050F4E1D635AAEA75DD41609D8D2F67E92')
      '19043' = @('0FC1B94FA41FD15A32488F1360E347E49934AD731B495656A0A95658A74AD67F')
      '19044' = @('1323FD1EF0CBFD4BF23FA56A6538FF69DD410AD49969983FEE3DF936A6C811C5')
      '22000' = @('ACECC96822EBCDDB3887D45A5A5B69EEC55AE2979FBEAB38B14F5E7F10EEB488')
    }
  } Else {
    $hashes = @{
      '19042' = @('6C6856405DBC7674EDA21BC5F7094F5A18AF5C9BACC67ED111E8F53F02E7D13D')
      '19043' = @('6911E839448FA999B07C321FC70E7408FE122214F5C4E80A9CCC64D22D0D85EA')
      '19044' = @('7F6538F0EB33C30F0A5CBBF2F39973D4C8DEA0D64F69BD18E406012F17A8234F')
      '22000' = @('667BD113A4DEB717BC49251E7BDC9F09C2DB4577481DDFBCE376436BEB9D1D2F', '4BC6C7E7C61AF4B5D1B086C5D279947357CFF45C2F82021BB58628C2503EB64E')
    }
  }

  If ($hashes[$targetBuild] -eq "") {
    Throw "There is no HASH defined for $targetBuild in the script! Please edit the script and define an expected file hash for this build!"; Return
  }

  Return $hashes[$targetBuild]
}

Function Get-InstallationPrerequisites ([string[]]$acceptableHashes, [string]$isoFilePath) {
  # Microsoft guidance states that 20Gb is needed for installation
  $diskCheck = Get-IsDiskFull -MinGb 20

  # These checks should return $true upon desirable state (should continue), $false is a failed check
  Return @{
    InstallationPrerequisites = @(
      @{
        # No need to continue if the ISO doesn't exist
        Check = (Test-Path -Path $isoFilePath)
        Error = "!Warning: ISO doesn't exist yet.. Still waiting on that."
      },
      @{
        # Ensure hash matches
        Check = (Get-HashCheck -Path $isoFilePath -AcceptableHashes $acceptableHashes)
        Error = "!Error: The hash doesn't match!! This ISO file needs to be deleted via the cleanup script and redownloaded via the download script, OR a new hash needs to be added to this script!!"
      },
      @{
        Check = !$diskCheck.DiskFull
        Error = "!Error: " + $diskCheck.Output
      }
    )
  }
}

Function Get-PreviousInstallationErrors {
  # We don't want windows setup to repeatedly try if the machine is having an issue
  If (Test-RegistryValue -Name $winSetupErrorKey) {
    $setupErr = Get-RegistryValue -Name $winSetupErrorKey
    $setupExitCode = Get-RegistryValue -Name $winSetupExitCodeKey
    Throw "Windows setup experienced an error upon last installation. This should be manually assessed and you should delete $regPath\$winSetupErrorKey in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'"; Return
  }

  # There could also be an error at a location from a previous version of this script, identified by version ID 20H2
  If (Test-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError') {
    $setupErr = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupError'
    $setupExitCode = Get-RegistryValue -Path 'HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade' -Name 'WindowsSetupExitCode'
    Throw "Windows setup experienced an error upon last installation. This should be manually assessed and you should delete HKLM:\SOFTWARE\LabTech\Service\Win10_20H2_Upgrade\WindowsSetupError in order to make the script try again. The exit code was $setupExitCode and the error output was '$setupErr'"; Return
  }
}

Function Invoke-PreviousInstallCheck (
  $pendingRebootForThisUpgradeKey,
  $rebootInitiatedForThisUpgradeKey,
  $winSetupErrorKey,
  $winSetupExitCodeKey,
  $excludeFromReboot,
  $restartMessage,
  $regPath
) {
  If ((Test-RegistryValue -Name $pendingRebootForThisUpgradeKey) -and ((Get-RegistryValue -Name $pendingRebootForThisUpgradeKey) -eq 1)) {
    If ((Test-RegistryValue -Name $rebootInitiatedForThisUpgradeKey) -and ((Get-RegistryValue -Name $rebootInitiatedForThisUpgradeKey) -eq 1)) {
      # If the reboot for this upgrade has already occurred, the installation doesn't appear to have succeeded so the installer must have errored out without
      # actually throwing an error code? Let's set the error state for assessment.
      $failMsg = "Windows setup appears to have succeeded (it didn't throw an error) but windows didn't actually complete the upgrade for some reason. This machine needs to be manually assessed. If you want to try again, delete registry values at '$rebootInitiatedForThisUpgradeKey', '$pendingRebootForThisUpgradeKey' and '$winSetupErrorKey'"
      Write-RegistryValue -Name $winSetupErrorKey -Value $failMsg
      Write-RegistryValue -Name $winSetupExitCodeKey -Value 'Unknown Error'
      Throw $failMsg; Return
    }

    $userLogonStatus = Get-LogonStatus

    If (($userLogonStatus -eq 0) -and !$excludeFromReboot) {
      # No user logged in, no reboot exclusion, Invoke-RebootIfNeeded DOES trigger a reboot, so the machine is rebooting NOW
      If (Invoke-RebootIfNeeded -Message $restartMessage) {
        Write-RegistryValue -Name $rebootInitiatedForThisUpgradeKey -Value 1
        Return @{
          Result = $true
          Message = "This machine has already been upgraded but is pending reboot. No user is logged in and machine has not been excluded from reboots, so rebooting now."
        }
      }
    } Else {
      If ($excludeFromReboot) {
        $reason = 'Machine has been excluded from automatic reboots'
      } Else {
        $reason = 'User is logged in'
      }

      Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
      Return @{
        Result = $true
        Message = "This machine has already been upgraded but is pending reboot via reg value at $regPath\$pendingRebootForThisUpgradeKey. $reason, so not rebooting."
      }
    }
  }

  Return @{ Result = $false }
}


# Return $true if no pending reboots and false if pending reboots
# Also return whether rebooting or not
Function Invoke-RebootHandler (
  [int]$excludeFromReboot,
  [string]$releaseChannel,
  [string]$targetBuild,
  [string]$targetVersion,
  [string]$windowsGeneration,
  [string]$rebootInitiatedKey
) {
  $restartMessage = "Restarting to complete Windows $windowsGeneration $targetVersion - $targetBuild upgrade"
  $rebootInitiated = Get-RegistryValue -Name $rebootInitiatedKey
  $rebootStatus = Read-PendingRebootStatus
  # $shouldCachePendingReboots = $false

  if (!$rebootInitiated) {
    $rebootInitiated = 0
  }

  If ($rebootStatus.HasPendingReboots -and !$excludeFromReboot -and ($rebootInitiated -ge 3)) {
    # Reboot has been attempted 3 times. Instead of trying again, set the counter back to 0 and tell the installation process to cache them and go ahead
    Write-RegistryValue -Name $rebootInitiatedKey -Value 0
    $outputLog += "There are reboots pending, but we have tried gracefully clear by rebooting 3 times. Will now cache the pending reboots and continue with installation and will restore them after installation."
    $outputLog = (Install-WinBuild -CachePendingReboots $true) + $outputLog
    Invoke-Output $outputObject
    Return
  } ElseIf ($rebootStatus.HasPendingReboots) {
    # There are pending reboots
    If (!$excludeFromReboot -and $userIsLoggedOut) {
      # Machine is not excluded, and no user is logged in, so let's try reboot
      $outputLog = "!Warning: Machine is not excluded from reboots and no user is logged in. Rebooting now." + $outputLog
      Invoke-RebootIfNeeded -Message $restartMessage
      # Increment the rebootinitiated counter
      Write-RegistryValue -Name $rebootInitiatedKey -Value ($rebootInitiated + 1)
      # Exit here because we're about to reboot
      Invoke-Output $outputObject
      # TODO: Trigger the installation process in a scheduled task.
      Return
    } ElseIf ($excludeFromReboot) {
      # Machine is excluded from automatic reboots
      $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetBuild installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($rebootStatus.Output)" + $outputLog
      Invoke-Output $outputObject
      Return
    } ElseIf (!$userIsLoggedOut) {
      # User is currently logged in
      $outputLog = "!Warning: This machine has a pending reboot and needs to be rebooted before starting the $targetBuild installation, but it has been excluded from patching reboots. Will try again later. The reboot flags are: $($rebootStatus.Output)" + $outputLog
      Invoke-Output $outputObject
      Return
    }
  } Else {
    # No pending reboots!
    $outputLog += "Verified there is no reboot pending"
    Write-RegistryValue -Name $rebootInitiatedKey -Value 0
  }
}
