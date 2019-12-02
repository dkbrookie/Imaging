## Bloatware removal
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Bloatware_Remover.ps1') | Invoke-Expression
## Tune Windows 10 preferences
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Tune_Windows_10_Preferences.ps1') | Invoke-Expression
## Deploy basic apps w/ Ninite
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Basic_App_Deploy/Powershell/General_App_Deploy.ps1') | Invoke-Expression
## Install drivers and OS updates
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Update_Drivers_And_OS.ps1') | Invoke-Expression
