from flask import Flask, request, jsonify
import json
import os
import re
import requests
import hashlib
import time as time_module
from datetime import datetime
from urllib.parse import quote

app = Flask(__name__)

if not os.path.exists('logs'):
    os.makedirs('logs')

# ============================================================
# LRC Parser
# ============================================================

def parse_lrc(lrc_text, duration_sec=0):
    """Parse LRC format into structured JSON array.
    Supports standard [mm:ss.xx] and enhanced <mm:ss.xx> word-sync tags.
    """
    lines = lrc_text.strip().split('\n')
    result = []
    offset_ms = 0
    
    time_regex = re.compile(r'\[(\d+):(\d+)\.(\d+)\]')
    word_regex = re.compile(r'<(\d+):(\d+)\.(\d+)>')
    id_tag_regex = re.compile(r'^\[(\w+):(.*)\]$')
    
    def parse_time_tag(m, g, s, cs):
        minutes = int(m)
        seconds = int(s)
        cs_str = cs
        if len(cs_str) == 2:
            ms = int(cs_str) * 10
        elif len(cs_str) == 3:
            ms = int(cs_str)
        else:
            ms = int(cs_str)
        return minutes * 60000 + seconds * 1000 + ms
    
    for line in lines:
        line = line.strip()
        if not line:
            continue
        
        # Check for offset tag
        id_match = id_tag_regex.match(line)
        if id_match and id_match.group(1) == 'offset':
            try:
                offset_ms = int(id_match.group(2))
            except:
                pass
            continue
        if id_match and id_match.group(1) in ['ti', 'ar', 'al', 'au', 'lr', 'length', 'by', 're', 'tool', 've', '#']:
            continue
        
        # Extract time tags
        time_matches = list(time_regex.finditer(line))
        if not time_matches:
            continue
        
        text = time_regex.sub('', line).strip()
        if not text:
            continue
        
        # Parse word-level sync if present
        parts = []
        word_matches = list(word_regex.finditer(text))
        if word_matches:
            plain_text = word_regex.sub('', text).strip()
            fragments = word_regex.split(text)
            word_parts = []
            for wi, wm in enumerate(word_matches):
                word_time = parse_time_tag(wm.group(1), wm.group(1), wm.group(2), wm.group(3))
                # Get the text fragment after this word tag
                frag_idx = (wi + 1) * 4  # Each match has 3 groups + the gap
                # Simpler: just collect word timestamps
                word_parts.append({'startTimeMs': word_time + offset_ms})
            
            # Rebuild parts with text
            raw_fragments = word_regex.split(text)
            current_parts = []
            word_idx = 0
            for fi, frag in enumerate(raw_fragments):
                if fi % 4 == 0 and frag.strip():  # Text fragment
                    start_ms = word_parts[word_idx]['startTimeMs'] if word_idx < len(word_parts) else 0
                    current_parts.append({
                        'startTimeMs': start_ms,
                        'words': frag,
                        'durationMs': 0
                    })
                elif fi % 4 != 0:
                    word_idx += 1
            
            # Calculate durations for parts
            for pi in range(len(current_parts)):
                if pi < len(current_parts) - 1:
                    current_parts[pi]['durationMs'] = current_parts[pi+1]['startTimeMs'] - current_parts[pi]['startTimeMs']
            
            parts = current_parts
            text = plain_text
        
        for tm in time_matches:
            start_ms = parse_time_tag(tm.group(1), tm.group(1), tm.group(2), tm.group(3)) + offset_ms
            
            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': text,
                'durationMs': 0
            }
            if parts:
                entry['parts'] = parts
            
            result.append(entry)
    
    # Sort by time
    result.sort(key=lambda x: x['startTimeMs'])
    
    # Calculate durations
    duration_ms = duration_sec * 1000
    for i in range(len(result)):
        if i < len(result) - 1:
            result[i]['durationMs'] = result[i+1]['startTimeMs'] - result[i]['startTimeMs']
        else:
            result[i]['durationMs'] = max(int(duration_ms - result[i]['startTimeMs']), 3000)
        result[i]['duration'] = round(result[i]['durationMs'] / 1000.0, 3)
    
    return result


