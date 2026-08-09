#Requires -Version 5.1
[CmdletBinding()]
param()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinAudio {
    [DllImport("winmm.dll")] public static extern int waveOutGetVolume(IntPtr h, out uint vol);
    [DllImport("winmm.dll")] public static extern int waveOutSetVolume(IntPtr h, uint vol);
}
public class WinConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@

function Disable-ConsoleQuickEdit {
    try {
        $STD_INPUT_HANDLE      = -10
        $ENABLE_QUICK_EDIT     = 0x0040
        $ENABLE_EXTENDED_FLAGS = 0x0080
        $h = [WinConsole]::GetStdHandle($STD_INPUT_HANDLE)
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]-1) { return }
        $mode = 0
        if ([WinConsole]::GetConsoleMode($h, [ref]$mode)) {
            $newMode = ($mode -band -bnot $ENABLE_QUICK_EDIT) -bor $ENABLE_EXTENDED_FLAGS
            [WinConsole]::SetConsoleMode($h, $newMode) | Out-Null
        }
    } catch {}
}

function Play-SoundWithVolume {
    param([string]$FilePath, [int]$Volume)
    $origVol = [uint32]0
    [WinAudio]::waveOutGetVolume([IntPtr]::Zero, [ref]$origVol) | Out-Null
    $level  = [uint32]([Math]::Round($Volume / 100.0 * 0xFFFF))
    $packed = $level -bor ($level -shl 16)
    [WinAudio]::waveOutSetVolume([IntPtr]::Zero, $packed) | Out-Null
    try {
        ([System.Media.SoundPlayer]::new($FilePath)).PlaySync()
    }
    finally {
        [WinAudio]::waveOutSetVolume([IntPtr]::Zero, $origVol) | Out-Null
    }
}

function Read-IniFile {
    param([string]$Path)
    $result  = [ordered]@{}
    $section = '__global__'
    $result[$section] = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $line = $line.Trim()
        if ($line -eq '' -or $line -match '^[;#]') { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $result.Contains($section)) { $result[$section] = [ordered]@{} }
            continue
        }
        if ($line -match '^([^=]+)=(.*)$') {
            $key   = $Matches[1].Trim()
            $value = ($Matches[2].Trim()) -replace '\s*[;#].*$', ''
            $result[$section][$key] = $value
        }
    }
    return $result
}

function Get-SharedHttpClient {
    if (-not $script:http) {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch {}
            Add-Type -AssemblyName System.Net.Http
        }
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $script:http = New-Object System.Net.Http.HttpClient($handler)
        $script:http.Timeout = [TimeSpan]::FromSeconds(30)
        $script:http.DefaultRequestHeaders.Add('Accept', 'application/json')
        $script:http.DefaultRequestHeaders.Add('User-Agent', 'tarkov-flip-chimer')
    }
    return $script:http
}

function ConvertFrom-JsonCompat {
    param([string]$Json)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ($Json | ConvertFrom-Json -AsHashtable -Depth 100)
    }
    # Windows PowerShell 5.1: ConvertFrom-Json throws on keys that differ only by
    # case (the tarkov.dev translations file has some). JavaScriptSerializer's
    # Dictionary<string,object> is case-sensitive and tolerates them.
    if (-not $script:jsSerializer) {
        Add-Type -AssemblyName System.Web.Extensions
        $script:jsSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:jsSerializer.MaxJsonLength  = [int]::MaxValue
        $script:jsSerializer.RecursionLimit = 1000
    }
    return $script:jsSerializer.DeserializeObject($Json)
}

$script:httpCache = @{}

function Invoke-CachedJsonGet {
    # Conditional GET with ETag caching. Returns @{ Status; Data }, Status one of:
    #   ok           - fresh 200, Data is freshly parsed
    #   notmodified  - 304, Data is the previously cached parse
    #   notfound     - 404 (drives game-mode fallback)
    #   error        - network/parse failure or unusable state; caller retries next cycle
    param([string]$Uri)
    $client  = Get-SharedHttpClient
    $cached  = $script:httpCache[$Uri]
    $req     = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Uri)
    if ($cached -and $cached.ETag) {
        $req.Headers.TryAddWithoutValidation('If-None-Match', $cached.ETag) | Out-Null
    }
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        if ([int]$resp.StatusCode -eq 304) {
            if ($cached) { return @{ Status = 'notmodified'; Data = $cached.Data } }
            return @{ Status = 'error'; Data = $null }
        }
        if ([int]$resp.StatusCode -eq 404) { return @{ Status = 'notfound'; Data = $null } }
        if (-not $resp.IsSuccessStatusCode) { return @{ Status = 'error'; Data = $null } }
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $data = ConvertFrom-JsonCompat -Json $text
        $etag = if ($resp.Headers.ETag) { $resp.Headers.ETag.ToString() } else { $null }
        $script:httpCache[$Uri] = @{ ETag = $etag; Data = $data }
        return @{ Status = 'ok'; Data = $data }
    }
    catch {
        Write-Warning "  HTTP error for ${Uri}: $_"
        return @{ Status = 'error'; Data = $null }
    }
    finally { $req.Dispose() }
}

function Initialize-PriceLog {
    param(
        [string]$Path,
        [Nullable[int]]$MaxEntries,
        [Nullable[long]]$MaxSizeBytes
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not $MaxEntries -and -not $MaxSizeBytes) { return }
    $lines = [System.IO.File]::ReadAllLines($Path)
    if (-not $lines -or $lines.Count -eq 0) { return }
    if ($MaxEntries -and $lines.Count -gt $MaxEntries) {
        $start = $lines.Count - $MaxEntries
        $lines = $lines[$start..($lines.Count - 1)]
    }
    if ($MaxSizeBytes) {
        $kept    = New-Object 'System.Collections.Generic.List[string]'
        $size    = 0
        $nlBytes = [System.Text.Encoding]::UTF8.GetByteCount([Environment]::NewLine)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $b = [System.Text.Encoding]::UTF8.GetByteCount($lines[$i]) + $nlBytes
            if ($size + $b -gt $MaxSizeBytes) { break }
            $kept.Insert(0, $lines[$i])
            $size += $b
        }
        $lines = $kept.ToArray()
    }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($Path, $lines, $enc)
}

