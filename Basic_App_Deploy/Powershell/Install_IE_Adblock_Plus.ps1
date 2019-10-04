(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Install-MSI.ps1') | iex
Install-MSI -AppName 'Adblock Plus' -Arguments "/qn" -FileDownloadLink 'https://drive.google.com/uc?export=download&id=1Pt_w9xsfVKDoxln1DbUtjsJ9akWKBBqF'
