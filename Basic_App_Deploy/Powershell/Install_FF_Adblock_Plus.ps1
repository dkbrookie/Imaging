$ff64 = "$env:ProgramFiles\Mozilla Firefox\firefox.exe"
$ff86 = "${env:ProgramFiles(x86)}\Mozille Firefox\firefox.exe"
$ffDir = "$env:windir\LTSvc\packages\Software\Mozilla\Firefox"
$adblockInstall = "$ffDir\AdblockPlus.xpi"
$adblockURL = "https://addons.cdn.mozilla.net/user-media/addons/1865/adblock_plus-3.6.3-an+fx.xpi?filehash=sha256%3Ae5e00d678f99f6275fc1fe4279cad134224987965b7b4c7de587a37dcbed970e"

If (!(Test-Path $ffDir)) {
    New-Item $ffDir | Out-Null
}

Try {
    (New-Object System.Net.WebClient).DownloadFile($adblockURL,$adblockInstall)
} Catch {
    Write-Warning "There was a problem trying to download Adblock Plus for Firefox"
    Break
}

Try {
    If ((Test-Path $ff64 -PathType Leaf) {
        Start-Process $ff64 -ArgumentList "-install-global-extension ""$adblockInstall"""
    }

    If ((Test-Path $ff86 -PathType Leaf)) {
        Start-Process $ff86 -ArgumentList "-install-global-extension ""$adblockInstall"""
    }
} Catch {
    Write-Warning "There was a problem when attempting to install Adblock Plus for Firefox"
}