def parse_plain(plain_text):
    """Parse plain (unsynced) lyrics."""
    lines = plain_text.strip().split('\n')
    result = []
    for line in lines:
        text = line.strip()
        if text:
            result.append({
                'time': 0,
                'startTimeMs': 0,
                'text': text,
                'durationMs': 0,
                'duration': 0
            })
    return result


# ============================================================
# Provider 1: LRCLIB (free, no auth)
# ============================================================

def fetch_lrclib(title, artist, album='', duration=0):
    """Fetch lyrics from LRCLIB. Tries exact match, then search."""
    headers = {'User-Agent': 'YTMusicUltimate/1.0 (https://github.com/user/ytmusicultimate)'}
    
    # Exact match
    try:
        params = {'track_name': title, 'artist_name': artist}
        if album:
            params['album_name'] = album
        if duration:
            params['duration'] = duration
        
        resp = requests.get('https://lrclib.net/api/get', params=params, timeout=10, headers=headers)
        if resp.status_code == 200:
            data = resp.json()
            if data.get('syncedLyrics') or data.get('plainLyrics'):
                return {
                    'synced': data.get('syncedLyrics'),
                    'plain': data.get('plainLyrics', ''),
                    'source': 'LRCLib',
                    'instrumental': data.get('instrumental', False)
                }
    except Exception as e:
        print(f"[LRCLIB exact] Error: {e}")
    
    # Search fallback
    try:
        resp = requests.get('https://lrclib.net/api/search',
                          params={'q': f"{artist} {title}"},
                          timeout=10, headers=headers)
        if resp.status_code == 200:
            results = resp.json()
            # Prefer synced
            for r in results:
                if r.get('syncedLyrics'):
                    return {
                        'synced': r['syncedLyrics'],
                        'plain': r.get('plainLyrics', ''),
                        'source': 'LRCLib',
                        'instrumental': r.get('instrumental', False)
                    }
            # Fallback to plain
            for r in results:
                if r.get('plainLyrics'):
                    return {
                        'synced': None,
                        'plain': r['plainLyrics'],
                        'source': 'LRCLib',
                        'instrumental': r.get('instrumental', False)
                    }
    except Exception as e:
        print(f"[LRCLIB search] Error: {e}")
    
    return None


# ============================================================
# Provider 2: YouTube Music Lyrics (via ytmusicapi)
# ============================================================

_ytm = None

def get_ytmusic():
    global _ytm
    if _ytm is None:
        from ytmusicapi import YTMusic
        _ytm = YTMusic()
    return _ytm


def get_song_info(video_id):
    """Get song metadata from YT Music."""
    try:
        ytm = get_ytmusic()
        info = ytm.get_song(video_id)
        if not info or 'videoDetails' not in info:
            return None
        
        d = info['videoDetails']
        title = d.get('title', '')
        artist = d.get('author', '')
        duration = int(d.get('lengthSeconds', 0))
        
        album = ''
        try:
            album = info.get('microformat', {}).get('microformatDataRenderer', {}).get('tags', [''])[0]
        except:
            pass
        
        return {'title': title, 'artist': artist, 'album': album, 'duration': duration}
    except Exception as e:
        print(f"[ytmusicapi] get_song error: {e}")
        return None


def fetch_yt_lyrics(video_id):
    try:
        ytm = get_ytmusic()
        watch_playlist = ytm.get_watch_playlist(video_id)
        lyrics_browse_id = watch_playlist.get('lyrics') if watch_playlist else None
        
        if lyrics_browse_id:
            lyrics = ytm.get_lyrics(lyrics_browse_id)
            if lyrics and lyrics.get('lyrics'):
                return {'plain': lyrics['lyrics'], 'source': 'YouTube Music'}
    except Exception as e:
        print(f"  ❌ ytmusicapi error: {e}")
    return None

