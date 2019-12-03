## Run this script last since it will reboot!

## Install PSWindowsUpdate
Install-PackageProvider -Name NuGet -Force -Confirm:$False -EA 0 | Out-Null
Install-Module -Name PSWindowsUpdate -Force -Confirm:$False -EA 0 | Out-Null

## Import the PowerShell Module
Import-Module PSWindowsUpdate

## Install or update all drivers
Write-Output 'Checking for driver updates...'
Install-WindowsUpdate -Category Driver -AcceptAll -Install -Verbose
## Install all missing windows updates
Write-Output 'Checking for general Windows updates...'
Install-WindowsUpdate -AcceptAll -Install -Verbose