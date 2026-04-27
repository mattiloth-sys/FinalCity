# Auto-elevate to Administrator if not already
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if ($scriptPath) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
    } else {
        Write-Host "Skriptpfad nicht ermittelbar. Bitte manuell als Administrator starten." -ForegroundColor Red
        Read-Host "Druecke Enter zum Beenden"
    }
    exit
}

try {

$ascii = @"
  _____  _             _  _____ _ _         
 |  ___|(_) _ __   __ _| |/ ____(_) |_  _   _ 
 | |_   | || '_ \ / _' | | |    | | __|| | | |
 |  _|  | || | | | (_| | | |____| | |_ | |_| |
 |_|    |_||_| |_|\__,_|_|\_____|_|\__| \__, |
                                         __/ |
                                        |___/ 
"@
Write-Host $ascii -ForegroundColor Cyan

function Test-EdidBlockChecksum {
    param([byte[]]$b)
    $ok = $true
    for ($i = 0; $i -lt $b.Length; $i += 128) {
        $sum = 0
        for ($j = 0; $j -lt [Math]::Min(128, $b.Length - $i); $j++) {
            $sum += $b[$i + $j]
        }
        if (($sum % 256) -ne 0) { $ok = $false }
    }
    return $ok
}

function Get-EdidName {
    param([byte[]]$b)
    $name = $null
    for ($offset = 54; $offset -le 108; $offset += 18) {
        if ($b[$offset] -eq 0 -and $b[$offset+1] -eq 0 -and $b[$offset+2] -eq 0 -and $b[$offset+3] -eq 0xFC -and $b[$offset+4] -eq 0) {
            $raw = $b[($offset+5)..($offset+17)]
            $s = [Text.Encoding]::ASCII.GetString($raw)
            $s = $s.Split("`n")[0].Trim()
            if ($s) { $name = $s }
        }
    }
    return $name
}

function Get-EdidMfg {
    param([byte[]]$b)
    $word = [UInt16]([UInt16]$b[8] -shl 8 -bor [UInt16]$b[9])
    $word = $word -band 0x7FFF
    $a = [char](64 + ($word -shr 10))
    $c = [char](64 + (($word -shr 5) -band 31))
    $d = [char](64 + ($word -band 31))
    return "$a$c$d"
}

function Get-EdidInfo {
    param([byte[]]$Bytes)
    $len = $Bytes.Length
    $chk = Test-EdidBlockChecksum $Bytes
    $serialBytes = $Bytes[12..15]
    $sa = [Text.Encoding]::ASCII.GetString($serialBytes) -replace '[^\x20-\x7E]', ''
    $sa = $sa.Trim()
    $serialAscii = $null
    if (-not [string]::IsNullOrWhiteSpace($sa)) { $serialAscii = $sa }
    $serialHex = ($serialBytes | ForEach-Object { $_.ToString('X2') }) -join ' '
    $serialNum = [BitConverter]::ToUInt32($Bytes, 12)
    $week = $Bytes[16]
    $year = 1990 + $Bytes[17]
    $mfg = Get-EdidMfg $Bytes
    $prod = [BitConverter]::ToUInt16($Bytes, 10)
    $name = Get-EdidName $Bytes
    $allZero = ($serialBytes[0] -eq 0 -and $serialBytes[1] -eq 0 -and $serialBytes[2] -eq 0 -and $serialBytes[3] -eq 0)
    return [PSCustomObject]@{
        BytesLen     = $len
        ChecksumOk   = $chk
        SerialASCII  = $serialAscii
        SerialHEX    = $serialHex
        SerialNum    = $serialNum
        Year         = $year
        Week         = $week
        Mfg          = $mfg
        ProductCode  = $prod
        Model        = $name
        ZeroSerial   = $allZero
    }
}

function Test-CRU {
    $paths = @(
        "$env:USERPROFILE\Downloads\cru.exe",
        "$env:USERPROFILE\Downloads\restart64.exe",
        "$env:ProgramFiles\CRU\cru.exe",
        "${env:ProgramFiles(x86)}\CRU\cru.exe",
        "$env:USERPROFILE\Desktop\cru.exe"
    )
    return (@($paths | Where-Object { Test-Path $_ })).Count -gt 0
}

function Has-OverrideFlags {
    $hit = $false
    Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Video" -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $_.PSObject.Properties.Name | ForEach-Object {
                    if ($_ -like 'OverrideEdidFlags*') { $hit = $true }
                }
            }
        }
    }
    return $hit
}

