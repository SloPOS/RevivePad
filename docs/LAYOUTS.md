# Layout reference

Each iPad loads `/config/www/hapanel/<panel>.json` from Home Assistant (`panel` is the name given in
the app's connection form). Until that file exists the app shows a starter layout it builds from
Home Assistant's entities; saving from the editor creates the file. It re-checks the file every 60 seconds; gear, *Reload layout* applies a
change at once. If the JSON has a mistake, the iPad keeps its last good layout and shows the
error under the date. A full working example is in [`ha/examples/panel.json`](../ha/examples/panel.json).

Two ways to change a layout:

- **On the iPad:** gear, *Edit layout*.
  - Drag a card to any empty cell, or onto another card to swap them. Cards stay where you put
    them and removing one leaves its cell empty.
  - *Narrower / Wider / Shorter / Taller* resize a card; *Hide* removes it (kept under
    `hidden_cards`, *Restore* brings it back).
  - *+ Widget* adds a card from a list (light, thermostat, music player, now playing, cameras,
    forecast, timer, button, sensor, Tesla, updates, ad block). Where a widget needs an entity,
    you pick it from Home Assistant's list. Cameras and Tesla copy the settings of a card of
    that type already in the layout.
  - *+ Screen* / *− Screen* add or remove a screen; the arrows switch between them. On the
    dashboard, swipe left and right between screens.
  - The second line sets columns, rows and each row's height for the screen being edited.
  - *Save* writes the file in Home Assistant and keeps the previous 10 versions in
    `www/hapanel/backups/`.
- **In the file:** Home Assistant's File editor. Needed for card contents: which entities, which
  drawers, new cards.

> Files in `/config/www` are served without login at `/local/...`. Keep secrets out of them.

## File structure

```json
{
  "weather": "weather.forecast_home",
  "columns": 3,
  "row_heights": [1, 1, 0.55],
  "presence": { "enabled": true, "dim_after": 60, "sensitivity": "medium",
                "idle": "photos", "photo_url": "http://192.168.1.60:3000/image",
                "photo_interval": 45, "blank_after": 1800 },
  "alerts": { "timer": "timer.panel" },
  "theme": { "accent": "#FFB340" },
  "cards": [ ],
  "sidebar": [ ],
  "home": true
}
```

| Key | Meaning |
|---|---|
| `weather` | Weather entity for the header. Omit to hide the header weather. |
| `columns`, `rows`, `row_heights` | Grid columns; minimum number of rows (empty rows stay empty); relative row heights (missing rows count as 1) |
| `cards` | First screen. Every card takes `w`, `h` (cells) and `title` (`""` hides it). A card with `col` and `row` (0-based) sits in that cell; cards without them fill the first gap, left to right, top to bottom. The on-screen editor gives every card a `col` and `row`. |
| `pages` | Further screens, swiped left and right: a list of `{ "cards": [], "columns": 3, "rows": 3, "row_heights": [] }` |
| `sidebar` | Drawers on the left rail (below) |
| `home` | `false` hides the shared Home drawer |
| `presence` | Camera presence and idle behaviour (below). Omit to never dim. |
| `alerts` | `timer`: timer entity. `doorbell`: `{ "trigger": "event.x or binary_sensor.x", "camera": "camera.x", "title": "Front door" }`. `detections`: camera pop-up when Frigate sees a person (below) |
| `theme` | Default colors: `accent`, `media`, `background`, `card`, `button`, `text`, `dim`, `heat`, `cool`. Colors picked on the iPad (gear, *Colors*) override these. |

Any card can open a drawer: `"opens": "Climate"` adds a link in its corner
(`"opens_label"` changes the text; `"tap_opens": true` makes the whole card the button).

## Sidebar drawers

```json
{ "name": "Music", "icon": "🎵", "width": 0.94, "row_heights": [0.42, 1], "cards": [ ] }
```

| Key | Meaning |
|---|---|
| `name`, `icon` | Rail button. Only emoji from Unicode 6 exist on iOS 8 (🎵 🚫 🏠 💡 🚗 ⏰ 🔄 ❄️ work; newer ones show as "?") |
| `width` | Fraction of the screen the drawer covers (default 0.55) |
| `columns`, `rows`, `row_heights` | Grid inside the drawer; `rows` stops one short card stretching |
| `hidden` | `true`: no rail icon, opened only by a card's `opens` |
| `badge` | `"updates"`: red count of pending Home Assistant updates |

A drawer can hold several sections behind tab buttons along its top. Use `tabs` in place of `cards`:

```json
{ "name": "Home", "icon": "🏠", "width": 0.94, "tabs": [
  { "name": "Lights", "icon": "💡", "width": 0.55, "cards": [ ] },
  { "name": "Music", "icon": "🎵", "row_heights": [0.42, 1], "cards": [ ] },
  { "name": "Switches", "cards": [ { "type": "home" } ] } ] }
```

Each tab takes `name`, `icon`, `cards`, `columns`, `rows`, `row_heights`, and `width` (the fraction
of the drawer its cards use). A card's `"opens": "Lights"` also finds a tab of that name. The drawer
remembers the tab you last used. `{ "type": "home" }` inside a tab shows the shared Home list
(set `"home": false` at the top level to drop its separate button).

Drawers close when you tap outside, after 90 seconds without a touch, and when the screen goes idle.

## Cards

```json
{ "type": "light", "entity": "light.bedroom", "members": false, "opens": "Lights", "h": 2 }
{ "type": "light_members", "entity": "light.bedroom", "strip_prefix": "Bedroom " }
{ "type": "climate", "entity": "climate.living_room", "opens": "Climate", "opens_label": "Details", "w": 2 }
{ "type": "climate_detail", "entity": "climate.living_room", "hours": 24 }
{ "type": "media", "players": [ { "entity": "media_player.bedroom", "name": "Bedroom" } ],
  "plex_session": "media_player.plex_plex_cast_chromecast" }
{ "type": "library", "browse_entity": ["media_player.bedroom"], "auto_open": ["Plex", "Music"],
  "targets": [ { "name": "Bedroom", "entity": "media_player.bedroom" },
               { "name": "All speakers", "entity": ["media_player.bedroom", "media_player.kitchen"] } ] }
{ "type": "cameras", "interval": 6, "w": 3, "title": "", "cameras": [
  { "name": "Front Yard", "url": "http://192.168.1.50:1984/api/frame.jpeg?src=front_yard&width=480" } ] }
{ "type": "weather_detail", "entity": "weather.forecast_home", "days": 10 }
{ "type": "forecast", "entity": "weather.forecast_home", "days": 7, "w": 3 }
{ "type": "tesla", "cars": [ { "prefix": "tesla_", "name": "Model S", "image": "/local/hapanel/cars/model_s.png" } ] }
{ "type": "timer", "entity": "timer.panel", "presets": [1, 3, 5, 10, 15, 30, 60] }
{ "type": "updates" }
{ "type": "adblock", "pause_minutes": [10, 60] }
{ "type": "network", "wan": "binary_sensor.router_wan_status", "down": "sensor.router_download_speed",
  "up": "sensor.router_upload_speed", "ip": "sensor.router_external_ip",
  "sensors": [ { "entity": "sensor.adguard_dns_queries_blocked", "name": "Blocked today" } ] }
{ "type": "batteries", "low": 20, "only_low": false, "exclude": ["sensor.tesla*", "sensor.*_battery_level"] }
{ "type": "freeze_dryer", "prefix": "harvestright_freeze_dryer" }
{ "type": "detections", "frigate": "http://192.168.1.61:5000", "labels": ["person", "dog", "cat"],
  "limit": 60, "cameras": { "front_yard": "Front Yard" } }
{ "type": "buttons", "title": "Scenes", "columns": 2, "buttons": [
  { "name": "Movie", "service": "scene.turn_on", "data": { "entity_id": "scene.movie" } },
  { "name": "Fan", "entity": "fan.bedroom" } ] }
{ "type": "sensors", "title": "Climate", "entities": [ { "entity": "sensor.temperature", "name": "Temp" } ] }
```

Notes per card:

- **climate** draws a round dial scaled to its tile. Drag around the ring, or use the − / + buttons
  peeking out on either side for one-degree steps. Nothing is sent until the target has been left
  alone for 3 seconds (`"delay"`), and a change of more than 5 degrees (`"confirm_over"`) asks for
  confirmation first. The ring covers `"min"` to `"max"` (default 65 to 85 on a Fahrenheit thermostat, the
  thermostat's own limits otherwise); the buttons can go beyond it. Tiles at least two columns
  wide add the readings beside the dial, and the mode buttons appear when there is room.
- **timer** and **light** also fit their tile: the timer drops preset rows and shrinks the clock,
  the light keeps a square button and hides the brightness slider on very short tiles.
- **media / context music controls** go to the speaker entity with explicit pause and play. The
  button flips immediately and Home Assistant confirms a moment later. On the **media** card ■
  stops casting (`media_player.turn_off`). The **context** card has back, one play/stop button
  (stop pauses, so the same button starts the music again), forward and volume; on a narrow tile
  the buttons and volume run across the full width under the artwork.
- **artwork** for now playing comes from the speaker; when it has none (Cast playing Plex) the
  card shows the cover of the exact track the speaker reports, which needs `"plex_server": "<Plex
  server id>"` on the card (the id is in the `plex://<id>/...` links of the library). Without it
  the `plex_session` entity's picture is used, but only while it is on the same track.
- **library play options**: tapping a song inside an album or playlist queues the whole album
  from that song on. 🔀 and 🔁 turn shuffle and repeat on for what is played next. For Plex the
  queue is created on the Plex server and handed to Home Assistant as a play queue; players with
  their own shuffle / repeat switch (Spotify, Music Assistant, Sonos) also get
  `media_player.shuffle_set` / `repeat_set`. Other sources play the tapped item as before.
- **skip and seek**: Cast speakers playing Plex do not offer next / previous through Home
  Assistant, so the cards skip by starting the remembered Plex queue again at the neighbouring
  track (this works for queues started from the library card). Players that can skip by
  themselves get the normal service. The **media** card has a seek bar with elapsed and remaining
  time (`media_player.media_seek`); the **context** card shows the time left, and tapping its
  artwork or titles opens the drawer or tab named in `"opens"` (default `Music`).
- **library** browses through `media_player.browse_media`, caches every page on the iPad (instant
  on the second visit), shows tracks as a list, and only sends to speakers that are online. A list
  of entities plays on each separately; for synced multi-room audio use one speaker-group entity.
- **cameras** refresh independently, at most two downloads at a time; a camera that fails twice
  is marked *no signal*. Snapshots pause while the screen is idle. Tap one for full screen.
- **weather_detail** and the header use `/local/hapanel/forecast.json` (10 days daily and hourly
  from Open-Meteo, written by `ha/hapanel/fetch_forecast.py`). Without that file they fall back to
  the weather entity, which usually has 5-7 days and 2 days of hourly data.
- **tesla** reads `sensor.<prefix>*` and `binary_sensor.<prefix>*` (see `ha/packages/teslamate.yaml`;
  copy it with `cars/2/` and a `tesla_2_` prefix for a second car). Swipe between cars.
- **network** needs no settings with a UPnP router integration: it finds the entities ending in
  `_wan_status`, `_download_speed`, `_upload_speed` and `_external_ip`. Speeds are shown in Mb/s.
- **batteries** lists sensors with device class `battery`; `exclude` takes `*` wildcards.
- **detections** is a grid of Frigate events, newest first, refreshed every 30 seconds while it is
  showing. Tap one for the full snapshot with the detection box (enable `snapshots` in Frigate;
  without them the thumbnail is shown). It works well as a drawer:
  `{ "name": "Alerts", "icon": "🚨", "width": 0.94, "cards": [ { "type": "detections", ... } ] }`.
- **freeze_dryer** reads `sensor.<prefix>_mode`, `_temperature`, `_batch_elapsed`,
  `_prep_remaining` and `text.<prefix>_batch_name`.
- **adblock** calls `rest_command.adguard_pause` (with `minutes`) and `rest_command.adguard_resume`.
- **buttons**: `entity` alone runs scripts and scenes, triggers automations, toggles anything else.

### context card

Shows *now playing* (or paused) for the first active player; otherwise the first item whose
`when` matches; otherwise a greeting.

```json
{ "type": "context", "w": 2,
  "players": ["media_player.bedroom"],
  "player_names": { "media_player.bedroom": "Bedroom" },
  "items": [
    { "when": { "after": "20:00", "before": "03:00" }, "title": "Good night", "subtitle": "Lights off, AC to 72",
      "buttons": [ { "name": "Goodnight", "icon": "🌙", "entity": "script.goodnight", "confirm": true } ] } ] }
```

`when` supports `after` / `before` (24-hour, may wrap midnight), `days` (`mon`...`sun`) and
`state` (one or a list of `{ "entity", "is" | "not" }`).

## Home drawer (`home.json`, shared by every iPad)

Lists lights, switches, covers, fans, locks and input_booleans grouped by Home Assistant area,
refreshed every 3 seconds while open.

```json
{ "name": "Home", "icon": "🏠", "width": 0.94, "columns": 4,
  "domains": ["light", "switch", "cover"],
  "area_order": ["Living Room", "Kitchen"],
  "exclude": ["switch.*_cam_*", "light.bulb_inside_a_group"] }
```

`exclude` takes exact entity IDs or `*` / `?` wildcards.

## Presence and idle

The front camera runs at low resolution, about 5 frames a second. Motion (brightness changes on a
16x12 grid) or a detected face counts as someone being there. Frames are analysed in memory and
discarded.

- After `dim_after` seconds alone: photo slideshow from `photo_url` (any URL that returns a
  random image, for example Immich Kiosk's `/image`), if `"idle": "photos"`.
- After `blank_after` seconds: black at minimum brightness.
- Motion, a face or a touch returns to the dashboard. `sensitivity` is `low`, `medium` or `high`.

## Camera pop-up on a detection

```json
"alerts": { "detections": {
  "frigate": "http://192.168.1.61:5000", "labels": ["person"], "seconds": 20, "cooldown": 60,
  "quiet": { "after": "23:00", "before": "06:00" },
  "cameras": { "front_yard": { "name": "Front Yard",
               "url": "http://192.168.1.60:1984/api/frame.jpeg?src=front_yard&width=960" } } } }
```

Every 3 seconds the panel asks [Frigate](https://frigate.video) (its unauthenticated port 5000,
so keep that on a trusted network) for detections in progress. A new one with a matching label
wakes the screen and shows that camera full screen, refreshed every second, for `seconds`. The
camera then stays quiet for `cooldown` seconds, and `quiet` (optional) silences pop-ups overnight.
`cameras` maps Frigate's camera names to a title and a snapshot address; a camera that is not
listed uses Frigate's own latest picture. Home Assistant and MQTT are not involved. An example
detection-only Frigate config is in [`ha/examples/frigate.yml`](../ha/examples/frigate.yml).

## Battery sensor

Every 5 minutes the app posts `sensor.<panel>_ipad_battery` (percent, with a `charging`
attribute). iOS 8 has no charge limit, so pair it with a smart plug and an automation
(on below about 40%, off above about 80%).