function Write-PriceLogEntry {
    param(
        [string]$Path,
        [string]$Clock,
        [hashtable]$Rows,
        [object[]]$Sections,
        [object[]]$Alerts,
        [string]$GameMode
    )
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $Sections) {
        if ($s -notmatch '^Item\.') { continue }
        if (-not $Rows.Contains($s)) { continue }
        $r = $Rows[$s]
        $items.Add([ordered]@{
            label        = $r.label
            direction    = $r.direction
            currentPrice = $r.currentPrice
            targetPrice  = $r.targetPrice
            diff         = $r.diffLabel
            avg24h       = $r.avg24h
            avg7d        = $r.avg7d
            updated      = $r.updatedAgo
            source       = $r.source
            triggered    = $r.triggered
        })
    }
    $alertList = New-Object 'System.Collections.Generic.List[object]'
    foreach ($a in $Alerts) {
        $alertList.Add([ordered]@{ label = $a.Label; direction = $a.Direction })
    }
    $entry = [ordered]@{
        time     = (Get-Date).ToString('o')
        clock    = $Clock
        gameMode = $GameMode
        items    = $items
        alerts   = $alertList
    }
    $json = $entry | ConvertTo-Json -Depth 6 -Compress
    $enc  = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $enc)
}

function Format-Price {
    param([long]$Value)
    return '{0:N0}' -f $Value
}

