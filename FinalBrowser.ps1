#Requires -Version 5.1
<#
.SYNOPSIS
    FiveM & Cheat Aktivitaeten in Browsern aufspueren
.DESCRIPTION
    Benoetigt KEINE externe Software (kein sqlite3.exe, kein Python, kein Admin).
    Liest Browser-Datenbanken direkt mit einem eingebetteten C#-SQLite-Parser
    und durchsucht laufende Browser-Prozesse per ReadProcessMemory
    (dieselbe Methode wie System Informer / Strings).

    Unterstuetzte Browser: Chrome, Edge, Brave, Opera, Opera GX, Firefox
    Ausgabe: Konsole + Textdatei auf dem Desktop

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FiveMCheatScan.ps1
    powershell -ExecutionPolicy Bypass -File .\FiveMCheatScan.ps1 -ExportCSV
#>

[CmdletBinding()]
param(
    [string] $AusgabePfad  = "$env:USERPROFILE\Desktop\FiveM_Bericht_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt",
    [int]    $MaxEintraege = 5000,
    [switch] $ExportCSV
)

$ErrorActionPreference = "SilentlyContinue"
Set-StrictMode -Off

Write-Host ""
Write-Host "  _____ _             _  ____ _ _         " -ForegroundColor Cyan
Write-Host " |  ___(_)_ __   __ _| |/ ___(_) |_ _   _ " -ForegroundColor Cyan
Write-Host " | |_  | | '_ \ / _' | | |   | | __| | | |" -ForegroundColor Cyan
Write-Host " |  _| | | | | | (_| | | |___| | |_| |_| |" -ForegroundColor Cyan
Write-Host " |_|   |_|_| |_|\__,_|_|\____|_|\__|\__, |" -ForegroundColor Cyan
Write-Host "                                      |___/ " -ForegroundColor Cyan
Write-Host ""
try {

# =============================================================================
# CHEAT / FIVEM KEYWORDS
# =============================================================================
$Keywords = @(
    "fivem","cfx.re","cfxre","citizenfx","alt-v","altv","ragemp","samp",
    "cheat","hack","inject","injector","exploit","bypass","spoofer","hwid",
    "unban","aimbot","triggerbot","esp","wallhack","mod menu","modmenu",
    "trainer","cracked","crack","leaked","leak","free cheat","free hack",
    "external cheat","internal cheat","ragebot","hvh","bunnyhop","speedhack",
    "flyhack","godmode","teleport hack","money hack","lua executor","lua inject",
    "resource bypass","server bypass","fiveguard","badger","eulen","brutan",
    "unknowncheats","uc.me","mpgh.net","mpgh","elitepvpers","hackforums",
    "cracked.to","nulled.to","nulled","leakforums","v3rmillion","wearedevs",
    "fivem cheat","fivem hack","fivem bypass","fivem mod","fivem trainer",
    "fivem exploit","fivem lua","fivem crack","fivem free","fivem inject",
    "fivem standalone","fivem resource","fivem native","neverlose","onetap",
    "skycheats","aimclub","exodus-cheats","interwebz","iwcheats","projectinject",
    "cheatseller","ringofcheats","scripthookv","dinput8.dll","dsound.dll",
    "winhttp.dll","version.dll","d3d11 cheat",
    # GTA / FiveM Dateien und Mods
    "reshade","reshade.ini","enbseries","enblocal.ini","sweetfx",
    "bloodfx","blood.ytd","blood texture","bloodfx.asi","bloodfx.ini",
    "soundpack","sound pack","sounds.awc","audio.awc","sfxpack",
    "openiv","openiv.asi","openiv.oiv","asiloader","asi loader",
    "citizenfx","citizenfx.ini","citizen.dll","FiveM_GTAProcess",
    "fxmanifest","__resource.lua","resource.lua",
    "nativeui","vmenu","zmenu","menyoo","vehfuncs","mellotrainer",
    "dlcpacks","patchday","x64.rpf","update.rpf",".rpf",
    "GTA5.exe","gta_sa.exe","FiveM Application Data",
    "citizen/scripting","FiveM\\FiveM","plugins\\asi","mods\\update",
    "gta5 mod","gta v mod","gta online cheat","gta mod menu",
    "rage.dll","rage plugin","scripthookv.dll","scripthookv64"
)
$KwPattern = ($Keywords | ForEach-Object { [regex]::Escape($_) }) -join "|"
$KwRegex   = [regex]("(?i)(" + $KwPattern + ")")
function Test-Cheat { param([string]$s); return $KwRegex.IsMatch($s) }

# =============================================================================
# LOGGING
# =============================================================================
$Log  = [System.Text.StringBuilder]::new()
$Tmp  = Join-Path $env:TEMP "FiveMScan_$(Get-Date -Format 'HHmmss')"
$null = New-Item -ItemType Directory $Tmp -Force
$SEP1 = "=" * 88
$SEP2 = "-" * 88

$script:ShowProgress = $false

function L {
    param([string]$t = "", [ConsoleColor]$c = "White", [switch]$nn)
    if (-not $script:ShowProgress) {
        if ($nn) { Write-Host $t -ForegroundColor $c -NoNewline }
        else      { Write-Host $t -ForegroundColor $c }
    }
    $null = $Log.AppendLine($t)
}

function Show-Progress {
    param([string]$Status, [int]$Pct)
    Write-Progress -Activity "FiveM & Cheat Browser-Analyse" -Status $Status -PercentComplete ([Math]::Min($Pct, 99))
}

# =============================================================================
# C# SQLITE PARSER  (kein externes Tool noetig - reines .NET)
# =============================================================================
Show-Progress "Initialisierung ..." 1
if (-not ([Management.Automation.PSTypeName]'FMScan.SqliteReader').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace FMScan {

public class SqliteReader {
    private readonly byte[] _db;
    private readonly int    _ps;

    public SqliteReader(string path) {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete))
        using (MemoryStream ms = new MemoryStream()) {
            fs.CopyTo(ms);
            _db = ms.ToArray();
        }
        int ps = (_db.Length > 18) ? ((_db[16] << 8) | _db[17]) : 4096;
        _ps = (ps <= 1) ? 65536 : ps;
    }

    private byte[] GetPage(int n) {
        int off = (n - 1) * _ps;
        byte[] p = new byte[_ps];
        int avail = Math.Max(0, _db.Length - off);
        if (avail > 0) Array.Copy(_db, off, p, 0, Math.Min(_ps, avail));
        return p;
    }

    private static int U16(byte[] b, int o) {
        if (o + 1 >= b.Length) return 0;
        return (b[o] << 8) | b[o + 1];
    }

    private static long U32(byte[] b, int o) {
        if (o + 3 >= b.Length) return 0;
        return (long)(((uint)b[o] << 24) | ((uint)b[o+1] << 16)
                    | ((uint)b[o+2] <<  8) |  (uint)b[o+3]);
    }

    private static long Varint(byte[] b, int o, out int end) {
        long v = 0; end = o;
        for (int i = 0; i < 9; i++) {
            if (end >= b.Length) break;
            byte x = b[end++];
            if (i == 8) { v = (v << 8) | (uint)x; break; }
            v = (v << 7) | (uint)(x & 0x7F);
            if ((x & 0x80) == 0) break;
        }
        return v;
    }

    private int LocalSize(int total) {
        int M = ((_ps - 12) * 32 / 255) - 23;
        if (M < 0) M = 0;
        int maxL = _ps - 35;
        if (total <= maxL) return total;
        int s = M + ((total - M) % (_ps - 4));
        return (s <= maxL) ? s : M;
    }

    private byte[] ReadPayload(byte[] pg, int off, int total) {
        if (total <= 0 || off >= pg.Length) return new byte[0];
        int cap = Math.Min(total, 2 * 1024 * 1024);
        byte[] buf = new byte[cap];
        int local = LocalSize(total);
        int copy = Math.Min(local, Math.Min(pg.Length - off, cap));
        if (copy > 0) Array.Copy(pg, off, buf, 0, copy);
        int pos = local;
        if (local < total && off + local + 4 <= pg.Length) {
            int ovPg = (int)U32(pg, off + local);
            int usable = _ps - 4;
            int safety = 0;
            while (ovPg > 0 && pos < cap && safety++ < 500) {
                byte[] op = GetPage(ovPg);
                ovPg = (int)U32(op, 0);
                int chunk = Math.Min(cap - pos, usable);
                int avail = Math.Max(0, op.Length - 4);
                int c2 = Math.Min(chunk, avail);
                if (c2 > 0) Array.Copy(op, 4, buf, pos, c2);
                pos += chunk;
            }
        }
        return buf;
    }

    private string[] ParseRecord(byte[] pg, int off, int total) {
        try {
            byte[] payload = ReadPayload(pg, off, total);
            if (payload.Length == 0) return null;
            int p = 0;
            long hdr = Varint(payload, p, out p);
            if (hdr <= 0 || hdr > payload.Length) return null;
            List<long> types = new List<long>();
            int hp = p, he = (int)hdr;
            while (hp < he && hp < payload.Length && types.Count < 200)
                types.Add(Varint(payload, hp, out hp));
            string[] row = new string[types.Count];
            int dp = he;
            for (int i = 0; i < types.Count; i++) {
                if (dp >= payload.Length) break;
                long t = types[i];
                try {
                    if      (t == 0) { row[i] = null; }
                    else if (t == 1) { row[i] = ((sbyte)payload[dp]).ToString(); dp++; }
                    else if (t == 2) { row[i] = ((short)U16(payload,dp)).ToString(); dp+=2; }
                    else if (t == 3) {
                        int v=(payload[dp]<<16)|(payload[dp+1]<<8)|payload[dp+2];
                        if ((v&0x800000)!=0) v|=unchecked((int)0xFF000000);
                        row[i]=v.ToString(); dp+=3;
                    }
                    else if (t == 4) { row[i]=((int)U32(payload,dp)).ToString(); dp+=4; }
                    else if (t == 5) {
                        long v=0;
                        for(int b=0;b<6&&dp+b<payload.Length;b++) v=(v<<8)|payload[dp+b];
                        row[i]=v.ToString(); dp+=6;
                    }
                    else if (t == 6) {
                        long v=0;
                        for(int b=0;b<8&&dp+b<payload.Length;b++) v=(v<<8)|payload[dp+b];
                        row[i]=v.ToString(); dp+=8;
                    }
                    else if (t == 7) { dp+=8; row[i]=""; }
                    else if (t == 8) { row[i]="0"; }
                    else if (t == 9) { row[i]="1"; }
                    else if (t>=12 && t%2==0) { int l=(int)((t-12)/2); row[i]=""; dp+=l; }
                    else if (t>=13 && t%2==1) {
                        int l=(int)((t-13)/2);
                        row[i]=(l>0&&dp+l<=payload.Length)
                               ? Encoding.UTF8.GetString(payload,dp,l) : "";
                        dp+=l;
                    }
                } catch { dp=payload.Length; break; }
            }
            return row;
        } catch { return null; }
    }

    private void Walk(int pgNum, List<string[]> rows, HashSet<int> seen) {
        if (pgNum < 1 || seen.Contains(pgNum)) return;
        seen.Add(pgNum);
        byte[] pg = GetPage(pgNum);
        int hOff = (pgNum == 1) ? 100 : 0;
        if (hOff >= pg.Length) return;
        byte pt = pg[hOff];
        bool leaf  = (pt == 0x0D);
        bool inter = (pt == 0x05);
        if (!leaf && !inter) return;
        int nc = U16(pg, hOff+3);
        if (nc > 50000) return;
        int rm  = inter ? (int)U32(pg, hOff+8) : 0;
        int cpb = hOff + (leaf ? 8 : 12);
        for (int i = 0; i < nc; i++) {
            int po = cpb + i*2;
            if (po+2 > pg.Length) break;
            int co = U16(pg, po);
            if (co == 0 || co >= pg.Length) continue;
            if (inter) {
                Walk((int)U32(pg, co), rows, seen);
            } else {
                int pos = co;
                long sz = Varint(pg, pos, out pos);
                Varint(pg, pos, out pos);
                if (sz > 0 && sz < 5*1024*1024 && pos < pg.Length) {
                    string[] r = ParseRecord(pg, pos, (int)sz);
                    if (r != null) rows.Add(r);
                }
            }
        }
        if (inter && rm > 0) Walk(rm, rows, seen);
    }

    public List<Dictionary<string,string>> ReadTable(string tbl) {
        List<Dictionary<string,string>> result = new List<Dictionary<string,string>>();
        try {
            List<string[]> master = new List<string[]>();
            Walk(1, master, new HashSet<int>());
            int rootPage = 0;
            string[] cols = null;
            foreach (string[] r in master) {
                if (r == null || r.Length < 4) continue;
                if (!"table".Equals(r[0], StringComparison.OrdinalIgnoreCase)) continue;
                if (!tbl.Equals(r[1], StringComparison.OrdinalIgnoreCase))     continue;
                int.TryParse(r[3], out rootPage);
                if (r.Length >= 5 && r[4] != null) cols = ParseCols(r[4]);
                break;
            }
            if (rootPage < 1 || cols == null || cols.Length == 0) return result;
            List<string[]> data = new List<string[]>();
            Walk(rootPage, data, new HashSet<int>());
            foreach (string[] row in data) {
                Dictionary<string,string> d =
                    new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < cols.Length; i++)
                    d[cols[i]] = (i < row.Length && row[i] != null) ? row[i] : "";
                result.Add(d);
            }
        } catch {}
        return result;
    }

    private static string[] ParseCols(string sql) {
        Match m = Regex.Match(sql, @"\((.+)\)\s*$", RegexOptions.Singleline);
        if (!m.Success) return new string[0];
        List<string> defs = new List<string>();
        int depth = 0;
        StringBuilder cur = new StringBuilder();
        foreach (char c in m.Groups[1].Value) {
            if      (c == '(') { depth++; cur.Append(c); }
            else if (c == ')') { depth--; cur.Append(c); }
            else if (c == ',' && depth == 0) { defs.Add(cur.ToString().Trim()); cur.Clear(); }
            else cur.Append(c);
        }
        if (cur.Length > 0) defs.Add(cur.ToString().Trim());
        List<string> cols = new List<string>();
        foreach (string def in defs) {
            string u = def.TrimStart().ToUpper();
            if (u.StartsWith("PRIMARY") || u.StartsWith("UNIQUE")  ||
                u.StartsWith("FOREIGN") || u.StartsWith("CHECK")   ||
                u.StartsWith("CONSTRAINT")) continue;
            Match cm = Regex.Match(def.TrimStart(), @"^[`""']?(\w+)[`""']?");
            if (cm.Success) cols.Add(cm.Groups[1].Value.ToLower());
        }
        return cols.ToArray();
    }
}

} // namespace FMScan
'@
}

