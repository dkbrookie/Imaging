$chromeGPODir = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist\'
If (!(Test-Path $chromeGPODir)) {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\' -EA 0 | Out-Null
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome\' -EA 0 | Out-Null
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist\' -EA 0 | Out-Null
    Set-ItemProperty -Path $chromeGPODir -Name '1' -Value 'cfhdojbkjhnklbpkdaibdccddilifddb' | Out-Null
    Write-Output 'Successfully set Chrome Adblock Plus GPO regf auto deploy'
} Else {
    Write-Output 'Verified Chrome Adblock Plus GPO reg auto deploy is set'
}