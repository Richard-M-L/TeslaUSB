#!/usr/bin/env python3
"""
USB Gadget Web Control Interface

A Flask web application for controlling USB gadget modes.
Organized using blueprints for better maintainability.
"""

import logging
import sys

from flask import Flask
import os

# Configure logging to stderr (captured by systemd journal)
logging.basicConfig(
    level=logging.INFO,
    format='%(levelname)s:%(name)s:%(message)s',
    stream=sys.stderr,
)

# Import configuration
from config import SECRET_KEY, WEB_PORT, GADGET_DIR, MAX_UPLOAD_SIZE_MB, MAX_UPLOAD_CHUNK_MB

# Flask app initialization
app = Flask(__name__)
app.secret_key = SECRET_KEY

# Upload limits (protect RAM-constrained devices)
app.config['MAX_CONTENT_LENGTH'] = MAX_UPLOAD_SIZE_MB * 1024 * 1024
app.config['MAX_FORM_MEMORY_SIZE'] = MAX_UPLOAD_CHUNK_MB * 1024 * 1024

# Production optimizations
app.config['USE_X_SENDFILE'] = False  # Disabled - requires nginx/apache
app.config['TEMPLATES_AUTO_RELOAD'] = False  # Disable template watching - saves memory

# Register blueprints
from blueprints import (
    mode_control_bp,
    videos_bp,
    lock_chimes_bp,
    light_shows_bp,
    music_bp,
    boombox_bp,
    wraps_bp,
    license_plates_bp,
    media_bp,
    analytics_bp,
    mapping_bp,
    cleanup_bp,
    api_bp,
    fsck_bp,
    captive_portal_bp,
    catch_all_redirect,
    cloud_archive_bp,
    archive_queue_bp,
    storage_retention_bp,
    jobs_bp,
    system_health_bp,
    settings_advanced_bp,
)

app.register_blueprint(mapping_bp)
app.register_blueprint(mode_control_bp)
app.register_blueprint(videos_bp)
app.register_blueprint(lock_chimes_bp)
app.register_blueprint(light_shows_bp)
app.register_blueprint(music_bp)
app.register_blueprint(boombox_bp)
app.register_blueprint(wraps_bp)
app.register_blueprint(license_plates_bp)
app.register_blueprint(media_bp)
app.register_blueprint(analytics_bp)
app.register_blueprint(cleanup_bp)
app.register_blueprint(api_bp)
app.register_blueprint(fsck_bp)
app.register_blueprint(cloud_archive_bp)
app.register_blueprint(archive_queue_bp)
app.register_blueprint(storage_retention_bp)
app.register_blueprint(jobs_bp)
app.register_blueprint(system_health_bp)
app.register_blueprint(settings_advanced_bp)
# Register captive portal blueprint LAST to avoid conflicting with other routes
app.register_blueprint(captive_portal_bp)


# ---------------------------------------------------------------------------
# i18n initialisation — load translations once at startup
# ---------------------------------------------------------------------------
from services.i18n_service import load_translations, get_text, detect_locale, supported_locales, get_all_translations
_translations_dir = os.path.join(os.path.dirname(__file__), 'translations')
load_translations(_translations_dir)


@app.before_request
def set_locale():
    """Detect locale on every request; stored in Flask g for the template _() helper."""
    from flask import g, request
    g.lang = detect_locale(request)


@app.route('/api/i18n/<locale>.js')
def i18n_js(locale):
    """Serve translation table as a cacheable JS file.

    Previously the full translation dict was embedded inline on every HTML
    page (~15 KB for zh).  Serving it as an external script lets browsers
    cache it (24 h) so it only travels once per locale.
    """
    import json as _json
    from flask import make_response
    if locale not in supported_locales():
        locale = 'zh'
    payload = _json.dumps(
        get_all_translations(locale), separators=(',', ':'), ensure_ascii=False,
    )
    resp = make_response(f"window._translations={payload};", 200)
    resp.mimetype = 'application/javascript'
    resp.cache_control.max_age = 86400
    resp.cache_control.public = True
    return resp


