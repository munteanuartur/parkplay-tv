# ParkPlay TV

**YouTube without ads on Apple TV** — a native tvOS app (SwiftUI) that plays YouTube in a hidden web view, with its own remote-friendly interface.

- **Home:** continue watching (with the red progress bar), Daily Mixes, For you, trending, categories
- **Search** with filters (today / week / month / year, newest, most viewed), recent searches
- **Library:** favorites, history, now playing, playlists, ParkPlay Wrapped (your stats)
- **Player:** YouTube-style scrubbing with thumbnails, resume where you left off, subtitles (+ auto-translate), speed, 📻 Radio (endless similar videos), up-next queue, Autoplay, SponsorBlock
- **Sync page** on your network (`http://<apple-tv-ip>:8080`): import / export backups, send a YouTube link to the TV, sign in to YouTube with cookies from your browser
- Stops completely in the background, so the Apple TV can sleep

> Not on the App Store: the app loads WebKit through a **private API** (tvOS has no public web view), so it is installed from Xcode with your own Apple ID. Playback goes up to **1080p** (see *How playback works*).

## How playback works

tvOS WebKit has no MediaSource, and YouTube no longer gives HLS to its mobile site — a plain web view only gets a single 360p file. ParkPlay TV works around it:

1. **Fake MediaSource** (`TV/ParkPlayTV/TVFakeMSE.swift`): a JavaScript MediaSource / SourceBuffer is injected into the YouTube page before its own scripts. YouTube's player believes it can do adaptive streaming, picks H.264 + AAC up to 1080p and streams them itself (SABR protocol, signed in with your account, its own anti-bot checks) — the app never deals with stream URLs.
2. **Native rendering** (`TVMSERenderer.swift`): every fMP4 chunk the player appends is sent to the app, unpacked (moov → format, moof/mdat → frames) and fed to Apple's `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` (hardware H.264 decoding). The renderer's clock is sent back to the page as `video.currentTime`, so YouTube's player buffers in step with real playback.
3. **Keep-alive**: tvOS suspends a web page that isn't playing real media, so the page loops one second of silence.
4. **Fallback**: if no data arrives within 15 s, the page reloads without the fake MediaSource (single 360p file).

Older approaches are still in Settings → Advanced → Diagnostic → *Old tests*: the InnerTube iOS client with AVPlayer / VLC (YouTube now limits it to the first minute and blocks it per IP). `TV/tools/probe-youtube.py` shows what each YouTube client gets from your network (`--detail`, `--open`, `--deep`, `--time`).

## Requirements

- A Mac with **Xcode** (latest) and your Apple ID in Xcode → Settings → Accounts (a free one works)
- **CocoaPods** (`brew install cocoapods`) — required: run `pod install` in `TV/` once after cloning (VLC for the old 4K test)
- An Apple TV (tvOS 17+) on the same network, paired with Xcode: Window → Devices and Simulators
  (on the Apple TV: Settings → Remotes and Devices → Remote App and Devices)

## Install

```bash
git clone https://github.com/<you>/parkplay-tv.git
cd parkplay-tv/TV
pod install
open ParkPlayTV.xcworkspace
```

In Xcode: target **ParkPlayTV** → **Signing & Capabilities** → choose your **Team** and change the **Bundle Identifier** to something of yours (e.g. `com.yourname.parkplay.tv`). Pick your Apple TV as the destination → **Run (⌘R)**.

### From the command line (and automatic reinstall)

Create `TV/tools/local.conf` (it's git-ignored):

```bash
TEAM_ID="ABCDE12345"                 # your Team ID (Xcode → Settings → Accounts → your Apple ID)
BUNDLE_ID="com.yourname.parkplay.tv"
```

Then:

```bash
bash TV/tools/reinstall-appletv.sh --force   # build + install now
bash TV/tools/auto-reinstall.sh              # reinstall automatically every 6 days (free Apple ID = 7-day signature)
bash TV/tools/auto-reinstall.sh --status
bash TV/tools/auto-reinstall.sh --remove
```

With a free Apple ID the app expires after **7 days**; the auto-reinstall keeps it alive while your Mac is on. With the paid Apple Developer Program it lasts a year.

## YouTube sign-in ("Sign in to confirm you're not a bot")

Sometimes YouTube refuses to play on the Apple TV and asks you to sign in (`LOGIN_REQUIRED`): the video stays black with a spinner, and Settings → Advanced → Diagnostic → "Ultimul eveniment" shows the YouTube error. Fix it by sending the cookies of a signed-in YouTube account to the TV:

1. In Chrome, install the **Get cookies.txt LOCALLY** extension, then `chrome://extensions` → Details → turn on **Allow in Incognito**.
2. Open an **Incognito** window (⇧⌘N), go to **youtube.com** and sign in (a secondary account is a good idea).
3. On the YouTube page: extension icon → format **Netscape** → **Copy**.
4. On the TV: Settings → turn on the **sync page**. On your Mac, in a normal window, open the address shown on the TV (`http://<apple-tv-ip>:8080`).
5. Paste into **Cont YouTube** → **🔑 Conectează pe Apple TV**. The current video reloads by itself.
6. Close the Incognito window **without** signing out of YouTube (signing out invalidates the session on the TV too).

Without the extension: in the signed-in Incognito window, ⌥⌘I → **Network** → ⌘R → click the first request (`www.youtube.com`) → Request Headers → copy the **cookie:** value and paste it in step 5. JSON exported from **Cookie-Editor** works too.

The status is in Settings → Cont YouTube (conectat / neconectat), along with a sign-out button. WebKit keeps the session across restarts. If YouTube asks again, the app shows a message — repeat steps 2–5 with fresh cookies.

## Project layout

```
TV/                      tvOS app (Xcode project, Podfile, scripts)
  ParkPlayTV/            app sources (SwiftUI + PPWebKit.m, the private WebKit bridge)
  tools/                 reinstall / auto-reinstall scripts
Sources/ParkPlayVideo/   shared code: YouTube search, page scripts (ad blocking, player bridge),
                         library, playlists, stats, backups
```

More details (in Romanian) in [TV/README.md](TV/README.md).

## Disclaimer

Personal, non-commercial project. Not affiliated with YouTube or Google. Blocking ads may go against YouTube's Terms of Service — use at your own risk.

---

**Pe scurt, în română:** aplicație tvOS care redă YouTube fără reclame pe Apple TV. Ai nevoie de un Mac cu Xcode și Apple ID-ul tău. `cd TV && pod install && open ParkPlayTV.xcworkspace`, alegi Team-ul și un Bundle Identifier propriu, apoi ⌘R. Cu Apple ID gratuit expiră la 7 zile; `TV/tools/auto-reinstall.sh` o reinstalează automat. Dacă YouTube cere „Sign in to confirm you're not a bot”, trimiți pe TV cookie-urile contului prin pagina de sincronizare (pașii în `TV/README.md`, secțiunea „Cont YouTube”).
