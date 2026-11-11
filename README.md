# RevivePad

Turn an old, jailbroken iPad into a fast wall dashboard for [Home Assistant](https://www.home-assistant.io/).

Old iPads (iPad mini 1, iPad 2/3, iOS 8-9) can no longer run the Home Assistant app or its web
dashboard. RevivePad is a small native app, built for 32-bit iOS 8, that talks to Home Assistant's
REST API directly over your local network. No cloud, no browser, no certificates.

> **Status: early.** Developed and tested on one iPad mini 1 (iOS 8.4.1). It sets itself up with a
> starter layout and has an on-screen editor; drawers and finer options are still JSON.

## Quick start

1. Jailbreak the iPad and install OpenSSH and AppSync Unified from Cydia.
2. Build and install the app (`HAPanel/wsl-build.sh`, `HAPanel/deploy.sh`), or install a `.deb`.
3. Open the app, tap *Connect…*, enter your Home Assistant address and a long-lived access token.
   A starter dashboard appears, built from your own lights, thermostat, speakers and weather.
4. Run `sh ha/install.sh` on the Home Assistant machine so the forecast, the Home drawer and
   saving from the layout editor work.

Details for every step: **[docs/SETUP.md](docs/SETUP.md)**.

## What it does

**Dashboard**
- Clock, date and current weather, then the next two days to its right in the header (tap for the full forecast)
- A grid of cards and a sidebar of slide-out drawers (with tabs for several sections in one
  drawer), both defined per iPad in a JSON file that
  lives in Home Assistant, so several iPads can each show something different
- Several screens, swiped left and right like the iPad's own home screen
- First run without any files: connection form on the iPad, then a starter layout made from the
  entities Home Assistant already has
- On-screen layout editor (gear, then *Edit layout*): drag cards to any cell of the grid (gaps
  stay where you leave them), resize them, add widgets from a list and pick their entity from
  Home Assistant, add or remove screens, change columns, rows and row heights, hide or restore
  cards, and save back to Home Assistant with backups
- Color themes picked on the iPad or set in the layout

**Cards**

| Card | What it shows |
|---|---|
| `light` | Big on/off button and brightness for a light or light group |
| `light_members` | Every bulb in a group: on/off and brightness each |
| `climate` | Round thermostat dial: target in the middle, current temperature on the ring, blue while cooling, orange while heating; drag the ring or use +/- |
| `climate_detail` | Mode, fan and preset buttons, 24-hour graph, activity log |
| `context` | *Now playing* while music plays (back, play/stop, forward, volume, time left; tap for the full player); otherwise time- or state-based actions (for example a Goodnight button in the evening) |
| `media` | Player with artwork, play/pause, skip, seek bar, stop casting, volume |
| `library` | Browse a media library through Home Assistant (for example Plex) and cast to speakers; play an album from any song, shuffle, repeat |
| `cameras` | Live snapshot strip, tap for full screen |
| `weather_detail` | 10-day forecast with a per-day view: details, hourly graph, hour-by-hour strip |
| `forecast` | Compact daily forecast strip |
| `tesla` | TeslaMate data for one or more cars, swipe between them |
| `timer` | Countdown timer with a full-screen alarm |
| `updates` | Pending Home Assistant updates with a badge on the sidebar |
| `adblock` | Pause and resume AdGuard Home |
| `network` | Internet up/down, current download and upload speed, public address |
| `batteries` | Every battery sensor in the house, lowest first |
| `detections` | History of what Frigate has seen (people, pets), with snapshots |
| `freeze_dryer` | HarvestRight freeze dryer: stage, temperature, elapsed and remaining time |
| `buttons`, `sensors` | Any service call or toggle; a name and value list |
| Home drawer | Every light, switch and cover in the house, grouped by area, shared by all iPads |

**Built for a wall**
- Presence detection with the front camera (motion and face detection, processed on the device,
  nothing stored or sent): photo slideshow when nobody is around, fully black after 30 minutes,
  instant wake when someone walks up
- Alerts that wake the screen: timer finished, doorbell with camera snapshot, and a live camera
  pop-up when Frigate detects a person
- Reports the iPad's battery level to Home Assistant, so a smart plug can limit charging
- Cards adapt to the size of their tile (the timer, light and thermostat rearrange themselves)
- Classic iOS-style animations that stay smooth on an A5 chip

## How it works

```
iPad (RevivePad app)  --HTTP, local network-->  Home Assistant
   reads   /local/hapanel/<panel>.json     layout for this iPad
           /local/hapanel/home.json        shared Home drawer
           /local/hapanel/forecast.json    10-day forecast (written by HA every 30 min)
   calls   /api/states, /api/services, /api/template   with a long-lived access token
```

The app never streams the Home Assistant web UI. Every button is a native control that calls a
Home Assistant service, which is why it stays fast on hardware from 2012.

## Repository layout

| Path | Contents |
|---|---|
| `HAPanel/` | The iOS app (Objective-C, UIKit, Theos project) |
| `HAPanel/wsl-build.sh`, `deploy.sh` | Build on Linux/WSL, install over SSH |
| `HAPanel/tools/` | Connection setup over SSH, `.deb` packaging, SDK patch for 32-bit builds, remote screenshot helper |
| `ha/install.sh` | Copies the Home Assistant files into `/config` |
| `ha/hapanel/` | Scripts that run inside Home Assistant: forecast fetcher, layout saver |
| `ha/packages/` | Home Assistant packages: shell commands, forecast automation, timer, TeslaMate sensors |
| `ha/examples/` | Full example layout, Home drawer config, go2rtc and Frigate configs, Goodnight script |
| `docs/` | [Setup](docs/SETUP.md) and the [layout reference](docs/LAYOUTS.md) |

## Requirements

- A jailbroken iPad on iOS 8 or 9 with **OpenSSH** and **AppSync Unified** installed from Cydia
- Home Assistant reachable over plain HTTP on your local network
- A Linux machine or WSL to build ([Theos](https://theos.dev), no Mac needed)

See **[docs/SETUP.md](docs/SETUP.md)** to build, install and connect it, and
**[docs/LAYOUTS.md](docs/LAYOUTS.md)** for every card and option.

## Known limits

- Tested on a single device model. Other screen sizes should work (layouts are computed) but are untested.
- Sidebar drawers and the finer card options are still edited as JSON. The on-screen editor
  arranges cards, adds standard widgets and manages screens.
- An app cannot switch the LCD backlight fully off. "Blank" is black at minimum brightness.
- Files under Home Assistant's `www/` folder are readable without login. Layouts contain entity
  names only; keep secrets out of them.
- Google Cast speakers need mDNS to cross subnets if your Wi-Fi and Home Assistant are on
  different networks.
- Music queues (play an album from a song, skip, shuffle, repeat) are built for Plex through
  Home Assistant's Plex integration. Other sources play the tapped item, and skip only works
  where the player offers it.

## License

[Apache License 2.0](LICENSE).
