# animepahe-dl (Unraid Fork)

Forked from [KevCui/animepahe-dl](https://github.com/KevCui/animepahe-dl). This fork adds several quality-of-life improvements tailored for self-hosted Unraid setups, where anime is downloaded to a NAS media share and Cloudflare bypass needs to be fully automated.

## What's different from upstream

### Automatic Cloudflare bypass via CF-Clearance-Scraper

The original script requires you to manually grab `cf_clearance` and `user-agent` from your browser and paste them into `config.json`. This fork replaces that with an automatic call to [CF-Clearance-Scraper](https://github.com/Xewdy444/CF-Clearance-Scraper) at startup, so credentials are always fresh without any manual intervention — important for unattended/scheduled runs on Unraid.

The scraper runs inside its own Python virtualenv. Configure it in `config.json`:

```json
{
  "scraper_path": "/path/to/CF-Clearance-Scraper",
  "scraper_venv": "/path/to/CF-Clearance-Scraper/cf-scraper",
}
```

`scraper_venv` defaults to `<scraper_path>/cf-scraper` if omitted.

### Auto-install of fzf and ffmpeg

On Unraid, user-installed packages don't survive a reboot — the OS boots from a USB flash drive and the root filesystem is rebuilt each time. To avoid having to reinstall `fzf` and `ffmpeg` after every reboot, the script checks for them at startup and downloads/installs them automatically if missing. This makes the script safe to run as an Unraid User Script or scheduled job without any manual setup after a reboot.

### Smart episode caching

Episode lists are cached locally in `.source.json` per anime. On subsequent runs, if no specific episode is requested, the script only fetches the last page of the API to check for new episodes — rather than re-downloading the full episode list every time. This reduces unnecessary API calls and speeds up repeated runs.

### Resume / auto-increment from last downloaded episode

The script tracks the last successfully downloaded episode per anime, keyed by audio language and resolution (e.g. `jpn_720`). On the next run without a `-e` flag, it automatically figures out the next episode to download. If a range of new episodes is available (e.g. 20–23 released since you last ran it), it queues them all. If the next episode isn't out yet, it tells you when the last one was released and estimates when the next one might drop (based on a 7-day cadence). If it's been more than 7 days past that estimate, it flags the series as potentially on hiatus.

### Plex-friendly output filenames

Downloaded files are named in the format `Anime Name - S01E05.mp4`, which Plex and Jellyfin pick up correctly without any manual renaming. Season number is detected automatically from the anime title (e.g. "Season 2" → `S02`).

## Configuration

Minimal `config.json`:

```json
{
  "scraper_path": "/mnt/user/appdata/animepahe-dl/CF-Clearance-Scraper"
}
```

All other keys are optional and have sensible defaults.

## Everything else

Usage, flags, and all other behaviour are identical to upstream — see the [original README](https://github.com/KevCui/animepahe-dl) for full documentation.
