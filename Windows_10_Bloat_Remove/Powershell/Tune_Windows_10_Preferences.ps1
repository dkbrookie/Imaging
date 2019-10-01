#/Services
## Disables diagnostics tracking services, various Xbox services, and Windows Media Player network sharing (you can turn this back on if you share your media libraries with WMP)
Get-Service Diagtrack,XblAuthManager,XblGameSave,XboxNetApiSvc,WMPNetworkSvc -EA 0 | Stop-Service -PassThru | Set-Service -StartupType Disabled

#/Non Local-GP Settings
## Disabling advertising info and device metadata collection for this machine
Reg Add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /T REG_DWORD /V "Enabled" /D 0 /F | Out-Null
Reg Add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" /V "PreventDeviceMetadataFromNetwork" /T REG_DWORD /D 1 /F | Out-Null
Write-Output 'Disabled Microsoft advertising services'

#/Windows Update
## Turn off featured software notifications through WU (basically ads)			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /T REG_DWORD /V "EnableFeaturedSoftware" /D 0 /F | Out-Null
Write-Output 'Disabled Microsoft new application advertising'

#/Delivery optimization			
## Disable DO; set to 1 to allow DO over LAN only			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /T REG_DWORD /V "DODownloadMode" /D 1 /F | Out-Null
Write-Output 'Disabled WAN update sharing, enabled local update sharing'

#/Microsoft Edge			
## Always send do not track			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" /T REG_DWORD /V "DoNotTrack" /D 1 /F | Out-Null
Write-Output 'Set Edge to Do Not Track'

#/Data Collection and Preview Builds			
## Set Telemetry to basic (switches to 1:basic for W10Pro and lower, disabled altogether by disabling service anyways)			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /T REG_DWORD /V "AllowTelemetry" /D 0 /F | Out-Null
## Disable pre-release features and settings			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds" /T REG_DWORD /V "EnableConfigFlighting" /D 0 /F | Out-Null
## Do not show feedback notifications			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /T REG_DWORD /V "DoNotShowFeedbackNotifications" /D 1 /F | Out-Null
Write-Output 'Disabled pre-release builds and data collection notifications'

#/Cloud Content			
## Do not show Windows Tips			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /T REG_DWORD /V "DisableSoftLanding" /D 1 /F | Out-Null
## Turn off Consumer Experiences			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /T REG_DWORD /V "DisableWindowsConsumerFeatures" /D 1 /F | Out-Null
Write-Output 'Disabled Windows 10 tips and consumer experience (ads / live tiles in the start menu)'

#/Search
## Disallow web search from desktop search			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /T REG_DWORD /V "DisableWebSearch" /D 1 /F | Out-Null
## Don't search the web or display web results in search			
Reg Add	"HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /T REG_DWORD /V "ConnectedSearchUseWeb" /D 0 /F | Out-Null
Write-Output 'Disabled bing/web search from the start menu'