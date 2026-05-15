"""
Lightweight i18n service for TeslaUSB web UI.

Loads translation JSON files once at startup. Provides O(1) dict lookup
for every translation key — zero per-request I/O, ~20KB memory footprint.

Language detection cascade: URL param (?lang=zh) → Cookie (lang) →
Accept-Language header → default 'zh' (China fork).
"""

import json
import logging
import os
from typing import List

logger = logging.getLogger(__name__)

_translations = {}          # {'en': {...}, 'zh': {...}}
_supported_locales = ['en', 'zh']
_default_locale = 'zh'


def load_translations(translations_dir: str) -> None:
    """Load all translation JSON files at startup. Called once from web_control.py."""
    global _translations
    for locale in _supported_locales:
        path = os.path.join(translations_dir, f'{locale}.json')
        try:
            with open(path, 'r', encoding='utf-8') as f:
                _translations[locale] = json.load(f)
            logger.info(
                "Loaded %d translations for '%s'",
                len(_translations[locale]), locale,
            )
        except FileNotFoundError:
            logger.warning("Translation file not found: %s (locale '%s' will fall back)", path, locale)
            _translations[locale] = {}
        except (json.JSONDecodeError, ValueError) as e:
            logger.error("Failed to parse %s: %s", path, e)
            _translations[locale] = {}


def get_text(key: str, locale: str = None) -> str:
    """Look up a translation key.

    Fallback chain: requested locale → English → return the key itself
    (so a missing translation is visible as the untranslated key).
    """
    if locale is None:
        locale = _default_locale
    locale_data = _translations.get(locale, {})
    if key in locale_data:
        return locale_data[key]
    en_data = _translations.get('en', {})
    if key in en_data:
        return en_data[key]
    logger.debug("Missing translation key: %s (locale=%s)", key, locale)
    return key


def detect_locale(request) -> str:
    """Detect locale from URL param → Cookie → Accept-Language → default 'zh'."""
    lang = request.args.get('lang')
    if lang and lang in _supported_locales:
        return lang
    lang = request.cookies.get('lang')
    if lang and lang in _supported_locales:
        return lang
    accept = request.headers.get('Accept-Language', '')
    for part in accept.split(','):
        code = part.strip().split(';')[0].split('-')[0]
        if code in _supported_locales:
            return code
    return _default_locale


def supported_locales() -> List[str]:
    """Return list of supported locale codes."""
    return _supported_locales.copy()