# =============================================================================
# C# WINDOWS API (ReadProcessMemory / VirtualQueryEx)
# =============================================================================
if (-not ([Management.Automation.PSTypeName]'FMScan.WinApi').Type) {
    Add-Type -Language CSharp -Namespace FMScan -Name WinApi -MemberDefinition @'
[DllImport("kernel32.dll",SetLastError=true)]
public static extern IntPtr OpenProcess(uint a,bool b,int pid);
[DllImport("kernel32.dll",SetLastError=true)]
public static extern bool ReadProcessMemory(IntPtr h,IntPtr base_,
    [Out]byte[] buf,long sz,out long rd);
[DllImport("kernel32.dll",SetLastError=true)]
public static extern bool CloseHandle(IntPtr h);
[DllImport("kernel32.dll",SetLastError=true)]
public static extern long VirtualQueryEx(IntPtr h,IntPtr addr,out MBI mbi,long sz);
[StructLayout(LayoutKind.Sequential)]
public struct MBI {
    public IntPtr Base, AllocBase;
    public uint   AllocProt;
    public IntPtr Size;
    public uint   State, Prot, Type;
}
public const uint VM_READ=0x0010, QI=0x0400, COMMIT=0x1000, NOACC=0x01, GUARD=0x100;
'@
}

# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================
function fmtChr {
    param([string]$v)
    try {
        $u=[Int64]$v; if($u-le 0){return "-"}
        return [DateTime]::new(1601,1,1,0,0,0,'Utc').AddTicks($u*10).ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss")
    } catch { return "?" }
}
function fmtFx {
    param([string]$v)
    try {
        $u=[Int64]$v; if($u-le 0){return "-"}
        return [DateTimeOffset]::FromUnixTimeMilliseconds($u/1000).LocalDateTime.ToString("dd.MM.yyyy HH:mm:ss")
    } catch { return "?" }
}
function fmtSz {
    param([string]$v)
    try {
        $b=[Int64]$v
        if ($b -le 0) { return "     -" }
        if ($b -lt 1MB) { return ("{0,6:N0} KB" -f ($b / 1KB)) }
        return ("{0,6:N1} MB" -f ($b / 1MB))
    } catch { return "     ?" }
}
function ReadDB {
    param([string]$Path,[string]$Table)
    $tmp=[IO.Path]::Combine($Tmp,[IO.Path]::GetRandomFileName()+".db")
    try {
        Copy-Item $Path $tmp -Force
        return [FMScan.SqliteReader]::new($tmp).ReadTable($Table)
    } catch { return @() }
    finally { Remove-Item $tmp -Force -EA SilentlyContinue }
}