@app.context_processor
def inject_i18n():
    """Inject translation helper and locale info into all Jinja templates."""
    from flask import g
    lang = getattr(g, 'lang', 'zh')
    def _(key, **kwargs):
        text = get_text(key, lang)
        if kwargs:
            return text.format(**kwargs)
        return text
    return {
        '_': _,
        'current_locale': lambda: lang,
        'supported_locales': supported_locales,
        '_translations_js': get_all_translations(lang),
    }


@app.template_filter('translate_wifi')
def translate_wifi_filter(msg):
    """Translate common English wifi status messages to the current locale."""
    if not msg:
        return msg
    from flask import g
    lang = getattr(g, 'lang', 'zh')
    if lang != 'zh':
        return msg
    # Pattern replacements — order matters (longer first)
    replacements = [
        ("Successfully connected to '", "已成功连接到 '"),
        ("Already connected to '", "已连接到 '"),
        ("Failed to connect to '", "无法连接到 '"),
        ("Connection to '", "连接 '"),
        ("' timed out.", "' 超时。"),
        ("' timed out and could not restore previous connection. Fallback AP has been started.", "' 超时且无法恢复之前的连接，已启动备用 AP。"),
        ("' timed out. Reverted to previous network '", "' 超时。已恢复到之前的网络 '"),
        ("'. Reverted to previous network '", "'。已恢复到之前的网络 '"),
        ("' and could not restore previous connection. Fallback AP has been started for direct access.", "' 且无法恢复之前的连接。已启动备用 AP 供直接访问。"),
        ("'. Please connect to the fallback AP to reconfigure.", "'。请连接到备用 AP 重新配置。"),
        ("Network '", "网络 '"),
        ("' is not in the saved list", "' 不在已保存列表中"),
        ("Another connect attempt is in progress. Please wait.", "另一个连接请求正在进行中，请稍候。"),
        ("Reconnect to '", "重新连接到 '"),
        ("' started. AP will drop for ~30-60 seconds while we attempt the connection.", "' 已启动。AP 将断开约 30-60 秒以尝试连接。"),
        ("' started.", "' 已启动。"),
        ("Cannot forget the only saved network", "无法删除唯一已保存的网络"),
        ("Network priorities updated", "网络优先级已更新"),
        ("Some networks failed: ", "部分网络操作失败："),
        ("Failed to start: ", "启动失败："),
        ("Failed to delete: ", "删除失败："),
        ("' forgotten", "' 已删除"),
        (" (switched to alternate network)", "（已切换到备用网络）"),
    ]
    for eng, chn in replacements:
        msg = msg.replace(eng, chn)
    return msg

@app.route('/lang/<locale>')
def switch_lang(locale):
    """Set the language cookie and redirect back to the referring page."""
    from flask import redirect, request
    if locale in supported_locales():
        resp = redirect(request.referrer or '/')
        resp.set_cookie('lang', locale, max_age=365 * 24 * 3600, samesite='Lax')
        return resp
    return redirect('/')


# Global error handler for upload space exhaustion
@app.errorhandler(OSError)
def handle_os_error(e):
    """Catch OSError (e.g., temp space exhaustion during large uploads)."""
    import errno
    from flask import request, jsonify, flash, redirect
    if e.errno == errno.ENOSPC:
        msg = "Upload too large for available memory. Try uploading fewer or smaller files."
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return jsonify({"success": False, "error": msg}), 413
        flash(msg, "error")
        return redirect(request.referrer or '/')
    raise e  # Re-raise non-space errors