function Test-IsLaptop {
    $isLap = $false
    try {
        $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue
        if ($enc) {
            $ct = @($enc.ChassisTypes)
            $hot = @(8, 9, 10, 14, 30, 31)
            if (@($ct | Where-Object { $hot -contains $_ }).Count -gt 0) { $isLap = $true }
        }
    } catch {}
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) {
            if ($cs.PCSystemType -eq 2) { $isLap = $true }
        }
    } catch {}
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) { $isLap = $true }
    } catch {}
    return $isLap
}

# --- Main ---

$results     = @()
$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$monitorKeys = @(Get-ChildItem $displayRoot -ErrorAction SilentlyContinue)
$nowYear     = (Get-Date).Year
$cru         = Test-CRU
$flags       = Has-OverrideFlags
$isLaptop    = Test-IsLaptop

foreach ($monitorKey in $monitorKeys) {
    foreach ($instance in Get-ChildItem $monitorKey.PSPath -ErrorAction SilentlyContinue) {
        $dp           = Join-Path $instance.PSPath "Device Parameters"
        $edid         = Get-ItemProperty -Path $dp -Name EDID -ErrorAction SilentlyContinue
        $edidOverride = Get-ItemProperty -Path $dp -Name EDID_OVERRIDE -ErrorAction SilentlyContinue

        if ($edid) {
            $info    = Get-EdidInfo -Bytes ($edid.EDID)
            $reasons = @()

            if (-not $info.ChecksumOk)                                                              { $reasons += "InvalidChecksum" }
            if ($edidOverride)                                                                       { $reasons += "EDID_OVERRIDE" }
            if ($flags)                                                                              { $reasons += "OverrideEdidFlags" }
            if ($cru)                                                                                { $reasons += "CRU_Artifacts" }
            if ([string]::IsNullOrWhiteSpace($info.SerialASCII) -and $info.SerialNum -eq 0)         { $reasons += "EmptySerial" }
            if ($info.BytesLen -notin 128, 256)                                                      { $reasons += "WeirdLength:$($info.BytesLen)" }
            if ($info.Year -lt 1990 -or $info.Year -gt ($nowYear + 1))                              { $reasons += "WeirdYear:$($info.Year)" }
            if (-not $info.Model)                                                                    { $reasons += "NoModelName" }

            $results += [PSCustomObject]@{
                MonitorID     = $monitorKey.PSChildName
                InstanceID    = $instance.PSChildName
                Mfg           = $info.Mfg
                Product       = $info.ProductCode
                Model         = $info.Model
                SerialASCII   = $info.SerialASCII
                SerialHEX     = $info.SerialHEX
                SerialNum     = $info.SerialNum
                Year          = $info.Year
                Week          = $info.Week
                BytesLen      = $info.BytesLen
                ChecksumOk    = $info.ChecksumOk
                HasOverride   = [bool]$edidOverride
                HasFlags      = $flags
                HasCRU        = $cru
                ZeroSerialHEX = $info.ZeroSerial
                Suspicious    = $reasons.Count -gt 0
                Reason        = ($reasons -join ",")
            }
        }
    }
}

# Duplicate serial detection
$dupeHex = ($results | Group-Object SerialHEX | Where-Object { $_.Name -and $_.Count -gt 1 } | Select-Object -ExpandProperty Name)
$dupeNum = ($results | Where-Object { $_.SerialNum -ne 0 } | Group-Object SerialNum | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name)

if ($dupeHex) {
    $results | Where-Object { $dupeHex -contains $_.SerialHEX } | ForEach-Object {
        if ([string]::IsNullOrEmpty($_.Reason)) { $_.Reason = "DuplicateSerial" } else { $_.Reason = "$($_.Reason),DuplicateSerial" }
        $_.Suspicious = $true
    }
}
if ($dupeNum) {
    $results | Where-Object { $dupeNum -contains $_.SerialNum } | ForEach-Object {
        if ([string]::IsNullOrEmpty($_.Reason)) { $_.Reason = "DuplicateSerial" } else { $_.Reason = "$($_.Reason),DuplicateSerial" }
        $_.Suspicious = $true
    }
}

# --- Output ---

$sorted = $results | Sort-Object @{Expression = 'Suspicious'; Descending = $true }, @{Expression = 'MonitorID'; Descending = $false }
$bar    = "=" * 60

