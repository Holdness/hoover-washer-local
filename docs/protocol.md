# The simply-Fi local protocol

What we worked out about the Wi-Fi module in a Hoover HBDOS695TAMCE-80
washer-dryer, from probing it on the network and from reading how the old Hoover
Wizard Android app talks to it. Other Candy/Hoover simply-Fi appliances use the
same API, but programme numbers, defaults and options differ between models.

## The hardware

- The Wi-Fi module is an ESP8266.
- In setup mode it runs an open hotspot named `WIFIWASHMACHINE-xxxx` and is the
  gateway at `192.168.0.1`, handing out addresses by DHCP.
- It broadcasts its MAC and IP on UDP port 55555 every 15–30 seconds.
- The web server on port 80 takes about 15 seconds to start after a device joins
  the hotspot, so a probe that comes in too early makes the washer look dead.
- It handles **one HTTP connection at a time**. Anything that polls it (such as
  the Home Assistant integration) will collide with your commands, so always retry.

### Entering setup mode

Turn the dial to any programme except OFF, then hold **Temperature + Start/Pause**
together until the display shows `rr` (3-digit displays; 4-digit displays use
Prewash + Start/Pause). The Wi-Fi symbol flashes. If no hotspot appears, switch the
washer off at the wall for 30 seconds and try again.

## Encryption

Requests and replies are encrypted with a **repeating-key XOR**, written as
**uppercase hex**.

| Stage | Key |
|---|---|
| Setup (washer is its own hotspot) | The last 8 characters of the hotspot name: `WIFIWASHMACHINE-ab12` → `INE-ab12` |
| After provisioning | The 16-character key you sent in the setup request |

The app generates a random 16-character alphanumeric key during setup and the
washer adopts it for all later traffic. Because we write the setup request
ourselves, we choose that key, so Home Assistant can use it.

## Endpoints

| Address | Purpose |
|---|---|
| `/http-read.json?encrypted=1` | Read status. Decrypts to JSON under `statusLavatrice`. |
| `/http-write.json?encrypted=1&data=<hex>` | Send a command. Replies `{"response":"SUCCESS"}`, or `READ ONLY` when the washer won't accept remote commands. |
| `/http-config.json?encrypted=1&data=<hex>` | Setup only: join Wi-Fi and set the key. |
| `/http-prepareStatistics.json`, `/http-getStatistics.json` | Present, but this model only answers `ERROR`. |

`encrypted=0` returns `BAD REQUEST` on this model.

## Setup request

Plaintext before encryption with the setup key:

```
NTW_MODE=<mode>&SSID=<home wifi name>&PASSWORD=<home wifi password>&ENCRYPT_KEY=<16 chars>
```

`NTW_MODE` is 3 for WPA/WPA2, 2 for WEP, 0 for an open network. The name and
password are sent unescaped, so `&` or `=` in either breaks the request.

On success the washer replies `SUCCESS` (encrypted with the **new** key), drops
its hotspot and joins your network. Ours took about nine minutes to appear.

## Status fields

| Field | Meaning |
|---|---|
| `MachMd` | 1 idle · 2 running · 3 paused · 4 setting a delay (passes in about 20 s) · 5 delayed start programmed · 7 finished |
| `Pr` | Programme number. 15 is ONE Fi EXTRA, the remote-control position. |
| `PrPh` | Phase of the wash. |
| `Temp` | Temperature, °C. |
| `SpinSp` | Spin, in hundreds of rpm. |
| `SLevel` | Soil level, 1–3. |
| `DryT` | Drying choice, 0–8. |
| `DelVal` | Hours of delay; 255 means none. |
| `RemTime` | The washer's time estimate. |
| `WiFiStatus` | 1 when it will accept remote commands, 0 in standby or just after power-on. |
| `Err` | 255 means no error. |

## Commands

A start is one command built from parts:

```
Write=1&Pa=0&Sel=0&PrNm=<programme>
  &StSt=1                              start now
  &DelMd=1&DelVl=<hours>               or: start after a delay (whole hours, 1-24)
  &TmpTgt=<°C>&TmpDf=<default °C>      only if not the programme default
  &SpdTgt=<rpm/100>&SpdDef=<default>   only if LOWER than the default (see below)
  &SLevTgt=<1|2|3>                     soil level, optional
  &Stm=0&Dry=<1-8>                     drying, optional
  &OptMsk=0

Stop / cancel a delay:  Write=1&StSt=0&DelMd=0&PrNm=<programme>
```

| `Dry=` | Drying | `SLevTgt=` | Soil level |
|---|---|---|---|
| 1 | Extra dry | 1 | Lightly soiled (the app raises it to 2 at 90°) |
| 2 | Iron dry | 2 | Normal |
| 3 | Cupboard dry | 3 | Very dirty |
| 4 | Cool down | | |
| 5 · 6 · 7 · 8 | 120 · 90 · 60 · 30 min | | |

There is no command to change temperature or spin on their own: they're only
set as part of a start.

This washer belongs to what the app calls the "axibianca" family. For it, drying
is the `Stm`/`Dry` pair. The `Option=` field and the option bitmask the app uses
for other models are ignored.

### Measured effects (Cottons, from the washer's own time estimate)

| Command | Estimate |
|---|---|
| Cottons, defaults | 170 min (soil level 3) |
| `SLevTgt=2` | 132 min |
| `SLevTgt=1` | 20 min |
| `Dry=1` / `2` / `3` / `4` / `5` / `6` | 400 / 390 / 340 / 180 / 290 / 260 min |

## Quirks

- **The reply comes first.** `SUCCESS` arrives before the washer has acted. Its
  status catches up a few seconds later; setting a delay takes about 20 seconds.
- **Standby.** About five minutes after going idle the washer sleeps. It then
  reports a misleading "running, 5 minutes left" status and answers `READ ONLY` to
  every command. Turning the dial off and back to ONE Fi EXTRA wakes it.
- **Spin above the default.** Asking for more than the programme's default spin
  (Mixed at 1400 when its default is 1200) left our washer beeping constantly and
  off the network until it was switched off and on. Lower speeds work.
- **Delayed starts lock up the Wi-Fi.** When a delayed start begins running, the
  module still answers ping but its web server stops responding until the washer
  is power-cycled. The wash itself runs normally.
- **Display during a delay.** It shows the dial position, not the programme that
  was sent. The washer still runs what was sent.
- **After a cancelled delay** the washer keeps reporting the cancelled programme
  until the dial is turned away and back.