# ============================================================
# Cubey API (Turnstile bypassed)
# ============================================================

def fetch_cubey(jwt_token, video_id, title, artist, duration_sec):
    url = "https://lyrics.api.dacubeking.com/v2/lyrics"
    data = {
        "videoId": video_id,
        "song": title,
        "artist": artist,
        "duration": str(int(duration_sec)),
        "alwaysFetchMetadata": "false",
        "token": jwt_token
    }
    
    try:
        response = requests.post(url, data=data, stream=True, timeout=15)
        if response.status_code != 200:
            print(f"  ❌ Cubey API error: {response.status_code}")
            return None
            
        best_lyrics = None
        
        for line in response.iter_lines():
            if not line:
                continue
            line = line.decode('utf-8').strip()
            if line.startswith("data:"):
                data_str = line[5:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    event_data = json.loads(data_str)
                    provider = event_data.get("provider")
                    results = event_data.get("results")
                    
                    if not results: continue
                    
                    # We prefer synced LRC. QQ/KuGou often return raw JSON strings in "lyrics".
                    if provider == "musixmatch":
                        if results.get("wordByWord"):
                            return {"synced": results["wordByWord"], "source": "Musixmatch"}
                        if results.get("synced"):
                            best_lyrics = {"synced": results["synced"], "source": "Musixmatch"}
                    
                    elif provider == "netease" and results.get("synced"):
                        if not best_lyrics:
                            best_lyrics = {"synced": results["synced"], "source": "NetEase"}
                            
                    elif provider == "kugou" and results.get("lyrics"):
                        try:
                            k_json = json.loads(results["lyrics"])
                            if k_json.get("lyrics") and not best_lyrics:
                                best_lyrics = {"synced": k_json["lyrics"], "source": "KuGou"}
                        except: pass
                        
                except Exception as e:
                    pass
        
        return best_lyrics
    except Exception as e:
        print(f"  ❌ Cubey API request failed: {e}")
        return None


# ============================================================
# Provider 3: Unison (community lyrics, free with x-key-id)
# ============================================================

def generate_unison_key():
    """Generate a unique key ID for Unison API."""
    import uuid
    return hashlib.sha256(str(uuid.uuid4()).encode()).hexdigest()[:32]

_unison_key = None

def get_unison_key():
    global _unison_key
    if _unison_key is None:
        _unison_key = generate_unison_key()
    return _unison_key


def fetch_unison(video_id, title='', artist='', duration=0):
    """Fetch lyrics from Unison community API."""
    try:
        headers = {
            'x-key-id': get_unison_key(),
            'Content-Type': 'application/json'
        }
        params = {'videoId': video_id}
        if title:
            params['title'] = title
        if artist:
            params['artist'] = artist
        if duration:
            params['duration'] = str(int(duration))
        
        resp = requests.get('https://unison.boidu.dev/lyrics',
                          params=params, headers=headers, timeout=10)
        
        if resp.status_code == 200:
            data = resp.json()
            fmt = data.get('format', '')
            lyrics_text = data.get('lyrics', '')
            
            if not lyrics_text:
                return None
            
            if fmt == 'lrc':
                return {
                    'synced': lyrics_text,
                    'plain': None,
                    'source': 'Unison',
                    'format': 'lrc'
                }
            elif fmt == 'plain':
                return {
                    'synced': None,
                    'plain': lyrics_text,
                    'source': 'Unison',
                    'format': 'plain'
                }
            elif fmt == 'ttml':
                # Parse TTML to extract lines
                ttml_lyrics = parse_ttml_basic(lyrics_text, duration)
                if ttml_lyrics:
                    return {
                        'parsed': ttml_lyrics,
                        'source': 'Unison',
                        'format': 'ttml'
                    }
    except Exception as e:
        print(f"[Unison] Error: {e}")
    return None


# ============================================================
# Basic TTML Parser
# ============================================================

def parse_ttml_basic(ttml_text, duration_sec=0):
    """Basic TTML parser - extracts timed lines from TTML/AMLL XML."""
    try:
        import xml.etree.ElementTree as ET
        
        # Fix common namespace issues
        ttml_text = re.sub(r'xmlns:amll="[^"]*"', '', ttml_text)
        ttml_text = re.sub(r'amll:', '', ttml_text)
        
        # Remove default namespace for easier parsing
        ttml_text = re.sub(r'xmlns="[^"]*"', '', ttml_text)
        
        root = ET.fromstring(ttml_text)
        
        results = []
        
        # Find all <p> elements (lines)
        for p in root.iter('p'):
            begin = p.get('begin', p.get('{http://www.w3.org/ns/ttml}begin', ''))
            end = p.get('end', p.get('{http://www.w3.org/ns/ttml}end', ''))
            
            if not begin:
                continue
            
            start_ms = parse_ttml_time(begin)
            end_ms = parse_ttml_time(end) if end else start_ms + 5000
            
            # Get text content
            text_parts = []
            parts = []
            
            # Check for spans (word-level sync)
            spans = list(p.iter('span'))
            if spans:
                for span in spans:
                    span_begin = span.get('begin', '')
                    span_end = span.get('end', '')
                    span_text = (span.text or '').strip()
                    
                    if span_text:
                        text_parts.append(span_text)
                        if span_begin:
                            parts.append({
                                'startTimeMs': parse_ttml_time(span_begin),
                                'words': span_text,
                                'durationMs': parse_ttml_time(span_end) - parse_ttml_time(span_begin) if span_end else 0
                            })
            else:
                text_parts = [(p.text or '').strip()]
            
            full_text = ' '.join(t for t in text_parts if t)
            if not full_text:
                continue
            
            entry = {
                'time': round(start_ms / 1000.0, 3),
                'startTimeMs': start_ms,
                'text': full_text,
                'durationMs': end_ms - start_ms,
                'duration': round((end_ms - start_ms) / 1000.0, 3)
            }
            if parts:
                entry['parts'] = parts
            
            results.append(entry)
        
        return results if results else None
    except Exception as e:
        print(f"[TTML Parser] Error: {e}")
        return None


def parse_ttml_time(time_str):
    """Parse TTML time format (HH:MM:SS.mmm or seconds) to milliseconds."""
    if not time_str:
        return 0
    
    # Format: HH:MM:SS.mmm or MM:SS.mmm
    parts = time_str.replace(',', '.').split(':')
    try:
        if len(parts) == 3:
            h, m, s = int(parts[0]), int(parts[1]), float(parts[2])
            return int((h * 3600 + m * 60 + s) * 1000)
        elif len(parts) == 2:
            m, s = int(parts[0]), float(parts[1])
            return int((m * 60 + s) * 1000)
        else:
            return int(float(parts[0]) * 1000)
    except:
        return 0


# ============================================================
# Cohere Translate (Command A Translate - free tier)
# ============================================================

COHERE_API_KEYS = [
    "XlQ23B0II2OEgSO1sNa1mWXgiuMsuYcGWBAblLfX",
    "8SNdZXeGNQwTLaZQz6bpHWKW5SnnujUbMBgpi1jJ",
    "ZpSlGaleZDIWf5WnzJrxxz2fAEv26Xc7vdZgyqiz",
    "gGIDUA29FUdmauU7rden49bWXRurTThqzbbBEqNy",
]
_cohere_key_idx = 0

translate_cache = {}

def get_cohere_key():
    global _cohere_key_idx
    key = COHERE_API_KEYS[_cohere_key_idx % len(COHERE_API_KEYS)]
    return key

def rotate_cohere_key():
    global _cohere_key_idx
    _cohere_key_idx += 1
    print(f"  [Cohere] Rotated to key index {_cohere_key_idx % len(COHERE_API_KEYS)}")

LANG_NAMES = {
    'zh-TW': 'Traditional Chinese',
    'zh-CN': 'Simplified Chinese',
    'ja': 'Japanese',
    'ko': 'Korean',
    'en': 'English',
}

def cohere_translate(texts, target_lang='zh-TW'):
    """Translate a list of text lines using Cohere Command A Translate."""
    if not texts:
        return []
    
    # Filter out lines that are already the target language or empty
    # Simple heuristic: if all chars are CJK and target is zh, skip
    non_empty = [t for t in texts if t.strip()]
    if not non_empty:
        return texts
    
    cache_key = f"cohere:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    if cache_key in translate_cache:
        return translate_cache[cache_key]
    
    lang_name = LANG_NAMES.get(target_lang, target_lang)
    
    # Join all lines with a numbered marker for reliable splitting
    numbered = [f"[{i+1}] {t}" for i, t in enumerate(texts)]
    joined = '\n'.join(numbered)
    
    prompt = (
        f"Translate the following song lyrics into {lang_name}. "
        f"Keep the same numbered format [1], [2], etc. "
        f"If a line is already in {lang_name} or is romanization/gibberish, keep it as-is. "
        f"Return ONLY the translated lines with their numbers, nothing else.\n\n"
        f"{joined}"
    )
    
    for attempt in range(len(COHERE_API_KEYS)):
        try:
            api_key = get_cohere_key()
            resp = requests.post(
                "https://api.cohere.com/v2/chat",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "command-a-translate-08-2025",
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=30
            )
            
            if resp.status_code == 429:  # Rate limited
                print(f"  [Cohere] Rate limited on key {attempt}, rotating...")
                rotate_cohere_key()
                continue
            
            if resp.status_code != 200:
                print(f"  [Cohere] Error {resp.status_code}: {resp.text[:200]}")
                rotate_cohere_key()
                continue
            
            data = resp.json()
            translated_text = data['message']['content'][0]['text']
            
            # Parse numbered lines back
            result_map = {}
            for line in translated_text.split('\n'):
                line = line.strip()
                if line.startswith('['):
                    try:
                        bracket_end = line.index(']')
                        idx = int(line[1:bracket_end])
                        content = line[bracket_end+1:].strip()
                        result_map[idx] = content
                    except:
                        pass
            
            # Reconstruct in order
            results = [result_map.get(i+1, texts[i]) for i in range(len(texts))]
            translate_cache[cache_key] = results
            save_cache()
            return results
            
        except Exception as e:
            print(f"  [Cohere] Exception: {e}")
            rotate_cohere_key()
    
    # Fallback: return originals
    print(f"  [Cohere] All keys failed, returning originals")
    return texts


def google_translate_fast(texts, target_lang='zh-TW'):
    """Fast Google translate - no API key needed, for immediate results."""
    if not texts:
        return []
    
    cache_key = f"gtx:{target_lang}:{hashlib.md5('|'.join(texts).encode()).hexdigest()}"
    if cache_key in translate_cache:
        return translate_cache[cache_key]
    
    delimiter = '\n\n;\n\n'
    batches, current_batch, current_len = [], [], 0
    for text in texts:
        if current_len + len(text) > 3500:
            batches.append(current_batch)
            current_batch, current_len = [], 0
        current_batch.append(text)
        current_len += len(text)
    if current_batch:
        batches.append(current_batch)
    
    all_translations = []
    for batch in batches:
        joined = delimiter.join(batch)
        try:
            url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={target_lang}&dt=t&q={quote(joined)}"
            resp = requests.get(url, timeout=8, headers={'User-Agent': 'Mozilla/5.0'})
            if resp.status_code == 200:
                data = resp.json()
                translated = ''.join(part[0] for part in data[0] if part[0])
                parts = translated.split(';')
                if len(parts) == len(batch):
                    all_translations.extend([p.strip() for p in parts])
                else:
                    lines = [t.strip() for t in translated.split('\n') if t.strip()]
                    while len(lines) < len(batch): lines.append('')
                    all_translations.extend(lines[:len(batch)])
            else:
                all_translations.extend(['' for _ in batch])
        except Exception as e:
            all_translations.extend(['' for _ in batch])
    
    translate_cache[cache_key] = all_translations
    save_cache()
    return all_translations


# ============================================================
# Cache
# ============================================================

lyrics_cache = {}

CACHE_FILE = 'lyrics_cache.json'
TRANSLATE_CACHE_FILE = 'translate_cache.json'

def load_cache():
    global lyrics_cache, translate_cache
    try:
        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, 'r', encoding='utf-8') as f:
                loaded = json.load(f)
                for k, v in loaded.items():
                    lyrics_cache[k] = {'data': v['data'], 'ts': datetime.fromisoformat(v['ts'])}
        if os.path.exists(TRANSLATE_CACHE_FILE):
            with open(TRANSLATE_CACHE_FILE, 'r', encoding='utf-8') as f:
                for k, v in json.load(f).items():
                    translate_cache[k] = v
        print(f"Loaded {len(lyrics_cache)} lyrics and {len(translate_cache)} translations from cache.")
    except Exception as e:
        print(f"Error loading cache: {e}")

