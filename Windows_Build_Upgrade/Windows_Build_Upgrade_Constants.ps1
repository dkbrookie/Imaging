Get-Constants ([string]$targetBuild) {
  $LTSvc = "$env:windir\LTSvc"
  $workDir = "$LTSvc\packages\OS"
  $isoFilePath = "$downloadDir\$targetBuild.iso"
  $windowslogsDir = "$workDir\Windows-$targetBuild-Logs"
  $downloadDir = "$workDir\Windows\$targetBuild"
  $regPath = "HKLM:\SOFTWARE\LabTech\Service\Windows_$($targetBuild)_Upgrade"
  $pendingRebootForThisUpgradeKey = "PendingRebootForThisUpgrade"
  $rebootInitiatedForThisUpgradeKey = "RebootInitiatedForThisUpgrade"
  $rebootInitiatedKey = "ExistingRebootInitiated"
  $installationAttemptCountKey = 'InstallationAttemptCount'

  Return @{
    LTSvc                            = $LTSvc
    workDir                          = $workDir
    isoFilePath                      = $isoFilePath
    windowslogsDir                   = $windowslogsDir
    downloadDir                      = $downloadDir
    regPath                          = $regPath
    pendingRebootForThisUpgradeKey   = $pendingRebootForThisUpgradeKey
    rebootInitiatedForThisUpgradeKey = $rebootInitiatedForThisUpgradeKey
    rebootInitiatedKey               = $rebootInitiatedKey
    installationAttemptCountKey      = $installationAttemptCountKey
  }
}
