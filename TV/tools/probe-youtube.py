#!/usr/bin/env python3
"""ParkPlay TV — verifică ce dă YouTube fiecărui client (HLS? calitate maximă?). Autor: arturm
Rulare:  python3 TV/tools/probe-youtube.py [videoId]"""
import json, sys

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
VID = ARGS[0] if ARGS else "LXb3EKWsInQ"

def get(url, headers=None, data=None):
    # curl din macOS folosește certificatele sistemului (Python de pe python.org nu le are).
    import subprocess, tempfile
    cmd = ["curl", "-s", "-m", "20", "-w", "\n%{http_code}", url]
    for k, v in (headers or {}).items(): cmd += ["-H", f"{k}: {v}"]
    if data is not None:
        f = tempfile.NamedTemporaryFile(delete=False); f.write(data); f.close()
        cmd += ["-X", "POST", "--data-binary", "@" + f.name]
    out = subprocess.run(cmd, capture_output=True).stdout
    body, _, code = out.rpartition(b"\n")
    try: return int(code), body
    except ValueError: return 0, out

def appstore():
    c, b = get("https://itunes.apple.com/lookup?bundleId=com.google.ios.youtube&country=us")
    try: return json.loads(b)["results"][0]["version"]
    except Exception: return None

def player(name, cid, ver, ua, extra):
    client = {"clientName": name, "clientVersion": ver, "hl": "ro", "gl": "RO", **extra}
    body = json.dumps({"context": {"client": client}, "videoId": VID,
                       "contentCheckOk": True, "racyCheckOk": True}).encode()
    h = {"Content-Type": "application/json", "User-Agent": ua,
         "X-YouTube-Client-Name": str(cid), "X-YouTube-Client-Version": ver}
    code, b = get("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", h, body)
    label = f"{name} {ver}"
    try: o = json.loads(b)
    except Exception:
        print(f"{label:28} HTTP {code}  răspuns ne-JSON: {b[:120]!r}"); return
    if "error" in o:
        print(f"{label:28} HTTP {code}  EROARE: {o['error'].get('message')}"); return
    ps = o.get("playabilityStatus", {})
    sd = o.get("streamingData", {})
    fm = sd.get("adaptiveFormats", []) + sd.get("formats", [])
    direct = [f for f in fm if "url" in f]
    mh = max([f.get("height", 0) for f in fm] or [0])
    print(f"{label:28} HTTP {code}  status={ps.get('status')}  HLS={'da' if sd.get('hlsManifestUrl') else 'nu'}"
          f"  formate={len(fm)} (directe {len(direct)})  max={mh}p  {ps.get('reason','') or ''}")
    if direct and "--detail" in sys.argv:
        seen = set()
        for f in sorted(direct, key=lambda f: (f.get("height", 0), f.get("bitrate", 0)), reverse=True):
            mime = f.get("mimeType", "")
            key = (f.get("height"), mime.split(";")[0], mime.split('codecs="')[-1][:4])
            if key in seen: continue
            seen.add(key)
            c3, b3 = get(f["url"], {"User-Agent": ua, "Range": "bytes=0-65535"})
            kind = (f"{f.get('height')}p{f.get('fps','')}" if "video" in mime else f"audio {f.get('bitrate',0)//1000}k")
            print(f"{'':28}   itag {f.get('itag'):>3} {kind:12} {mime[:42]:42} -> HTTP {c3}, {len(b3)} octeți")
    if direct and "--open" in sys.argv:
        # Cum citește VLC: cerere fără capăt (bytes=0-) — câți octeți vin în 8 secunde?
        import subprocess
        for f in direct:
            if f.get("itag") in (337, 701, 335, 299, 140):
                out = subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "8", "-H", f"User-Agent: {ua}",
                                      "-H", "Range: bytes=0-", "-w", "%{http_code} %{size_download} %{speed_download}", f["url"]],
                                     capture_output=True, text=True).stdout.split()
                if len(out) == 3:
                    print(f"{'':28}   itag {f['itag']:>3} bytes=0- -> HTTP {out[0]}, {int(out[1])//1024} KB în 8 s, "
                          f"{float(out[2])*8/1e6:.1f} Mbit/s")
    if sd.get("hlsManifestUrl"):
        c2, m = get(sd["hlsManifestUrl"], {"User-Agent": ua})
        res = sorted({l.split("RESOLUTION=")[1].split(",")[0] for l in m.decode(errors="ignore").splitlines() if "RESOLUTION=" in l},
                     key=lambda r: int(r.split("x")[1]), reverse=True)
        print(f"{'':28} manifest HTTP {c2}: {', '.join(res[:8])}")

print(f"Video: {VID}")
av = appstore()
print(f"YouTube iOS în App Store: {av}")
for v in [x for x in [av, "20.10.4", "19.45.4"] if x]:
    player("IOS", 5, v, f"com.google.ios.youtube/{v} (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
           {"deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"})
player("ANDROID_VR", 28, "1.65.10",
       "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
       {"deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"})
player("MWEB", 2, "2.20250910.01.00",
       "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1", {})
player("TVHTML5", 7, "7.20250910.13.00",
       "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", {})