# ---------------------------------------------------------------------------
# Map tile proxy — lets devices on the Pi's WiFi see the map even when
# they cannot reach tile servers directly (e.g. mainland China without
# VPN).  Tiles are cached to SD card; each unique tile is fetched only
# once from the upstream source.
#
# Default upstream: Gaode (高德) street tiles, accessible inside China
# without VPN.  Gaode tiles use the GCJ-02 datum, but the frontend
# (mapping.html) automatically transforms Tesla's WGS-84 GPS to GCJ-02
# before rendering, so points align correctly with roads.  If you prefer
# OpenStreetMap tiles (native WGS-84, no transform needed), set
# ``map.tile_upstream_url`` in config.yaml — requires VPN in China:
#
#     mapping:
#       tile_upstream_url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
# ---------------------------------------------------------------------------
import urllib.request
import urllib.error

_TILE_CACHE_DIR = os.path.join(GADGET_DIR, 'tile_cache')
_TILE_FETCH_TIMEOUT = 10  # seconds

# Default upstream: Gaode (Amap) street tiles — accessible without VPN in China.
_DEFAULT_TILE_UPSTREAM = (
    'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1'
    '&style=8&x={x}&y={y}&z={z}'
)


def _tile_upstream_url():
    """Return the configured tile upstream URL (with {x},{y},{z} placeholders)."""
    try:
        _mapping_cfg = config.get('mapping', {}) if isinstance(config.get('mapping'), dict) else {}
        url = _mapping_cfg.get('tile_upstream_url', '')
        if url and isinstance(url, str) and '{x}' in url:
            return url
    except Exception:  # noqa: BLE001
        pass
    return _DEFAULT_TILE_UPSTREAM


@app.route('/tiles/<int:z>/<int:x>/<int:y>.png')
def tile_proxy(z, x, y):
    """Proxy a map tile — serve from cache, or fetch + cache once."""
    cache_path = os.path.join(_TILE_CACHE_DIR, str(z), str(x))
    cache_file = os.path.join(cache_path, f'{y}.png')

    # Cache hit — serve directly (tiles never change)
    if os.path.isfile(cache_file):
        from flask import send_file
        resp = send_file(cache_file, mimetype='image/png')
        resp.cache_control.max_age = 86400
        resp.cache_control.public = True
        return resp

    # Cache miss — fetch from upstream via the Pi's internet connection
    upstream = _tile_upstream_url()
    try:
        os.makedirs(cache_path, exist_ok=True)
        req = urllib.request.Request(
            upstream.format(z=z, x=x, y=y),
            headers={'User-Agent': 'TeslaUSB/1.0 (tile proxy)'},
        )
        with urllib.request.urlopen(req, timeout=_TILE_FETCH_TIMEOUT) as resp_up:
            data = resp_up.read()
        # Write atomically: temp file → rename
        tmp = cache_file + '.tmp'
        with open(tmp, 'wb') as f:
            f.write(data)
        os.replace(tmp, cache_file)
        from flask import send_file
        resp = send_file(cache_file, mimetype='image/png')
        resp.cache_control.max_age = 86400
        resp.cache_control.public = True
        return resp
    except (urllib.error.URLError, OSError, ValueError) as e:
        logging.getLogger('teslausb.tile_proxy').warning(
            "Tile fetch failed %d/%d/%d: %s", z, x, y, e,
        )
        # Pi has no internet — redirect the client to fetch the tile
        # directly from the upstream source using its own connection
        # (e.g. a phone tethered to the Pi's AP with cellular data).
        from flask import redirect
        return redirect(
            upstream.format(z=z, x=x, y=y), code=302,
        )


# Serve tile cache service worker from root scope (SW scope must match serving path)
@app.route('/tile-cache-sw.js')
def tile_cache_service_worker():
    from flask import send_from_directory
    return send_from_directory(
        app.static_folder, 'tile-cache-sw.js',
        mimetype='application/javascript',
        max_age=86400,
    )


# ---------------------------------------------------------------------------
# Online upgrade — git pull + restart via web UI
# ---------------------------------------------------------------------------
_UPGRADE_SCRIPT = os.path.join(GADGET_DIR, 'upgrade.sh')
_UPGRADE_STATUS_FILE = '/tmp/teslausb_upgrade_status.json'


