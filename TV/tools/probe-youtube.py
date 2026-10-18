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
    if direct and "--deep" in sys.argv:
        # Merge și mai departe în fișier, nu doar la început? (bucăți de 1 MB, ca un player)
        for f in direct:
            if f.get("itag") not in (299, 137, 140): continue
            total = int(f.get("contentLength", "0") or 0)
            res = []
            for frac in (0, 0.05, 0.15, 0.3, 0.5, 0.8, 0.98):
                a = int(total * frac); b = min(a + (1 << 20) - 1, total - 1)
                c4, b4 = get(f["url"], {"User-Agent": ua, "Range": f"bytes={a}-{b}"})
                res.append(f"{int(frac*100)}%:{c4}")
            seq_ok = 0
            for i in range(30):   # 30 MB la rând, ca la redare
                a = i << 20
                if a >= total: break
                c5, _ = get(f["url"], {"User-Agent": ua, "Range": f"bytes={a}-{a + (1 << 20) - 1}"})
                if c5 != 206: break
                seq_ok += 1
            print(f"{'':28}   itag {f['itag']:>3} ({total >> 20} MB): {'  '.join(res)}  · la rând: {seq_ok} MB OK"
                  + ("" if seq_ok >= min(30, total >> 20) else f" (apoi HTTP {c5})"))
    if direct and "--time" in sys.argv and name == "IOS":
        # Limita e după poziție (secunde de conținut) sau crește cu timpul?
        import time
        f = next((x for x in direct if x.get("itag") == 299), None) or next((x for x in direct if x.get("itag") == 137), None)
        if f:
            total = int(f.get("contentLength", "0")); dur = int(f.get("approxDurationMs", "1")) / 1000
            bps = total / dur
            def at(sec, url=f["url"]):
                a = int(sec * bps); c, _ = get(url, {"User-Agent": ua, "Range": f"bytes={a}-{a + (512 << 10) - 1}"}); return c
            print(f"{'':28}   itag {f['itag']}: {dur:.0f} s, {bps*8/1e6:.1f} Mbit/s")
            print(f"{'':28}   A) prima cerere direct la 120 s: HTTP {at(120)}")
            # adrese noi pentru B
            body = json.dumps({"context": {"client": {"clientName": name, "clientVersion": ver, "hl": "ro", "gl": "RO", **extra}},
                               "videoId": VID, "contentCheckOk": True, "racyCheckOk": True}).encode()
            h = {"Content-Type": "application/json", "User-Agent": ua, "X-YouTube-Client-Name": str(cid), "X-YouTube-Client-Version": ver}
            _, b2 = get("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", h, body)
            o2 = json.loads(b2); fs = o2["streamingData"]["adaptiveFormats"]
            u2 = next(x["url"] for x in fs if x.get("itag") == f["itag"])
            t0 = time.time()
            print(f"{'':28}   B) adrese noi: 0 s:{at(0, u2)}  50 s:{at(50, u2)}  90 s:{at(90, u2)}  150 s:{at(150, u2)}")
            for wait in (30, 30):
                time.sleep(wait)
                el = time.time() - t0
                print(f"{'':28}      după {el:.0f} s: 90 s:{at(90, u2)}  150 s:{at(150, u2)}  {int(60+el)} s:{at(60+el, u2)}")
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
