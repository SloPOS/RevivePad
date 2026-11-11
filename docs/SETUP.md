# Setup

Four parts: prepare the iPad, get the app onto it, connect it to Home Assistant, and add the
Home Assistant files that the forecast, the Home drawer and the layout editor need.

## 1. Prepare the iPad

1. Jailbreak it (32-bit, iOS 8 or 9: iPad 2, 3, 4, iPad mini 1).
2. In Cydia install **OpenSSH** and **AppSync Unified** (lets unsigned apps run).
3. Change the root password from the default `alpine` (`passwd` in an SSH session).
4. Add your SSH public key to `/var/root/.ssh/authorized_keys` and a host entry on your
   computer. Old iOS only offers `ssh-rsa` host keys, so modern OpenSSH needs them re-enabled:

   ```
   Host ipad
       HostName <ipad address>
       User root
       IdentityFile ~/.ssh/<your key>
       HostKeyAlgorithms +ssh-rsa
       PubkeyAcceptedAlgorithms +ssh-rsa
   ```

## 2. Get the app onto the iPad

### Option A: build it (Linux or WSL, no Mac, no root)

One-time toolchain:

```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
mkdir -p ~/theos/toolchain/linux/iphone ~/theos/sdks
curl -L -o /tmp/tc.tar.xz https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-x86_64.tar.xz
tar -xJf /tmp/tc.tar.xz -C ~/theos/toolchain/linux/iphone --strip-components=1   # so bin/clang sits directly inside
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
(cd /tmp/sdks && git sparse-checkout set iPhoneOS10.3.sdk && mv iPhoneOS10.3.sdk ~/theos/sdks/)
```

The iOS 10.3 SDK is used with a deployment target of iOS 8.0. Its library stubs leave out a few
32-bit symbols that iOS 8 really has; `HAPanel/tools/patch-sdk.sh` adds them (the build script
runs it automatically and keeps the originals as `*.orig`).

Build and install:

```bash
bash HAPanel/wsl-build.sh      # in Linux/WSL; output lands in HAPanel/build/
bash HAPanel/deploy.sh ipad    # from a shell that has the "ipad" SSH host
```

`deploy.sh` always removes the old app before copying the new one. Overwriting the binary in
place makes iOS kill the app at launch (it caches code signatures per file). It then relaunches
the app with `uiopen hapanel://`.

### Option B: install a package

`bash HAPanel/tools/package.sh 1.0` (after a build) makes
`HAPanel/build/revivepad_1.0_iphoneos-arm.deb`. Copy it to the iPad and install it with
`dpkg -i <file>` over SSH, or open it in Filza. If the project's Releases page has a package,
you can use that and skip the toolchain.

## 3. Connect it to Home Assistant

In Home Assistant create a **long-lived access token**: your profile, *Security*, *Long-lived
access tokens*. The token's user must be an **administrator** (the Home drawer and the updates
card use the template API; saving layouts uses a shell command).

Then either:

- **On the iPad:** open the app and tap *Connect…* (later: gear, *Connection…*). Enter the
  address as you open it on your network (`http://`, not `https://`), paste or type the token,
  and give this iPad a short panel name such as `kitchen`.
- **From your computer:** `bash HAPanel/tools/configure.sh ipad` asks the same three things and
  writes them over SSH, which saves typing a long token on the iPad.

Both store the settings in `/var/mobile/Library/HAPanel/config.plist`, readable only by the
app's user. The token stays on the iPad and is only sent to your Home Assistant.

The app now shows a **starter layout** built from what it finds in Home Assistant: the first
lights, a thermostat, speakers, a timer and the weather. Nothing is stored in Home Assistant
until you save a layout (next step).

## 4. Home Assistant side

On the Home Assistant machine (for example in the *Terminal & SSH* add-on), from a copy of this
repository:

```bash
sh ha/install.sh timer
```

