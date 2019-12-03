## This script is called from X:\Windows\System32\startnet.cmd. You can add anything you want to this file
## and it will execute when PE starts. If you mount the image on a workstation you can find this file at 
<#
C:\WinPE_amd64_PS_v2\mount\Windows\System32\startnet.cmd

Open Deployment and Imaging Tools Environment CMD prompt as admin

Mount the image with Dism /Mount-Image /ImageFile:"C:\WinPE_amd64_PS_v2\media\sources\boot.wim" /index:1 /MountDir:"C:\WinPE_amd64_PS_v2\mount"

Unmount and commit changes with Dism /Unmount-Image /MountDir:"C:\WinPE_amd64_PS_v2\mount" /commit

Create bootable USB with MakeWinPEMedia /UFD C:\WinPE_amd64_PS_v2 F:

Create ISO with MakeWinPEMedia /ISO C:\WinPE_amd64_PS_v2 C:\WinPE_amd64_PS_v2\WinPE_amd64_PS_v2.iso

Full instructions here: https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-mount-and-customize#addwallpaper

Add Powershell support to the PE image

Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-WMI.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-WMI_en-us.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-NetFX.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-NetFX_en-us.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-Scripting.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-Scripting_en-us.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-PowerShell.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-PowerShell_en-us.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-StorageWMI.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-StorageWMI_en-us.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\WinPE-DismCmdlets.cab"
Dism /Add-Package /Image:"C:\WinPE_amd64_PS_v2\mount" /PackagePath:"C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs\en-us\WinPE-DismCmdlets_en-us.cab"
#>

#region fileChecks
$1903Dir = "X:\Windows\Win10Deploy\Win10.Pro.1903.x64"
$windowslogs = "$1903Dir\Win10-Install-Logs"
$SetupComplete = "$1903Dir\SetupComplete.cmd"

Try {
    ## Find the drive mounted that has the install files
    $drives = (Get-PSDrive).Name -match '^[a-z]$'
    ForEach ($drive in $drives) {
        If ($drive -like '*c*') {
        } ElseIf ($drive -like '*d*') {
        } Else {
            $path = $drive + ':\INSTALL DIR DO NOT REMOVE.txt' 
            If ((Get-ChildItem -File $path -EA 0)) {
                $setupPath = $drive + ':\Setup.exe'
            }
        }
    }
    ## Call setup.exe w/ all of our required install arguments
    Start-Process -FilePath $setupPath -ArgumentList "/Auto Clean /Quiet /Compat IgnoreWarning /ShowOOBE None /DynamicUpdate Enable /ResizeRecoveryPartition Enable /copylogs $windowslogs /PostOOBE $setupComplete" -PassThru
} Catch {
    Write-Warning "Setup ran into an issue while attempting to install the 1903 upgrade."
}
#endregion download/install