def save_cache():
    try:
        serializable_lyrics = {}
        for k, v in lyrics_cache.items():
            serializable_lyrics[k] = {'data': v['data'], 'ts': v['ts'].isoformat()}
        with open(CACHE_FILE, 'w', encoding='utf-8') as f:
            json.dump(serializable_lyrics, f, ensure_ascii=False)
        with open(TRANSLATE_CACHE_FILE, 'w', encoding='utf-8') as f:
            json.dump(translate_cache, f, ensure_ascii=False)
    except Exception as e:
        print(f"Error saving cache: {e}")

def get_cached(video_id):
    if video_id in lyrics_cache:
        entry = lyrics_cache[video_id]
        if (datetime.now() - entry['ts']).total_seconds() < 86400 * 3: # Cache for 3 days
            return entry['data']
    return None

def set_cached(video_id, data):
    lyrics_cache[video_id] = {'data': data, 'ts': datetime.now()}
    save_cache()


# ============================================================
# Main Lyrics Pipeline
# ============================================================

# Server-side in-flight dedup
_in_flight = {}  # cache_key -> threading.Event
import threading

def fetch_fast_lyrics(video_id, song_info, translate_to='zh-TW'):
    """Fast path: LRCLIB only + Google translate. Returns in ~1-2s."""
    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    result = None

    lrc = fetch_lrclib(title, artist, album, duration)
    if lrc:
        if lrc.get('instrumental'):
            result = {'lyrics': [{'time': 0, 'text': '🎵 Instrumental', 'translated': '純音樂', 'duration': 0}], 'source': 'LRCLib', 'synced': False}
        elif lrc.get('synced'):
            print(f"  [fast] ✅ LRCLIB synced!")
            result = {'lyrics': parse_lrc(lrc['synced'], duration), 'source': 'LRCLib', 'synced': True}
        elif lrc.get('plain'):
            print(f"  [fast] ⚠️ LRCLIB plain")
            result = {'lyrics': parse_plain(lrc['plain']), 'source': 'LRCLib', 'synced': False}

    if not result:
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  [fast] ✅ YouTube plain!")
            result = {'lyrics': parse_plain(yt['plain']), 'source': 'YouTube Music', 'synced': False}

    if not result:
        return None

    result['song'] = title
    result['artist'] = artist

    if translate_to and result.get('lyrics'):
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = google_translate_fast(texts, translate_to)
        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations) and translations[i]:
                lyric['translated'] = translations[i]

    return result

