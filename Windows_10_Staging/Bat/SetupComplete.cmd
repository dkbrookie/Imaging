@echo off

REM Enable the local administrator account
net user Administrator /active:yes
net user Administrator Dummy!

REM Run bloatware remover
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Bloatware_Remover.ps1') | iex;}"

REM Tune Windows 10 settings
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Tune_Windows_10_Preferences.ps1') | iex;}"

REM Install basic apps w/ Ninite
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Basic_App_Deploy/Powershell/General_App_Deploy.ps1') | iex;}"

REM Install Adblock Plus for Chrome
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Basic_App_Deploy/Powershell/Install_Chrome_Adblock_Plus.ps1') | iex;}"

REM Install Adblock Plus for IE
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Basic_App_Deploy/Powershell/Install_IE_Adblock_Plus.ps1') | iex;}"

REM Update drivers and OS
powershell.exe -ExecutionPolicy Bypass -Command "& {(new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/Imaging/master/Windows_10_Staging/Powershell/Update_Drivers_And_OS.ps1') | iex;}"