@app.route('/api/system/upgrade/check', methods=['POST'])
def upgrade_check():
    """git fetch and report whether new commits are available."""
    import subprocess
    try:
        # Fetch without merging — safe, read-only after fetch
        result = subprocess.run(
            ['git', '-c', f'safe.directory={GADGET_DIR}', 'fetch', 'origin'],
            capture_output=True, text=True, timeout=60,
            cwd=GADGET_DIR,
        )
        if result.returncode != 0:
            stderr = (result.stderr or '').strip()
            # Extract the last meaningful line for concise diagnostics
            lines = [l for l in stderr.splitlines() if l.strip() and 'warning:' not in l.lower()]
            detail = lines[-1] if lines else stderr[:200]
            return {'available': False, 'error': f'git fetch 失败: {detail}'}
        # Compare HEAD to origin/main
        result = subprocess.run(
            ['git', '-c', f'safe.directory={GADGET_DIR}',
             'rev-list', '--count', 'HEAD..origin/main'],
            capture_output=True, text=True, timeout=10,
            cwd=GADGET_DIR,
        )
        count = int(result.stdout.strip() or 0)
        if count == 0:
            return {'available': False, 'current': True}
        return {'available': True, 'commits_behind': count}
    except subprocess.TimeoutExpired:
        return {'available': False, 'error': '检查超时 — 网络慢或 GitHub 不可达'}, 504
    except Exception as e:
        return {'available': False, 'error': str(e)[:200]}, 500


@app.route('/api/system/upgrade', methods=['POST'])
def upgrade_run():
    """Trigger upgrade (git pull + web restart) in the background.

    Writes progress to ``/tmp/teslausb_upgrade_status.json`` which the
    frontend polls via ``GET /api/system/upgrade/status``.
    """
    import subprocess
    if not os.path.isfile(_UPGRADE_SCRIPT):
        return {'ok': False, 'error': 'upgrade.sh not found'}, 404
    try:
        subprocess.Popen(
            ['sudo', '-n', 'bash', _UPGRADE_SCRIPT, '--non-interactive'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            cwd=GADGET_DIR,
            start_new_session=True,  # survive gadget_web.service restart
        )
        return {'ok': True}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:200]}, 500


@app.route('/api/system/upgrade/status')
def upgrade_status():
    """Poll the upgrade status file."""
    import json as _json
    try:
        with open(_UPGRADE_STATUS_FILE, 'r') as fh:
            return _json.load(fh)
    except (OSError, ValueError):
        return {'phase': 'idle', 'message': '', 'pct': 0, 'code': 0}


# Add catch-all route for captive portal (must be last)
@app.route('/<path:path>')
def wildcard_redirect(path):
    result = catch_all_redirect(path)
    if result:
        return result
    # If catch_all_redirect returns None, let Flask handle it normally (404)
    from flask import abort
    abort(404)


