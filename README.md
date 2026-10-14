# ParkPlay TV

**YouTube without ads on Apple TV** — a native tvOS app (SwiftUI) that plays YouTube in a hidden web view, with its own remote-friendly interface.

- **Home:** continue watching (with the red progress bar), Daily Mixes, For you, trending, categories
- **Search** with filters (today / week / month / year, newest, most viewed), recent searches
- **Library:** favorites, history, now playing, playlists, ParkPlay Wrapped (your stats)
- **Player:** YouTube-style scrubbing with thumbnails, resume where you left off, subtitles (+ auto-translate), speed, 📻 Radio (endless similar videos), up-next queue, Autoplay, SponsorBlock
- **Sync page** on your network (`http://<apple-tv-ip>:8080`): import / export backups, send a YouTube link to the TV
- Stops completely in the background, so the Apple TV can sleep

> Not on the App Store: the app loads WebKit through a **private API** (tvOS has no public web view), so it is installed from Xcode with your own Apple ID. Playback uses the m.youtube page (HLS), up to **1080p**.

## Requirements

- A Mac with **Xcode** (latest) and your Apple ID in Xcode → Settings → Accounts (a free one works)
- **CocoaPods** (`brew install cocoapods`) — used for the optional VLC-based 4K test
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

**Pe scurt, în română:** aplicație tvOS care redă YouTube fără reclame pe Apple TV. Ai nevoie de un Mac cu Xcode și Apple ID-ul tău. `cd TV && pod install && open ParkPlayTV.xcworkspace`, alegi Team-ul și un Bundle Identifier propriu, apoi ⌘R. Cu Apple ID gratuit expiră la 7 zile; `TV/tools/auto-reinstall.sh` o reinstalează automat (detalii în `TV/README.md`).