# =============================================================================
# BROWSER-PROFILE
# =============================================================================
$Defs = @(
    @{N="Chrome";  T="ch"; B="$env:LOCALAPPDATA\Google\Chrome\User Data"}
    @{N="Edge";    T="ch"; B="$env:LOCALAPPDATA\Microsoft\Edge\User Data"}
    @{N="Brave";   T="ch"; B="$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"}
    @{N="Opera";   T="ch"; B="$env:APPDATA\Opera Software\Opera Stable"}
    @{N="OperaGX"; T="ch"; B="$env:APPDATA\Opera Software\Opera GX Stable"}
    @{N="Firefox"; T="fx"; B="$env:APPDATA\Mozilla\Firefox\Profiles"}
)

$AllProf = [Collections.Generic.List[hashtable]]::new()
foreach ($d in $Defs) {
    if (-not (Test-Path $d.B)) { continue }
    if ($d.T -eq "fx") {
        Get-ChildItem $d.B -Directory -EA SilentlyContinue | ForEach-Object {
            $AllProf.Add(@{ N=$d.N; Profil=$_.Name; T="fx"; H=Join-Path $_.FullName "places.sqlite" })
        }
    } else {
        $subs = Get-ChildItem $d.B -Directory -EA SilentlyContinue |
                Where-Object { $_.Name -match "^(Default|Profile\s*\d+)$" }
        if ($subs) {
            $subs | ForEach-Object {
                $AllProf.Add(@{ N=$d.N; Profil=$_.Name; T="ch"; H=Join-Path $_.FullName "History" })
            }
        } else {
            $h=Join-Path $d.B "History"
            if (Test-Path $h) { $AllProf.Add(@{ N=$d.N; Profil="Default"; T="ch"; H=$h }) }
        }
    }
}

# =============================================================================
# KOPFZEILE (ins Log schreiben, aber nicht auf Konsole - Progress laeuft)
# =============================================================================
$null = $Log.AppendLine($SEP1)
$null = $Log.AppendLine("  FIVEM & CHEAT BROWSER-ANALYSE")
$null = $Log.AppendLine("  Datum    : " + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))
$null = $Log.AppendLine("  Benutzer : " + $env:USERNAME + "  |  PC: " + $env:COMPUTERNAME)
$null = $Log.AppendLine("  Methode  : Eingebetteter C#-SQLite-Parser + ReadProcessMemory (keine Installation noetig)")
$null = $Log.AppendLine("  Browser  : Chrome, Edge, Brave, Opera, Opera GX, Firefox  |  Profile: " + $AllProf.Count)
$null = $Log.AppendLine($SEP1)
$null = $Log.AppendLine("")
$AllProf | ForEach-Object {
    $ok = if (Test-Path $_.H) { "OK" } else { "DB nicht gefunden" }
    $null = $Log.AppendLine("  [" + $_.N.PadRight(8) + "] " + $_.Profil.PadRight(15) + " [" + $ok + "]  " + $_.H)
}
$null = $Log.AppendLine("")

$csvDl       = [Collections.Generic.List[PSObject]]::new()
$csvHist     = [Collections.Generic.List[PSObject]]::new()
$csvRam      = [Collections.Generic.List[PSObject]]::new()
$csvArtefakt = [Collections.Generic.List[PSObject]]::new()
# Discord-Tracker: Dateiname -> Liste aller Downloads dieser Datei
$discordMap = [Collections.Generic.Dictionary[string,Collections.Generic.List[PSObject]]]::new([StringComparer]::OrdinalIgnoreCase)

# =============================================================================
# PRO PROFIL: DOWNLOADS + VERLAUF
# =============================================================================
$script:ShowProgress = $true
Show-Progress "Starte Scan ..." 1
$_profIdx   = 0
$_profTotal = [Math]::Max(1, $AllProf.Count)
foreach ($p in $AllProf) {

    $_profPct = [int](5 + ($_profIdx / $_profTotal) * 55)
    Show-Progress ("Profil [{0}] {1} - Downloads ..." -f $p.N, $p.Profil) $_profPct

    L $SEP2 "DarkCyan"
    L ("  [{0}]  Profil: {1}" -f $p.N, $p.Profil) "Cyan"
    L $SEP2 "DarkCyan"

    if (-not (Test-Path $p.H)) {
        L "  Datenbankdatei nicht gefunden." "DarkYellow"
        L ""
        $_profIdx++
        continue
    }

    # ─── DOWNLOADS ─────────────────────────────────────────────────────────
    L "  [DOWNLOADS mit FiveM / Cheat-Bezug]" "Green"
    $dlN = 0

    if ($p.T -eq "ch") {
        foreach ($r in (ReadDB $p.H "downloads")) {
            $pfad  = $r["target_path"]
            $src   = $r["tab_url"]
            $ref   = $r["referrer"]
            $mime  = $r["mime_type"]
            $zeit  = fmtChr $r["start_time"]
            $sz    = fmtSz  $r["total_bytes"]
            # Discord Attachment Tracking (alle Downloads, unabhaengig von Cheat-Keywords)
            if ($src -match 'cdn\.discordapp\.com/attachments/[^/]+/[^/]+/([^?#/]+)') {
                $dname = $Matches[1]
                if (-not $discordMap.ContainsKey($dname)) { $discordMap[$dname] = [Collections.Generic.List[PSObject]]::new() }
                $discordMap[$dname].Add([PSCustomObject]@{Browser=$p.N;Profil=$p.Profil;Zeit=$zeit;Pfad=$pfad;URL=$src;Bytes=$r["total_bytes"]})
            }
            if (-not (Test-Cheat "$pfad $src $ref $mime")) { continue }
            $dlN++
            L ("  {0}  {1}  {2}" -f $zeit,$sz,$pfad) "Yellow"
            if ($src)                  { L ("  {0,-22}  Quelle  : {1}" -f "",$src)  "DarkGray" }
            if ($ref -and $ref-ne$src) { L ("  {0,-22}  Referrer: {1}" -f "",$ref)  "DarkGray" }
            if ($mime)                 { L ("  {0,-22}  MIME    : {1}" -f "",$mime) "DarkGray" }
            L ""
            $csvDl.Add([PSCustomObject]@{
                Browser=$p.N;Profil=$p.Profil;Zeitstempel=$zeit
                Pfad=$pfad;Groesse=$r["total_bytes"];Quelle=$src;Referrer=$ref;MIME=$mime
            })
        }
    } else {
        $annos  = ReadDB $p.H "moz_annos"
        $attrs  = @{}; (ReadDB $p.H "moz_anno_attributes") | ForEach-Object { $attrs[$_["id"]]=$_["name"] }
        $places = @{}; (ReadDB $p.H "moz_places")          | ForEach-Object { $places[$_["id"]]=$_ }
        $dlNames= "downloads/destinationFileName","downloads/destinationFileURI","downloads/metaData"
        foreach ($a in $annos) {
            $aname = $attrs[$a["anno_attribute_id"]]
            if (-not ($dlNames -contains $aname)) { continue }
            $pl  = $places[$a["place_id"]]
            $src = if ($pl) { $pl["url"] } else { "" }
            $inh = $a["content"]
            $zeit= fmtFx $a["dateAdded"]
            # Discord Attachment Tracking
            if ($src -match 'cdn\.discordapp\.com/attachments/[^/]+/[^/]+/([^?#/]+)') {
                $dname = $Matches[1]
                if (-not $discordMap.ContainsKey($dname)) { $discordMap[$dname] = [Collections.Generic.List[PSObject]]::new() }
                $discordMap[$dname].Add([PSCustomObject]@{Browser=$p.N;Profil=$p.Profil;Zeit=$zeit;Pfad=$inh;URL=$src;Bytes=""})
            }
            if (-not (Test-Cheat "$src $inh")) { continue }
            $dlN++
            L ("  {0}  Quelle: {1}" -f $zeit,$src) "Yellow"
            if ($inh) { L ("  {0,-22}  Info  : {1}" -f "",$inh) "DarkGray" }
            L ""
            $csvDl.Add([PSCustomObject]@{
                Browser=$p.N;Profil=$p.Profil;Zeitstempel=$zeit
                Pfad=$inh;Groesse="";Quelle=$src;Referrer="";MIME=""
            })
        }
    }
    if ($dlN -eq 0) { L "  Keine verdaechtigen Downloads gefunden." "DarkGray" }
    L ""

    # ─── VERLAUF ───────────────────────────────────────────────────────────
    $_profHistPct = [int](5 + (($_profIdx + 0.5) / $_profTotal) * 55)
    Show-Progress ("Profil [{0}] {1} - Verlauf ..." -f $p.N, $p.Profil) $_profHistPct
    L "  [VERLAUF - FiveM / Cheat Webseiten]" "Green"
    $histN = 0

    if ($p.T -eq "ch") {
        $rows = ReadDB $p.H "urls"
        $zaehler = 0
        foreach ($r in ($rows | Sort-Object { [Int64]$_["last_visit_time"] } -Descending)) {
            if ($zaehler++ -ge $MaxEintraege) { break }
            $url  = $r["url"]; $tit=$r["title"]
            $rufz = $r["visit_count"]; $zeit=fmtChr $r["last_visit_time"]
            if (-not (Test-Cheat "$url $tit")) { continue }
            $histN++
            $uShow=if($url.Length-gt 100){$url.Substring(0,97)+"..."}else{$url}
            L ("  {0}  {1,4}x  {2}" -f $zeit,$rufz,$uShow) "White"
            if ($tit -and $tit-ne$url -and $tit.Trim().Length-gt 0) {
                $tShow=if($tit.Length-gt 72){$tit.Substring(0,69)+"..."}else{$tit}
                L ("              > {0}" -f $tShow) "DarkGray"
            }
            $csvHist.Add([PSCustomObject]@{
                Browser=$p.N;Profil=$p.Profil;Zeitstempel=$zeit
                URL=$url;Titel=$tit;Aufrufe=$rufz
            })
        }
    } else {
        $places = @{}; (ReadDB $p.H "moz_places") | ForEach-Object { $places[$_["id"]]=$_ }
        $visits = ReadDB $p.H "moz_historyvisits"
        $zaehler= 0
        foreach ($v in ($visits | Sort-Object { [Int64]$_["visit_date"] } -Descending)) {
            if ($zaehler++ -ge $MaxEintraege) { break }
            $pl = $places[$v["place_id"]]
            if (-not $pl) { continue }
            $url  = $pl["url"]; $tit=$pl["title"]
            $rufz = $pl["visit_count"]; $zeit=fmtFx $v["visit_date"]
            if (-not (Test-Cheat "$url $tit")) { continue }
            $histN++
            $uShow=if($url.Length-gt 100){$url.Substring(0,97)+"..."}else{$url}
            L ("  {0}  {1,4}x  {2}" -f $zeit,$rufz,$uShow) "White"
            if ($tit -and $tit-ne$url -and $tit.Trim().Length-gt 0) {
                $tShow=if($tit.Length-gt 72){$tit.Substring(0,69)+"..."}else{$tit}
                L ("              > {0}" -f $tShow) "DarkGray"
            }
            $csvHist.Add([PSCustomObject]@{
                Browser=$p.N;Profil=$p.Profil;Zeitstempel=$zeit
                URL=$url;Titel=$tit;Aufrufe=$rufz
            })
        }
    }
    if ($histN -eq 0) { L "  Keine verdaechtigen Webseiten im Verlauf." "DarkGray" }
    L ""
    $_profIdx++
}