def fetch_all_lyrics(video_id, song_info, translate_to=None, jwt_token=None):
    """Try all providers in priority order, return best result."""
    
    title = song_info['title']
    artist = song_info['artist']
    album = song_info.get('album', '')
    duration = song_info.get('duration', 0)
    
    result = None
    
    # Priority 0: Cubey API (if we have JWT)
    if jwt_token:
        print(f"  [0/4] Trying Cubey API (with JWT)...")
        cubey = fetch_cubey(jwt_token, video_id, title, artist, duration)
        if cubey and cubey.get('synced'):
            print(f"  ✅ Cubey: synced LRC lyrics found from {cubey.get('source')}!")
            parsed = parse_lrc(cubey['synced'], duration)
            result = {'lyrics': parsed, 'source': cubey.get('source'), 'synced': True}
            # Skip other providers - we already have the best
            result['song'] = title
            result['artist'] = artist
            if translate_to and result.get('lyrics'):
                print(f"  🌐 Translating {len(result['lyrics'])} lines with Cohere...")
                texts = [l['text'] for l in result['lyrics'] if l.get('text')]
                translations = cohere_translate(texts, translate_to)
                for i, lyric in enumerate(result['lyrics']):
                    if i < len(translations):
                        lyric['translated'] = translations[i]
            return result
    
    # Priority 1: LRCLIB (best for synced lyrics)
    print(f"  [1/3] Trying LRCLIB...")
    lrc = fetch_lrclib(title, artist, album, duration)
    if lrc:
        if lrc.get('instrumental'):
            result = {
                'lyrics': [{'time': 0, 'text': '🎵 Instrumental', 'translated': '純音樂', 'duration': 0}],
                'source': 'LRCLib', 'synced': False
            }
        elif lrc.get('synced'):
            print(f"  ✅ LRCLIB: synced lyrics found!")
            parsed = parse_lrc(lrc['synced'], duration)
            result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': True}
        elif lrc.get('plain'):
            print(f"  ⚠️ LRCLIB: plain lyrics only")
            parsed = parse_plain(lrc['plain'])
            result = {'lyrics': parsed, 'source': 'LRCLib', 'synced': False}
    
    # Priority 2: Unison (community)
    if not result or not result.get('synced'):
        print(f"  [2/3] Trying Unison...")
        uni = fetch_unison(video_id, title, artist, duration)
        if uni:
            if uni.get('parsed'):
                # Already parsed TTML
                print(f"  ✅ Unison: TTML lyrics found!")
                if not result or not result.get('synced'):
                    result = {'lyrics': uni['parsed'], 'source': 'Unison', 'synced': True}
            elif uni.get('synced'):
                print(f"  ✅ Unison: synced LRC lyrics found!")
                parsed = parse_lrc(uni['synced'], duration)
                if not result or not result.get('synced'):
                    result = {'lyrics': parsed, 'source': 'Unison', 'synced': True}
            elif uni.get('plain'):
                print(f"  ⚠️ Unison: plain lyrics only")
                if not result:
                    parsed = parse_plain(uni['plain'])
                    result = {'lyrics': parsed, 'source': 'Unison', 'synced': False}
    
    # Priority 3: YouTube Music lyrics
    if not result:
        print(f"  [3/3] Trying YouTube Music lyrics...")
        yt = fetch_yt_lyrics(video_id)
        if yt and yt.get('plain'):
            print(f"  ✅ YouTube: plain lyrics found!")
            parsed = parse_plain(yt['plain'])
            result = {'lyrics': parsed, 'source': yt.get('source', 'YouTube Music'), 'synced': False}
    
    # No lyrics found
    if not result:
        print(f"  ❌ No lyrics found from any provider")
        result = {
            'lyrics': [{'time': 0, 'text': f'No lyrics found', 'translated': f'找不到歌詞: {title}', 'duration': 0}],
            'source': 'none', 'synced': False
        }
    
    # Add song metadata
    result['song'] = title
    result['artist'] = artist
    
    # Translation
    if translate_to and result.get('lyrics'):
        print(f"  🌐 Translating {len(result['lyrics'])} lines with Cohere...")
        texts = [l['text'] for l in result['lyrics'] if l.get('text')]
        translations = cohere_translate(texts, translate_to)
        
        for i, lyric in enumerate(result['lyrics']):
            if i < len(translations):
                lyric['translated'] = translations[i]
    
    return result


