# animepahe-dl (Unraid Fork)

Forked from [KevCui/animepahe-dl](https://github.com/KevCui/animepahe-dl). This fork adds several quality-of-life improvements tailored for self-hosted Unraid setups, where anime is downloaded to a NAS media share and Cloudflare bypass needs to be fully automated.

## What's different from upstream

### Automatic Cloudflare clearance via FlareSolverr

Normal AnimePahe requests use curl. When a request encounters a Cloudflare challenge, the script calls an existing [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) service, saves its `cf_clearance` cookie and matching user-agent to `config.json`, and retries the request once. Later requests reload the saved credentials, including requests from queued anime and subshells.

FlareSolverr runs the browser on the service host. The downloader no longer needs CF-Clearance-Scraper, its Python virtualenv, or local Chrome/Chromium binaries. Clearance is refreshed when needed rather than on every startup. Other configuration values are preserved.

The default service URL is `http://127.0.0.1:8191`. Override it for another installation:

```bash
FLARESOLVERR_URL=http://YOUR_SERVER:8191 ./animepahe-dl.sh -a 'one piece' -e 1
```

If automatic refresh fails during search or episode lookup, the script retains the interactive prompt for a new cookie. Unattended runs fail that lookup rather than waiting for input. To use manual cookie updates only:

```bash
FLARESOLVERR_URL= ./animepahe-dl.sh -a 'one piece' -e 1
```

### Dependencies and bootstrap

The script requires Bash, curl, jq, Node.js, fzf, yt-dlp, and ffmpeg, plus standard Linux utilities such as `realpath`. Node.js runs the local Kwik playlist decoder; no Glot service is used.

At startup, missing fzf and yt-dlp binaries are downloaded and installed into `/usr/local/bin`. This bootstrap requires wget, tar, and permission to write there; the bundled downloads target Linux x86-64. Install the other dependencies separately, including ffmpeg.

Video downloads use yt-dlp's Chrome impersonation support. For a Python installation, install it with:

```bash
python3 -m pip install 'yt-dlp[default,curl-cffi]'
```

### Defaults and anime selection

The preferred resolution is 720p. Downloads, episode caches, and per-stream last-episode state are stored under `/mnt/user/data/media/unsorted/<Anime Name>/`.

Search results are de-duplicated by session, and selected titles resolve to their exact displayed matches. In the fzf picker, use TAB to queue multiple anime or seasons, then ENTER to confirm. Each queued entry is processed separately.

### Smart episode caching

Episode lists are cached locally in `.source.json` per anime. On subsequent runs, if no specific episode is requested, the script fetches the first page and, when available, the last page of the API to check for new episodes — rather than re-downloading the full episode list every time. This reduces unnecessary API calls and speeds up repeated runs.

### Resume / auto-increment from last downloaded episode

The script tracks the last successfully downloaded episode per anime, keyed by audio language and resolution (e.g. `jpn_720`). On the next run without a `-e` flag, it automatically figures out the next episode to download. If a range of new episodes is available (e.g. 20–23 released since you last ran it), it queues them all. If the next episode isn't out yet, it tells you when the last one was released and estimates when the next one might drop (based on a 7-day cadence). If it's been more than 7 days past that estimate, it flags the series as potentially on hiatus.

### Plex-friendly output filenames

Downloaded files are named in the format `Anime Name - S01E05.mp4`, which Plex and Jellyfin pick up correctly without any manual renaming. Season number is detected automatically from the anime title (e.g. "Season 2" → `S02`).

## Configuration

Place `config.json` beside the script. With FlareSolverr enabled, an empty object is sufficient for initial setup:

```json
{}
```

The script writes `cf` and `ua` after a successful challenge solve. Existing `scraper_path`, `scraper_venv`, and other scraper settings are no longer used; they can be removed. Keep generated cookies and personal configuration out of commits.

For manual-only operation, supply both values from the same browser session:

```json
{
  "cf": "YOUR_CF_CLEARANCE",
  "ua": "YOUR_USER_AGENT"
}
```

## Usage

The published script is named `animepahe-dl.sh`. In the local Unraid working directory it may be named `animepahe.sh`; use that name when running the local copy.

```bash
./animepahe-dl.sh -a 'one piece' -e 1
./animepahe-dl.sh -a 'one piece' -e '1,3-5' -r 720 -o jpn
./animepahe-dl.sh -s ANIME_SESSION -e '*' -r 1080
./animepahe-dl.sh -a 'one piece' -e 1 -l
```

Options: `-a` searches by title, `-s` selects a session/slug, `-e` selects episodes or ranges, `-r` selects resolution, `-o` selects audio language, `-l` prints playlist links without downloading, and `-d` enables debug output. Use `-h` or `--help` to display the script's help. Debug output may include cookies; redact it before sharing.

When `-e` is omitted, saved progress is used to select newly available episodes. For multiple queued entries without saved progress, all available episodes are selected; a single entry prompts for episode selection.
