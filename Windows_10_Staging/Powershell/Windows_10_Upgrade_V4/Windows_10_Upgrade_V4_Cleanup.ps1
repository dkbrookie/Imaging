$outputLog = @()

# Define build number this script will upgrade you to, should be like '20H2'
# This should be defined in the calling script
If (!$automateWin10Build) {
    Write-Output "!ERROR: No Windows Build was defined! Please define the `$automateWin10Build variable to something like '20H2' and then run this again!"
    Return
}

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
######################
## Define Constants ##
######################
#>

$workDir = "$env:windir\LTSvc\packages\OS"
$downloadDir = "$workDir\Win10\$automateWin10Build"
$isoFilePath = "$downloadDir\$automateWin10Build.iso"
$regPath = 'HKLM:\\SOFTWARE\LabTech\Service\Win10Upgrade'
$jobIdKey = "JobId"

Try {
    Remove-ItemProperty -Path $regPath -Name $jobIdKey -Force -ErrorAction Stop
} Catch {
    $outputLog += Get-ErrorMessage $_ "Could not remove JobId reg key."
}

Try {
    Remove-Item -Path $isoFilePath -Force -ErrorAction Stop
} Catch {
    $outputLog += Get-ErrorMessage $_ "Could not remove ISO."
}

$outputLog += "Done."

Invoke-Output $outputLog
