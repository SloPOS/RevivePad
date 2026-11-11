#!/usr/bin/env python3
"""Fetch a 10-day forecast from Open-Meteo and write it where the iPad panels can read it.

Runs inside Home Assistant (shell_command.hapanel_forecast, every 30 minutes). Location, time zone
and units come from Home Assistant's own settings, so nothing personal lives in this file.
Output: /config/www/hapanel/forecast.json  ->  http://<ha>/local/hapanel/forecast.json

Why not a weather entity? Most HA weather integrations return 5-7 daily entries and about 2 days
of hourly data. Open-Meteo is free, needs no API key, and gives 10+ days of both.
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

CONFIG = os.environ.get("HA_CORE_CONFIG", "/config/.storage/core.config")
OUT = os.environ.get("HAPANEL_FORECAST_OUT", "/config/www/hapanel/forecast.json")
DAYS = 10

# WMO weather code -> Home Assistant condition name (the app maps these to icons)
WMO = {0: "sunny", 1: "sunny", 2: "partlycloudy", 3: "cloudy", 45: "fog", 48: "fog",
       51: "rainy", 53: "rainy", 55: "rainy", 56: "snowy-rainy", 57: "snowy-rainy",
       61: "rainy", 63: "rainy", 65: "pouring", 66: "snowy-rainy", 67: "snowy-rainy",
       71: "snowy", 73: "snowy", 75: "snowy", 77: "snowy", 80: "rainy", 81: "rainy", 82: "pouring",
       85: "snowy", 86: "snowy", 95: "lightning-rainy", 96: "lightning-rainy", 99: "lightning-rainy"}


def condition(code, is_day=True):
    c = WMO.get(int(code) if code is not None else -1, "cloudy")
    return "clear-night" if c == "sunny" and not is_day else c


def main():
    with open(CONFIG, encoding="utf-8") as f:
        core = json.load(f)["data"]
    us = (core.get("unit_system_v2") or core.get("unit_system") or "metric") == "us_customary"
    params = {
        "latitude": core["latitude"], "longitude": core["longitude"],
        "timezone": core.get("time_zone") or "auto", "forecast_days": DAYS,
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
                 "precipitation_sum,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,"
                 "uv_index_max,sunrise,sunset,relative_humidity_2m_mean",
        "hourly": "weather_code,temperature_2m,apparent_temperature,precipitation_probability,"
                  "precipitation,wind_speed_10m,relative_humidity_2m,is_day",
        "current": "weather_code,temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,is_day",
    }
    if us:
        params.update(temperature_unit="fahrenheit", wind_speed_unit="mph", precipitation_unit="inch")
    url = "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        data = json.load(r)

    off = int(data.get("utc_offset_seconds", 0))
    tz = "%s%02d:%02d" % ("-" if off < 0 else "+", abs(off) // 3600, abs(off) % 3600 // 60)

    def iso(t):  # "2026-11-10T07:00" or "2026-11-10" -> ISO 8601 with offset
        return (t if "T" in t else t + "T00:00") + ":00" + tz

    d, h, c = data["daily"], data["hourly"], data.get("current", {})
    daily = [{
        "datetime": iso(d["time"][i]), "condition": condition(d["weather_code"][i]),
        "temperature": d["temperature_2m_max"][i], "templow": d["temperature_2m_min"][i],
        "precipitation_probability": d["precipitation_probability_max"][i],
        "precipitation": d["precipitation_sum"][i],
        "wind_speed": d["wind_speed_10m_max"][i], "wind_gust_speed": d["wind_gusts_10m_max"][i],
        "wind_bearing": d["wind_direction_10m_dominant"][i], "uv_index": d["uv_index_max"][i],
        "humidity": d["relative_humidity_2m_mean"][i],
        "sunrise": iso(d["sunrise"][i]), "sunset": iso(d["sunset"][i]),
    } for i in range(len(d["time"]))]
    hourly = [{
        "datetime": iso(h["time"][i]), "condition": condition(h["weather_code"][i], h["is_day"][i]),
        "temperature": h["temperature_2m"][i], "apparent_temperature": h["apparent_temperature"][i],
        "precipitation_probability": h["precipitation_probability"][i],
        "precipitation": h["precipitation"][i], "wind_speed": h["wind_speed_10m"][i],
        "humidity": h["relative_humidity_2m"][i],
    } for i in range(len(h["time"]))]
    out = {
        "source": "open-meteo", "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
        "units": {"temperature": "°F" if us else "°C", "wind_speed": "mph" if us else "km/h",
                  "precipitation": "in" if us else "mm"},
        "current": {"condition": condition(c.get("weather_code"), c.get("is_day", 1)),
                    "temperature": c.get("temperature_2m"), "apparent_temperature": c.get("apparent_temperature"),
                    "humidity": c.get("relative_humidity_2m"), "wind_speed": c.get("wind_speed_10m")} if c else None,
        "daily": daily, "hourly": hourly,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))
    os.replace(tmp, OUT)
    print("wrote %s: %d days, %d hours" % (OUT, len(daily), len(hourly)))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # keep the previous file; HA logs the non-zero exit
        print("forecast failed: %s" % e, file=sys.stderr)
        sys.exit(1)