function Format-UpdatedAgo {
    param($UpdatedField)
    if (-not $UpdatedField) { return '' }
    try {
        if ($UpdatedField -is [datetime]) {
            $elapsed = [datetime]::UtcNow - $UpdatedField.ToUniversalTime()
        } else {
            $dt = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
                      [System.Globalization.DateTimeStyles]::AdjustToUniversal
            if (-not [datetime]::TryParse([string]$UpdatedField,
                    [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) {
                return ''
            }
            $elapsed = [datetime]::UtcNow - $dt
        }
        if ($elapsed.TotalSeconds -lt 0) { return '' }
        if     ($elapsed.TotalMinutes -lt 1)  { return 'just now' }
        elseif ($elapsed.TotalHours   -lt 1)  { return "$([int]$elapsed.TotalMinutes)m ago" }
        elseif ($elapsed.TotalHours   -lt 24) {
            $h = [Math]::Floor($elapsed.TotalHours)
            return "${h}h $([Math]::Floor($elapsed.TotalMinutes - $h*60))m ago"
        }
        else { return "$([int]$elapsed.TotalDays)d ago" }
    }
    catch { return '' }
}

function Get-TarkovItemsAll {
    param([string]$ApiKey, [string]$GameMode)
    $prefix = switch ($GameMode) {
        'pve'  { 'pve/' }
        'pvps' { 'season/' }
        default { '' }
    }
    $uri = "https://api.tarkov-market.app/api/v1/${prefix}items/all"
    try {
        return Invoke-RestMethod -Uri $uri -Headers @{ 'x-api-key' = $ApiKey } -Method Get -ErrorAction Stop
    }
    catch {
        Write-Warning "  Bulk API error: $_"
        return $null
    }
}

$script:freeBuilt = $null

function Get-TarkovItemsAllFree {
    # tarkov.dev's GraphQL API is dead (422 "GraphQL server unavailable"); the
    # site itself now reads from json.tarkov.dev. Item names/shortNames in the
    # main items file are untranslated placeholders ("<id> Name") -- real
    # strings live in a separate, rarely-changing items_<lang> file.
    # Returns: item list (possibly $script:freeBuilt reused via 304), or
    # @{ Status = 'notfound' } if the game mode doesn't exist there yet, or
    # $null on a transient failure (caller retries next cycle).
    param([string]$TarkovDevMode)

    $itemsResult = Invoke-CachedJsonGet -Uri "https://json.tarkov.dev/$TarkovDevMode/items"
    if ($itemsResult.Status -eq 'notfound') { return @{ Status = 'notfound' } }
    if ($itemsResult.Status -eq 'error')    { return $null }

    $namesResult = Invoke-CachedJsonGet -Uri "https://json.tarkov.dev/$TarkovDevMode/items_en"
    if ($namesResult.Status -eq 'notfound') { return @{ Status = 'notfound' } }
    if ($namesResult.Status -eq 'error')    { return $null }

    if ($itemsResult.Status -eq 'notmodified' -and $namesResult.Status -eq 'notmodified' -and $script:freeBuilt) {
        return $script:freeBuilt
    }

    try {
        $items = $itemsResult.Data['data']['items']
        $names = $namesResult.Data['data']
        $built = New-Object 'System.Collections.Generic.List[object]'
        foreach ($kv in $items.GetEnumerator()) {
            $id  = $kv.Key
            $it  = $kv.Value
            $low = $it['lastLowPrice']
            if ($null -eq $low -or [long]$low -le 0) { continue }   # not tradeable on flea
            $name = $names["$id Name"]
            if (-not $name) { $name = $it['normalizedName'] }
            $built.Add([PSCustomObject]@{
                id            = $id
                name          = $name
                shortName     = $names["$id ShortName"]
                price         = [long]$low
                avg24hPrice   = [long]$it['avg24hPrice']
                avg7daysPrice = 0L
                updated       = $it['updated']
            })
        }
        $script:freeBuilt = $built
        return $built
    }
    catch {
        Write-Warning "  Free bulk parse error: $_"
        return $null
    }
}

function ConvertTo-UpdatedDateTime {
    param($UpdatedField)
    if (-not $UpdatedField) { return $null }
    if ($UpdatedField -is [datetime]) { return $UpdatedField.ToUniversalTime() }
    $dt = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
              [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse([string]$UpdatedField,
            [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) {
        return $dt
    }
    return $null
}

function Merge-PriceSources {
    param($PaidItem, $FreeItem)
    if ($null -eq $PaidItem -and $null -eq $FreeItem) { return $null }
    if ($null -eq $FreeItem) {
        return [PSCustomObject]@{
            name          = $PaidItem.name
            price         = [long]$PaidItem.price
            avg24hPrice   = [long]$PaidItem.avg24hPrice
            avg7daysPrice = [long]$PaidItem.avg7daysPrice
            updated       = $PaidItem.updated
            source        = 'paid'
        }
    }
    if ($null -eq $PaidItem) {
        return [PSCustomObject]@{
            name          = $FreeItem.name
            price         = [long]$FreeItem.price
            avg24hPrice   = [long]$FreeItem.avg24hPrice
            avg7daysPrice = 0L
            updated       = $FreeItem.updated
            source        = 'free'
        }
    }
    $paidUpd = ConvertTo-UpdatedDateTime $PaidItem.updated
    $freeUpd = ConvertTo-UpdatedDateTime $FreeItem.updated
    $freeIsFresher = ($null -ne $freeUpd) -and (($null -eq $paidUpd) -or ($freeUpd -gt $paidUpd))
    if ($freeIsFresher) {
        return [PSCustomObject]@{
            name          = $PaidItem.name
            price         = [long]$FreeItem.price
            avg24hPrice   = [long]$FreeItem.avg24hPrice
            avg7daysPrice = [long]$PaidItem.avg7daysPrice
            updated       = $FreeItem.updated
            source        = 'free'
        }
    }
    return [PSCustomObject]@{
        name          = $PaidItem.name
        price         = [long]$PaidItem.price
        avg24hPrice   = [long]$PaidItem.avg24hPrice
        avg7daysPrice = [long]$PaidItem.avg7daysPrice
        updated       = $PaidItem.updated
        source        = 'paid'
    }
}

function Find-TarkovItemLocal {
    param($AllItems, [string]$Query)
    $q     = $Query.ToLower()
    $found = @($AllItems | Where-Object {
        ($_.name      -and $_.name.ToLower().Contains($q)) -or
        ($_.shortName -and $_.shortName.ToLower().Contains($q))
    })
    if ($found.Count -eq 0) {
        Write-Warning "  No results for: $Query"
        return $null
    }
    return $found
}

$script:debugEnabled = $false
$script:debugFile    = $null
$script:debugFrame   = New-Object System.Text.StringBuilder
$script:debugLine    = New-Object System.Text.StringBuilder

function Write-DebugRaw {
    param([string]$Text, [switch]$NoNewline)
    if (-not $script:debugEnabled) { return }
    [void]$script:debugLine.Append($Text)
    if (-not $NoNewline) {
        [void]$script:debugFrame.Append($script:debugLine.ToString()).Append([Environment]::NewLine)
        [void]$script:debugLine.Clear()
    }
}

function Set-DebugCursorLeft {
    param([int]$Col)
    if (-not $script:debugEnabled) { return }
    if ($script:debugLine.Length -lt $Col) {
        [void]$script:debugLine.Append(' ', ($Col - $script:debugLine.Length))
    }
}

function Reset-DebugFrame {
    if (-not $script:debugEnabled) { return }
    [void]$script:debugFrame.Clear()
    [void]$script:debugLine.Clear()
}

function Complete-DebugFrame {
    param([string]$Timestamp)
    if (-not $script:debugEnabled) { return }
    if ($script:debugLine.Length -gt 0) {
        [void]$script:debugFrame.Append($script:debugLine.ToString()).Append([Environment]::NewLine)
        [void]$script:debugLine.Clear()
    }
    $enc    = New-Object System.Text.UTF8Encoding $false
    $header = "=== cycle @ $Timestamp ===" + [Environment]::NewLine
    try {
        [System.IO.File]::AppendAllText($script:debugFile, $header + $script:debugFrame.ToString(), $enc)
        $fi = Get-Item -LiteralPath $script:debugFile -ErrorAction Stop
        if ($fi.Length -gt 2MB) {
            $lines        = [System.IO.File]::ReadAllLines($script:debugFile)
            $frameStarts  = New-Object 'System.Collections.Generic.List[int]'
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like '=== cycle @ *') { $frameStarts.Add($i) } }
            if ($frameStarts.Count -gt 20) {
                $cutIdx = $frameStarts[$frameStarts.Count - 20]
                [System.IO.File]::WriteAllLines($script:debugFile, $lines[$cutIdx..($lines.Count - 1)], $enc)
            }
        }
    }
    catch { Write-Warning "  Debug log write error: $_" }
    [void]$script:debugFrame.Clear()
}

function wh {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
    Write-DebugRaw -Text $Text -NoNewline:$NoNewline
}

function Write-SepLine {
    param([string]$Text, [string]$Color = 'DarkGray')
    if ($Color -match '^#([0-9A-Fa-f]{6})$') {
        $r = [Convert]::ToInt32($Matches[1].Substring(0,2), 16)
        $g = [Convert]::ToInt32($Matches[1].Substring(2,2), 16)
        $b = [Convert]::ToInt32($Matches[1].Substring(4,2), 16)
        Write-Host "`e[38;2;${r};${g};${b}m${Text}`e[0m"
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Write-ColumnHeader {
    param([switch]$NoNewline)
    if ($useFree) {
        $text = "     {0,-$wLabel}  {1,$wPrice}     {2,$wTarget}     {3,$wDiff}    {4,$wAvg}     {5,-$wUpd}" -f `
            'Item', 'Price', 'Target', 'Diff', 'avg24h', 'Updated'
    } else {
        $text = "     {0,-$wLabel}  {1,$wPrice}     {2,$wTarget}     {3,$wDiff}    {4,$wAvg}     {5,$wAvg}     {6,-$wUpd}" -f `
            'Item', 'Price', 'Target', 'Diff', 'avg24h', 'avg7d', 'Updated'
    }
    if ($NoNewline) { Write-Host $text -ForegroundColor DarkGray -NoNewline }
    else            { Write-Host $text -ForegroundColor DarkGray }
    Write-DebugRaw -Text $text -NoNewline:$NoNewline
}

function Write-ItemRow {
    param($r)
    wh "  " -NoNewline
    wh $r.direction $r.bsColor -NoNewline
    wh "  " -NoNewline
    wh ("{0,-$wLabel}" -f $r.label) $r.labelColor -NoNewline
    wh "  " -NoNewline
    wh ("{0,$wPrice}" -f (Format-Price $r.currentPrice)) $r.priceColor -NoNewline
    wh " $rub   " DarkGray -NoNewline
    if ($null -ne $r.targetPrice) {
        wh ("{0,$wTarget}" -f (Format-Price $r.targetPrice)) $r.targetColor -NoNewline
        wh " $rub   " DarkGray -NoNewline
    } else {
        wh ("{0,$wTarget}" -f '') -NoNewline
        wh "      " -NoNewline
    }
    wh ("{0,$wDiff}" -f $r.diffLabel) $r.diffColor -NoNewline
    wh "    " -NoNewline
    wh ("{0,$wAvg}" -f (Format-Price $r.avg24h)) DarkGray -NoNewline
    wh " $rub   " DarkGray -NoNewline
    if (-not $useFree) {
        wh ("{0,$wAvg}" -f (Format-Price $r.avg7d)) DarkGray -NoNewline
        wh " $rub   " DarkGray -NoNewline
    }
    wh ("{0,-$wUpd}" -f $r.updatedAgo) $r.updatedColor -NoNewline
    if ($r.triggered) { wh "  !!" $r.bsColor -NoNewline }
}

function Get-AlertText {
    param($a)
    if ($a.Direction -eq 'B') { return "  !! good time to buy $($a.Label) !!" }
    return "  !! good time to sell $($a.Label) !!"
}

function Write-Alert {
    param($a, [switch]$NoNewline)
    $text  = Get-AlertText $a
    $color = if ($a.Direction -eq 'B') { 'Green' } else { 'Red' }
    if ($NoNewline) { Write-Host $text -ForegroundColor $color -NoNewline }
    else            { Write-Host $text -ForegroundColor $color }
    Write-DebugRaw -Text $text -NoNewline:$NoNewline
}

function Get-AlertColumnLayout {
    # Chunks a same-direction alert list into sub-columns of up to $WrapAfter
    # rows each, capped to however many actually fit in $MaxWidth -- if more
    # chunks would be needed than fit, the overflow is merged into the last
    # column (it grows taller rather than colliding with the other side).
    param([object[]]$Alerts, [int]$WrapAfter, [int]$MaxWidth)
    if (-not $Alerts -or $Alerts.Count -eq 0) { return @{ Columns = @(); ColWidth = 0 } }
    if ($WrapAfter -le 0 -or $Alerts.Count -le $WrapAfter) {
        return @{ Columns = @(,$Alerts); ColWidth = $MaxWidth }
    }
    $textWidth = ($Alerts | ForEach-Object { (Get-AlertText $_).Length } | Measure-Object -Maximum).Maximum
    $colWidth  = $textWidth + 2
    $maxCols   = [Math]::Max(1, [Math]::Floor($MaxWidth / $colWidth))

    $chunks = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $Alerts.Count; $i += $WrapAfter) {
        $end = [Math]::Min($i + $WrapAfter, $Alerts.Count) - 1
        $chunks.Add(@($Alerts[$i..$end]))
    }
    if ($chunks.Count -gt $maxCols) {
        $kept = New-Object 'System.Collections.Generic.List[object]'
        for ($i = 0; $i -lt $maxCols - 1; $i++) { $kept.Add($chunks[$i]) }
        $overflow = New-Object 'System.Collections.Generic.List[object]'
        for ($i = $maxCols - 1; $i -lt $chunks.Count; $i++) { $overflow.AddRange([object[]]$chunks[$i]) }
        $kept.Add(@($overflow.ToArray()))
        $chunks = $kept
    }
    return @{ Columns = @($chunks.ToArray()); ColWidth = $colWidth }
}

function Write-SeparatorRow {
    param([string]$Section, [int]$Width, [switch]$NoNewline)
    $sepLabel = $Section -replace '^Separator\.', ''
    $sepColor = if ($ini[$Section]['color']) { $ini[$Section]['color'] } else { 'DarkGray' }
    $mid      = if ($sepLabel) { " $sepLabel " } else { $dash * 4 }
    $sides    = [Math]::Max(2, [Math]::Floor(($Width - $mid.Length) / 2))
    $text     = ($dash * $sides) + $mid + ($dash * $sides)
    if     ($text.Length -lt $Width) { $text += ($dash * ($Width - $text.Length)) }
    elseif ($text.Length -gt $Width) { $text  = $text.Substring(0, $Width) }

    if ($sepColor -match '^#([0-9A-Fa-f]{6})$') {
        $rr = [Convert]::ToInt32($Matches[1].Substring(0,2), 16)
        $gg = [Convert]::ToInt32($Matches[1].Substring(2,2), 16)
        $bb = [Convert]::ToInt32($Matches[1].Substring(4,2), 16)
        $line = "`e[38;2;${rr};${gg};${bb}m${text}`e[0m"
        if ($NoNewline) { Write-Host $line -NoNewline } else { Write-Host $line }
    } else {
        if ($NoNewline) { Write-Host $text -ForegroundColor $sepColor -NoNewline }
        else            { Write-Host $text -ForegroundColor $sepColor }
    }
    Write-DebugRaw -Text $text -NoNewline:$NoNewline
}

# ─── startup ──────────────────────────────────────────────────────────────────

$scriptDir  = $PSScriptRoot
$configPath = Join-Path $scriptDir 'config.ini'

if (-not (Test-Path $configPath)) {
    Write-Error "config.ini not found ($configPath)"; exit 1
}

$ini = Read-IniFile -Path $configPath
$rub  = [char]0x20BD
$dash = ([string][char]0x2500)

$general = $ini['General']
$apiKey  = $general['apiKey']
if ($general['checkIntervalSecs']) { $checkIntervalSec = [int]$general['checkIntervalSecs'] } else { $checkIntervalSec = 300 }
$soundFileRel = if ($general['soundFile']) { $general['soundFile'] } else { 'alert.wav' }
$soundFile    = Join-Path $scriptDir $soundFileRel
$volumeRaw    = $general['volume']
if ($volumeRaw -ne $null -and $volumeRaw -ne '') { $v = [int]$volumeRaw } else { $v = 80 }
$volume = [Math]::Max(0, [Math]::Min(100, $v))

$windowHeightOffset = 0
if ($general['windowHeightOffset'] -match '^-?\d+$') { $windowHeightOffset = [int]$general['windowHeightOffset'] }

$debugVal = $general['debug']
$script:debugEnabled = ($debugVal -and ($debugVal.ToString().ToLower() -in @('yes','true','1','on')))
if ($script:debugEnabled) {
    $debugFileRel     = if ($general['debugFile']) { $general['debugFile'] } else { 'analytics/debug-console.txt' }
    $script:debugFile = Join-Path $scriptDir $debugFileRel
    $debugDir         = Split-Path -Parent $script:debugFile
    if ($debugDir -and -not (Test-Path -LiteralPath $debugDir)) {
        New-Item -ItemType Directory -Force -Path $debugDir | Out-Null
    }
}

$useFree = ($apiKey -eq 'YOUR_API_KEY_HERE' -or -not $apiKey)

# ── game mode: pvp (default) | pve | pvps (PvP Season) ────────────────────
$gameModeRaw = if ($general['gameMode']) { $general['gameMode'].ToString().ToLower() } else { 'pvp' }
if ($gameModeRaw -notin @('pvp', 'pve', 'pvps')) {
    Write-Error "Invalid gameMode '$gameModeRaw' in config.ini -- must be pvp, pve, or pvps"; exit 1
}
$gameMode = $gameModeRaw

# tarkovDevMode: which json.tarkov.dev/<mode>/ segment feeds the free source.
# An explicit config override always wins. Otherwise pvp/pve map directly;
# pvps is probed at startup since tarkov.dev doesn't have season data yet --
# this makes the tool pick it up automatically the moment tarkov.dev adds it.
$freeSourceEnabled = $true
$tarkovDevMode      = $null
if ($general['tarkovDevMode']) {
    $tarkovDevMode = $general['tarkovDevMode'].ToString()
}
else {
    switch ($gameMode) {
        'pvp' { $tarkovDevMode = 'regular' }
        'pve' { $tarkovDevMode = 'pve' }
        'pvps' {
            foreach ($candidate in @('season', 'pvps')) {
                $probe = Invoke-CachedJsonGet -Uri "https://json.tarkov.dev/$candidate/items_en"
                if ($probe.Status -eq 'ok') { $tarkovDevMode = $candidate; break }
            }
            if (-not $tarkovDevMode) {
                if ($useFree) {
                    Write-Error "gameMode=pvps needs a tarkov-market API key for now -- tarkov.dev has no PvP Season data yet. Set apiKey in config.ini, or set tarkovDevMode manually once tarkov.dev adds season support."
                    exit 1
                }
                $freeSourceEnabled = $false
                Write-Warning "  tarkov.dev has no PvP Season data yet -- running paid-only via tarkov-market.app. Set tarkovDevMode in config.ini once it appears."
            }
        }
    }
}

$itemSections      = $ini.Keys | Where-Object { $_ -match '^Item\.' }
$displaySections   = $ini.Keys | Where-Object { $_ -match '^(Item|Separator)\.' }
$separatorSections = @($ini.Keys | Where-Object { $_ -match '^Separator\.' })
if (-not $itemSections) { Write-Error "No [Item.*] sections in config.ini"; exit 1 }

# two-column mode: presence of [Column.Break] both enables it and marks split point
$leftSections  = New-Object System.Collections.Generic.List[string]
$rightSections = New-Object System.Collections.Generic.List[string]
$seenBreak     = $false
foreach ($k in $ini.Keys) {
    if ($k -eq 'Column.Break') { $seenBreak = $true; continue }
    if ($k -match '^(Item|Separator)\.') {
        if ($seenBreak) { $rightSections.Add($k) | Out-Null }
        else            { $leftSections.Add($k)  | Out-Null }
    }
}
$twoColumn      = $seenBreak
# Alert layout applies symmetrically to both the buy and sell side -- it
# lives in [General], not [Column.Break], so it doesn't read as "settings
# for the right column". Only meaningful (and only takes effect) once
# [Column.Break] enables two-column mode.
$splitTriggers  = $false
$alertWrapAfter = 0
if ($twoColumn) {
    $val = $general['splitTriggers']
    if ($val) { $splitTriggers = ($val.ToString().ToLower() -in @('yes','true','1','on')) }
    $wrapVal = $general['alertWrapAfter']
    if ($wrapVal -match '^\d+$') { $alertWrapAfter = [int]$wrapVal }
}

# logging
$logEnabled      = $false
$logPath         = $null
$logMaxEntries   = $null
$logMaxSizeBytes = $null
if ($ini.Contains('Logging')) {
    $logging = $ini['Logging']
    $en      = $logging['enabled']
    $logEnabled = ($en -and ($en.ToString().ToLower() -in @('yes','true','1','on')))
    if ($logEnabled) {
        $rel     = if ($logging['path']) { $logging['path'] } else { 'analytics/prices.log.jsonl' }
        $logPath = Join-Path $scriptDir $rel
        $logDir  = Split-Path -Parent $logPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        if ($logging['maxEntries'] -match '^\d+$') { $logMaxEntries   = [int]$logging['maxEntries'] }
        if ($logging['maxSizeKB']  -match '^\d+$') { $logMaxSizeBytes = [long]$logging['maxSizeKB'] * 1024 }
        Initialize-PriceLog -Path $logPath -MaxEntries $logMaxEntries -MaxSizeBytes $logMaxSizeBytes
    }
}

# column widths
$wLabel  = 20
$wPrice  = 12
$wAvg    = 12
$wDiff   = 7
$wUpd    = 12
$wTarget = 12

$contentWidth = 5 + $wLabel + 2 + $wPrice + 5 + $wTarget + 5 + $wDiff + 4 + $wAvg + 5
if (-not $useFree) { $contentWidth += $wAvg + 5 }
$contentWidth += $wUpd + 4   # +4 for "  !!" trigger mark

$colWidth   = $contentWidth
$gutterText = ' ' + ([char]0x2502) + ' '

# lineWidth = window width; slightly wider than content so "  !!" never wraps
if ($twoColumn) {
    $lineWidth = [Math]::Min($colWidth * 2 + $gutterText.Length + 4, [Console]::LargestWindowWidth)
} else {
    $lineWidth = [Math]::Min($contentWidth + 4, [Console]::LargestWindowWidth)
}

try {
    if ($twoColumn) {
        $rowsPerSide = [Math]::Max($leftSections.Count, $rightSections.Count)
        # Reserve extra rows for the alert block below the table -- it can grow
        # well past a couple of lines when many items trigger at once (worse
        # yet when splitTriggers puts them all on one lopsided side). With
        # alertWrapAfter set, sub-columns are capped to what fits width-wise,
        # so an extreme burst can still exceed one column's worth of rows --
        # budget roughly double as headroom; otherwise reserve a generous
        # flat amount so a burst doesn't scroll the header out of view.
        $alertBudget = if ($alertWrapAfter -gt 0) { $alertWrapAfter * 2 } else { 15 }
        $h = [Math]::Min([Math]::Ceiling(1.4 * $rowsPerSide) + 8 + $alertBudget, [Console]::LargestWindowHeight)
    } else {
        $h = [Math]::Min([Math]::Ceiling(1.3 * $itemSections.Count) + $separatorSections.Count + 16, [Console]::LargestWindowHeight)
    }
    $h = [Math]::Max(5, [Math]::Min($h + $windowHeightOffset, [Console]::LargestWindowHeight))
    $bufW = [Math]::Min($lineWidth + 40, [Console]::LargestWindowWidth)
    if ([Console]::BufferWidth  -lt $bufW) { [Console]::BufferWidth  = $bufW }
    if ([Console]::BufferHeight -lt $h)    { [Console]::BufferHeight = $h }
    [Console]::WindowWidth  = $lineWidth
    [Console]::WindowHeight = $h
} catch {}

Disable-ConsoleQuickEdit

$lastAlertedPrice = @{}
$lastPrices       = @{}

# ─── main loop ────────────────────────────────────────────────────────────────
try {
    while ($true) {
        $timestamp   = Get-Date -Format 'HH:mm:ss'
        $alerts        = @()   # array of @{Label;Direction}
        $freshAlerts   = @()
        $rowsBySection = @{}
        $fetchError    = $null
        $firstCycle    = ($lastPrices.Count -eq 0)
        $anyChanged    = $false

        # ── compute phase: fetch + per-section work, no console output ────
        $allItems  = $null
        $freeItems = $null
        $freeById  = @{}

        if ($freeSourceEnabled) {
            $freeResult = Get-TarkovItemsAllFree -TarkovDevMode $tarkovDevMode
            if ($freeResult -is [hashtable] -and $freeResult.Status -eq 'notfound') {
                $freeSourceEnabled = $false
                if ($useFree) {
                    $fetchError = "tarkov.dev no longer has $gameMode data, retrying next cycle"
                }
                else {
                    Write-Warning "  tarkov.dev no longer has $gameMode data -- switching to paid-only."
                }
            }
            else {
                $freeItems = $freeResult
            }
        }
        if ($freeItems) {
            foreach ($f in $freeItems) { if ($f.id) { $freeById[$f.id] = $f } }
        }

        if (-not $fetchError -and -not $useFree) {
            $allItems = Get-TarkovItemsAll -ApiKey $apiKey -GameMode $gameMode
            if ($null -eq $allItems) {
                $fetchError = 'bulk fetch failed, retrying next cycle'
            }
        }

        $apiLabel = if ($useFree) {
            "tarkov.dev free ($gameMode)"
        } elseif ($freeSourceEnabled) {
            "tarkov-market.app + tarkov.dev ($gameMode)"
        } else {
            "tarkov-market.app ($gameMode, paid-only)"
        }

        if (-not $fetchError) {
            foreach ($section in $itemSections) {
                $cfg       = $ini[$section]
                $label     = if ($cfg['label']) { $cfg['label'] } else { $section -replace '^Item\.', '' }
                $query     = $cfg['query']
                $avgSource = if ($cfg['avgSource']) { $cfg['avgSource'] } else { 'avg7d' }
                if ($useFree -and ($avgSource -eq 'avg7d' -or $avgSource -match '^-?\d+\.\d+$')) {
                    $avgSource = 'avg24h'
                }
                $alertVal  = $cfg['alert']

                $soundVal     = $cfg['sound']
                $soundEnabled = $true
                if ($null -ne $soundVal -and $soundVal -ne '') {
                    $soundEnabled = ($soundVal.ToString().ToLower() -in @('yes','true','1','on'))
                }

                if (-not $query -or -not $alertVal) {
                    Write-Warning "  [$section] missing 'query' or 'alert' -- skipping"
                    continue
                }

                if ($alertVal -match '^([BSbs])(.+)$') {
                    $direction = $Matches[1].ToUpper(); $alertVal = $Matches[2]
                }
                else { $direction = 'B' }

                $bsColor = if ($direction -eq 'B') { 'Green' } else { 'Red' }

                if ($useFree) {
                    $apiItems = if ($freeItems) { Find-TarkovItemLocal -AllItems $freeItems -Query $query } else { $null }
                }
                else {
                    $paidMatches = Find-TarkovItemLocal -AllItems $allItems -Query $query
                    if ($paidMatches) {
                        $apiItems = @($paidMatches | ForEach-Object {
                            $free = if ($_.bsgId -and $freeById.ContainsKey($_.bsgId)) { $freeById[$_.bsgId] } else { $null }
                            Merge-PriceSources -PaidItem $_ -FreeItem $free
                        })
                    }
                    else { $apiItems = $null }
                }
                if (-not $apiItems) { continue }

                $usedVal = $cfg['used']
                if ($usedVal -and $usedVal.ToLower() -eq 'yes') {
                    $apiItem = $apiItems | Sort-Object { [long]$_.price } | Select-Object -First 1
                }
                else {
                    $apiItem = $apiItems | Sort-Object { [long]$_.price } -Descending | Select-Object -First 1
                }

                $currentPrice = [long]$apiItem.price
                $updatedAgo   = Format-UpdatedAgo $apiItem.updated

                $prevPrice = $lastPrices[$section]
                $changed   = ($null -ne $prevPrice) -and ($prevPrice -ne $currentPrice)
                if ($changed) { $anyChanged = $true }
                $lastPrices[$section] = $currentPrice

                $avg24h = [long]$apiItem.avg24hPrice
                $avg7d  = [long]$apiItem.avg7daysPrice

                $refAvg = $null
                if     ($avgSource -eq 'avg24h')   { $refAvg = $avg24h }
                elseif ($avgSource -eq 'avg7d')    { $refAvg = $avg7d }
                elseif ($avgSource -match '^-?\d+\.\d+$') {
                    $w = [double]::Parse($avgSource, [System.Globalization.CultureInfo]::InvariantCulture)
                    $refAvg = [long]($avg7d + $w * ($avg24h - $avg7d))
                }
                elseif ($avgSource -match '^\d+$') { $refAvg = [long]$avgSource }

                $diffVal   = if ($refAvg -and $refAvg -gt 0) { ($currentPrice - $refAvg) / $refAvg * 100.0 } else { $null }
                $diffLabel = if ($null -ne $diffVal)         { '{0:+0.0;-0.0}%' -f $diffVal }                else { '' }

                $isPercent   = $alertVal -match '^(\d+(?:\.\d+)?)%$'
                $triggered   = $false
                $targetPrice = $null

                if ($isPercent) {
                    $pct = [double]$Matches[1]
                    if ($direction -eq 'B') {
                        $targetPrice = [long]($refAvg * (1.0 - $pct / 100.0))
                        $triggered   = $currentPrice -lt $targetPrice
                    }
                    else {
                        $targetPrice = [long]($refAvg * (1.0 + $pct / 100.0))
                        $triggered   = $currentPrice -gt $targetPrice
                    }
                }
                else {
                    $targetPrice = [long]$alertVal
                    if ($direction -eq 'B') { $triggered = $currentPrice -lt $targetPrice }
                    else                    { $triggered = $currentPrice -gt $targetPrice }
                }

                $targetOverride = $cfg['target']
                if ($targetOverride -and $targetOverride -match '^\d+$') {
                    $targetPrice = [long]$targetOverride
                }

                # ── colors ───────────────────────────────────────────────────────

                $priceColor   = if ($triggered) { 'Yellow' } else { 'Cyan' }
                $labelColor   = if ($triggered) { $bsColor  } else { 'Gray' }
                $targetColor  = if ($triggered) { 'Yellow' } else { 'DarkGray' }
                $updatedColor = if ($changed)   { 'Yellow' } else { 'DarkGray' }

                $diffColor = if ($triggered) {
                    'Yellow'
                } elseif ($null -eq $diffVal) {
                    'DarkGray'
                } elseif ($direction -eq 'B') {
                    if   ($diffVal -lt 0) { 'Green' } elseif ($diffVal -gt 0) { 'Red' } else { 'Gray' }
                } else {
                    if   ($diffVal -gt 0) { 'Green' } elseif ($diffVal -lt 0) { 'Red' } else { 'Gray' }
                }

                $rowsBySection[$section] = [PSCustomObject]@{
                    direction    = $direction
                    bsColor      = $bsColor
                    label        = $label
                    labelColor   = $labelColor
                    currentPrice = $currentPrice
                    priceColor   = $priceColor
                    targetPrice  = $targetPrice
                    targetColor  = $targetColor
                    diffLabel    = $diffLabel
                    diffColor    = $diffColor
                    avg24h       = $avg24h
                    avg7d        = $avg7d
                    updatedAgo   = $updatedAgo
                    updatedColor = $updatedColor
                    source       = $apiItem.source
                    triggered    = $triggered
                }

                # ── alert bookkeeping ────────────────────────────────────────────
                if ($triggered) {
                    $prev = $lastAlertedPrice[$section]
                    if ($null -eq $prev) {
                        $alerts += @{ Label = $label; Direction = $direction; Section = $section }
                        if ($soundEnabled) { $freshAlerts += $label }
                        $lastAlertedPrice[$section] = $currentPrice
                    }
                    elseif ($currentPrice -ne $prev) {
                        $alerts += @{ Label = $label; Direction = $direction; Section = $section }
                        $lastAlertedPrice[$section] = $currentPrice
                    }
                    else {
                        $alerts += @{ Label = $label; Direction = $direction; Section = $section }
                    }
                }
                else { $lastAlertedPrice.Remove($section) }
            }
        }

        # ── log phase: append JSON line if data changed (or first cycle) ──
        if ($logEnabled -and -not $fetchError -and ($firstCycle -or $anyChanged)) {
            Write-PriceLogEntry -Path $logPath -Clock $timestamp `
                -Rows $rowsBySection -Sections $displaySections -Alerts $alerts -GameMode $gameMode
        }

        # ── render phase: clear screen, print everything in one burst ───
        [Console]::Clear()
        Reset-DebugFrame
        wh "Tarkov Price Alert | $apiLabel | $($itemSections.Count) items | every ${checkIntervalSec}s | Ctrl+C to stop" DarkGray

        $mid   = " $timestamp "
        $sides = [Math]::Floor(($lineWidth - $mid.Length) / 2)
        wh (($dash * $sides) + $mid + ($dash * $sides)) DarkGray

        if ($fetchError) {
            wh ""
            wh "  $fetchError" DarkGray
            Complete-DebugFrame -Timestamp $timestamp
            Start-Sleep -Seconds $checkIntervalSec
            continue
        }

        if (-not $twoColumn) {
            Write-ColumnHeader

            foreach ($section in $displaySections) {
                if ($section -match '^Separator\.') {
                    Write-SeparatorRow $section $lineWidth
                    continue
                }
                if (-not $rowsBySection.ContainsKey($section)) { continue }
                Write-ItemRow $rowsBySection[$section]
                wh ""
            }
        }
        else {
            Write-ColumnHeader -NoNewline
            [Console]::CursorLeft = $colWidth
            Set-DebugCursorLeft $colWidth
            wh $gutterText DarkGray -NoNewline
            Write-ColumnHeader -NoNewline
            wh ""

            $maxRows = [Math]::Max($leftSections.Count, $rightSections.Count)
            for ($i = 0; $i -lt $maxRows; $i++) {
                $leftSec  = if ($i -lt $leftSections.Count)  { $leftSections[$i]  } else { $null }
                $rightSec = if ($i -lt $rightSections.Count) { $rightSections[$i] } else { $null }

                if ($leftSec) {
                    if ($leftSec -match '^Separator\.') {
                        Write-SeparatorRow $leftSec $colWidth -NoNewline
                    } elseif ($rowsBySection.ContainsKey($leftSec)) {
                        Write-ItemRow $rowsBySection[$leftSec]
                    }
                }
                [Console]::CursorLeft = $colWidth
                Set-DebugCursorLeft $colWidth
                wh $gutterText DarkGray -NoNewline
                if ($rightSec) {
                    if ($rightSec -match '^Separator\.') {
                        Write-SeparatorRow $rightSec $colWidth -NoNewline
                    } elseif ($rowsBySection.ContainsKey($rightSec)) {
                        Write-ItemRow $rowsBySection[$rightSec]
                    }
                }
                wh ""
            }
        }

        wh ""

        $alertRightCol   = $colWidth + $gutterText.Length
        $alertsTwoColumn = $twoColumn -and ($splitTriggers -or $alertWrapAfter -gt 0)
        if ($alerts.Count -eq 0) {
            if ($alertsTwoColumn) {
                wh "  no good deals :(" DarkGray -NoNewline
                [Console]::CursorLeft = $alertRightCol
                Set-DebugCursorLeft $alertRightCol
                wh "  no good deals :(" DarkGray -NoNewline
                wh ""
            } else {
                wh "  no good deals :(" DarkGray
            }
        }
        else {
            if ($twoColumn -and $alertWrapAfter -gt 0) {
                # Buy alerts always in the left half, sell always in the right --
                # each half wraps into its own extra sub-column(s) past
                # alertWrapAfter rows, so a lopsided burst (e.g. mostly buys)
                # never grows past the console window, and buy/sell never mix.
                $buyAlerts  = @($alerts | Where-Object { $_.Direction -eq 'B' })
                $sellAlerts = @($alerts | Where-Object { $_.Direction -eq 'S' })
                $buyLayout  = Get-AlertColumnLayout -Alerts $buyAlerts  -WrapAfter $alertWrapAfter -MaxWidth $colWidth
                $sellLayout = Get-AlertColumnLayout -Alerts $sellAlerts -WrapAfter $alertWrapAfter -MaxWidth $colWidth

                $maxRows = 0
                foreach ($c in $buyLayout.Columns)  { $maxRows = [Math]::Max($maxRows, $c.Count) }
                foreach ($c in $sellLayout.Columns) { $maxRows = [Math]::Max($maxRows, $c.Count) }

                for ($i = 0; $i -lt $maxRows; $i++) {
                    $x = 0
                    foreach ($c in $buyLayout.Columns) {
                        [Console]::CursorLeft = $x
                        Set-DebugCursorLeft $x
                        if ($i -lt $c.Count) { Write-Alert $c[$i] -NoNewline }
                        $x += $buyLayout.ColWidth
                    }
                    $x = $alertRightCol
                    foreach ($c in $sellLayout.Columns) {
                        [Console]::CursorLeft = $x
                        Set-DebugCursorLeft $x
                        if ($i -lt $c.Count) { Write-Alert $c[$i] -NoNewline }
                        $x += $sellLayout.ColWidth
                    }
                    wh ""
                }
            }
            elseif ($twoColumn -and $splitTriggers) {
                $leftAlerts  = @($alerts | Where-Object { $leftSections.Contains($_.Section) })
                $rightAlerts = @($alerts | Where-Object { $rightSections.Contains($_.Section) })
                $maxAlerts   = [Math]::Max($leftAlerts.Count, $rightAlerts.Count)
                for ($i = 0; $i -lt $maxAlerts; $i++) {
                    if ($i -lt $leftAlerts.Count)  { Write-Alert $leftAlerts[$i]  -NoNewline }
                    [Console]::CursorLeft = $alertRightCol
                    Set-DebugCursorLeft $alertRightCol
                    if ($i -lt $rightAlerts.Count) { Write-Alert $rightAlerts[$i] -NoNewline }
                    wh ""
                }
            }
            else {
                foreach ($a in $alerts) { Write-Alert $a }
            }
            if ($freshAlerts.Count -gt 0 -and $volume -gt 0) {
                if (Test-Path $soundFile) {
                    try   { Play-SoundWithVolume -FilePath $soundFile -Volume $volume }
                    catch { Write-Warning "  Could not play sound: $_" }
                }
                else { Write-Warning "  Sound file not found: $soundFile" }
            }
        }
        Complete-DebugFrame -Timestamp $timestamp
        Start-Sleep -Seconds $checkIntervalSec
    }
}
finally {
    Write-Host ""
    wh "Stopped." Cyan
}