# ============================================================
# API Endpoints
# ============================================================

@app.route('/api/lyrics', methods=['GET'])
def api_lyrics():
    video_id = request.args.get('v')
    translate_to = request.args.get('lang', 'zh-TW')
    jwt_token = request.args.get('jwt')
    fast_mode = request.args.get('fast', '0') == '1'
    
    print("=" * 60)
    mode_str = 'FAST' if fast_mode else ('JWT+Cohere' if jwt_token else 'Normal')
    print(f"🌟 Lyrics request: {video_id} [{mode_str}]")
    print("=" * 60)
    
    if not video_id:
        return jsonify({"error": "Missing video ID"}), 400
    
    # Separate cache keys for fast vs full results
    cache_key = f"{video_id}:{translate_to}:fast" if fast_mode else f"{video_id}:{translate_to}"
    if cache_key in _in_flight:
        print(f"⏳ Waiting for in-flight request for {video_id}...")
        _in_flight[cache_key].wait(timeout=30)
        cached = get_cached(cache_key)
        if cached:
            print(f"✅ Got result from in-flight wait")
            return jsonify(cached)
    
    # Cache check
    cached = get_cached(cache_key)
    if cached:
        print(f"✅ Cache hit!")
        return jsonify(cached)
    
    # Mark as in-flight
    event = threading.Event()
    _in_flight[cache_key] = event
    
    # Get song info
    print(f"🔍 Looking up song info...")
    song_info = get_song_info(video_id)
    
    if not song_info:
        if cache_key in _in_flight:
            _in_flight[cache_key].set()
            del _in_flight[cache_key]
        return jsonify({
            'lyrics': [{'time': 0, 'text': 'Could not identify song', 'translated': '無法識別歌曲', 'duration': 0}],
            'source': 'error', 'synced': False
        })
    
    print(f"🎵 {song_info['title']} - {song_info['artist']} ({song_info['duration']}s)")
    
    # Fetch lyrics
    try:
        if fast_mode:
            result = fetch_fast_lyrics(video_id, song_info, translate_to)
            if not result:
                result = {
                    'lyrics': [{'time': 0, 'text': 'No lyrics found', 'translated': '找不到歌詞', 'duration': 0}],
                    'source': 'none', 'synced': False
                }
        else:
            result = fetch_all_lyrics(video_id, song_info, translate_to, jwt_token)
    finally:
        # Always release the in-flight lock
        if cache_key in _in_flight:
            _in_flight[cache_key].set()
            del _in_flight[cache_key]
    
    # Cache result
    set_cached(cache_key, result)
    
    print(f"📤 Returning {len(result.get('lyrics', []))} lines from {result.get('source', '?')}")
    print("=" * 60)
    
    return jsonify(result)