# =============================================================================
# DISCORD ATTACHMENT - DIESELBE DATEI >7x HERUNTERGELADEN
# =============================================================================
Show-Progress "Discord Attachment Check ..." 62
$discordFlagged = @($discordMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 7 } | Sort-Object { $_.Value.Count } -Descending)
if ($discordFlagged.Count -gt 0) {
    L $SEP1 "Red"
    L "  [!!!] DISCORD ATTACHMENT ALARM - DIESELBE DATEI MEHR ALS 7x HERUNTERGELADEN [!!!]" "Red"
    L "  Wiederholter Download deutet auf Weitergabe von Cheat-/Mod-Dateien via Discord hin" "Red"
    L $SEP1 "Red"
    L ""
    foreach ($e in $discordFlagged) {
        $cnt = $e.Value.Count
        L ("  [!!!]  {0}x  -->  {1}" -f $cnt, $e.Key) "Red"
        foreach ($dl in $e.Value) {
            $szStr = if ([string]::IsNullOrEmpty($dl.Bytes) -or $dl.Bytes -eq '0') { '     -' } else { fmtSz $dl.Bytes }
            L ("         {0}  {1}  [{2} / {3}]" -f $dl.Zeit,$szStr,$dl.Browser,$dl.Profil) "DarkRed"
            L ("         {0}" -f $dl.URL) "DarkGray"
        }
        L ""
    }
} else {
    L "  Discord-Check: Keine Datei mehr als 7x heruntergeladen." "DarkGray"
    L ""
}

# =============================================================================
# WINDOWS ARTEFAKTE  (Prefetch | BAM | UserAssist | MUICache)
# =============================================================================
L $SEP1 "DarkMagenta"
L "  WINDOWS ARTEFAKTE  (Prefetch | BAM | UserAssist | MUICache)" "Magenta"
L "  Ausgefuehrte Programme - bleibt nach Neustart erhalten" "DarkMagenta"
L $SEP1 "DarkMagenta"
L ""

# ROT13-Decode fuer UserAssist-Schluessel
function UnRot13 { param([string]$s)
    -join ($s.ToCharArray() | ForEach-Object {
        if     ($_ -ge 'A' -and $_ -le 'Z') { [char](((([int][char]$_) - 65 + 13) % 26) + 65) }
        elseif ($_ -ge 'a' -and $_ -le 'z') { [char](((([int][char]$_) - 97 + 13) % 26) + 97) }
        else   { $_ }
    })
}

# ── PREFETCH ─────────────────────────────────────────────────────────────────
Show-Progress "Windows Artefakte - Prefetch ..." 65
L "  [PREFETCH]" "Green"
$pfDir = "C:\Windows\Prefetch"
$pfN = 0
if (Test-Path $pfDir) {
    Get-ChildItem $pfDir -Filter "*.pf" -EA SilentlyContinue | ForEach-Object {
        $exeName = $_.Name -replace '-[0-9A-F]{8}\.pf$','' -replace '\.pf$',''
        if (Test-Cheat $exeName) {
            $ts = $_.LastWriteTime.ToString("dd.MM.yyyy HH:mm:ss")
            L ("  {0}  {1}" -f $ts, $_.Name) "Yellow"
            $pfN++
            $csvArtefakt.Add([PSCustomObject]@{
                Quelle="Prefetch"; Name=$exeName
                Zeitstempel=$ts; Detail=$_.FullName; Risiko="HOCH"
            })
        }
    }
} else {
    L "  Prefetch-Ordner nicht gefunden (evtl. deaktiviert)." "DarkGray"
}
if ($pfN -eq 0) { L "  Keine verdaechtigen Prefetch-Eintraege." "DarkGray" }
L ""

# ── BAM (Background Activity Monitor) ────────────────────────────────────────
Show-Progress "Windows Artefakte - BAM ..." 70
L "  [BAM]" "Green"
$bamBase = "HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings"
$bamN = 0
if (Test-Path $bamBase) {
    Get-ChildItem $bamBase -EA SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -EA SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object {
                $_.Name -notmatch '^PS' -and $_.Name -match '\\'
            } | ForEach-Object {
                $path = $_.Name
                if (Test-Cheat $path) {
                    $ts = "-"
                    try {
                        if ($_.Value -and $_.Value.Length -ge 8) {
                            $ft = [BitConverter]::ToInt64([byte[]]$_.Value, 0)
                            if ($ft -gt 0) {
                                $ts = [DateTime]::FromFileTimeUtc($ft).ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss")
                            }
                        }
                    } catch {}
                    $exeN = [IO.Path]::GetFileName($path)
                    L ("  {0}  {1}" -f $ts, $path) "Yellow"
                    $bamN++
                    $csvArtefakt.Add([PSCustomObject]@{
                        Quelle="BAM"; Name=$exeN
                        Zeitstempel=$ts; Detail=$path; Risiko="HOCH"
                    })
                }
            }
        }
    }
} else {
    L "  BAM-Registrierungsschluessel nicht gefunden." "DarkGray"
}
if ($bamN -eq 0) { L "  Keine verdaechtigen BAM-Eintraege." "DarkGray" }
L ""

