# tarkov-flip-chimer

A PowerShell price-alert tool for Escape from Tarkov's flea market.
It polls prices on a configurable interval and plays a **chime** sound the moment a tracked item hits your buy or sell threshold — so you can flip deals without staring at the screen.

## Features

- **Buy alerts** — chime when a price drops below your target (fixed value or % below average)
- **Sell alerts** — chime when a price spikes above your target
- **Live dashboard** — scrolling console table with current price, target, Diff%, 24h average, and time since last update
- **Duplicate suppression** — the chime fires again only when the price actually changes, not every poll cycle
- **Free mode** — works out of the box via [tarkov.dev](https://tarkov.dev) with no account required
- **Game modes** — track PvP, PvE, or PvP Season (`gameMode = pvp | pve | pvps`) prices

## Will I get banned?

No. This tool never touches the game process — it calls public price APIs in a background terminal window.

For context: [RatScanner](https://ratscanner.com) overlays real-time item data directly on top of the Tarkov window by reading the screen, and even that has never resulted in bans. This tool is strictly less invasive — it only reads a website.

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (ships with Windows)
- *(Optional)* A paid API key from [tarkov-market.com/dev/api](https://tarkov-market.com/dev/api) for faster, more reliable data and 7-day averages. Required if you want `gameMode = pvps` before tarkov.dev adds season data

## Quick start

1. **Create your config** — copy `config.example.ini` to `config.ini`.

2. *(Optional)* **Add an API key** — subscribe to tarkov-market.com, open the API section, and paste your key into `config.ini`.
   Without a key the tool uses [tarkov.dev](https://tarkov.dev) for free (could be slower and less reliable).
   See [`how-to-get-api-key.png`](how-to-get-api-key.png) for a screenshot.

   ![How to get API key](how-to-get-api-key.png)

3. **Add items to watch** — one `[Item.<Label>]` section per item.
   Search for the item on [tarkov-market.com](https://tarkov-market.com) and use its name as the `query` value (see [`where-to-get-item-name.png`](where-to-get-item-name.png)):

   ![Where to get item name](where-to-get-item-name.png)

   ```ini
   [Item.PACA]
   query = PACA Soft Armor
   alert = 29000          ; buy when price < 29 000 ₽

   [Item.Bitcoin]
   query     = physical bitcoin
   avgSource = avg24h
   alert     = S7%        ; sell when price > 7% above 24h average
   ```

4. **Run** — double-click `run.bat` (or open a terminal and run `.\Check-TarkovPrices.ps1`).

## Configuration reference

### `[General]`

| Key | Default | Description |
|---|---|---|
| `apiKey` | — | tarkov-market.com API key. Leave blank or as placeholder to use tarkov.dev for free |
| `checkIntervalSecs` | `61` | Seconds between API polls |
| `gameMode` | `pvp` | `pvp`, `pve`, or `pvps` (PvP Season). tarkov.dev doesn't have PvP Season data yet, so `pvps` runs paid-only (tarkov-market.app) until it does — the tool probes for it automatically at startup and picks it up once it appears |
| `tarkovDevMode` | (auto) | Advanced/optional: override which `json.tarkov.dev/<mode>/` path feeds the free source, if the automatic `gameMode` mapping ever picks the wrong one |
| `soundFile` | `alert.wav` | Path to the chime sound (relative to the script folder) |
| `volume` | `5` | Playback volume 0–100 |
| `windowHeightOffset` | `0` | Adjust auto-computed console window height in rows. Negative shrinks (e.g. `-7`), positive grows (e.g. `+3`). |
| `debug` | `no` | `yes` mirrors every rendered frame (table + alerts, no colors) to `debugFile` — useful for diagnosing bad data or misaligned columns without needing to screenshot the console |
| `debugFile` | `analytics/debug-console.txt` | Path for the debug mirror log (relative to the script folder) |

### `[Item.<Label>]`

| Key | Default | Description |
|---|---|---|
| `query` | — | Search string sent to the API (**required**) |
| `alert` | — | Alert threshold (**required**) — see format below |
| `label` | section name | Display name in the table. Set this to give two sections the same on-screen label (e.g. one buy + one sell tracker for the same item) |
| `avgSource` | `avg7d` | Reference average: `avg7d`, `avg24h`, a decimal weight (e.g. `0.7`, `1.3`) blending the two, or an integer fixed price. See [Weighted `avgSource`](#weighted-avgsource) |
| `used` | `no` | `yes` = track the cheapest (worn) variant; `no` = most expensive (new) |

**Alert format**

| Example | Meaning |
|---|---|
| `15000` | Buy when price < 15 000 ₽ |
| `B15000` | Same as above (explicit buy) |
| `S45000` | Sell when price > 45 000 ₽ |
| `B15%` | Buy when price is more than 15% below `avgSource` |
| `S7%` | Sell when price is more than 7% above `avgSource` |

#### Same item, two directions

Section headers must be unique, but two sections can share the same display label via `label`. Useful for tracking buy and sell triggers on the same item without arrow-suffixed names:

```ini
[Item.BitcoinBuy]
query     = physical bitcoin
label     = Bitcoin
avgSource = avg24h
alert     = B5%

[Item.BitcoinSell]
query     = physical bitcoin
label     = Bitcoin
avgSource = avg24h
alert     = S7%
```

Both rows render as `Bitcoin` in the table — the buy and sell trackers stay independent (separate alert state, separate triggers), but the labels match.

#### Weighted `avgSource`

`avgSource` accepts a decimal **weight** that blends the two API averages:

```
refAvg = avg7d + w * (avg24h - avg7d)
       = avg7d * (1 − w) + avg24h * w
```

A decimal point in the value is the marker — `1.0` is a weight, `1` is a fixed price.

| `avgSource` | Meaning |
|---|---|
| `0.0` | pure `avg7d` (most stable, slowest to react) |
| `0.5` | midpoint between the two |
| `1.0` | pure `avg24h` (most responsive, noisier) |
| `0.7` | mostly 24h, slightly anchored to 7d |
| `1.3` | extrapolates **past** `avg24h`, amplifying the recent trend (the gap between 7d and 24h) |
| `2.0` | doubles the trend signal — aggressive |

**The point.** The current price wiggles minute-to-minute around its average. When `avg24h ≈ avg7d`, the market is calm and `refAvg` barely moves regardless of `w` — so minor wiggles don't push you across the trigger. When `avg24h` drifts away from `avg7d`, that's a real recent shift, and `w > 1` makes `refAvg` lean into it harder so the alert reacts faster.

**Worked numbers** (with `avg7d = 100 000 ₽`):

| Market | `avg24h` | `w=0.0` | `w=0.5` | `w=0.7` | `w=1.0` | `w=1.3` | `w=2.0` |
|---|---:|---:|---:|---:|---:|---:|---:|
| Calm | 100 500 | 100 000 | 100 250 | 100 350 | 100 500 | 100 650 | 101 000 |
| Up trend +5% | 105 000 | 100 000 | 102 500 | 103 500 | 105 000 | 106 500 | 110 000 |
| Down trend −3% | 97 000 | 100 000 |  98 500 |  97 900 |  97 000 |  96 100 |  94 000 |

In a calm market the choice of `w` barely matters (the row stays close to 100k either way). In a trending market `w` decides how aggressively `refAvg` follows the trend.

**Free mode.** `avg7d` is unavailable through the free API, so a decimal weight automatically falls back to `avg24h` when no key is configured.

**Examples:**

```ini
; Stable reference — buy if price drops 15% below the 7-day average,
; ignore short-term spikes.
[Item.WaterFilter]
query     = water filter
avgSource = avg7d         ; same as 0.0
alert     = B15%

; Smoothed midpoint — react to recent shifts but don't chase 24h noise.
[Item.LedX]
query     = LEDX
avgSource = 0.5
alert     = B10%

; Mostly 24h with a slight anchor to 7d — fast, but resists single-spike noise.
[Item.GpuBuy]
query     = Graphics card
label     = GPU
avgSource = 0.7
alert     = B12%

; Trend-amplified — refAvg pushes past 24h in the direction the 7d→24h
; gap points to. Useful for sell triggers when prices are climbing.
[Item.GpuSell]
query     = Graphics card
label     = GPU
avgSource = 1.3
alert     = S10%
```

### `[Separator.<Label>]`

Inserts a labeled divider line between item rows. Position in the file determines where it appears. The label is taken from the section name.

| Key | Default | Description |
|---|---|---|
| `color` | `DarkGray` | Line color — any PowerShell ConsoleColor name or `#RRGGBB` hex |

**Named colors** (PowerShell ConsoleColor):

| Color | | Color | |
|---|---|---|---|
| `Black` | | `DarkBlue` | |
| `DarkGreen` | subdued green | `DarkCyan` | subdued cyan |
| `DarkRed` | subdued red | `DarkMagenta` | purple-ish |
| `DarkYellow` | brown / olive | `DarkGray` | dim *(default)* |
| `Gray` | neutral | `Blue` | |
| `Green` | buy / positive | `Cyan` | info |
| `Red` | sell / negative | `Magenta` | bright purple |
| `Yellow` | alert | `White` | bright |

**Hex colors** — any RGB value via `#RRGGBB`, e.g. `#8B4513` (brown), `#6A0DAD` (purple), `#4B8BBE` (Python blue).

```ini
[Separator.Armor & Gear]
color = DarkCyan

[Separator.Valuables]
color = #8B6914
```

### `[Column.Break]`

Optional. If present, splits the output into two side-by-side columns separated by a vertical bar (`│`) — sections above this line render in the left column, sections below render in the right. Useful when the item list is long: window becomes ~2× wider and ~2× shorter. Without `[Column.Break]`, single-column layout is used.

The bottom alert list has three layouts, checked in this order:

| Key | Default | Notes |
|---|---|---|
| `alertWrapAfter` | off | Once the alert count exceeds this number, continue in a second column instead of growing taller. Splits by raw count, not buy/sell — so a lopsided burst (e.g. 20 buy alerts, 1 sell) still fills both columns instead of scrolling the table off the top of the window. Takes priority over `splitTriggers` when both are set. |
| `splitTriggers` | `no` | If `yes` (and `alertWrapAfter` didn't kick in), triggers from left-column items appear bottom-left, from right-column items bottom-right. Handy when left is your buy list and right is your sell list — but a lopsided burst still grows one side tall on its own, since it's split by side, not by count. |

If neither is set, alerts render as one plain vertical list.

```ini
[Item.PACA]
query = PACA Soft Armor
alert = 29000

[Column.Break]
alertWrapAfter = 10   ; wrap alerts into a 2nd column past 10, regardless of side
splitTriggers  = yes  ; fallback when alert count is under alertWrapAfter

[Item.Hawk]
query = Gunpowder "Hawk"
alert = S25000
```

### `[Logging]`

Optional. When enabled, appends a JSON Lines entry per cycle to a log file. A new line is written only when at least one item's current price changed since the previous cycle (the very first cycle is always written so the starting state is captured). Each entry mirrors the data shown on screen.

| Key | Default | Description |
|---|---|---|
| `enabled` | `no` | `yes` to turn the JSON log on |
| `path` | `prices.log.jsonl` | Log file path, relative to the script folder |
| `maxEntries` | — | On startup, keep at most N most recent lines (empty = no limit) |
| `maxSizeKB` | — | On startup, trim oldest lines so the file fits in N KB (empty = no limit). Both can be set; whichever is more strict wins |

```ini
[Logging]
enabled    = yes
maxEntries = 5000
maxSizeKB  = 1024
```

## Files

| File | Description |
|---|---|
| `Check-TarkovPrices.ps1` | Main monitoring script |
| `run.bat` | Launches the monitor |
| `config.example.ini` | Config template — copy to `config.ini` and edit |
| `chime.wav` | Default alert sound |

## License

MIT