@app.route('/log', methods=['POST'])
def proxy_log():
    try:
        data = request.get_json(force=True)
        req_type = data.get('type', '')
        
        if req_type == "UI_DUMP":
            timestamp = datetime.now().strftime("%H-%M-%S")
            print(f"\n[{timestamp}] 📦 UI Dump received!")
            
            dump_content = data.get('request_body', '')
            filepath = f"logs/UI_DUMP_{timestamp}.txt"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(dump_content)
            print(f"✅ Saved to {filepath}")
            
    except Exception as e:
        print("Log error:", e)

    return jsonify({"status": "ok"})


if __name__ == '__main__':
    load_cache()
    print("=" * 60)
    print("🎵 YTMusic Ultimate - Lyrics API Server")
    print("=" * 60)
    print("Providers (priority order):")
    print("  0. Cubey API  (Musixmatch/KuGou/NetEase, requires JWT)")
    print("  1. LRCLIB     (synced + plain, free)")
    print("  2. Unison     (community, free)")
    print("  3. YT Music   (plain, via ytmusicapi)")
    print("Translation: Cohere Command A Translate")
    print("Auth: Cloudflare Turnstile via in-app WKWebView")
    print("=" * 60)
    print("Server: http://0.0.0.0:20016")
    print("=" * 60)
    app.run(host='0.0.0.0', port=20016, debug=True)
