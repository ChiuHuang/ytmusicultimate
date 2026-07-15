import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.path.insert(0, '.')
from proxy_server import get_song_info_from_ytmusic, fetch_lrclib, parse_lrc_to_json, parse_plain_to_json

# Test 1: Moonlight by Hoshimachi Suisei
print("=== Test 1: Moonlight ===")
info = get_song_info_from_ytmusic('Pmvjj62_Dbc')
print(f"Song: {info['title']} - {info['artist']} ({info['duration']}s)")
lrc = fetch_lrclib(info['title'], info['artist'], '', info['duration'])
if lrc:
    print(f"Source: {lrc['source']}, Synced: {bool(lrc.get('synced'))}, Plain: {bool(lrc.get('plain'))}")
    if lrc.get('synced'):
        lyrics = parse_lrc_to_json(lrc['synced'], info['duration'])
        print(f"Parsed {len(lyrics)} synced lines")
        for l in lyrics[:5]:
            print(f"  [{l['time']:.1f}s | {l['duration']:.1f}s] {l['text']}")
    elif lrc.get('plain'):
        lyrics = parse_plain_to_json(lrc['plain'])
        print(f"Parsed {len(lyrics)} plain lines")
        for l in lyrics[:5]:
            print(f"  {l['text']}")

# Test 2: A popular song (Shape of You)
print("\n=== Test 2: Shape of You ===")
info2 = get_song_info_from_ytmusic('JGwWNGJdvx8')
print(f"Song: {info2['title']} - {info2['artist']} ({info2['duration']}s)")
lrc2 = fetch_lrclib(info2['title'], info2['artist'], '', info2['duration'])
if lrc2:
    print(f"Source: {lrc2['source']}, Synced: {bool(lrc2.get('synced'))}, Plain: {bool(lrc2.get('plain'))}")
    if lrc2.get('synced'):
        lyrics2 = parse_lrc_to_json(lrc2['synced'], info2['duration'])
        print(f"Parsed {len(lyrics2)} synced lines")
        for l in lyrics2[:5]:
            print(f"  [{l['time']:.1f}s | {l['duration']:.1f}s] {l['text']}")

print("\nDone!")
