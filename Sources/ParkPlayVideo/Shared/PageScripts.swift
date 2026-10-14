import Foundation

/// Scripturile puse în pagina YouTube și regulile de blocare a reclamelor — aceleași pe Mac și
/// pe Apple TV (amândouă folosesc WebKit). Autor: arturm
enum PageScripts {

    // MARK: - Blocare reclame: regulile de rețea (WebKit content blocker)

    private static let blockedHosts = [
        "doubleclick.net",
        "googleadservices.com",
        "googlesyndication.com",
        "adservice.google.com",
        "imasdk.googleapis.com",
        "google-analytics.com",
    ]

    private static let blockedPaths = [
        "/pagead/",
        "/api/stats/ads",
        "/api/stats/qoe?adformat",
        "/ptracking",
        "/get_midroll_",
        "/pcs/activeview",
        "/youtubei/v1/player/ad_break",
    ]

    private static func esc(_ s: String) -> String {
        var out = ""
        for c in s {
            if ".?*+()[]{}|^$\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Regulile de rețea în formatul WebKit (content blocker).
    static var adBlockRules: String {
        var rules: [[String: Any]] = []
        for h in blockedHosts {
            rules.append([
                "trigger": ["url-filter": "^https?://([^/]+\\.)?" + esc(h) + "[/:]"],
                "action": ["type": "block"],
            ])
        }
        for host in ["youtube.com", "google.com"] {
            for p in blockedPaths {
                rules.append([
                    "trigger": ["url-filter": "^https?://([^/]+\\.)?" + esc(host) + ".*" + esc(p)],
                    "action": ["type": "block"],
                ])
            }
        }
        let d = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: - Scriptlet json-prune (scoate reclamele din datele playerului)

    static let adBlock = """
    (function(){
      if (window.__ppAdBlock) return;
      window.__ppAdBlock = true;
      var KEYS = ['adPlacements','adSlots','playerAds','adBreakHeartbeatParams'];
      function prune(o){
        try {
          if (!o || typeof o !== 'object') return o;
          for (var i = 0; i < KEYS.length; i++) { if (KEYS[i] in o) delete o[KEYS[i]]; }
          if (o.playerResponse) prune(o.playerResponse);
          if (Array.isArray(o)) o.forEach(function(x){ if (x && x.playerResponse) prune(x.playerResponse); });
        } catch (e) {}
        return o;
      }
      var origParse = JSON.parse;
      JSON.parse = function(){ return prune(origParse.apply(this, arguments)); };
      if (window.Response && Response.prototype.json) {
        var origJson = Response.prototype.json;
        Response.prototype.json = function(){ return origJson.apply(this, arguments).then(prune); };
      }
      ['ytInitialPlayerResponse'].forEach(function(name){
        var val;
        try {
          Object.defineProperty(window, name, {
            configurable: true,
            get: function(){ return val; },
            set: function(v){ val = prune(v); }
          });
        } catch (e) {}
      });
    })();
    """

    // MARK: - Puntea cu aplicația (player pe toată pagina, stare, calitate, statistici, AirPlay)

    static let bridge = """
    (function(){
      if (window.__ppMedia) return;
      window.__ppMedia = true;

      // Trafic: numărăm octeții primiți de pagină (fluxurile video vin prin fetch + ReadableStream).
      window.__ppBytes = window.__ppBytes || 0;
      function addBytes(n){ if (n > 0) window.__ppBytes += n; }
      try {
        var RP = window.ReadableStreamDefaultReader && ReadableStreamDefaultReader.prototype;
        if (RP && RP.read && !RP.__ppHooked) {
          var origRead = RP.read;
          RP.read = function(){
            return origRead.apply(this, arguments).then(function(r){
              try { if (r && r.value && r.value.byteLength) addBytes(r.value.byteLength); } catch (e) {}
              return r;
            });
          };
          RP.__ppHooked = true;
        }
        var BP = window.Response && Response.prototype;
        if (BP && BP.arrayBuffer && !BP.__ppHooked) {
          var origAB = BP.arrayBuffer;
          BP.arrayBuffer = function(){ return origAB.apply(this, arguments).then(function(b){ try { addBytes(b.byteLength); } catch (e) {} return b; }); };
          var origText = BP.text;
          BP.text = function(){ return origText.apply(this, arguments).then(function(t){ try { addBytes(t.length); } catch (e) {} return t; }); };
          BP.__ppHooked = true;
        }
        var XP = window.XMLHttpRequest && XMLHttpRequest.prototype;
        if (XP && !XP.__ppHooked) {
          var origSend = XP.send;
          XP.send = function(){
            this.addEventListener('loadend', function(){
              try {
                var r = this.response, n = 0;
                if (r && r.byteLength) n = r.byteLength;
                else if (r && r.size) n = r.size;
                else if (typeof r === 'string') n = r.length;
                addBytes(n);
              } catch (e) {}
            });
            return origSend.apply(this, arguments);
          };
          XP.__ppHooked = true;
        }
      } catch (e) {}
      if (typeof window.__ppWant === 'undefined') window.__ppWant = true;
      var post = function(o){ try { window.webkit.messageHandlers.pp.postMessage(o); } catch (e) {} };
      var PPair = function(v){ post({t:'air', avail: !!window.__ppAirAvail, on: !!v.webkitCurrentPlaybackTargetIsWireless}); };
      var PP = {
        onState: function(p, pos, d, ad, buf){ post({t:'state', p:p, pos:pos, d:d, ad:ad, buf:buf}); },
        onEnded: function(){ post({t:'ended'}); },
        onVideoSize: function(w, h){ post({t:'size', w:w, h:h}); },
        onQualities: function(l, c){ post({t:'q', l:l, c:c}); }
      };
      try {
        Object.defineProperty(document, 'hidden', {get: function(){ return false; }});
        Object.defineProperty(document, 'visibilityState', {get: function(){ return 'visible'; }});
      } catch (e) {}
      document.addEventListener('visibilitychange', function(e){ e.stopImmediatePropagation(); }, true);

      var CSS = 'html,body{background:#000!important;overflow:hidden!important;margin:0!important}' +
        'body *{visibility:hidden!important}' +
        '#player-container-id,#player-container-id *,.player-container,.player-container *,#movie_player,#movie_player *{visibility:visible!important}' +
        '#movie_player{position:fixed!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;max-height:none!important;z-index:2147483646!important;background:#000!important}' +
        '.html5-video-container{position:absolute!important;left:0!important;top:0!important;width:100%!important;height:100%!important;background:#000!important}' +
        'video{position:fixed!important;object-fit:contain!important;z-index:2147483647!important;visibility:visible!important;background:#000!important}' +
        '.ytp-chrome-top,.ytp-chrome-bottom,.ytp-gradient-top,.ytp-gradient-bottom,#player-control-overlay,.player-controls-background,.player-controls-content,.player-controls-top,ytm-custom-control,.ytp-pause-overlay,.ytp-ce-element,.ytp-endscreen-content,.ytp-paid-content-overlay,.ytp-watermark,.ytp-cards-teaser,.ytp-spinner,.ytp-large-play-button,.ytp-cued-thumbnail-overlay,.ytm-autonav-bar,.ytp-ad-overlay-container,.ytp-caption-window-container,.ytp-contextmenu,.ytp-tooltip,.ytp-autonav-endscreen,.ytp-suggested-action,.ytp-overlay-bottom-right,.ytp-player-content{display:none!important}' +
        // Subtitrări: ascunse, cu excepția cazului în care aplicația le pornește (clasa pp-cc pe <html>).
        'html.pp-cc .ytp-caption-window-container{display:block!important;z-index:2147483647!important}' +
        'html.pp-cc .ytp-caption-segment{font-size:calc(var(--pp-cc-size,1) * 3.2vh)!important;background:rgba(0,0,0,.7)!important}';
      function css(){
        if (document.getElementById('pp-video-css')) return;
        var h = document.head || document.documentElement;
        if (!h) return;
        var s = document.createElement('style');
        s.id = 'pp-video-css';
        s.textContent = CSS;
        h.appendChild(s);
      }

      // Un părinte cu transform / filter / contain face ca „position:fixed” să fie relativ la el.
      function unbox(v){
        var n = v.parentElement;
        while (n && n !== document.documentElement) {
          try {
            var cs = getComputedStyle(n);
            if (cs.transform !== 'none' || cs.filter !== 'none' || cs.perspective !== 'none' ||
                (cs.contain && cs.contain !== 'none') || (cs.willChange || '').indexOf('transform') >= 0) {
              n.style.setProperty('transform', 'none', 'important');
              n.style.setProperty('filter', 'none', 'important');
              n.style.setProperty('perspective', 'none', 'important');
              n.style.setProperty('contain', 'none', 'important');
              n.style.setProperty('will-change', 'auto', 'important');
            }
          } catch (e) {}
          n = n.parentElement;
        }
        if (window.scrollY) window.scrollTo(0, 0);
      }
      // Video-ul încadrat întreg (centrat) în fereastră, după dimensiunea lui reală.
      function fit(v){
        try {
          var W = window.innerWidth, H = window.innerHeight;
          var vw = v.videoWidth || 16, vh = v.videoHeight || 9;
          var s = Math.min(W / vw, H / vh);
          var w = Math.round(vw * s), h = Math.round(vh * s);
          var st = {
            position: 'fixed', left: Math.round((W - w) / 2) + 'px', top: Math.round((H - h) / 2) + 'px',
            right: 'auto', bottom: 'auto', width: w + 'px', height: h + 'px',
            'max-width': 'none', 'max-height': 'none', 'min-width': '0', 'min-height': '0',
            margin: '0', padding: '0', 'object-fit': 'fill', transform: 'none',
            'z-index': '2147483647', visibility: 'visible', display: 'block'
          };
          for (var k in st) {
            if (v.style.getPropertyValue(k) !== st[k] || v.style.getPropertyPriority(k) !== 'important') {
              v.style.setProperty(k, st[k], 'important');
            }
          }
          var key = (v.videoWidth || 0) + 'x' + (v.videoHeight || 0);
          if (v.videoWidth && v.videoHeight && key !== window.__ppSize) {
            window.__ppSize = key;
            PP.onVideoSize(v.videoWidth, v.videoHeight);
          }
        } catch (e) {}
      }
      // Pe paginile cu mai multe video-uri îl alegem pe cel care chiar rulează.
      function activeVideo(vs){
        var main = document.querySelector('video.html5-main-video');
        if (main) return main;
        var best = null;
        for (var i = 0; i < vs.length; i++) {
          var x = vs[i];
          if (!x.paused && x.currentTime > 0) return x;
          if (!best || x.readyState > best.readyState) best = x;
        }
        return best;
      }

      var last = 0;
      function isAd(){ return !!document.querySelector('.ad-showing, .ad-interrupting'); }
      function report(v, t){
        try {
          if (t === 'ended') { if (!isAd()) PP.onEnded(); return; }
          var d = isFinite(v.duration) ? v.duration : 0;
          var buf = !v.paused && v.readyState < 3;
          PP.onState(!v.paused, v.currentTime || 0, d, isAd(), buf);
        } catch (e) {}
      }

      // Calitatea: raportăm nivelurile disponibile și o aplicăm pe cea aleasă.
      var ORDER = ['hd2160','hd1440','hd1080','hd720','large','medium','small','tiny'];
      var lastKey = '';
      function quality(){
        try {
          var mp = document.getElementById('movie_player');
          if (!mp || !mp.getAvailableQualityLevels) return;
          var lv = (mp.getAvailableQualityLevels() || []).filter(function(q){ return q !== 'auto'; });
          var cur = mp.getPlaybackQuality ? (mp.getPlaybackQuality() || '') : '';
          var key = lv.join(',') + '|' + cur;
          if (key !== lastKey) { lastKey = key; PP.onQualities(lv, cur); }
          if (typeof window.__ppQ !== 'string') return;
          var want = window.__ppQ;
          var now = Date.now();
          if (want === 'auto') {
            if (window.__ppQSet !== 'auto') {
              window.__ppQSet = 'auto';
              if (mp.setPlaybackQualityRange) mp.setPlaybackQualityRange('auto', 'auto');
            }
            return;
          }
          if (!lv.length) return;
          var target = null;
          if (lv.indexOf(want) >= 0) target = want;
          else {
            for (var i = Math.max(ORDER.indexOf(want), 0); i < ORDER.length; i++) {
              if (lv.indexOf(ORDER[i]) >= 0) { target = ORDER[i]; break; }
            }
            if (!target) target = lv[lv.length - 1];
          }
          if (window.__ppQSet !== target || (cur !== target && now - (window.__ppQAt || 0) > 5000)) {
            window.__ppQSet = target;
            window.__ppQAt = now;
            if (mp.setPlaybackQualityRange) mp.setPlaybackQualityRange(target, target);
            if (mp.setPlaybackQuality) mp.setPlaybackQuality(target);
          }
        } catch (e) {}
      }

      // YouTube pornește uneori cu sunetul oprit; îl activăm.
      // Volumul ales în aplicație (__ppVol 0…1, __ppMute) — pe Apple TV nu se folosește.
      function unmute(v){
        if (!v) return;
        try {
          if (window.__ppMute === true) { if (!v.muted) v.muted = true; return; }
          if (typeof window.__ppVol === 'number' && Math.abs(v.volume - window.__ppVol) > 0.01) v.volume = window.__ppVol;
          if (!window.__ppWant) return;
          if (v.muted) v.muted = false;
          var mp = document.getElementById('movie_player');
          if (mp && mp.isMuted && mp.isMuted()) { mp.unMute(); }
        } catch (e) {}
      }
      // AirPlay: YouTube poate interzice redarea la distanță; o permitem și raportăm starea.
      function air(v){ PPair(v); }
      function hook(v){
        if (v.__pp) return;
        v.__pp = true;
        try {
          v.disableRemotePlayback = false;
          v.setAttribute('x-webkit-airplay', 'allow');
        } catch (e) {}
        v.addEventListener('webkitplaybacktargetavailabilitychanged', function(e){
          window.__ppAirAvail = e.availability === 'available';
          air(v);
        });
        v.addEventListener('webkitcurrentplaybacktargetiswirelesschanged', function(){ air(v); });
        ['playing','loadeddata'].forEach(function(t){
          v.addEventListener(t, function(){ unmute(v); });
        });
        ['play','playing','pause','ended','durationchange','loadedmetadata','waiting','canplay','seeked'].forEach(function(t){
          v.addEventListener(t, function(){ report(v, t); });
        });
        v.addEventListener('timeupdate', function(){
          var n = Date.now();
          if (n - last > 500) { last = n; report(v, 'time'); }
        });
      }
      // YouTube trece singur la următorul video (autoplay-ul lui); lista o conduce aplicația.
      // Statistici o dată pe secundă (doar când panoul e deschis în aplicație).
      var sLast = 0, sBytes = 0, sFrames = -1;
      setInterval(function(){
        if (!window.__ppStats) { sFrames = -1; return; }
        try {
          var now = performance.now();
          var dt = sLast ? (now - sLast) / 1000 : 0;
          var v = document.querySelector('video.html5-main-video') || document.querySelector('video');
          var o = {t:'stats', bytes: window.__ppBytes, kbps: 0, fps: 0, dropped: 0, frames: 0, vw: 0, vh: 0, buf: 0,
                   ww: window.innerWidth, wh: window.innerHeight, dpr: window.devicePixelRatio || 1};
          if (dt > 0) o.kbps = (window.__ppBytes - sBytes) * 8 / 1000 / dt;
          if (v) {
            o.vw = v.videoWidth; o.vh = v.videoHeight;
            var total = 0, dropped = 0;
            if (v.getVideoPlaybackQuality) {
              var q = v.getVideoPlaybackQuality();
              total = q.totalVideoFrames || 0; dropped = q.droppedVideoFrames || 0;
            } else if (typeof v.webkitDecodedFrameCount === 'number') {
              total = v.webkitDecodedFrameCount; dropped = v.webkitDroppedFrameCount || 0;
            }
            o.frames = total; o.dropped = dropped;
            var shown = total - dropped;
            if (dt > 0 && sFrames >= 0 && shown >= sFrames) o.fps = (shown - sFrames) / dt;
            sFrames = shown;
            try {
              for (var i = 0; i < v.buffered.length; i++) {
                if (v.buffered.start(i) <= v.currentTime + 0.5 && v.buffered.end(i) >= v.currentTime) o.buf = v.buffered.end(i) - v.currentTime;
              }
            } catch (e) {}
          }
          var mp = document.getElementById('movie_player');
          if (mp && mp.getStatsForNerds) {
            var n = mp.getStatsForNerds() || {};
            o.conn = n.bandwidth_kbps || '';
            o.codecs = n.codecs || '';
            o.frameInfo = n.dims_and_frames || n.resolution || '';
            o.netAct = n.network_activity_bytes || '';
          }
          sLast = now; sBytes = window.__ppBytes;
          post(o);
        } catch (e) {}
      }, 1000);

      function noAutonav(){
        try {
          var b = document.querySelector('.ytp-autonav-toggle-button[aria-checked="true"]');
          if (b) b.click();
        } catch (e) {}
      }
      setInterval(function(){
        css();
        var vs = document.querySelectorAll('video');
        vs.forEach(hook);
        var v = activeVideo(vs);
        if (v) {
          unbox(v);
          fit(v);
          for (var j = 0; j < vs.length; j++) {
            if (vs[j] !== v) vs[j].style.setProperty('visibility', 'hidden', 'important');
          }
        }
        // Rezervă: dacă totuși rulează o reclamă, o punem pe mut și o sărim la final.
        if (v && isAd()) {
          v.muted = true;
          if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.3) {
            try { v.currentTime = v.duration - 0.1; } catch (e) {}
          }
        } else {
          unmute(v);
          quality();
          noAutonav();
          var r = window.__ppRate || 1;
          if (v && Math.abs(v.playbackRate - r) > 0.01) { try { v.playbackRate = r; } catch (e) {} }
        }
        if (v && window.__ppWant && v.paused && !v.ended && v.readyState >= 1) {
          var p = v.play(); if (p && p.catch) p.catch(function(){});
        }
        if (v && !window.__ppWant && !v.paused) { try { v.pause(); } catch (e) {} }
        var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        if (skip) skip.click();
      }, 500);
    })();
    """
}
