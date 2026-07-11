#!/usr/bin/env python3
"""Show active Jellyfin playback sessions: PlayMethod + TranscodeReasons + what's being
transcoded vs direct. Run while a title is playing to diagnose why it transcodes.

Usage: jf_sessions.py <server-url> <api-key>
   or: set JF_URL / JF_APIKEY and run without arguments.
API key: Jellyfin Dashboard > API Keys.
"""
import json, os, sys, urllib.request
sys.stdout.reconfigure(encoding="utf-8")

BASE = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("JF_URL", "")).rstrip("/")
KEY = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("JF_APIKEY", "")
if not BASE or not KEY:
    sys.exit(__doc__.strip())

req = urllib.request.Request(BASE + "/Sessions", headers={"X-Emby-Token": KEY})
sessions = json.load(urllib.request.urlopen(req, timeout=20))
active = 0
for s in sessions:
    npi = s.get("NowPlayingItem")
    if not npi:
        continue
    active += 1
    ps = s.get("PlayState") or {}
    ti = s.get("TranscodingInfo") or {}
    print(f"== {s.get('Client')} / {s.get('DeviceName')} ==")
    print(f"  item        : {npi.get('Name')}")
    print(f"  PlayMethod  : {ps.get('PlayMethod')}")
    print(f"  TranscodeReasons: {ti.get('TranscodeReasons')}")
    print(f"  VideoDirect={ti.get('IsVideoDirect')} AudioDirect={ti.get('IsAudioDirect')}  -> v={ti.get('VideoCodec')} a={ti.get('AudioCodec')} ch={ti.get('AudioChannels')} cont={ti.get('Container')} sub={ti.get('SubProtocol')} bitrate={ti.get('Bitrate')}")
    for st in (npi.get("MediaStreams") or []):
        if st.get("Type") in ("Video", "Audio"):
            print(f"    src {st.get('Type')}: codec={st.get('Codec')} profile={st.get('Profile')} range={st.get('VideoRangeType')} ch={st.get('Channels')} bitrate={st.get('BitRate')}")
if not active:
    print("No active playback session (start playback first, then re-run).")
