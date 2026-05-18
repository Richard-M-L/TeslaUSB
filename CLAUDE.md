# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

TeslaUSB runs on a Raspberry Pi Zero 2 W (512 MB RAM, single SDIO bus shared between SD card and WiFi). It presents a multi-LUN USB gadget to a Tesla vehicle, captures dashcam clips to SD before Tesla rotates them, indexes H.264 SEI metadata for GPS/telemetry, displays a map-centric web UI on port 80, and optionally uploads to cloud storage via rclone.

## Commands

```bash
# Run tests (Python 3, pytest)
cd scripts/web && python -m pytest ../../tests --tb=short -q
# Single test file
cd scripts/web && python -m pytest ../../tests/test_mapping_service.py --tb=short -q
# Single test
cd scripts/web && python -m pytest ../../tests/test_sei_parser.py::TestSEIParser::test_speed_mph_conversion -q

# Deploy after changing templates or scripts
sudo ./setup_usb.sh

# View logs
sudo journalctl -u gadget_web.service -f
sudo journalctl -u wifi-monitor.service -f

# Manual web app run (dev)
cd /home/pi/TeslaUSB && python3 web_control.py
```

There is **no CI pipeline**; tests are run locally by contributors.

## Architecture

### Modes
- **Present mode** (default): USB gadget bound, partitions mounted RO at `/mnt/gadget/part*-ro`, Samba off. Tesla is actively recording.
- **Edit mode**: gadget unbound, partitions mounted RW, Samba on for network file access.
- `state.txt` holds mode token. `mode_service.current_mode()` resolves it.
- **Never expose "Present Mode" / "Edit Mode" terminology in UI.** User-facing concept is "Network File Sharing" (status dot: green=normal, amber=sharing).

### USB gadget safety (critical)
- The gadget serves `.img` files **directly** as LUN backing files — not loop devices. Loop devices are for local mount access only.
- **Background subsystems (archive, indexer, cloud sync, file watcher) are read-only consumers.** They must NEVER unmount, remount, or rebind the USB gadget. Tesla may be writing at any moment.
- All mount/umount commands use `nsenter --mount=/proc/1/ns/mnt` to operate in PID 1 namespace.
- `quick_edit_part2` temporarily remounts part2 RW for chime/asset uploads. Keep operations short, always restore RO mount + LUN backing on all code paths.

### Flask application (`scripts/web/`)
- **App factory**: `web_control.py` loads config → inits DBs → registers blueprints → starts background workers as daemon threads → binds port 80.
- **Blueprints** (`blueprints/`): thin HTTP routes, delegate to services.
- **Services** (`services/`): all business logic — workers, queues, parsers, mount helpers.
- **Templates** (`templates/`): Jinja2 HTML. Source templates in repo root `templates/` use `__PLACEHOLDER__` syntax; `setup_usb.sh` substitutes and deploys them.
- **Static** (`static/`): CSS (design tokens on `:root` + `[data-theme="dark"]`), vanilla JS, Inter font (bundled WOFF2), Lucide SVG icon sprite.

### Background workers (all threads in `gadget_web.service`)
1. **File watcher** (`file_watcher_service.py`): inotify + 5-min polling fallback on RO mount + `~/ArchivedClips`. Routes new mp4 → archive callback (60s age gate), new mp4 in ArchivedClips → indexing callback, new `event.json` → live event callback (no age gate).
2. **Archive worker** (`archive_worker.py`): drains `archive_queue` → copies clips from USB RO mount to `~/ArchivedClips` before Tesla's 1-hour circular buffer deletes them. Heavily throttled (chunk pause, per-file time budget, load-pause guard).
3. **Indexing worker** (`indexing_worker.py`): drains `indexing_queue` in `geodata.db` one file at a time. Parses MP4 SEI → extracts GPS/telemetry → writes `trips`/`waypoints`/`detected_events`. Returns typed `IndexResult` with `IndexOutcome` enum.
4. **Cloud worker** (`cloud_archive_service.py`): drains `pipeline_queue` (priority-ordered). Live events at `PRIORITY_LIVE_EVENT = 0`, bulk at `PRIORITY_CLOUD_BULK = 4`. Single rclone subprocess at a time.

### Mutual exclusion
`task_coordinator.py` is the single fairness lock. Tasks: `indexer`, `archive`, `cloud_sync`, `retention`. Workers call `acquire_task('<name>', wait_seconds=N, yield_to_waiters=True)`. **Never hold the lock across sleeps** — always `acquire → work → release → sleep`. `WATCHDOG_NEAR_MISS_THRESHOLD_SECONDS = 60.0`: any hold longer than this logs WARNING.

### Persistent state
- `usb_cam.img`, `usb_lightshow.img`, `usb_music.img` (optional) — **protected**: never deleted by any code path (`file_safety.is_protected_file()`).
- `~/ArchivedClips/<YYYY-MM-DD>/` — SD-card archive copies.
- `geodata.db` — trips, waypoints, detected_events, indexed_files, indexing_queue (schema v6, see `mapping_migrations.py`).
- `cloud_sync.db` — cloud upload state, archive_queue.
- `config.yaml` — **single source of truth** for ALL configuration. Bash reads via `config.sh` (yq), Python via `web/config.py` (PyYAML). Never hardcode values.

