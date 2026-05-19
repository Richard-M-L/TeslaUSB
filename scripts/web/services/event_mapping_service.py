"""
Event-based map display service for TeslaUSB.

Reads event.json files from SentryClips/SavedClips event folders
and enriches them for map marker display. Designed for China-version
Teslas where GPS coordinates are only available via event.json (not
in the SEI video stream).

Performance: in-memory cache with 30s TTL. Each scan only reads the
small event.json files (~200 bytes) and checks for thumb.png existence
-- no video files are opened. For ~500 event folders on a Pi Zero 2 W,
a cold scan takes < 2 seconds.
"""

import json
import logging
import os
import re
import threading
import time

from services.mode_service import current_mode
from config import MNT_DIR, RO_MNT_DIR

logger = logging.getLogger(__name__)

# --- Cache ---

_cache: dict = {}
_cache_lock = threading.Lock()
_CACHE_TTL = 30.0  # seconds

# Regex: event folder names like 2026-05-19_14-30-00
_EVENT_FOLDER_RE = re.compile(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$')

# 1x1 transparent PNG (served when thumb.png is missing)
TRANSPARENT_PNG = (
    b'\x89PNG\r\n\x1a\n'
    b'\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01'
    b'\x08\x06\x00\x00\x00\x1f\x15\xc4\x89'
    b'\x00\x00\x00\nIDATx\x9cc\x00\x00\x00\x02\x00\x01\xe5\x27\xde\xfc'
    b'\x00\x00\x00\x00IEND\xaeB`\x82'
)


def _cache_get(key):
    with _cache_lock:
        entry = _cache.get(key)
        if entry and (time.monotonic() - entry[0]) < _CACHE_TTL:
            return entry[1]
    return None


def _cache_set(key, data):
    with _cache_lock:
        _cache[key] = (time.monotonic(), data)
        if len(_cache) > 200:
            now = time.monotonic()
            stale = [k for k, v in _cache.items()
                      if (now - v[0]) > _CACHE_TTL * 2]
            for k in stale:
                del _cache[k]


# --- Path Resolution ---

def _get_teslacam_root():
    """Return TeslaCam root path (mode-aware), or None."""
    mode = current_mode()
    if mode == 'present':
        p = os.path.join(RO_MNT_DIR, 'part1-ro', 'TeslaCam')
        if os.path.isdir(p):
            return p
    elif mode == 'edit':
        p = os.path.join(MNT_DIR, 'part1', 'TeslaCam')
        if os.path.isdir(p):
            return p
    return None


def _get_archive_root():
    """Return archive root path, or None."""
    try:
        from config import ARCHIVE_DIR, ARCHIVE_ENABLED
    except ImportError:
        return None
    if ARCHIVE_ENABLED and ARCHIVE_DIR and os.path.isdir(ARCHIVE_DIR):
        return ARCHIVE_DIR
    return None


# --- Event.json Parsing ---

def _parse_event_json(path):
    """Read and validate event.json. Returns dict or None."""
    try:
        with open(path, 'r') as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None

    try:
        lat = float(data.get('est_lat', 0))
        lon = float(data.get('est_lon', 0))
    except (TypeError, ValueError):
        return None

    if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
        return None
    if lat == 0.0 and lon == 0.0:
        return None

    return {
        'lat': lat,
        'lon': lon,
        'city': str(data.get('city', '') or ''),
        'street': str(data.get('street', '') or ''),
        'reason': str(data.get('reason', '') or ''),
        'timestamp': str(data.get('timestamp', '') or ''),
    }


def _find_front_mp4(event_path, event_name):
    """Find a front-camera MP4 in the event folder."""
    try:
        with os.scandir(event_path) as entries:
            for entry in entries:
                if entry.is_file() and entry.name.lower().endswith('-front.mp4'):
                    return entry.name
    except OSError:
        pass
    return f'{event_name}-front.mp4'


def _reason_display(reason):
    """Convert event.json reason string to human-readable label."""
    if not reason:
        return 'Event'
    mapping = {
        'sentry_aware_object_detection': 'Sentry Detection',
        'sentry_aware_accel': 'Sentry Acceleration',
        'sentry_aware': 'Sentry Aware',
        'user_interaction_dashcam_launcher_action_tapped': 'Manual Save',
        'user_interaction_honk': 'Honk Save',
        'user_interaction': 'User Save',
        'panic': 'Panic Save',
    }
    return mapping.get(reason, reason.replace('_', ' ').title())


# --- Core Scanner ---

def _scan_events_in_path(scan_path, source_folder, events, seen):
    """Scan a directory for event subfolders with event.json."""
    try:
        with os.scandir(scan_path) as entries:
            for entry in entries:
                if not entry.is_dir():
                    continue
                name = entry.name
                if not _EVENT_FOLDER_RE.match(name):
                    continue

                # Dedup: if already seen with TeslaCam source, skip archive copy
                prev = seen.get(name)
                if prev and prev != 'ArchivedClips':
                    continue

                ej_path = os.path.join(entry.path, 'event.json')
                ej = _parse_event_json(ej_path)
                if ej is None:
                    continue

                timestamp = ej['timestamp'] or name
                thumb_path = os.path.join(entry.path, 'thumb.png')
                front_name = _find_front_mp4(entry.path, name)

                event_type = 'sentry' if source_folder == 'SentryClips' else 'saved'
                event = {
                    'name': name,
                    'timestamp': timestamp,
                    'source_folder': source_folder,
                    'event_folder': name,
                    'event_type': event_type,
                    'description': f'{ej["city"]} — {_reason_display(ej["reason"])}',
                    'lat': ej['lat'],
                    'lon': ej['lon'],
                    'city': ej['city'],
                    'street': ej['street'],
                    'reason': ej['reason'],
                    'reason_display': _reason_display(ej['reason']),
                    'has_thumbnail': os.path.isfile(thumb_path),
                    'video_path': f'{source_folder}/{name}/{front_name}',
                    'frame_offset': 0,
                }

                seen[name] = source_folder
                events.append(event)

    except OSError:
        logger.warning("Cannot scan %s", scan_path)


def scan_event_folders():
    """Scan all SentryClips/SavedClips folders for event.json files.

    Returns list of event dicts sorted by timestamp (newest first).
    Cached for 30 seconds.
    """
    cache_key = 'all_events'
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    events = []
    seen = {}

    teslacam = _get_teslacam_root()
    if teslacam:
        for folder in ('SentryClips', 'SavedClips'):
            fp = os.path.join(teslacam, folder)
            if os.path.isdir(fp):
                _scan_events_in_path(fp, folder, events, seen)

    archive = _get_archive_root()
    if archive:
        _scan_events_in_path(archive, 'ArchivedClips', events, seen)

    events.sort(key=lambda e: e.get('timestamp', e.get('name', '')), reverse=True)
    _cache_set(cache_key, events)
    logger.debug("Event scan: %d events found", len(events))
    return events


# --- Public API ---

def get_event_dates():
    """Return sorted unique dates that have events, plus counts.

    Returns:
        dict with keys: dates (list), total (date count),
        total_events, earliest, latest
    """
    cache_key = 'event_dates'
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    events = scan_event_folders()
    dates_set = set()
    earliest = None
    latest = None

    for ev in events:
        d = ev['timestamp'][:10] if ev['timestamp'] else ev['name'][:10]
        if len(d) == 10:
            dates_set.add(d)
            if earliest is None or d < earliest:
                earliest = d
            if latest is None or d > latest:
                latest = d

    dates = sorted(dates_set, reverse=True)
    result = {
        'dates': dates,
        'total': len(dates),
        'total_events': len(events),
        'earliest': earliest,
        'latest': latest,
    }
    _cache_set(cache_key, result)
    return result


def get_events_by_date(date_str):
    """Return all events for a specific date (YYYY-MM-DD).

    Returns:
        dict with keys: date, events (list), total
    """
    cache_key = f'events_date_{date_str}'
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    events = scan_event_folders()
    filtered = [
        ev for ev in events
        if (ev['timestamp'][:10] if ev['timestamp'] else ev['name'][:10]) == date_str
    ]

    result = {'date': date_str, 'events': filtered, 'total': len(filtered)}
    _cache_set(cache_key, result)
    return result
