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
'@

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
    param([string]$ApiKey)
    $uri = "https://api.tarkov-market.app/api/v1/items/all"
    try {
        return Invoke-RestMethod -Uri $uri -Headers @{ 'x-api-key' = $ApiKey } -Method Get -ErrorAction Stop
    }
    catch {
        Write-Warning "  Bulk API error: $_"
        return $null
    }
}

function Get-TarkovItemsAllFree {
    $body = @{ query = '{ items { name lastLowPrice avg24hPrice updated } }' } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri 'https://api.tarkov.dev/graphql' -Method Post `
            -ContentType 'application/json' -Body $body -ErrorAction Stop
        $items = $r.data.items
        if (-not $items) { return $null }
        return $items | ForEach-Object {
            [PSCustomObject]@{
                name          = $_.name
                price         = [long]$_.lastLowPrice
                avg24hPrice   = [long]$_.avg24hPrice
                avg7daysPrice = 0L
                updated       = $_.updated
            }
        }
    }
    catch {
        Write-Warning "  Free bulk API error: $_"
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

function Get-TarkovItemFree {
    param([string]$Query)
    $gql  = '{ items(name: ' + (ConvertTo-Json $Query) + ') { name lastLowPrice avg24hPrice updated } }'
    $body = @{ query = $gql } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri 'https://api.tarkov.dev/graphql' -Method Post `
            -ContentType 'application/json' -Body $body -ErrorAction Stop
        $items = $r.data.items
        if (-not $items -or $items.Count -eq 0) {
            Write-Warning "  No results for: $Query"
            return $null
        }
        return $items | ForEach-Object {
            [PSCustomObject]@{
                name          = $_.name
                price         = [long]$_.lastLowPrice
                avg24hPrice   = [long]$_.avg24hPrice
                avg7daysPrice = 0L
                updated       = $_.updated
            }
        }
    }
    catch {
        Write-Warning "  API error for '$Query': $_"
        return $null
    }
}

function wh {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Text -ForegroundColor $Color }
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

$useFree = ($apiKey -eq 'YOUR_API_KEY_HERE' -or -not $apiKey)

$itemSections = $ini.Keys | Where-Object { $_ -match '^Item\.' }
if (-not $itemSections) { Write-Error "No [Item.*] sections in config.ini"; exit 1 }

try {
    $w = [Math]::Min(140, [Console]::LargestWindowWidth)
    $h = [int][Math]::Min([Math]::Ceiling(1.5 * $itemSections.Count) + 6, [Console]::LargestWindowHeight)
    if ([Console]::BufferWidth  -lt $w) { [Console]::BufferWidth  = $w }
    if ([Console]::BufferHeight -lt $h) { [Console]::BufferHeight = $h }
    [Console]::WindowWidth  = $w
    [Console]::WindowHeight = $h
} catch {}

$lastAlertedPrice = @{}
$lastPrices       = @{}

# column widths
$wLabel  = 20
$wPrice  = 12
$wAvg    = 12
$wDiff   = 7
$wUpd    = 12
$wTarget = 12