# ── USERASSIST ────────────────────────────────────────────────────────────────
Show-Progress "Windows Artefakte - UserAssist ..." 75
L "  [USERASSIST]" "Green"
$uaBase = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist"
$uaN = 0
if (Test-Path $uaBase) {
    Get-ChildItem $uaBase -EA SilentlyContinue | ForEach-Object {
        $countKey = Join-Path $_.PSPath "Count"
        if (Test-Path $countKey) {
            $props = Get-ItemProperty $countKey -EA SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $decoded = UnRot13 $_.Name
                    if (Test-Cheat $decoded) {
                        $exeN = [IO.Path]::GetFileName($decoded)
                        if ([string]::IsNullOrEmpty($exeN)) { $exeN = $decoded }
                        L ("  {0}" -f $decoded) "Yellow"
                        $uaN++
                        $csvArtefakt.Add([PSCustomObject]@{
                            Quelle="UserAssist"; Name=$exeN
                            Zeitstempel="-"; Detail=$decoded; Risiko="HOCH"
                        })
                    }
                }
            }
        }
    }
} else {
    L "  UserAssist-Registrierungsschluessel nicht gefunden." "DarkGray"
}
if ($uaN -eq 0) { L "  Keine verdaechtigen UserAssist-Eintraege." "DarkGray" }
L ""

# ── MUICACHE ──────────────────────────────────────────────────────────────────
Show-Progress "Windows Artefakte - MUICache ..." 80
L "  [MUICACHE]" "Green"
$muiKey = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
$muiN = 0
if (Test-Path $muiKey) {
    $props = Get-ItemProperty $muiKey -EA SilentlyContinue
    if ($props) {
        $props.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and $_.Name.Length -gt 5
        } | ForEach-Object {
            if (Test-Cheat $_.Name) {
                $exeN = [IO.Path]::GetFileName($_.Name)
                if ([string]::IsNullOrEmpty($exeN)) { $exeN = $_.Name }
                $dispName = if ($_.Value -and $_.Value.ToString().Trim().Length -gt 0) { $_.Value.ToString().Trim() } else { $exeN }
                L ("  {0}  [{1}]" -f $_.Name, $dispName) "Yellow"
                $muiN++
                $csvArtefakt.Add([PSCustomObject]@{
                    Quelle="MUICache"; Name=$exeN
                    Zeitstempel="-"; Detail=$_.Name; Risiko="MITTEL"
                })
            }
        }
    }
} else {
    L "  MUICache-Registrierungsschluessel nicht gefunden." "DarkGray"
}
if ($muiN -eq 0) { L "  Keine verdaechtigen MUICache-Eintraege." "DarkGray" }
L ""

# =============================================================================
# RAM-SCAN  (ReadProcessMemory + VirtualQueryEx)
# =============================================================================
L $SEP1 "DarkCyan"
L "  RAM-SCAN  (ReadProcessMemory + VirtualQueryEx - System-Informer-Methode)" "Cyan"
L "  Findet URLs + Dateipfade (.rpf/.dat/reshade/bloodfx/soundpack) auch bei geloeschtem Verlauf" "DarkCyan"
L $SEP1 "DarkCyan"
L ""

$reUrl        = [regex]'https?://[^\x00-\x09\x0B\x0C\x0E-\x1F\x7F"''<>,\s]{5,500}'
$reFilePath   = [regex]'[A-Za-z]:\\[^\x00-\x1F\x7F"<>|]{8,260}'
$rePasteRaw   = [regex]'https?://(?:pastebin\.com/raw/[A-Za-z0-9]{5,12}|raw\.githubusercontent\.com/[^\s"''<>]{10,300}|hastebin\.com/raw/[A-Za-z0-9]+|gist\.githubusercontent\.com/[^\s"''<>]{10,300})'
$reDiscordCDN = [regex]'https?://cdn\.discordapp\.com/attachments/\d+/\d+/[^\s"''<>?]{3,200}'

function Scan-ProcMemory {
    param([Diagnostics.Process]$Proc,[int]$MaxMB=128)
    $urls      = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths     = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pastes    = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dcLinks   = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hProc = [FMScan.WinApi]::OpenProcess([FMScan.WinApi]::VM_READ -bor [FMScan.WinApi]::QI,$false,$Proc.Id)
    if ($hProc -eq [IntPtr]::Zero) { return [PSCustomObject]@{URLs=$urls;Paths=$paths;Pastes=$pastes;DCLinks=$dcLinks} }
    $mbiSz = [Runtime.InteropServices.Marshal]::SizeOf([FMScan.WinApi+MBI]::new())
    $mbi   = [FMScan.WinApi+MBI]::new()
    $addr  = [IntPtr]::Zero
    $gelesen=[Int64]0; $maxB=$MaxMB*1MB
    try {
        while ($true) {
            if ([FMScan.WinApi]::VirtualQueryEx($hProc,$addr,[ref]$mbi,$mbiSz) -eq 0) { break }
            $next=[IntPtr]($addr.ToInt64()+$mbi.Size.ToInt64())
            # Nur PRIVATE committed pages lesen (Type 0x20000 = MEM_PRIVATE)
            # Das sind Heap, Stack und Datenbereiche — genau das was Strings enthaelt
            $ok=($mbi.State -eq [FMScan.WinApi]::COMMIT) -and
                ($mbi.Type  -eq 0x20000) -and
                (($mbi.Prot -band [FMScan.WinApi]::NOACC) -eq 0) -and
                (($mbi.Prot -band [FMScan.WinApi]::GUARD) -eq 0)
            if ($ok -and $gelesen-lt $maxB) {
                # Chunks max 4 MB — verhindert riesige String-Allokation
                $sz=[Math]::Min($mbi.Size.ToInt64(),4MB)
                $buf=[byte[]]::new($sz); $rd=[Int64]0
                if ([FMScan.WinApi]::ReadProcessMemory($hProc,$mbi.Base,$buf,$sz,[ref]$rd) -and $rd-gt 0) {
                    $gelesen+=$rd
                    $chunk=if($rd-lt$buf.Length){$buf[0..($rd-1)]}else{$buf}
                    foreach ($enc in @([Text.Encoding]::UTF8,[Text.Encoding]::Unicode)) {
                        $text=$enc.GetString($chunk)
                        foreach ($m in $reUrl.Matches($text))        { if (Test-Cheat $m.Value) { $null=$urls.Add($m.Value)    } }
                        foreach ($m in $reFilePath.Matches($text))   { if (Test-Cheat $m.Value) { $null=$paths.Add($m.Value)   } }
                        foreach ($m in $rePasteRaw.Matches($text))   { $null=$pastes.Add($m.Value)  }
                        foreach ($m in $reDiscordCDN.Matches($text)) { $null=$dcLinks.Add($m.Value) }
                    }
                }
            }
            $addr=$next
            if ($addr.ToInt64() -le 0) { break }
        }
    } finally { $null=[FMScan.WinApi]::CloseHandle($hProc) }
    return [PSCustomObject]@{URLs=$urls;Paths=$paths;Pastes=$pastes;DCLinks=$dcLinks}
}

$bProcs = @("chrome","msedge","firefox","brave","opera","launcher")
$laufend= Get-Process | Where-Object { $bProcs -contains $_.Name.ToLower() }

