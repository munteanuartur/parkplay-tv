# ParkPlay TV — YouTube fără reclame pe Apple TV

Autor: arturm. Folosește aceleași scripturi (`Sources/ParkPlayVideo/Shared/PageScripts.swift`) și aceleași date ca versiunea de Mac și cea de Android: favorite, istoric, playlisturi, statistici și backup.

- **Acasă:** Continuă, Mixurile tale (Daily Mix), Pentru tine, Din favorite, Hituri, Noutăți, Muzică românească, Categorii
- **Caută:** filtre (azi / săptămână / lună / an, cele mai noi, cele mai vizionate), căutări recente, categorii
- **Bibliotecă:** Favorite, Istoric, În redare, Playlisturi (creezi, redenumești, ștergi, scoți video-uri) și ParkPlay Wrapped
- **Player:** ⏯, ∓10 s, ❤, adaugi în playlist, calitate, viteză, lista „Urmează”, Autoplay, SponsorBlock, panou Diagnostic (FPS, trafic, reclame sărite)
- **Ține apăsat pe orice video:** Redă acum, Redă după acesta, Adaugă la coadă, Favorite, Adaugă în playlist
- **Sincronizare:** Setări → Sincronizare pornește o pagină web pe Apple TV (`http://IP:8080`). O deschizi pe telefon sau Mac ca să importi backup-ul ParkPlay, să descarci backup-ul de pe TV sau să trimiți un link YouTube care pornește pe televizor.

Redarea folosește pagina m.youtube într-un WKWebView încărcat prin **API privat**, deci aplicația se instalează doar din Xcode, nu din App Store. Pe Apple TV, YouTube dă cel mult **1080p** pe această cale: pagina desktop, care ar da 4K, cere MediaSource, iar WebKit-ul de pe tvOS nu îl are.

## Instalare

1. În folderul `TV`: `pod install` (o singură dată; CocoaPods: `brew install cocoapods`), apoi deschide `ParkPlayTV.xcworkspace` (nu `.xcodeproj`).
2. Target **ParkPlayTV** → **Signing & Capabilities** → alege Team-ul și pune un **Bundle Identifier** al tău (ex. `com.numeletau.parkplay.tv`). Pentru scripturi, scrie aceleași valori în `TV/tools/local.conf`: `TEAM_ID="…"` și `BUNDLE_ID="…"`.
3. Alege Apple TV-ul ca destinație → **Run (⌘R)**.

Cu un Apple ID gratuit, aplicația expiră după 7 zile și trebuie reinstalată din Xcode. Cu contul de dezvoltator (99 $/an), ține un an.

## Test 4K cu VLC (opțional)

Setări → Avansat → **Test 4K** cere de la YouTube fluxurile directe (clientul ANDROID_VR: VP9 / AV1, până la 4K) și le arată. Ca să le și redai, adaugi VLC:

```bash
brew install cocoapods     # o singură dată (CocoaPods 1.16 sau mai nou)
cd TV && pod install
open ParkPlayTV.xcworkspace
```

Apoi ⌘R. Fără VLC, aplicația merge normal; doar testul nu poate reda.

În player-ul de test, panoul arată rezoluția, FPS-ul afișat și cadrele pierdute. Dacă un flux 2160p VP9 rulează la ~60 fps fără cadre pierdute, 4K-ul poate deveni opțiune în player-ul principal.

## Telecomanda Siri în player

| Buton | Acțiune |
|---|---|
| ⏯ | redă / pauză |
| stânga / dreapta (cu controalele ascunse) | 10 s înapoi / înainte |
| click, sus, jos | arată controalele |
| Menu / Înapoi | închide lista / controalele, apoi player-ul |

## Iconiță

`ParkPlayTV/Assets.xcassets` are iconița stratificată pentru Apple TV (fundal + televizorul cu ▶, cu efect de paralaxă la focus) și imaginea pentru Top Shelf.

## Reinstalare automată (Apple ID gratuit = 7 zile)

```bash
cd TV/tools
bash reinstall-appletv.sh --force   # o dată acum, ca test
bash auto-reinstall.sh              # activează: Mac-ul verifică zilnic și reinstalează la 6 zile
bash auto-reinstall.sh --status     # starea + jurnalul
bash auto-reinstall.sh --remove     # oprește
```

Scriptul compilează cu `xcodebuild` (reînnoiește singur profilul de semnare) și instalează cu `xcrun devicectl`. Favoritele și playlisturile rămân. Condiții: Mac-ul pornit (sau trezit) la una din verificări, Xcode logat cu Apple ID-ul tău, Apple TV-ul în aceeași rețea și împerecheat. Jurnal: `~/Library/Logs/ParkPlayTV-reinstall.log`.