if __name__ == "__main__":
    print(f"Starting Tesla USB Gadget Web Control")
    print(f"Gadget directory: {GADGET_DIR}")
    print(f"Access the interface at: http://0.0.0.0:{WEB_PORT}/")

    # Phase 3a.2 (#98): one-shot migration of legacy cleanup_config.json
    # into the unified ``cleanup`` config.yaml section. Idempotent and
    # never raises — safe to call on every boot.
    try:
        from services.cleanup_service import migrate_legacy_cleanup_config
        migration = migrate_legacy_cleanup_config(GADGET_DIR)
        if migration.get('migrated'):
            print(
                f"cleanup migration: imported {migration['imported_folders']} "
                f"into config.yaml cleanup.policies"
            )
    except Exception as e:  # noqa: BLE001
        print(f"Warning: cleanup migration failed (non-fatal): {e}")

    # Phase 2b (issue #76): the legacy ``start_archive_timer`` periodic
    # thread is gone. The new flow is queue-driven: ``archive_producer``
    # enqueues into ``archive_queue``, and ``archive_worker`` drains
    # the queue one file at a time. Both are started below, after the
    # file watcher is wired so the worker's `wake()` from the producer
    # callback path lands cleanly.

    # Start file watcher for new video detection. The callback enqueues
    # individual paths into the indexing_queue table; the indexing
    # worker (started below) drains the queue one file at a time.
    try:
        from services.file_watcher_service import (
            start_watcher, register_callback, register_delete_callback,
            register_event_json_callback, register_archive_callback,
        )
        watch_paths = []
        # Watch TeslaCam on USB (RO mount)
        from config import RO_MNT_DIR
        teslacam_ro = os.path.join(RO_MNT_DIR, 'part1-ro', 'TeslaCam')
        if os.path.isdir(teslacam_ro):
            watch_paths.append(teslacam_ro)
        # Watch ArchivedClips on SD card
        try:
            from config import ARCHIVE_DIR, ARCHIVE_ENABLED
            if ARCHIVE_ENABLED and os.path.isdir(ARCHIVE_DIR):
                watch_paths.append(ARCHIVE_DIR)
        except ImportError:
            pass
        if watch_paths:
            try:
                from config import MAPPING_ENABLED, MAPPING_DB_PATH
                if MAPPING_ENABLED:
                    # Issue #184 Wave 2 — Phase C: the inotify→indexing
                    # callback that used to live here was a duplicate
                    # enqueue path. The archive worker (which is the
                    # only writer to ``ArchivedClips``) calls
                    # ``_enqueue_indexed`` directly after each
                    # successful copy, and ``boot_catchup_scan``
                    # handles anything an operator might rsync into
                    # ArchivedClips outside the worker. Per-clip
                    # ``indexing_queue`` INSERTs drop from 2→1.
                    def _on_deleted_videos(file_paths):
                        # Mirror deletes immediately so the map page
                        # doesn't keep showing trips/events for clips
                        # the user (or Tesla) just removed.
                        from services.mapping_service import (
                            purge_deleted_videos,
                        )
                        try:
                            purge_deleted_videos(
                                MAPPING_DB_PATH,
                                deleted_paths=list(file_paths),
                            )
                        except Exception as e:
                            print(f"Warning: purge_deleted_videos failed: {e}")

                    register_delete_callback(_on_deleted_videos)
                    print("File watcher → delete callback registered")
            except Exception as e:
                print(f"Warning: Failed to register watcher callbacks: {e}")

            # Wave 4 PR-F4 (issue #184): live-event upload producer.
            # Replaces the standalone Live Event Sync subsystem. The
            # file_watcher fires ``register_event_json_callback`` the
            # moment Tesla writes a new event.json; we enqueue at
            # ``PRIORITY_LIVE_EVENT`` into the unified pipeline_queue
            # so the cloud_archive worker picks it up before any
            # bulk catch-up rows. Same inotify watcher, no separate
            # service / queue / worker / config flag.
            try:
                def _on_new_event_json(file_paths):
                    from services.cloud_archive_service import (
                        enqueue_live_event_from_event_json,
                    )
                    try:
                        enqueue_live_event_from_event_json(list(file_paths))
                    except Exception as e:
                        print(f"Warning: live-event enqueue failed: {e}")

                register_event_json_callback(_on_new_event_json)
                print("File watcher → cloud live-event producer registered")
            except Exception as e:
                print(f"Warning: Failed to register live-event watcher callback: {e}")

            # Archive queue producer (issue #76 Phase 2a): mirror the
            # mp4 callback into the archive_queue table. Issue #184 Wave 1
            # made the queue subsystem unconditional — there is no longer
            # an enable flag.
            #
            # Issue #184 Wave 2 — Phase B: the inotify path now calls
            # ``archive_producer.enqueue_with_peek`` instead of the raw
            # ``archive_queue.enqueue_many_for_archive`` so RecentClips
            # candidates with no GPS-bearing SEI are dropped at the
            # producer (no queue row, no worker pick, no SD writes).
            try:
                def _on_new_videos_for_archive(file_paths):
                    from services.archive_producer import enqueue_with_peek
                    try:
                        enqueue_with_peek(list(file_paths))
                    except Exception as e:
                        print(
                            "Warning: archive_queue enqueue failed: "
                            f"{e}"
                        )

                register_archive_callback(_on_new_videos_for_archive)
                print("File watcher → archive_queue producer registered")
            except Exception as e:
                print(
                    "Warning: Failed to register archive_queue watcher "
                    f"callback: {e}"
                )

            # Cloud archive worker wake (Phase 3b #99): a freshly
            # archived mp4 is now visible to the cloud sync queue
            # producer — poke the continuous worker so the upload
            # starts on the next iteration instead of waiting for the
            # next 5-minute idle timeout. The wake is a single
            # threading.Event.set() so any debouncing is unnecessary
            # (multiple wakes during a drain are coalesced into one).
            try:
                from config import (
                    CLOUD_ARCHIVE_ENABLED, CLOUD_ARCHIVE_PROVIDER,
                )
                if CLOUD_ARCHIVE_ENABLED and CLOUD_ARCHIVE_PROVIDER:
                    def _on_new_videos_for_cloud(file_paths):
                        from services.cloud_archive_service import wake as _cloud_wake
                        try:
                            _cloud_wake()
                        except Exception as e:
                            print(
                                "Warning: cloud archive wake failed: "
                                f"{e}"
                            )

                    register_callback(_on_new_videos_for_cloud)
                    print(
                        "File watcher → cloud archive worker wake "
                        "registered"
                    )
            except Exception as e:
                print(
                    "Warning: Failed to register cloud archive wake "
                    f"callback: {e}"
                )

            start_watcher(watch_paths)
            print(f"File watcher started for {len(watch_paths)} paths")
    except Exception as e:
        print(f"Warning: Failed to start file watcher: {e}")

    # Start the indexing worker (single low-priority thread that drains
    # indexing_queue). This replaces the old "trigger_auto_index" full
    # filesystem walk that used to run on startup, on mode-switch, and
    # on every WiFi connect — those triggers caused the constantly-
    # flashing "Indexing…" banner. The worker only shows the banner
    # while it's actively parsing one specific file.
    try:
        from config import MAPPING_ENABLED, MAPPING_DB_PATH
        if MAPPING_ENABLED:
            from services.video_service import get_teslacam_path
            from services import indexing_worker
            from services.mapping_service import boot_catchup_scan
            tc = get_teslacam_path()
            if tc:
                # Catch-up scan first: any clip on disk that isn't in
                # indexed_files becomes a new queue row. Cheap (no
                # video parsing); takes tens of milliseconds even on a
                # full SD card. Worker picks them up afterwards.
                try:
                    summary = boot_catchup_scan(MAPPING_DB_PATH, tc)
                    print(
                        "Boot catch-up scan: "
                        f"scanned={summary['scanned']}, "
                        f"already_indexed={summary['already_indexed']}, "
                        f"enqueued={summary['enqueued']}"
                    )
                except Exception as e:
                    print(f"Warning: boot catch-up scan failed: {e}")
                indexing_worker.start_worker(MAPPING_DB_PATH, tc)
                print("Indexing worker started")
                # Independent safety net for stale geodata rows. Runs
                # ~daily with jitter; cheap (one os.path.isfile per
                # indexed_files row) and only logs the count it cleans.
                from services.mapping_service import (
                    start_daily_stale_scan,
                )
                from services.video_service import (
                    get_teslacam_path as _get_tc,
                )
                start_daily_stale_scan(MAPPING_DB_PATH, _get_tc)
                print("Daily stale scan scheduled")
    except Exception as e:
        print(f"Warning: Failed to start indexing worker: {e}")

    # Archive queue producer thread (issue #76 Phase 2a). Mirrors the
    # indexing worker's lifecycle: starts after the watcher is
    # registered so the boot catch-up scan and the every-60-s rescan
    # observe the same TeslaCam root. Failure here must never take
    # down gadget_web. Issue #184 Wave 1 made the producer
    # unconditional — no enable flag, boot catch-up always runs.
    try:
        from config import (
            ARCHIVE_QUEUE_RESCAN_INTERVAL_SECONDS,
            ARCHIVE_QUEUE_BOOT_SCAN_DEFER_SECONDS,
            MAPPING_DB_PATH as _ARCHIVE_QUEUE_DB,
        )
        from services.video_service import get_teslacam_path
        from services import archive_producer
        tc = get_teslacam_path()
        if tc:
            archive_producer.start_producer(
                tc,
                db_path=_ARCHIVE_QUEUE_DB,
                rescan_interval_seconds=(
                    ARCHIVE_QUEUE_RESCAN_INTERVAL_SECONDS
                ),
                boot_scan_defer_seconds=(
                    ARCHIVE_QUEUE_BOOT_SCAN_DEFER_SECONDS
                ),
            )
            print("Archive queue producer started (Phase 2a)")
    except Exception as e:
        print(f"Warning: Failed to start archive queue producer: {e}")

    # Archive queue worker thread (issue #76 Phase 2b). Drains
    # ``archive_queue`` one file at a time, copying USB-side clips
    # into ``ARCHIVE_DIR`` and enqueueing them into the indexer queue.
    # The producer above is the only thing that puts rows into the
    # queue; this worker is the only thing that takes them out. The
    # legacy ``video_archive_service`` periodic timer has been removed
    # in favor of this pair.
    try:
        from config import (
            ARCHIVE_DIR,
            MAPPING_DB_PATH as _ARCHIVE_WORKER_DB,
        )
        from services.video_service import get_teslacam_path
        from services import archive_worker
        tc = get_teslacam_path()
        archive_worker.start_worker(
            _ARCHIVE_WORKER_DB,
            ARCHIVE_DIR,
            teslacam_root=tc,
        )
        print("Archive queue worker started (Phase 2b)")

        # Phase 2c: archive watchdog + retention prune. Single
        # daemon thread that observes the queue/worker, exposes
        # ``/api/archive/status``, and runs the daily retention
        # prune on ``ArchivedClips``. Pure local-FS observer — it
        # never touches the USB gadget.
        try:
            from services import archive_watchdog
            archive_watchdog.start_watchdog(
                _ARCHIVE_WORKER_DB, ARCHIVE_DIR,
            )
            print("Archive watchdog started (Phase 2c)")
        except Exception as e:  # noqa: BLE001
            print(
                f"Warning: Failed to start archive watchdog: {e}"
            )
    except Exception as e:
        print(f"Warning: Failed to start archive queue worker: {e}")

    # Wave 4 PR-F4 (issue #184): the standalone Live Event Sync
    # worker has been deleted. Live-event uploads are now first-class
    # ``pipeline_queue`` rows enqueued by the file_watcher's
    # event.json callback (see ``_on_new_event_json`` above) at
    # ``PRIORITY_LIVE_EVENT`` so the cloud_archive worker picks them
    # up before any bulk catch-up rows.

    # Auto-start the continuous cloud archive worker (Phase 3b #99).
    # The worker is a long-lived daemon thread that idles on
    # threading.Event.wait() (~0.1% CPU) and drains the queue when
    # poked by the file watcher, NM dispatcher, mode-switch hook, or
    # manual UI button. Replaces the old one-shot timer + per-trigger
    # thread spawn pattern.
    #
    # Wave 4 PR-F4 (issue #184): the inter-file LES yield has been
    # removed; live events are pipeline_queue rows at
    # ``PRIORITY_LIVE_EVENT`` that the worker naturally picks first.
    try:
        from config import (
            CLOUD_ARCHIVE_ENABLED, CLOUD_ARCHIVE_PROVIDER,
            CLOUD_ARCHIVE_DB_PATH, CLOUD_PROVIDER_CREDS_PATH,
        )
        if (CLOUD_ARCHIVE_ENABLED and CLOUD_ARCHIVE_PROVIDER
                and os.path.isfile(CLOUD_PROVIDER_CREDS_PATH)):
            from services.cloud_archive_service import start as _cloud_start
            from services.video_service import get_teslacam_path
            teslacam = get_teslacam_path()
            if teslacam and _cloud_start(
                teslacam_path=teslacam, db_path=CLOUD_ARCHIVE_DB_PATH,
            ):
                print("Cloud archive worker started (continuous)")
    except Exception as e:
        print(f"Warning: Cloud archive worker start failed: {e}")

    # Idle-time WAL checkpoint service (issue #184 Wave 3 — Phase G).
    # Runs ``PRAGMA wal_checkpoint(TRUNCATE)`` every ~30 seconds when
    # no other heavy task holds the task_coordinator lock, pre-empting
    # the inline auto-checkpoints that would otherwise fight the
    # archive copies for SDIO bandwidth.
    try:
        from config import MAPPING_DB_PATH
        from services import wal_checkpoint_service
        _wal_dbs = [MAPPING_DB_PATH]
        try:
            from config import CLOUD_ARCHIVE_DB_PATH as _WAL_CLOUD_DB
            _wal_dbs.append(_WAL_CLOUD_DB)
        except Exception:  # noqa: BLE001
            pass
        if wal_checkpoint_service.start(_wal_dbs):
            print("WAL checkpoint service started (idle-time)")
    except Exception as e:  # noqa: BLE001
        print(f"Warning: WAL checkpoint service failed to start: {e}")

    # One-time pipeline_queue backfill (issue #184 Wave 4 — Phase I.1).
    # Idempotent — re-running on every boot is safe (the unique
    # constraint catches duplicates), AND a one-shot completion flag
    # in ``kv_meta`` makes subsequent boots a no-op (so we don't
    # re-scan four legacy tables every restart). Runs on a background
    # daemon thread so it never blocks the request loop.
    #
    # Daemon-thread kill semantics: ``daemon=True`` means the thread
    # dies abruptly when the process exits. That's fine here because
    # ``backfill_legacy_queues`` is fully idempotent — a kill in the
    # middle of one of the per-table loops just means the next boot
    # re-runs the scan and resumes (the ``ON CONFLICT DO NOTHING``
    # clause + UNIQUE constraint dedup any partial work). The
    # one-shot flag is only set on a successful end-to-end run.
    #
    # Read more in
    # ``services.pipeline_queue_service.backfill_legacy_queues``.
    try:
        import threading
        _backfill_logger = logging.getLogger('teslausb.pipeline_backfill')

        def _run_pipeline_backfill():
            try:
                from services import pipeline_queue_service
                counts = pipeline_queue_service.backfill_legacy_queues()
                if any(counts.values()):
                    _backfill_logger.info(
                        "pipeline_queue backfill: %s", counts,
                    )
                else:
                    _backfill_logger.debug(
                        "pipeline_queue backfill: nothing to do",
                    )
            except Exception as e:  # noqa: BLE001
                _backfill_logger.warning(
                    "pipeline_queue backfill failed: %s", e,
                )
        threading.Thread(
            target=_run_pipeline_backfill,
            name='pipeline-backfill',
            daemon=True,
        ).start()
    except Exception as e:  # noqa: BLE001
        logging.getLogger('teslausb.pipeline_backfill').warning(
            "failed to schedule pipeline_queue backfill: %s", e,
        )

    # Try to use Waitress if available, otherwise fall back to Flask dev server
    try:
        from waitress import serve
        print("Using Waitress production server")
        # 4 threads for Pi Zero 2 W — one extra for API polling while sync runs
        serve(app, host="0.0.0.0", port=WEB_PORT, threads=4, channel_timeout=120,
              send_bytes=4194304)  # 4MB send buffer for better video streaming
    except ImportError:
        print("Waitress not available, using Flask development server")
        print("WARNING: Flask dev server is slow for large files. Install waitress: pip3 install waitress")
        app.run(host="0.0.0.0", port=WEB_PORT, debug=False, threaded=True)