Show-Progress "RAM-Scan wird vorbereitet ..." 83
if (-not $laufend) {
    L "  Kein Browser laeuft - RAM-Scan nicht moeglich." "DarkYellow"
    L "  Browser starten und Skript erneut ausfuehren fuer Live-Scan." "DarkGray"
} else {
    $_ramGroups = @($laufend | Group-Object { $_.Name.ToLower() })
    $_ramIdx    = 0
    foreach ($g in $_ramGroups) {
        $_ramPct = [int](83 + (($_ramIdx / [Math]::Max(1, $_ramGroups.Count)) * 9))
        Show-Progress ("RAM-Scan: [{0}] ..." -f $g.Name.ToUpper()) $_ramPct
        L ("  Prozess [{0}]  -  {1} Instanz(en)" -f $g.Name.ToUpper(),$g.Group.Count) "Yellow"
        $alleUrls  =[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $allePaths =[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $allePastes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $alleDCLnk =[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($proc in $g.Group) {
            $mb=[int]($proc.WorkingSet64/1MB)
            $cap=64   # max 64 MB private heap pages pro Prozess
            Show-Progress ("RAM-Scan: [{0}] PID {1} ({2} MB) ..." -f $g.Name.ToUpper(),$proc.Id,$mb) $_ramPct
            L ("    PID {0,6}  RAM {1,5} MB  wird gescannt ..." -f $proc.Id,$mb) "DarkYellow" -nn
            $res=Scan-ProcMemory -Proc $proc -MaxMB $cap
            L ("  {0} Treffer" -f ($res.URLs.Count+$res.Paths.Count+$res.Pastes.Count+$res.DCLinks.Count)) "Green"
            foreach ($u  in $res.URLs)    { $null=$alleUrls.Add($u)   }
            foreach ($fp in $res.Paths)   { $null=$allePaths.Add($fp) }
            foreach ($pb in $res.Pastes)  { $null=$allePastes.Add($pb) }
            foreach ($dc in $res.DCLinks) { $null=$alleDCLnk.Add($dc) }
        }
        if ($alleUrls.Count-gt 0 -or $allePaths.Count-gt 0 -or $allePastes.Count-gt 0 -or $alleDCLnk.Count-gt 0) {
            $ts=Get-Date -Format "dd.MM.yyyy HH:mm:ss"
            if ($alleUrls.Count-gt 0) {
                L ""
                L ("  VERDAECHTIGE URLs IM RAM ({0}):" -f $alleUrls.Count) "Magenta"
                foreach ($url in ($alleUrls|Sort-Object)) {
                    $show=if($url.Length-gt 110){$url.Substring(0,107)+"..."}else{$url}
                    L ("    {0}" -f $show) "White"
                    $csvRam.Add([PSCustomObject]@{Zeitstempel=$ts;Prozess=$g.Name;Fund=$url;Typ="URL"})
                }
            }
            if ($allePaths.Count-gt 0) {
                L ""
                L ("  VERDAECHTIGE DATEIPFADE IM RAM ({0}):" -f $allePaths.Count) "Magenta"
                foreach ($fp in ($allePaths|Sort-Object)) {
                    $show=if($fp.Length-gt 110){$fp.Substring(0,107)+"..."}else{$fp}
                    L ("    {0}" -f $show) "Yellow"
                    $csvRam.Add([PSCustomObject]@{Zeitstempel=$ts;Prozess=$g.Name;Fund=$fp;Typ="Pfad"})
                }
            }
            if ($allePastes.Count-gt 0) {
                L ""
                L ("  RAW-SCRIPT-LINKS IM RAM ({0})  [Pastebin / GitHub Raw / Hastebin]:" -f $allePastes.Count) "Red"
                L "  --> Deutet auf Laden von externen Skripten hin (Cheat-Loader, Lua-Injector etc.)" "DarkRed"
                foreach ($pb in ($allePastes|Sort-Object)) {
                    $show=if($pb.Length-gt 110){$pb.Substring(0,107)+"..."}else{$pb}
                    L ("    {0}" -f $show) "Red"
                    $csvRam.Add([PSCustomObject]@{Zeitstempel=$ts;Prozess=$g.Name;Fund=$pb;Typ="RawScript"})
                }
            }
            if ($alleDCLnk.Count-gt 0) {
                L ""
                L ("  DISCORD CDN ATTACHMENT-LINKS IM RAM ({0}):" -f $alleDCLnk.Count) "Magenta"
                L "  --> Dateien die im Browser aufgerufen/angesehen wurden (auch ohne Download)" "DarkGray"
                foreach ($dc in ($alleDCLnk|Sort-Object)) {
                    $fname = if ($dc -match '/([^/?#]+)(?:[?#]|$)') { $Matches[1] } else { $dc }
                    $show=if($dc.Length-gt 110){$dc.Substring(0,107)+"..."}else{$dc}
                    L ("    {0}" -f $show) "Yellow"
                    $csvRam.Add([PSCustomObject]@{Zeitstempel=$ts;Prozess=$g.Name;Fund=$dc;Typ="DCAttachment"})
                }
            }
        } else {
            L "  Keine FiveM/Cheat-Funde im RAM." "DarkGray"
        }
        L ""
        $_ramIdx++
    }
}

# =============================================================================
# ABSCHLUSSBERICHT
# =============================================================================

# Zusammenfassung berechnen
$artefaktHoch    = ($csvArtefakt | Where-Object { $_.Risiko -eq "HOCH"   }).Count
$artefaktMittel  = ($csvArtefakt | Where-Object { $_.Risiko -eq "MITTEL" }).Count
$discordAlarmAnz = ($discordMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 7 }).Count
$ramUrls         = ($csvRam | Where-Object { $_.Typ -eq "URL"          }).Count
$ramPfade        = ($csvRam | Where-Object { $_.Typ -eq "Pfad"         }).Count
$ramPastes       = ($csvRam | Where-Object { $_.Typ -eq "RawScript"    }).Count
$ramDCLinks      = ($csvRam | Where-Object { $_.Typ -eq "DCAttachment" }).Count
$ges             = $csvDl.Count + $csvHist.Count + $csvArtefakt.Count + $csvRam.Count + $discordAlarmAnz

Write-Progress -Activity "FiveM & Cheat Browser-Analyse" -Completed
$script:ShowProgress = $false

L ""
L $SEP1 "Cyan"
L ("  ABSCHLUSSBERICHT  -  {0}" -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')) "Cyan"
L $SEP1 "Cyan"

# --- Downloads ---
L ""
L ("  DOWNLOADS  ({0} Treffer)" -f $csvDl.Count) $(if($csvDl.Count-gt 0){"Yellow"}else{"DarkGray"})
L ("  " + "-"*84) "DarkGray"
if ($csvDl.Count -eq 0) {
    L "    Keine." "DarkGray"
} else {
    foreach ($dl in $csvDl) {
        $fname = [IO.Path]::GetFileName($dl.Pfad); if([string]::IsNullOrEmpty($fname)){$fname=$dl.Pfad}
        $sz = if ([string]::IsNullOrEmpty($dl.Groesse)-or $dl.Groesse-eq"0") { "      -" } else { fmtSz $dl.Groesse }
        L ("    {0}  {1}  [{2}]  {3}" -f $dl.Zeitstempel,$sz,$dl.Browser,$fname) "Yellow"
        if ($dl.Quelle) {
            $s=if($dl.Quelle.Length-gt 86){$dl.Quelle.Substring(0,83)+"..."}else{$dl.Quelle}
            L ("    {0,-22}  > {1}" -f "",$s) "DarkGray"
        }
    }
}

# --- Verlauf Top-Domains ---
L ""
L ("  VERLAUF  ({0} Treffer)  -  Top-Seiten nach Aufrufen" -f $csvHist.Count) $(if($csvHist.Count-gt 0){"White"}else{"DarkGray"})
L ("  " + "-"*84) "DarkGray"
if ($csvHist.Count -eq 0) {
    L "    Keine." "DarkGray"
} else {
    $domMap = @{}
    foreach ($h in $csvHist) {
        try { $dom=([Uri]($h.URL)).Host } catch { $dom=$h.URL.Substring(0,[Math]::Min($h.URL.Length,50)) }
        if(-not $domMap.ContainsKey($dom)){$domMap[$dom]=@{C=0;T=""}}
        $domMap[$dom].C += [Math]::Max(1,[int]($h.Aufrufe))
        if($domMap[$dom].T-eq "" -and $h.Titel -and $h.Titel.Trim().Length-gt 0){$domMap[$dom].T=$h.Titel}
    }
    $domMap.GetEnumerator() | Sort-Object {$_.Value.C} -Descending | Select-Object -First 25 | ForEach-Object {
        $ti=if($_.Value.T.Length-gt 55){$_.Value.T.Substring(0,52)+"..."}else{$_.Value.T}
        $tiStr=if($ti){"  > $ti"}else{""}
        L ("    {0,5}x  {1}{2}" -f $_.Value.C,$_.Key,$tiStr) "White"
    }
}

# --- RAM ---
L ""
L ("  RAM-SCAN  ({0} Treffer)" -f $csvRam.Count) $(if($csvRam.Count-gt 0){"White"}else{"DarkGray"})
L ("  " + "-"*84) "DarkGray"
if ($csvRam.Count -eq 0) {
    L "    kein Browser lief oder keine Treffer." "DarkGray"
} else {
    L ("    URLs            : {0,4}" -f $ramUrls)    "White"
    L ("    Dateipfade      : {0,4}" -f $ramPfade)   "White"
    if ($ramPastes  -gt 0) { L ("    Raw-Skript-Links: {0,4}  [!!!]" -f $ramPastes)  "Red"     }
    if ($ramDCLinks -gt 0) { L ("    Discord CDN     : {0,4}" -f $ramDCLinks)         "Yellow"  }
}

# --- Discord ---
L ""
L ("  DISCORD-ALARM  ({0} Dateien mehr als 7x heruntergeladen)" -f $discordAlarmAnz) $(if($discordAlarmAnz-gt 0){"Red"}else{"DarkGray"})
L ("  " + "-"*84) "DarkGray"
if ($discordAlarmAnz -eq 0) {
    L "    Keine." "DarkGray"
} else {
    foreach ($e in ($discordMap.GetEnumerator() | Where-Object {$_.Value.Count-gt 7} | Sort-Object {$_.Value.Count} -Descending)) {
        L ("    [!!!] {0,3}x  {1}" -f $e.Value.Count,$e.Key) "Red"
    }
}

# --- Windows Artefakte ---
L ""
L ("  WINDOWS ARTEFAKTE  ({0} Treffer  |  Hoch: {1}  |  Mittel: {2})" -f $csvArtefakt.Count,$artefaktHoch,$artefaktMittel) $(if($csvArtefakt.Count-gt 0){"Yellow"}else{"DarkGray"})
L ("  " + "-"*84) "DarkGray"
if ($csvArtefakt.Count -eq 0) {
    L "    Keine." "DarkGray"
} else {
    foreach ($a in ($csvArtefakt | Sort-Object { $_.Quelle + $_.Name })) {
        $col = if ($a.Risiko -eq "HOCH") { "Yellow" } else { "White" }
        L ("    [{0,-10}] [{1,-6}]  {2}  {3}" -f $a.Quelle, $a.Risiko, $a.Zeitstempel, $a.Name) $col
        if ($a.Detail -and $a.Detail -ne $a.Name) {
            $d = if ($a.Detail.Length -gt 88) { $a.Detail.Substring(0,85)+"..." } else { $a.Detail }
            L ("    {0,-22}  > {1}" -f "", $d) "DarkGray"
        }
    }
}

# --- Bewertung ---
L ""
L $SEP1 "DarkCyan"
$bew=if($discordAlarmAnz-gt 0 -and $ges-gt 0)              {"[!!!] DISCORD-ALARM + FiveM-Aktivitaet bestaetigt"
     }elseif($csvDl.Count-gt 0 -and $artefaktHoch-gt 0)    {"[!!!] FiveM-Download + Ausfuehrungs-Beleg gefunden"
     }elseif($csvDl.Count-gt 0)                             {"[!!!] FiveM-Download nachgewiesen"
     }elseif($artefaktHoch-gt 0 -and $csvHist.Count-gt 0)  {"[!]  Starke Hinweise - Ausfuehrung + Verlauf belegt"
     }elseif($artefaktHoch-gt 0)                            {"[!]  Ausfuehrungs-Spuren in Windows-Artefakten"
     }elseif($ges-gt 50)                                    {"[!]  Starke Hinweise auf FiveM / Cheat-Nutzung"
     }elseif($ges-gt 5)                                     {"[!]  Hinweise auf FiveM / Cheat-Aktivitaet"
     }elseif($ges-gt 0)                                     {"[i]  Schwache Hinweise - weitere Pruefung empfohlen"
     }else                                                   {"[OK] Keine verdaechtigen Aktivitaeten gefunden"}
$bCol=if($discordAlarmAnz-gt 0 -or $csvDl.Count-gt 0 -or $artefaktHoch-gt 0){"Red"}elseif($ges-gt 0){"Yellow"}else{"Green"}
L ("  {0}" -f $bew) $bCol
L ""
L ("  Downloads : {0,3}  |  Verlauf : {1,3}  |  Artefakte : {2,3}  |  RAM : {3,3}  |  Discord-Alarm : {4,3}" -f $csvDl.Count,$csvHist.Count,$csvArtefakt.Count,$csvRam.Count,$discordAlarmAnz) "Cyan"
L ("  GESAMT    : {0,4}" -f $ges) "Cyan"
L $SEP1 "DarkCyan"

if ($ExportCSV) {
    L ""
    $dir=[IO.Path]::GetDirectoryName($AusgabePfad)
    $stem=[IO.Path]::GetFileNameWithoutExtension($AusgabePfad)
    foreach ($x in @(@{L=$csvDl;S="Downloads"},@{L=$csvHist;S="Verlauf"},@{L=$csvRam;S="RAM"})) {
        if ($x.L.Count-gt 0) {
            $out=Join-Path $dir ($stem+"_"+$x.S+".csv")
            $x.L | Export-Csv $out -NoTypeInformation -Encoding UTF8
            L ("  CSV: {0}" -f $out) "Green"
        }
    }
}
L ""
L $SEP1 "DarkCyan"
L ("  Bericht gespeichert: {0}" -f $AusgabePfad) "Green"
L $SEP1 "DarkCyan"

[IO.File]::WriteAllText($AusgabePfad,$Log.ToString(),[Text.Encoding]::UTF8)
Remove-Item $Tmp -Recurse -Force -EA SilentlyContinue

# =============================================================================
# DISCORD WEBHOOK
# =============================================================================
# Webhook-URL ist XOR-verschluesselt (Key 0x4D) und Base64-kodiert gespeichert.
# SHA256-Hash wird zur Laufzeit verifiziert - Manipulation unterbricht das Skript.
$_whEncoded  = "JTk5PT53YmIpJD4uIj8pYy4iIGIsPSRiOigvJSIiJj5ifHl1dXR4e391dHV8fXV/dHl5fmIEOgIfAX8SIRt5GwoUIBgoGCACARJ9LwA4KRJ1N38VeAM3KCIeBH0gISMAKxsOeyAUfSoUDDsoHR9/KHkUIQUUCTsUOw=="
$_whExpHash  = "ab664f09e45195c09140a631c5826e465a920cf2ba3e4751eb29696bf7cb73fc"
$_xk         = 0x4D
$_whBytes    = [Convert]::FromBase64String($_whEncoded) | ForEach-Object { $_ -bxor $_xk }
$webhookUrl  = [Text.Encoding]::UTF8.GetString($_whBytes)
$_sha        = [Security.Cryptography.SHA256]::Create()
$_actualHash = ($_sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($webhookUrl)) | ForEach-Object { $_.ToString("x2") }) -join ""
if ($_actualHash -ne $_whExpHash) {
    Write-Host "`nFEHLER: Dieses Skript wurde manipuliert oder ist nicht autorisiert." -ForegroundColor Red
    Write-Host "        Ausfuehrung wird abgebrochen." -ForegroundColor Red
    Start-Sleep -Seconds 3
    exit 1
}
Remove-Variable _whEncoded,_whExpHash,_xk,_whBytes,_sha,_actualHash -EA SilentlyContinue

# =============================================================================
# EMBED AUFBAU  (nur Hochrisiko-Felder + Fazit mit Wahrscheinlichkeit)
# =============================================================================

# Wahrscheinlichkeitsberechnung
$riskScore = 0
if ($csvDl.Count       -gt 0) { $riskScore += 40 }   # Download = harter Beweis
if ($artefaktHoch      -gt 0) { $riskScore += 30 }   # Prefetch/BAM/UA = Ausfuehrungs-Spur
if ($csvHist.Count     -gt 0) { $riskScore += 15 }   # Verlauf = Besuch belegt
if ($ramPastes         -gt 0) { $riskScore += 20 }   # Raw-Script = Loader-Verdacht
if ($ramDCLinks        -gt 0) { $riskScore += 10 }   # DC CDN = Datei-Transfer im RAM
if ($discordAlarmAnz   -gt 0) { $riskScore += 25 }   # >7x selbe Datei = Cheat-Weitergabe
$riskScore = [Math]::Min($riskScore, 99)

# Fazit-Bausteine
$fazitTeile = [Collections.Generic.List[string]]::new()
if ($csvDl.Count       -gt 0) { $fazitTeile.Add("FiveM/Cheat-Dateien wurden heruntergeladen") }
if ($artefaktHoch      -gt 0) { $fazitTeile.Add("Ausfuehrungs-Beleg in Systemartefakten (Prefetch/BAM/UserAssist)") }
if ($csvHist.Count     -gt 0) { $fazitTeile.Add("Cheat-relevante Webseiten besucht") }
if ($ramPastes         -gt 0) { $fazitTeile.Add("Externe Skript-Links im Browser-RAM (Cheat-Loader-Verdacht)") }
if ($ramDCLinks        -gt 0) { $fazitTeile.Add("Discord CDN Attachment-Links im RAM sichtbar") }
if ($discordAlarmAnz   -gt 0) { $fazitTeile.Add("Dieselbe Discord-Datei mehr als 7x heruntergeladen") }
if ($fazitTeile.Count  -eq 0) { $fazitTeile.Add("Keine verdaechtigen Aktivitaeten nachweisbar") }

$bewEmoji = if ($riskScore -ge 60) { ":red_circle:" } elseif ($riskScore -ge 25) { ":yellow_circle:" } else { ":green_circle:" }
$riskBar  = ":red_circle:" * [Math]::Round($riskScore/20) + ":white_circle:" * ([Math]::Round(100/20) - [Math]::Round($riskScore/20))

$embedDesc  = "**Wahrscheinlichkeit Cheat-Nutzung: $riskScore%**`n$riskBar`n`n"
$embedDesc += ":notepad_spiral: **Fazit:**`n"
$embedDesc += ($fazitTeile | ForEach-Object { "> $_" }) -join "`n"

# Felder - nur aufnehmen wenn Treffer vorhanden (Hochrisiko-Filter)
$embedFields = [System.Collections.Generic.List[object]]::new()
$embedFields.Add([ordered]@{ name=":clock1: Scan-Zeitpunkt"; value=(Get-Date -Format 'dd.MM.yyyy HH:mm:ss'); inline=$true })
$embedFields.Add([ordered]@{ name=":bar_chart: Treffer gesamt"; value="$ges"; inline=$true })

# Downloads (immer anzeigen wenn vorhanden)
if ($csvDl.Count -gt 0) {
    $dlLines = $csvDl | ForEach-Object {
        $fn=[IO.Path]::GetFileName($_.Pfad); if([string]::IsNullOrEmpty($fn)){$fn=$_.Pfad}
        ":arrow_down: ``$fn``  [$($_.Browser)]"
    }
    $dlVal = ($dlLines -join "`n")
    if ($dlVal.Length -gt 1000) { $dlVal = $dlVal.Substring(0,997)+"..." }
    $embedFields.Add([ordered]@{ name=":warning: Downloads ($($csvDl.Count))"; value=$dlVal; inline=$false })
}

# Artefakte (nur wenn Hochrisiko)
if ($artefaktHoch -gt 0) {
    $artLines = $csvArtefakt | Where-Object { $_.Risiko -eq "HOCH" } | Select-Object -First 15 | ForEach-Object {
        ":mag: ``[$($_.Quelle)]`` $($_.Name)"
        if ($_.Zeitstempel -ne "-") { "  _Zeitstempel: $($_.Zeitstempel)_" }
    }
    $artVal = ($artLines | Where-Object { $_ }) -join "`n"
    if ($artVal.Length -gt 1000) { $artVal = $artVal.Substring(0,997)+"..." }
    $embedFields.Add([ordered]@{ name=":detective: Systemartefakte HOCH ($artefaktHoch)"; value=$artVal; inline=$false })
}

# MUICache Mittel (kleiner Hinweis-Block)
if ($artefaktMittel -gt 0) {
    $muiLines = ($csvArtefakt | Where-Object { $_.Risiko -eq "MITTEL" } | Select-Object -First 8 | ForEach-Object {
        "> ``$($_.Name)``"
    }) -join "`n"
    if ($muiLines.Length -gt 500) { $muiLines = $muiLines.Substring(0,497)+"..." }
    $embedFields.Add([ordered]@{ name=":file_folder: MUICache Hinweise ($artefaktMittel)"; value=$muiLines; inline=$false })
}

# Verlauf Top-Seiten (nur wenn Treffer)
if ($csvHist.Count -gt 0) {
    $dm2 = @{}
    foreach ($h in $csvHist) {
        try{$d=([Uri]($h.URL)).Host}catch{$d=$h.URL.Substring(0,[Math]::Min($h.URL.Length,40))}
        if(-not $dm2[$d]){$dm2[$d]=0}; $dm2[$d]+=[Math]::Max(1,[int]($h.Aufrufe))
    }
    $topLines = ($dm2.GetEnumerator()|Sort-Object {$_.Value} -Descending|Select-Object -First 8|
        ForEach-Object{"> ``{0}``  {1}x" -f $_.Key,$_.Value}) -join "`n"
    if ($topLines.Length -gt 800) { $topLines = $topLines.Substring(0,797)+"..." }
    $embedFields.Add([ordered]@{ name=":globe_with_meridians: Verlauf Top-Seiten ($($csvHist.Count) Treffer)"; value=$topLines; inline=$false })
}

# Raw-Script (sehr gefaehrlich - immer anzeigen)
if ($ramPastes -gt 0) {
    $pasteLines = ($csvRam | Where-Object {$_.Typ -eq "RawScript"} | Select-Object -First 8 | ForEach-Object {
        $s = $_.Fund; if($s.Length -gt 90){$s=$s.Substring(0,87)+"..."}
        "> ``$s``"
    }) -join "`n"
    if ($pasteLines.Length -gt 900) { $pasteLines = $pasteLines.Substring(0,897)+"..." }
    $embedFields.Add([ordered]@{ name=":scroll: Raw-Script im RAM ($ramPastes) [!!!]"; value=$pasteLines; inline=$false })
}

# Discord CDN-Links im RAM
if ($ramDCLinks -gt 0) {
    $dcLines = ($csvRam | Where-Object {$_.Typ -eq "DCAttachment"} | Select-Object -First 8 | ForEach-Object {
        $fn = if ($_.Fund -match '/([^/?#]+)(?:[?#]|$)') { $Matches[1] } else { $_.Fund }
        "> ``$fn``"
    }) -join "`n"
    if ($dcLines.Length -gt 700) { $dcLines = $dcLines.Substring(0,697)+"..." }
    $embedFields.Add([ordered]@{ name=":link: Discord CDN im RAM ($ramDCLinks)"; value=$dcLines; inline=$false })
}

# Discord Alarm
if ($discordAlarmAnz -gt 0) {
    $discLines = ($discordMap.GetEnumerator()|Where-Object{$_.Value.Count-gt 7}|Sort-Object{$_.Value.Count} -Descending|
        ForEach-Object{":warning: ``{0}``  {1}x" -f $_.Key,$_.Value.Count}) -join "`n"
    if ($discLines.Length -gt 700) { $discLines = $discLines.Substring(0,697)+"..." }
    $embedFields.Add([ordered]@{ name=":rotating_light: Discord-Alarm ($discordAlarmAnz Dateien >7x)"; value=$discLines; inline=$false })
}

$embed = [ordered]@{
    title       = "$bewEmoji  FiveM-Scan: $env:COMPUTERNAME / $env:USERNAME"
    color       = if($riskScore -ge 60){16711680}elseif($riskScore -ge 25){16776960}else{65280}
    description = $embedDesc
    fields      = $embedFields.ToArray()
    footer      = [ordered]@{ text="FiveMCheatScan.ps1  |  $env:COMPUTERNAME  |  Bericht: $(Split-Path $AusgabePfad -Leaf)" }
    timestamp   = (Get-Date -Format 'o')
}

$jsonPayload = [ordered]@{ embeds = @($embed) } | ConvertTo-Json -Depth 10 -Compress

try {
    L "" ; L "  Sende Bericht an Discord-Webhook ..." "Cyan"

    # Schritt 1: Embed senden
    $null = Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType "application/json; charset=utf-8" `
                              -Body ([Text.Encoding]::UTF8.GetBytes($jsonPayload))

    # Schritt 2: Berichtsdatei als Anhang senden (multipart/form-data, PS 5.1-kompatibel)
    $fileBytes    = [IO.File]::ReadAllBytes($AusgabePfad)
    $fileName     = [IO.Path]::GetFileName($AusgabePfad)
    $boundary     = "----FMScanBoundary" + [Guid]::NewGuid().ToString("N")
    $CRLF         = "`r`n"
    $bodyParts    = [IO.MemoryStream]::new()
    $enc          = [Text.Encoding]::UTF8

    # -- Datei-Part
    $header = $enc.GetBytes(
        "--$boundary$CRLF" +
        "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$CRLF" +
        "Content-Type: text/plain; charset=utf-8$CRLF$CRLF"
    )
    $bodyParts.Write($header, 0, $header.Length)
    $bodyParts.Write($fileBytes, 0, $fileBytes.Length)

    # -- Abschluss-Boundary
    $footer = $enc.GetBytes("$CRLF--$boundary--$CRLF")
    $bodyParts.Write($footer, 0, $footer.Length)

    $null = Invoke-RestMethod -Uri $webhookUrl -Method Post `
                              -ContentType "multipart/form-data; boundary=$boundary" `
                              -Body $bodyParts.ToArray()

    L "  Discord-Webhook: Embed + Datei gesendet." "Green"

    # Schritt 3: Lokale Berichtsdatei loeschen
    Remove-Item $AusgabePfad -Force -EA SilentlyContinue
    L "  Lokale Berichtsdatei geloescht: $fileName" "DarkGray"

} catch {
    L ("  Discord-Webhook FEHLER: {0}" -f $_.Exception.Message) "Red"
}

} catch {
    Write-Progress -Activity "FiveM & Cheat Browser-Analyse" -Completed
    $script:ShowProgress = $false
    Write-Host ""
    Write-Host ("  [FEHLER] Zeile $($_.InvocationInfo.ScriptLineNumber): {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ""
}



$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
