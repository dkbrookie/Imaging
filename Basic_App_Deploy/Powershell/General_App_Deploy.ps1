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