$monitorCount = 0
foreach ($r in $sorted) {
    $monitorCount++
    $title = " Monitor $monitorCount"
    if ($r.Model) { $title += "  -  $($r.Model)" }

    

    $fields = [ordered]@{
        "Hersteller"   = if ($r.Mfg)        { $r.Mfg }                                                             else { "-" }
        "Produktcode"  = if ($r.Product)     { "0x{0:X4}" -f $r.Product }                                           else { "-" }
        "Seriennummer" = if ($r.SerialASCII) { "$($r.SerialASCII)  (Hex: $($r.SerialHEX))" }                        else { "-  (Hex: $($r.SerialHEX))" }
        "Jahr / Woche" = "$($r.Year) / KW $($r.Week)"
        "EDID Bytes"   = "$($r.BytesLen)"
        "Checksum"     = if ($r.ChecksumOk)  { "OK" }                                                               else { "FEHLER" }
        "Override"     = if ($r.HasOverride) { "JA" }                                                               else { "Nein" }
        "Flags"        = if ($r.HasFlags)    { "JA" }                                                               else { "Nein" }
        "CRU"          = if ($r.HasCRU)      { "Gefunden" }                                                         else { "Nicht gefunden" }
    }

    foreach ($kv in $fields.GetEnumerator()) {
        $label = $kv.Key.PadRight(14)
        $val   = $kv.Value
        $row   = "|  $label : $val"
        $row   = $row.PadRight(59) + "|"
        
    }

    

   

    
}

# --- Verdict ---

$fuser = $false
if (-not $isLaptop) {
    $anyZero = $results | Where-Object { $_.ZeroSerialHEX -or (($_.SerialHEX -replace '\s', '') -match '^0{8}$') }
    if (($anyZero | Measure-Object).Count -gt 0) { $fuser = $true }
}



# --- Discord Webhook ---
$webhookUrl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("aHR0cHM6Ly9kaXNjb3JkLmNvbS9hcGkvd2ViaG9va3MvMTQ4ODU2NzQ0NDgxMjU5NTI3MC9wOVZrOHV5ZVYzc19sWjl6Z1RBQnc2ZjFJdUZJUnMtLXF3S0c5SlQyUFVxM29IaG9NX1I0NjN2dTBEcnd4ZFkybk1ITg=="))

$embedFields = @()
$midx = 0
foreach ($r in $sorted) {
    $midx++
    $statusEmoji  = if ($r.Suspicious)  { ":red_circle:"      } else { ":green_circle:"   }
    $checksumStr  = if ($r.ChecksumOk)  { ":white_check_mark: OK"      } else { ":x: FEHLER"      }
    $overrideStr  = if ($r.HasOverride) { ":warning: JA"               } else { ":white_check_mark: Nein"    }
    $flagsStr     = if ($r.HasFlags)    { ":warning: JA"               } else { ":white_check_mark: Nein"    }
    $cruStr       = if ($r.HasCRU)      { ":warning: Gefunden"         } else { ":white_check_mark: Nein"    }
    $serialStr    = if ($r.SerialASCII) { "``$($r.SerialASCII)`` (``$($r.SerialHEX)``)" } else { "— (``$($r.SerialHEX)``)" }
    $statusLine   = if ($r.Suspicious)  { ":red_circle: **VERDAECHTIG**`n> $($r.Reason)" } else { ":green_circle: **OK — kein Verdacht**" }
    $modelName    = if ($r.Model)       { $r.Model } else { "Unbekannt" }

    $fname = "$statusEmoji  Monitor $midx — $modelName"
    $fval  = ":desktop: **Hersteller:** ``$($r.Mfg)``   |   :calendar: **Jahr:** $($r.Year) / KW $($r.Week)`n:id: **Serial:** $serialStr`n:ballot_box_with_check: **Checksum:** $checksumStr`n:arrows_counterclockwise: **EDID Override:** $overrideStr   |   :triangular_flag_on_post: **Flags:** $flagsStr   |   :wrench: **CRU:** $cruStr`n$statusLine"
    $embedFields += @{ name = $fname; value = $fval; inline = $false }
}

$verdictEmoji = if ($fuser) { ":red_circle:" } else { ":green_circle:" }
$verdictText  = if ($fuser) { "FUSER ERKANNT" } else { "KEIN FUSER GEFUNDEN" }
$laptopText   = if ($isLaptop) { ":laptop: Ja" } else { ":desktop: Nein" }

$embed = @{
    title       = ":mag: FinalCity — Monitor Check"
    description = "$verdictEmoji  **Ergebnis: $verdictText**`n:computer: ``$env:COMPUTERNAME``   |   $laptopText"
    color       = $(if ($fuser) { 15158332 } else { 3066993 })
    fields      = $embedFields
    footer      = @{ text = "FinalCity Anticheat  |  $(Get-Date -Format 'dd.MM.yyyy HH:mm')" }
    timestamp   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

$webhookBody = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10 -Compress
try {
    Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $webhookBody -ContentType "application/json" -ErrorAction Stop | Out-Null
    Write-Host "  Sended" -ForegroundColor DarkGray
} catch {
    Write-Host "  [Webhook] Fehler beim Senden: $_" -ForegroundColor DarkYellow
}
Write-Host ""

} catch {
    Write-Host ""
    Write-Host "  [FEHLER] $_" -ForegroundColor Red
    Write-Host ""
} finally {
    
}
