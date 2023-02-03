<#
###########################
### Check if on battery ###
##########################

We don't want to run the install if on battery power.
#>

$battery = Get-WmiObject -Class Win32_Battery | Select-Object -First 1
$hasBattery = $null -ne $battery
$batteryInUse = $battery.BatteryStatus -eq 1

If ($hasBattery -and $batteryInUse) {
  $outputLog = "!Warning: This is a laptop and it's on battery power. It would be unwise to install a new OS on battery power. Exiting Script." + $outputLog
  Invoke-Output @{
    outputLog                = $outputLog
    installationAttemptCount = $installationAttemptCount
  }
  Return
}

<#
###########################
# Check if user logged in #
###########################
#>

$userLogonStatus = Get-LogonStatus

# If userLogonStatus equals 0, there is no user logged in. If it is 1 or 2, there is a user logged in and we shouldn't allow reboots.
$userIsLoggedOut = $userLogonStatus -eq 0

Try {
  ## The portable ISO EXE is going to mount our image as a new drive and we need to figure out which drive
  ## that is. So before we mount the image, grab all CURRENT drive letters
  $curLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
  Mount-DiskImage $isoFilePath | Out-Null
  ## Have to sleep it here for a second because the ISO takes a second to mount and if we go too quickly
  ## it will think no new drive letters exist
  Start-Sleep 30
  ## Now that the ISO is mounted we should have a new drive letter, so grab all drive letters again
  $newLetters = (Get-PSDrive | Select-Object Name -ExpandProperty Name) -match '^[a-z]$'
  ## Compare the drive letters from before/after mounting the ISO and figure out which one is new.
  ## This will be our drive letter to work from
  $mountedLetter = (Compare-Object -ReferenceObject $curLetters -DifferenceObject $newLetters).InputObject + ':'
  ## Call setup.exe w/ all of our required install arguments
} Catch {
  $outputLog += "Could not mount the ISO for some reason. Exiting script."
  Dismount-DiskImage $isoFilePath | Out-Null
  Invoke-Output @{
    outputLog                = $outputLog
    installationAttemptCount = $installationAttemptCount
  }
  Return
}

If (($windowsGeneration -eq '11') -and ($forceInstallOnUnsupportedHardware)) {
  $outputLog += '$forceInstallOnUnsupportedHardware was specified, so setting HKLM:\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU to 1. This should avoid the installer erroring out due to TPM or CPU incompatibility.'

  Try {
    Write-RegistryValue -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'DWORD' -Value 1
  } Catch {
    $outputLog += "There was a problem, could net set AllowUpgradesWithUnsupportedTPMOrCPU to 1. Installation will not succeed if hardware is not compatible."
  }
}

$setupArgs = "/Auto Upgrade /NoReboot /Quiet /Compat IgnoreWarning /ShowOOBE None /Bitlocker AlwaysSuspend /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogsDir /Telemetry Disable"

# If a user is logged in, we want setup to run with low priority and without forced reboot
If (!$userIsLoggedOut) {
  $outputLog += "A user is logged in upon starting setup. Will reassess after installation finishes."
  $setupArgs = $setupArgs + " /Priority Low"
}

# We're running the installer here, so we can go ahead and increment $installationAttemptCount
$installationAttemptCount++

Write-RegistryValue -Name $installationAttemptCountKey -Value $installationAttemptCount

# If we determined that we should cache pending reboots earlier, do that now just before installation
If ($shouldCachePendingReboots) {
  Cache-AndRestorePendingReboots
}

$outputLog += "Starting upgrade installation of $targetBuild"
$process = Start-Process -FilePath "$mountedLetter\setup.exe" -ArgumentList $setupArgs -PassThru -Wait

$exitCode = $process.ExitCode

# If setup exited with a non-zero exit code, windows setup experienced an error
If ($exitCode -ne 0) {
  $setupErr = $process.StandardError
  $convertedExitCode = '{0:x}' -f $exitCode

  $outputLog += "Windows setup exited with a non-zero exit code. The exit code was: '$convertedExitCode'."

  If ($convertedExitCode -eq 'c1900200') {
    $outputLog += "Cannot install because this machine's hardware configuration does not meet the minimum requirements for the target Operating System 'Windows $windowsGeneration $targetBuild'. You may be able to force installation by setting `$forceInstallOnUnsupportedHardware to `$true."
    $setupErr = 'Hardware configuration unsupported.'
  }

  If ($setupErr -eq '') {
    $setupErr = 'Unknown Error - Windows Setup did not return an error message. Check the Exit Code.'
  }

  $outputLog += "This machine needs to be manually assessed. Writing error to registry at $regPath\$winSetupErrorKey. Clear this key before trying again. The error was: $setupErr"

  Write-RegistryValue -Name $winSetupErrorKey -Value $setupErr
  Write-RegistryValue -Name $winSetupExitCodeKey -Value $convertedExitCode
  Dismount-DiskImage $isoFilePath | Out-Null
} Else {
  $outputLog += "Windows setup completed successfully."

  # Setup took a long time, so check user logon status again
  $userLogonStatus = Get-LogonStatus

  If (($userLogonStatus -eq 0) -and !$excludeFromReboot) {
    $outputLog = "!Warning: No user is logged in and machine has not been excluded from reboots, so rebooting now." + $outputLog
    Invoke-Output @{
      outputLog                = $outputLog
      installationAttemptCount = $installationAttemptCount
    }
    Write-RegistryValue -Name $rebootInitiatedForThisUpgradeKey -Value 1
    shutdown /r /c $restartMessage
    Return
  } ElseIf ($excludeFromReboot) {
    $outputLog = "!Warning: This machine has been excluded from patching reboots so not rebooting. Marking pending reboot in registry." + $outputLog
    Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
  } Else {
    $outputLog = "!Warning: User is logged in after setup completed successfully, so marking pending reboot in registry." + $outputLog
    Write-RegistryValue -Name $pendingRebootForThisUpgradeKey -Value 1
  }
}