## Configuration
- `config.example.yaml` is the **versioned template** (tracked in git).
- `config.yaml` is the **user's runtime config** — gitignored, never overwritten by upgrades.
- `setup_usb.sh` copies `config.example.yaml` → `config.yaml` on fresh install if the latter is missing.
- Edit `config.yaml` → restart `gadget_web.service` (and `wifi-monitor.service` if network settings changed).
- Template changes also need `sudo ./setup_usb.sh` to substitute `__PLACEHOLDER__` values.
- For one-file template updates, sed-substitute manually and `systemctl daemon-reload` — faster than full `setup_usb.sh`.

## Key rules

### Mount safety
- Never use `umount -l + remount` to refresh VFS cache (breaks gadget view). Use `echo 2 > /proc/sys/vm/drop_caches` (slabs only).
- Background subsystems must NEVER unmount/remount USB gadget or change LUN backing. Only user-initiated operations may: `quick_edit_part2`, mode switch, gadget rebind after chime change.

### Indexing
- **Single queue, single worker.** Producers: boot catch-up scan, inotify, archive run, manual reindex. All go through `indexing_queue_service.enqueue_many_for_indexing()` — idempotent via canonical key.
- **Index from ArchivedClips only**, not the RO USB mount (Tesla rotates RecentClips; a mid-parse deletion causes `FILE_MISSING`).
- **Don't cascade-delete trips/waypoints/events** when source video is gone. `purge_deleted_videos` only NULLs `video_path` and deletes the `indexed_files` row. Trips are records of actual drives — only explicit user "Delete Trip" may remove them.
- Banner shows ONLY when `active_file != null` (a file is actively being parsed), not based on queue depth.
- GPS-derived UTC from MP4 `mvhd` atom is authoritative for absolute time, NOT the filename (Tesla onboard clock can drift by days).
- Use `CAST(strftime('%s', x) AS INTEGER)` for SQLite second-gap math — `julianday()` float precision breaks `<= 300` boundary checks.

### Cloud sync
- **Single queue for all cloud uploads:** `pipeline_queue` in `geodata.db`. Live events at priority 0, bulk at priority 4. No second cloud worker, no separate queue.
- Live event enqueue entry point: `cloud_archive_service.enqueue_live_event_from_event_json()`.
- **Don't reintroduce** the deleted `live_event_sync_service.py`, `blueprints/live_events.py`, or the `live_event_sync:` config block (removed in Wave 4 PR-F4, issue #184).

### Video playback
- **No standalone Videos page.** All video browsing is in the map page (`mapping.html`) via slide-out panel with Events / Trips / All Clips tabs.
- Fullscreen must target `.video-overlay-stage` wrapper (not bare `<video>`) so telemetry HUD rides into OS fullscreen.
- No thumbnails — system was removed.

### UI/UX
- **No emoji icons** — use Lucide SVG sprite (`icons/lucide-sprite.svg`).
- **Color tokens only** — never hardcode hex values. CSS custom properties on `:root` (light) and `[data-theme="dark"]` (dark). Test both modes.
- **Mobile-first:** bottom tabs <1024px, sidebar rail ≥1024px. Touch targets ≥44×44px. Test at 375px and 1024px+.
- **No external CDN calls** — Inter font bundled as WOFF2, Chart.js + Leaflet vendored.
- **Performance:** this runs on a Pi Zero 2 W with 512 MB RAM. No JS frameworks, inline critical CSS.
- SEI parsing uses `mmap.mmap` — never load entire MP4 into a `bytes` buffer (was an OOM source).

### Watchdog & stability
- Hardware watchdog configured with 90s timeout. `watchdog.service` has priority drop-in (`Nice=-5 IOSchedulingClass=realtime`).
- Archive copy guards (chunk pause, per-file time budget) exist to prevent SDIO bus saturation from starving the watchdog daemon.
- Don't lower `archive_queue` throttle defaults without re-validating on physical Pi Zero 2 W hardware.

### Housekeeping
- **Never install packages or create temp files inside the repo.** Test tooling goes outside (e.g., `../playwright-test/`).
- `*.db*`, `state.txt`, `*.log`, `fsck_status.json`, `config.yaml.bak.*`, `*.key`, `*.pem` are gitignored — never commit them.

## SEI parser & speed units
- `sei_parser.py` provides both `speed_mph` (×2.23694 from m/s) and `speed_kph` (×3.6 from m/s).
- Frontend currently uses mph everywhere. A China-adapted fork changes display to km/h.

## Feature gating
- UI nav items and routes are gated by whether their backing `.img` file exists on disk. `partition_service.get_feature_availability()` returns boolean flags checked per request.
- Settings page is always available regardless of disk images.
- New gated features need: availability flag, `{% if %}` guard in `base.html` nav, and `@bp.before_request` guard in the blueprint.