It copies the files below and tells you if `configuration.yaml` still needs the packages line.
It never overwrites a layout you already have.

| From | To | Purpose |
|---|---|---|
| `ha/hapanel/*.py` | `/config/hapanel/` | Forecast fetcher and layout saver |
| `ha/packages/hapanel.yaml` | `/config/packages/` | Shell commands and the 30-minute forecast automation |
| `ha/packages/panel_timer.yaml` | `/config/packages/` | Timer helper for the timer card (`timer` option) |
| `ha/packages/teslamate.yaml` | `/config/packages/` | TeslaMate MQTT sensors for the tesla card (`teslamate` option) |
| `ha/examples/home.json` | `/config/www/hapanel/home.json` | Which lights and switches the Home drawer lists |

Packages need this once in `configuration.yaml`, then a restart:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

### Your layout

- **Start on the iPad:** gear, *Edit layout*. Move and resize cards, add widgets and screens,
  then *Save*. That creates `/config/www/hapanel/<panel>.json` and keeps the previous 10
  versions as backups.
- **Or start from the example:** copy `ha/examples/panel.json` to
  `/config/www/hapanel/<panel>.json` and replace the entity names with yours. It shows every
  feature: tabbed drawers, cameras, music, alerts.

Sidebar drawers and the finer card options are edited in that file; see
[LAYOUTS.md](LAYOUTS.md).

## 5. Make it a wall panel

- Settings, General, Auto-Lock: **Never**. The app also keeps the screen awake while open.
- Settings, General, Accessibility, **Guided Access** locks the iPad to the app.
- The first launch asks for camera access. It is used only for presence detection, on the
  device; nothing is stored or sent.

## 6. Optional pieces

Each of these is independent; skip what you do not have.

| Feature | Needs |
|---|---|
| Camera strip | Any URL that returns a JPEG. For RTSP cameras run [go2rtc](https://github.com/AlexxIT/go2rtc) with [`ha/examples/go2rtc.yaml`](../ha/examples/go2rtc.yaml) and use `http://<go2rtc>:1984/api/frame.jpeg?src=<stream>&width=480` |
| Person pop-up and alert history | [Frigate](https://frigate.video) reading the same cameras; see [`ha/examples/frigate.yml`](../ha/examples/frigate.yml) and `alerts.detections` in the layout reference |
| Music library | A media player that supports browsing in Home Assistant. Tested with the Plex integration playing to Google Cast speakers |
| Photo slideshow when idle | Any URL that returns a random photo, for example Immich Kiosk's `/image` |
| Ad block card | Two `rest_command`s for AdGuard Home (see the layout reference) |
| Tesla card | TeslaMate publishing to Home Assistant's MQTT broker |
| Goodnight button | Any script; [`ha/examples/goodnight_script.yaml`](../ha/examples/goodnight_script.yaml) is one |

Keep camera passwords in an env file, not in the go2rtc config. go2rtc's and Frigate's own APIs
have no login by default and show stream addresses, so keep them on a trusted network.

## Development helpers

The app reads commands from `/var/mobile/Library/HAPanel/cmd` once a second, which lets you
drive and screenshot it over SSH: `snap`, `wake`, `stay:<s>`, `drawer:<name>`, `close`,
`reload`, `edit`, `page:<n>`, `starter` (preview the first-run layout), `connect` (open the
connection form), `demo:music`, `dump:<entity prefix>` (states to `dump.json`, tokens removed).

```bash
bash HAPanel/tools/snap.sh shot.jpg              # screenshot of the running app
bash HAPanel/tools/snap.sh shot.jpg drawer:Music # open a drawer first
ssh ipad 'cat /var/mobile/Library/HAPanel/debug.log'   # failed calls, load timings
```

Crash reports land in `/var/mobile/Library/Logs/CrashReporter/` and can be symbolized with
`llvm-symbolizer` against `HAPanel/build/HAPanel.dSYM`.