# ─── main loop ────────────────────────────────────────────────────────────────
try {
    while ($true) {
        $timestamp   = Get-Date -Format 'HH:mm:ss'
        $alerts      = @()   # array of @{Label;Direction}
        $freshAlerts = @()
        $rows        = New-Object System.Collections.Generic.List[object]
        $fetchError  = $null

        $apiLabel = if ($useFree) { 'tarkov.dev (free)' } else { 'tarkov-market.app + tarkov.dev' }

        # ── compute phase: fetch + per-section work, no console output ────
        $allItems   = $null
        $freeByName = @{}
        if (-not $useFree) {
            $allItems = Get-TarkovItemsAll -ApiKey $apiKey
            if ($null -eq $allItems) {
                $fetchError = 'bulk fetch failed, retrying next cycle'
            }
            else {
                $allItemsFree = Get-TarkovItemsAllFree
                if ($allItemsFree) {
                    foreach ($f in $allItemsFree) {
                        if ($f.name) { $freeByName[$f.name.ToLower()] = $f }
                    }
                }
            }
        }

        if (-not $fetchError) {
            foreach ($section in $itemSections) {
                $cfg       = $ini[$section]
                $label     = $section -replace '^Item\.', ''
                $query     = $cfg['query']
                $avgSource = if ($cfg['avgSource']) { $cfg['avgSource'] } else { 'avg7d' }
                if ($useFree -and $avgSource -eq 'avg7d') { $avgSource = 'avg24h' }
                $alertVal  = $cfg['alert']

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
                    $apiItems = Get-TarkovItemFree -Query $query
                }
                else {
                    $paidMatches = Find-TarkovItemLocal -AllItems $allItems -Query $query
                    if ($paidMatches) {
                        $apiItems = @($paidMatches | ForEach-Object {
                            $key   = if ($_.name) { $_.name.ToLower() } else { $null }
                            $free  = if ($key -and $freeByName.ContainsKey($key)) { $freeByName[$key] } else { $null }
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
                $lastPrices[$section] = $currentPrice

                $avg24h = [long]$apiItem.avg24hPrice
                $avg7d  = [long]$apiItem.avg7daysPrice

                $refAvg = $null
                if     ($avgSource -eq 'avg24h')   { $refAvg = $avg24h }
                elseif ($avgSource -eq 'avg7d')    { $refAvg = $avg7d }
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

                $rows.Add([PSCustomObject]@{
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
                })

                # ── alert bookkeeping ────────────────────────────────────────────
                if ($triggered) {
                    $prev = $lastAlertedPrice[$section]
                    if ($null -eq $prev) {
                        $alerts += @{ Label = $label; Direction = $direction }
                        $freshAlerts += $label
                        $lastAlertedPrice[$section] = $currentPrice
                    }
                    elseif ($currentPrice -ne $prev) {
                        $alerts += @{ Label = $label; Direction = $direction }
                        $lastAlertedPrice[$section] = $currentPrice
                    }
                    else {
                        $alerts += @{ Label = $label; Direction = $direction }
                    }
                }
                else { $lastAlertedPrice.Remove($section) }
            }
        }

        # ── render phase: clear screen, print everything in one burst ───
        [Console]::Clear()
        wh "Tarkov Price Alert | $apiLabel | $($itemSections.Count) items | every ${checkIntervalSec}s | Ctrl+C to stop" DarkGray

        $mid = " $timestamp "
        $sepW = if ($useFree) { 46 } else { 54 }
        wh (($dash * $sepW) + $mid + ($dash * $sepW)) DarkGray

        if ($fetchError) {
            Write-Host ""
            wh "  $fetchError" DarkGray
            Start-Sleep -Seconds $checkIntervalSec
            continue
        }

        if ($useFree) {
            wh ("     {0,-$wLabel}  {1,$wPrice}     {2,$wTarget}     {3,$wDiff}    {4,$wAvg}     {5}" -f `
                'Item', 'Price', 'Target', 'Diff', 'avg24h', 'Updated') DarkGray
        } else {
            wh ("     {0,-$wLabel}  {1,$wPrice}     {2,$wTarget}     {3,$wDiff}    {4,$wAvg}     {5,$wAvg}     {6}" -f `
                'Item', 'Price', 'Target', 'Diff', 'avg24h', 'avg7d', 'Updated') DarkGray
        }

        foreach ($r in $rows) {
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
            if (-not $useFree) {
                $srcMark = if ($r.source -eq 'free') { '*' } else { ' ' }
                wh " $srcMark" DarkGray -NoNewline
            }
            if ($r.triggered) { wh "  !!" $r.bsColor -NoNewline }
            Write-Host ""
        }

        Write-Host ""

        if ($alerts.Count -eq 0) {
            wh "  no good deals :(" DarkGray
        }
        else {
            foreach ($a in $alerts) {
                if ($a.Direction -eq 'B') {
                    wh "  !! good time to buy $($a.Label) !!" Green
                } else {
                    wh "  !! good time to sell $($a.Label) !!" Red
                }
            }
            if ($freshAlerts.Count -gt 0 -and $volume -gt 0) {
                if (Test-Path $soundFile) {
                    try   { Play-SoundWithVolume -FilePath $soundFile -Volume $volume }
                    catch { Write-Warning "  Could not play sound: $_" }
                }
                else { Write-Warning "  Sound file not found: $soundFile" }
            }
        }
        Start-Sleep -Seconds $checkIntervalSec
    }
}
finally {
    Write-Host ""
    wh "Stopped." Cyan
}