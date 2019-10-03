## Deploy Ninite applications
$niniteDownload = "https://drive.google.com/uc?export=download&id=1OjOOahQ3xWxFXDEOltTPOZnUss9UTqGT"
$niniteDir = "$env:windir\LTSvc\packages\OS\Win10\1903\"
$niniteEXE = "$niniteDir\ninitePro.exe"

If (!(Test-Path $niniteDir)) {
    New-Item $niniteDir -ItemType Directory | Out-Null
}

Try {
    (New-Object System.Net.WebClient).DownloadFile($niniteDownload,$niniteEXE)
} Catch {
    Write-Warning 'There was a problem downloading Ninite Pro'
    Break
}

Try {
    Start-Process $niniteEXE -ArgumentList "/silent /select Reader Chrome ""Flash (IE)"" Flash "".NET 4.8"" Silverlight Java" -Wait
} Catch {
    Write-Warning 'There was a problem deploying Ninite applications'
    Break
}

## Deploy Adblock Plus for IE
(New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/dkbrookie/PowershellFunctions/master/Function.Install-MSI.ps1') | iex
Install-MSI -AppName 'Adblock Plus' -Arguments "/qn" -FileDownloadLink 'https://drive.google.com/uc?export=download&id=1Pt_w9xsfVKDoxln1DbUtjsJ9akWKBBqF'

## Deploy Adblock Plus for Chrome
$chromeGPODir = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist\'
If ((Get-ItemProperty $chromeGPODir -Name '1').1 -ne 'cfhdojbkjhnklbpkdaibdccddilifddb') {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome\' -EA 0
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist\' -EA 0
    Set-ItemProperty -Path $chromeGPODir -Name '1' -Value 'cfhdojbkjhnklbpkdaibdccddilifddb'
} Else {
    Write-Output 'Verified Chrome Adblock Plus GPO reg auto deploy is set'
}