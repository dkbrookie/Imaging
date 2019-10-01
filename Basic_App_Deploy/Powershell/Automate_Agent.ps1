If (!$locationID) {
    $locationID = 1
}
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Install-MSI.ps1') | iex
Install-MSI -AppName 'Automate' -Arguments "/qn LOCATIONID=$locationID" -FileDownloadLink 'https://support.dkbinnovative.com/Labtech/Deployment.aspx?Probe=1&installType=msi&MSILocations=1'
