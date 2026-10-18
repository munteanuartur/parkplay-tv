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

1. Deschide `TV/ParkPlayTV.xcodeproj`. Dacă ai instalat VLC pentru testul 4K (vezi mai jos), deschide în schimb `ParkPlayTV.xcworkspace`.
2. Target **ParkPlayTV** → **Signing & Capabilities** → alege Team-ul.
3. Alege Apple TV-ul ca destinație → **Run (⌘R)**.

Cu un Apple ID gratuit, aplicația expiră după 7 zile și trebuie reinstalată din Xcode. Cu contul de dezvoltator (99 $/an), ține un an.

## Cont YouTube („Sign in to confirm you're not a bot”)

Uneori YouTube refuză redarea pe Apple TV și cere login (LOGIN_REQUIRED): video-ul rămâne negru, cu spinner, iar în Diagnostic → „Ultimul eveniment” apare eroarea. Pe Mac merge în aceeași rețea, deci blocajul e doar pe TV. Soluția: trimiți pe TV cookie-urile unui cont YouTube logat.

1. Chrome → instalează extensia **Get cookies.txt LOCALLY** → `chrome://extensions` → Details → activează **Allow in Incognito**.
2. Deschide o fereastră **Incognito** (⇧⌘N), intră pe **youtube.com** și loghează-te (de preferat cu un cont secundar).
3. Pe pagina YouTube: iconița extensiei → format **Netscape** → **Copy**.
4. Pe TV: Setări → pornește **Pagina de sincronizare**. Pe Mac, într-o fereastră normală, deschide adresa afișată (`http://IP:8080`).
5. Lipește textul în „Cont YouTube” → **🔑 Conectează pe Apple TV**. Video-ul curent se reîncarcă singur.
6. Închide fereastra Incognito **fără** „Deconectare” din YouTube (altfel Google invalidează și sesiunea de pe TV).

Fără extensie: în fereastra Incognito logată, ⌥⌘I → **Network** → ⌘R → click pe prima cerere (`www.youtube.com`) → Request Headers → copiază valoarea **cookie:** și lipește-o la pasul 5. Se acceptă și JSON exportat din **Cookie-Editor**.

Starea se vede în Setări → Cont YouTube (conectat / neconectat); tot acolo e butonul de deconectare. WebKit păstrează sesiunea între reporniri. Dacă YouTube cere iar login, aplicația afișează un mesaj: repeți pașii 2–5 cu cookie-uri noi.

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
