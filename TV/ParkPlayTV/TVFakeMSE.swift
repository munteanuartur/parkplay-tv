import Foundation

/// Experiment: un MediaSource „fals” pentru pagina YouTube din WebView.
/// WebKit-ul de pe tvOS n-are MediaSource, iar YouTube nu mai dă HLS site-ului mobil — rămâne doar 360p.
/// Dacă pagina crede că are MediaSource, player-ul YouTube cere formatele adaptive (până la 1080p H.264)
/// și ne dă bucățile video prin SourceBuffer.appendBuffer. Pasul 1 (acesta) doar MĂSOARĂ ce se întâmplă:
/// ce formate alege, câte date primește, ce fel de date sunt (fMP4?) și dacă cererile reușesc.
/// Rezultatul apare în Diagnostic → „MSE fals (test)”. Autor: arturm
enum FakeMSE {

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "fake_mse") }
        set { UserDefaults.standard.set(newValue, forKey: "fake_mse") }
    }

    /// Codul pus în pagină înaintea scripturilor YouTube.
    static let script = #"""
    (function(){
      if (window.__ppMSE) return;
      var S = window.__ppMSE = {created:0, attached:0, asked:[], types:[], buffers:[], appends:0, bytes:0,
                                net:{n:0, ok:0, bad:0, codes:{}, sabr:0, pot:0, sample:'', resp:[], ump:{}}, errors:[],
                                dbg:{ticks: 0, sets: 0, lastSet: '', adv: 0, stuck: '', awake: false}};
      // WebKit-ul de pe tvOS frânează temporizatoarele paginii (setTimeout / setInterval rulează rar).
      // Evenimentele MediaSource le trimitem ca microtask-uri, iar ceasul îl mișcă aplicația (__ppTick).
      function later(f){ Promise.resolve().then(f); }
      // Trimiterea către aplicație (redarea nativă a bucăților).
      function toApp(o){ try { window.webkit.messageHandlers.pp.postMessage(o); } catch (e) {} }
      function b64(u8){
        var s = '';
        for (var i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        return btoa(s);
      }
      function okType(t){
        t = String(t || '');
        if (S.asked.length < 30 && S.asked.indexOf(t) < 0) S.asked.push(t);
        // Doar ce poate decoda Apple TV în hardware: H.264 + AAC în mp4.
        if (/webm|vp0|vp9|av01|opus|ec-3|ac-3|hev|hvc/i.test(t)) return false;
        return /mp4/i.test(t);
      }
      // TimeRanges cu intervale reale (le calculăm din bucățile fMP4).
      function TR(list){ this._r = list || []; }
      Object.defineProperty(TR.prototype, 'length', {get: function(){ return this._r.length; }});
      TR.prototype.start = function(i){ if (i >= this._r.length) throw new DOMException('index', 'IndexSizeError'); return this._r[i][0]; };
      TR.prototype.end = function(i){ if (i >= this._r.length) throw new DOMException('index', 'IndexSizeError'); return this._r[i][1]; };
      function addRange(list, a, b){
        list.push([a, b]);
        list.sort(function(x, y){ return x[0] - y[0]; });
        var out = [];
        list.forEach(function(r){
          var l = out[out.length - 1];
          if (l && r[0] <= l[1] + 0.15) l[1] = Math.max(l[1], r[1]); else out.push([r[0], r[1]]);
        });
        return out;
      }
      function cutRange(list, a, b){
        var out = [];
        list.forEach(function(r){
          if (r[1] <= a || r[0] >= b) { out.push(r); return; }
          if (r[0] < a) out.push([r[0], a]);
          if (r[1] > b) out.push([b, r[1]]);
        });
        return out;
      }
      function ET(){ this._l = {}; }
      ET.prototype.addEventListener = function(t, f){ (this._l[t] = this._l[t] || []).push(f); };
      ET.prototype.removeEventListener = function(t, f){ var a = this._l[t] || []; var i = a.indexOf(f); if (i >= 0) a.splice(i, 1); };
      ET.prototype.dispatchEvent = function(e){
        var self = this, t = e.type;
        (this._l[t] || []).slice().forEach(function(f){ try { f.call(self, e); } catch (x) { if (S.errors.length < 5) S.errors.push(String(x)); } });
        var h = this['on' + t]; if (typeof h === 'function') { try { h.call(this, e); } catch (x) {} }
        return true;
      };
      function rd32(u, p){ return ((u[p] << 24) | (u[p+1] << 16) | (u[p+2] << 8) | u[p+3]) >>> 0; }
      function walk(u, s, e, cb){
        var p = s;
        while (p + 8 <= e) {
          var sz = rd32(u, p), h = 8;
          var ty = String.fromCharCode(u[p+4], u[p+5], u[p+6], u[p+7]);
          if (sz === 1) { sz = rd32(u, p + 8) * 4294967296 + rd32(u, p + 12); h = 16; }
          else if (sz === 0) sz = e - p;
          if (sz < h) break;
          cb(ty, p + h, Math.min(p + sz, e));
          p += sz;
        }
      }
      function boxes(u8){
        var out = [];
        walk(u8, 0, u8.length, function(t){ if (out.length < 5) out.push(/^[a-z0-9 ]{4}$/i.test(t) ? t : '?'); });
        return out.join(',') || ('octeți:' + u8.length);
      }
      // fMP4: din „moov” luăm scala de timp; din fiecare „moof” începutul (tfdt) și durata (trun).
      function parseMP4(sb, u){
        var segs = [];
        walk(u, 0, u.length, function(ty, s, e){
          if (ty === 'moov') {
            walk(u, s, e, function(t2, s2, e2){
              if (t2 === 'trak') walk(u, s2, e2, function(t3, s3, e3){
                if (t3 === 'mdia') walk(u, s3, e3, function(t4, s4){
                  if (t4 === 'mdhd') sb.ts = u[s4] === 1 ? rd32(u, s4 + 20) : rd32(u, s4 + 12);
                });
                if (t3 === 'tkhd') { var v = u[s3]; var q = s3 + (v === 1 ? 88 : 76); sb.w = rd32(u, q) / 65536; sb.h = rd32(u, q + 4) / 65536; }
              });
              if (t2 === 'mvex') walk(u, s2, e2, function(t3, s3){ if (t3 === 'trex') sb.defDur = rd32(u, s3 + 12); });
            });
            sb.init = true;
          }
          if (ty === 'moof') {
            var base = null, dur = 0, defDur = sb.defDur || 0;
            walk(u, s, e, function(t2, s2, e2){
              if (t2 !== 'traf') return;
              walk(u, s2, e2, function(t3, s3){
                var fl = (u[s3+1] << 16) | (u[s3+2] << 8) | u[s3+3];
                if (t3 === 'tfhd') { var q = s3 + 8; if (fl & 1) q += 8; if (fl & 2) q += 4; if (fl & 8) defDur = rd32(u, q); }
                if (t3 === 'tfdt') base = u[s3] === 1 ? rd32(u, s3 + 4) * 4294967296 + rd32(u, s3 + 8) : rd32(u, s3 + 4);
                if (t3 === 'trun') {
                  var n = rd32(u, s3 + 4), q2 = s3 + 8;
                  if (fl & 1) q2 += 4;
                  if (fl & 4) q2 += 4;
                  for (var i = 0; i < n; i++) {
                    if (fl & 0x100) { dur += rd32(u, q2); q2 += 4; } else dur += defDur;
                    if (fl & 0x200) q2 += 4;
                    if (fl & 0x400) q2 += 4;
                    if (fl & 0x800) q2 += 4;
                  }
                }
              });
            });
            if (base !== null && sb.ts) segs.push([base / sb.ts + sb.timestampOffset, (base + dur) / sb.ts + sb.timestampOffset]);
          }
        });
        return segs;
      }
      function SB(ms, type){
        ET.call(this);
        this.ms = ms; this.updating = false; this.r = []; this.mode = 'segments';
        this.timestampOffset = 0; this.appendWindowStart = 0; this.appendWindowEnd = Infinity;
        this.info = {type: type, n: 0, bytes: 0, first: '', range: ''};
        S.buffers.push(this.info);
      }
      SB.prototype = Object.create(ET.prototype);
      Object.defineProperty(SB.prototype, 'buffered', {get: function(){ return new TR(this.r.map(function(x){ return [x[0], x[1]]; })); }});
      SB.prototype.appendBuffer = function(d){
        var self = this;
        var u8 = d instanceof ArrayBuffer ? new Uint8Array(d) : new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
        self.info.n++; self.info.bytes += u8.length; S.appends++; S.bytes += u8.length;
        if (self.info.n <= 3) self.info.first += (self.info.first ? ' | ' : '') + boxes(u8);
        toApp({t: 'mse', k: /^video/.test(self.info.type) ? 'v' : 'a', d: b64(u8), o: self.timestampOffset || 0});
        try {
          parseMP4(self, u8).forEach(function(g){ self.r = addRange(self.r, g[0], g[1]); });
        } catch (x) { if (S.errors.length < 6) S.errors.push('parse: ' + x); }
        self.info.range = self.r.map(function(x){ return x[0].toFixed(1) + '–' + x[1].toFixed(1); }).join(' ');
        self.updating = true;
        later(function(){
          self.updating = false;
          self.dispatchEvent({type: 'update'}); self.dispatchEvent({type: 'updateend'});
          if (self.ms.el) mediaTick(self.ms.el);
        });
      };
      SB.prototype.remove = function(a, b){
        var self = this; self.updating = true;
        self.r = cutRange(self.r, a, b);
        later(function(){ self.updating = false; self.dispatchEvent({type: 'update'}); self.dispatchEvent({type: 'updateend'}); });
      };
      SB.prototype.abort = function(){};
      SB.prototype.changeType = function(t){ this.info.type += ' → ' + t; };
      function MS(){ ET.call(this); S.created++; this.readyState = 'closed'; this.sourceBuffers = []; this.activeSourceBuffers = []; this.duration = NaN; }
      MS.prototype = Object.create(ET.prototype);
      MS.isTypeSupported = okType;
      MS.canConstructInDedicatedWorker = false;
      MS.prototype.addSourceBuffer = function(t){ S.types.push(t); var sb = new SB(this, t); this.sourceBuffers.push(sb); this.activeSourceBuffers.push(sb); return sb; };
      MS.prototype.removeSourceBuffer = function(){};
      MS.prototype.endOfStream = function(){ this.readyState = 'ended'; };
      MS.prototype.setLiveSeekableRange = function(){};
      MS.prototype.clearLiveSeekableRange = function(){};
      // 1080p: player-ul YouTube alege calitatea și după ce crede că poate decoda / afișa dispozitivul.
      // Îi spunem ce poate de fapt Apple TV: ecran 1920×1080, decodare H.264 fluidă.
      S.screenBefore = (window.screen ? screen.width + '×' + screen.height : '?') + ' @' + (window.devicePixelRatio || 1) + 'x, fereastră ' + innerWidth + '×' + innerHeight;
      try {
        if (window.screen && screen.width < 1920) {
          Object.defineProperty(screen, 'width', {get: function(){ return 1920; }});
          Object.defineProperty(screen, 'height', {get: function(){ return 1080; }});
          Object.defineProperty(screen, 'availWidth', {get: function(){ return 1920; }});
          Object.defineProperty(screen, 'availHeight', {get: function(){ return 1080; }});
        }
      } catch (e) { S.errors.push('ecran: ' + e); }
      try {
        var mc = navigator.mediaCapabilities;
        if (mc && mc.decodingInfo) {
          var origDI = mc.decodingInfo.bind(mc);
          mc.decodingInfo = function(cfg){
            var ct = (cfg && cfg.video && cfg.video.contentType) || (cfg && cfg.audio && cfg.audio.contentType) || '';
            S.di = (S.di || 0) + 1;
            if (okType(ct)) return Promise.resolve({supported: true, smooth: true, powerEfficient: true});
            if (cfg && cfg.type === 'media-source') return Promise.resolve({supported: false, smooth: false, powerEfficient: false});
            return origDI(cfg);
          };
        }
      } catch (e) { S.errors.push('mediaCapabilities: ' + e); }
      // Calitatea preferată salvată de site (ca atunci când alegi 1080p în meniul YouTube).
      try {
        var now = Date.now();
        localStorage.setItem('yt-player-quality', JSON.stringify({data: JSON.stringify({quality: 1080, previousQuality: 720}), expiration: now + 31536e6, creation: now}));
      } catch (e) {}
      try {
        window.MediaSource = MS; window.ManagedMediaSource = MS; window.WebKitMediaSource = MS; window.SourceBuffer = SB;
      } catch (e) { S.errors.push('instalare: ' + e); }

      // blob: pentru MediaSource-ul nostru → îl „atașăm” noi la <video>
      var map = {}, nBlob = 0, origCreate = URL.createObjectURL;
      URL.createObjectURL = function(o){
        if (o instanceof MS) { var u = 'blob:' + location.origin + '/ppfake-' + (++nBlob); map[u] = o; return u; }
        return origCreate.apply(URL, arguments);
      };
      var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      function attach(el, v){
        var ms = map[v];
        if (!ms) return false;
        el.__ppFake = v; ms.readyState = 'open'; S.attached++;
        ms.el = el; el.__ppMS = ms;
        el.__ppS = {t: 0, paused: true, rs: 0, seeking: false, ended: false, rate: 1, meta: false, playing: false, waiting: false};
        window.__ppNT = undefined;
        toApp({t: 'mse-reset'});
        if (fakes.indexOf(el) < 0) fakes.push(el);
        keepAwake();
        later(function(){ ms.dispatchEvent({type: 'sourceopen'}); });
        return true;
      }
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true,
        get: function(){ return this.__ppFake || desc.get.call(this); },
        set: function(v){ if (!attach(this, v)) { this.__ppFake = null; desc.set.call(this, v); } }
      });
      var origSetAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(n, v){
        if (this instanceof HTMLMediaElement && String(n).toLowerCase() === 'src' && attach(this, v)) return;
        return origSetAttr.apply(this, arguments);
      };

      // <video> cu sursa noastră: îi simulăm starea (timp, pregătire, evenimente), ca player-ul YouTube
      // să creadă că redă și să continue streaming-ul. (Pasul următor: imaginea reală prin AVPlayer.)
      var fakes = [];
      // WebKit ține procesul paginii „treaz” cât redă un <audio> real. Fără asta, temporizatoarele și
      // cererile player-ului YouTube sunt aproape oprite. Redăm în buclă o secundă de liniște.
      var awake = null;
      function keepAwake(){
        try {
          if (!awake) {
            var n = 8000, buf = new ArrayBuffer(44 + n), v = new DataView(buf);
            function str(o, t){ for (var i = 0; i < t.length; i++) v.setUint8(o + i, t.charCodeAt(i)); }
            str(0, 'RIFF'); v.setUint32(4, 36 + n, true); str(8, 'WAVE'); str(12, 'fmt ');
            v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
            v.setUint32(24, 8000, true); v.setUint32(28, 8000, true); v.setUint16(32, 1, true); v.setUint16(34, 8, true);
            str(36, 'data'); v.setUint32(40, n, true);
            for (var i = 0; i < n; i++) v.setUint8(44 + i, 128);
            awake = document.createElement('audio');
            awake.loop = true; awake.volume = 0.01; awake.setAttribute('playsinline', '');
            awake.src = URL.createObjectURL(new Blob([buf], {type: 'audio/wav'}));
          }
          if (awake.paused) { var pr = awake.play(); if (pr && pr.catch) pr.catch(function(e){ if (S.errors.length < 6) S.errors.push('trezire: ' + e); }); }
          S.dbg.awake = !awake.paused;
        } catch (e) { if (S.errors.length < 6) S.errors.push('trezire: ' + e); }
      }
      function fire(el, t){ try { el.dispatchEvent(new Event(t)); } catch (e) {} }
      function aheadOf(el, t){
        var ms = el.__ppMS; if (!ms || !ms.sourceBuffers.length) return 0;
        var m = Infinity;
        ms.sourceBuffers.forEach(function(sb){
          var a = 0;
          sb.r.forEach(function(r){ if (r[0] <= t + 0.25 && r[1] > t) a = r[1] - t; });
          m = Math.min(m, a);
        });
        return m === Infinity ? 0 : m;
      }
      function mediaTick(el){
        var st = el.__ppS; if (!st) return;
        var ms = el.__ppMS;
        var inited = ms && ms.sourceBuffers.length && ms.sourceBuffers.every(function(sb){ return sb.init; });
        if (inited && !st.meta) {
          st.meta = true; st.rs = 1;
          fire(el, 'durationchange'); fire(el, 'loadedmetadata'); fire(el, 'resize');
        }
        var ahead = aheadOf(el, st.t);
        var old = st.rs;
        st.rs = !st.meta ? 0 : (ahead > 2 ? 4 : (ahead > 0.3 ? 3 : (ahead > 0 ? 2 : 1)));
        if (old < 2 && st.rs >= 2) fire(el, 'loadeddata');
        if (old < 3 && st.rs >= 3) fire(el, 'canplay');
        if (old < 4 && st.rs >= 4) fire(el, 'canplaythrough');
        if (!st.paused && st.rs >= 3 && !st.playing) { st.playing = true; st.waiting = false; fire(el, 'playing'); }
        if (!st.paused && st.rs < 3 && !st.waiting) { st.waiting = true; st.playing = false; fire(el, 'waiting'); }
      }
      var lastClock = performance.now();

      function tick(){
        var now = performance.now(), dt = (now - lastClock) / 1000; lastClock = now;
        if (dt < 0.05) return;
        dt = Math.min(dt, 1);
        S.dbg.ticks++;
        if (fakes.length) keepAwake();
        fakes.forEach(function(el){
          var st = el.__ppS; if (!st) return;
          if (st.paused || !st.playing || st.seeking) S.dbg.stuck = 'paused=' + st.paused + ' playing=' + st.playing + ' seeking=' + st.seeking;
          if (window.__ppNT !== undefined) { mediaTick(el); return; }
          if (!st.paused && st.playing && !st.seeking) {
            var ahead = aheadOf(el, st.t);
            S.dbg.adv++; S.dbg.stuck = 'ahead=' + ahead.toFixed(2) + ' dt=' + dt.toFixed(2) + ' rate=' + st.rate;
            st.t += Math.min(dt * st.rate, Math.max(ahead - 0.05, 0));
            var d = el.__ppMS && el.__ppMS.duration;
            if (isFinite(d) && d > 0 && st.t >= d - 0.1) { st.t = d; st.ended = true; st.paused = true; fire(el, 'timeupdate'); fire(el, 'ended'); return; }
            fire(el, 'timeupdate');
          }
          mediaTick(el);
        });
      }
      window.__ppTick = tick;
      // Ceasul real vine de la redarea nativă (aplicația îl trimite de 4 ori pe secundă).
      window.__ppClock = function(t, playing){
        window.__ppNT = t;
        fakes.forEach(function(el){
          var st = el.__ppS; if (!st || st.seeking) return;
          st.t = t;
          var d = el.__ppMS && el.__ppMS.duration;
          if (!st.paused && isFinite(d) && d > 0 && t >= d - 0.25) { st.ended = true; st.paused = true; fire(el, 'timeupdate'); fire(el, 'ended'); return; }
          if (!st.paused) fire(el, 'timeupdate');
          mediaTick(el);
        });
      };
      setInterval(tick, 250);
      function prop(name, getF, setF){
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, name) || Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, name);
        Object.defineProperty(name === 'videoWidth' || name === 'videoHeight' ? HTMLVideoElement.prototype : HTMLMediaElement.prototype, name, {
          configurable: true,
          get: function(){ return this.__ppS ? getF.call(this, this.__ppS) : (d && d.get ? d.get.call(this) : undefined); },
          set: function(v){ if (this.__ppS && setF) setF.call(this, this.__ppS, v); else if (d && d.set) d.set.call(this, v); }
        });
      }
      prop('currentTime', function(st){ return st.t; }, function(st, v){
        var el = this; st.t = Math.max(0, Number(v) || 0); st.ended = false; st.seeking = true; st.playing = false;
        // Aplicația golește ce avea în redare: player-ul trebuie să trimită din nou datele de la noua poziție.
        if (el.__ppMS) el.__ppMS.sourceBuffers.forEach(function(sb){ sb.r = []; });
        window.__ppNT = st.t;
        toApp({t: 'mse-seek', time: st.t});
        S.dbg.sets++; S.dbg.lastSet = String(v) + ' @' + Math.round(performance.now() / 1000) + 's';
        fire(el, 'seeking');
        later(function(){ st.seeking = false; fire(el, 'seeked'); fire(el, 'timeupdate'); mediaTick(el); });
      });
      prop('paused', function(st){ return st.paused; });
      prop('ended', function(st){ return st.ended; });
      prop('seeking', function(st){ return st.seeking; });
      prop('readyState', function(st){ return st.rs; });
      prop('networkState', function(){ return 2; });
      prop('duration', function(){ var d = this.__ppMS && this.__ppMS.duration; return isFinite(d) ? d : NaN; });
      prop('buffered', function(){ var ms = this.__ppMS; var sb = ms && ms.sourceBuffers[0]; return sb ? sb.buffered : new TR(); });
      prop('seekable', function(){ var d = this.__ppMS && this.__ppMS.duration; return new TR(isFinite(d) ? [[0, d]] : []); });
      prop('playbackRate', function(st){ return st.rate; }, function(st, v){ st.rate = Number(v) || 1; fire(this, 'ratechange'); });
      prop('videoWidth', function(){ var sb = (this.__ppMS && this.__ppMS.sourceBuffers || []).filter(function(b){ return b.w; })[0]; return sb ? sb.w : 0; });
      prop('videoHeight', function(){ var sb = (this.__ppMS && this.__ppMS.sourceBuffers || []).filter(function(b){ return b.h; })[0]; return sb ? sb.h : 0; });
      var origPause = HTMLMediaElement.prototype.pause;
      HTMLMediaElement.prototype.pause = function(){
        var st = this.__ppS; if (!st) return origPause.apply(this, arguments);
        if (!st.paused) { st.paused = true; st.playing = false; fire(this, 'pause'); }
        toApp({t: 'mse-pause'});
      };
      var origPlayEl = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(){
        var st = this.__ppS; if (!st) return origPlayEl.apply(this, arguments);
        if (st.paused) { st.paused = false; st.ended = false; fire(this, 'play'); mediaTick(this); }
        toApp({t: 'mse-play'});
        return Promise.resolve();
      };
      if (HTMLVideoElement.prototype.getVideoPlaybackQuality) {
        var origQ = HTMLVideoElement.prototype.getVideoPlaybackQuality;
        HTMLVideoElement.prototype.getVideoPlaybackQuality = function(){
          if (!this.__ppS) return origQ.apply(this, arguments);
          return {totalVideoFrames: Math.round(this.__ppS.t * 30), droppedVideoFrames: 0, corruptedVideoFrames: 0, creationTime: performance.now()};
        };
      }

      // Cererile către serverele video (googlevideo): reușesc? SABR? PO token?
      function note(url, status){
        if (!/googlevideo\.com|\/videoplayback/.test(url)) return;
        var n = S.net; n.n++;
        if (status >= 200 && status < 300) n.ok++; else n.bad++;
        n.codes[status] = (n.codes[status] || 0) + 1;
        if (/sabr/.test(url)) n.sabr++;
        if (/[?&]pot=/.test(url)) n.pot++;
        if (!n.sample) n.sample = url.replace(/^https?:\/\/[^\/]+/, '').slice(0, 160);
      }
      // Răspunsul SABR e în formatul „UMP”: [tip varint][mărime varint][date]... Ce tipuri vin?
      // (20/21/22 = antet / bucată / sfârșit media; 35 = politica următoarei cereri; 43 = redirect;
      //  44 = eroare SABR; 47 = protecția fluxului (PO token); 58 = reîncarcă player-ul)
      function varint(u8, p){
        var b = u8[p]; if (b === undefined) return null;
        if (b < 128) return [b, 1];
        if (b < 192) return [(b & 0x3f) + 64 * u8[p+1], 2];
        if (b < 224) return [(b & 0x1f) + 32 * (u8[p+1] + 256 * u8[p+2]), 3];
        if (b < 240) return [(b & 0x0f) + 16 * (u8[p+1] + 256 * (u8[p+2] + 256 * u8[p+3])), 4];
        return [(u8[p+1] | (u8[p+2] << 8) | (u8[p+3] << 16)) + u8[p+4] * 16777216, 5];
      }
      function ump(u8){
        var p = 0, list = [], media = 0;
        while (p < u8.length && list.length < 400) {
          var t = varint(u8, p); if (!t) break; p += t[1];
          var z = varint(u8, p); if (!z) break; p += z[1];
          list.push(t[0]);
          S.net.ump[t[0]] = (S.net.ump[t[0]] || 0) + 1;
          if (t[0] === 21) media += z[0];
          if (t[0] === 44 || t[0] === 47) {
            var txt = ''; for (var i = p; i < Math.min(p + z[0], p + 120); i++) { var c = u8[i]; txt += (c >= 32 && c < 127) ? String.fromCharCode(c) : '.'; }
            if (S.errors.length < 6) S.errors.push('UMP ' + t[0] + ': ' + txt);
          }
          p += z[0];
        }
        return {parts: list.length, media: media};
      }
      var of = window.fetch;
      if (of) window.fetch = function(input, init){
        var url = typeof input === 'string' ? input : (input && input.url) || '';
        return of.apply(this, arguments).then(function(r){
          note(url, r.status);
          if (/googlevideo\.com|\/videoplayback/.test(url)) {
            try {
              r.clone().arrayBuffer().then(function(ab){
                var u = ump(new Uint8Array(ab));
                if (S.net.resp.length < 8) S.net.resp.push(Math.round(ab.byteLength / 1024) + ' KB, ' + u.parts + ' părți, media ' + Math.round(u.media / 1024) + ' KB');
              });
            } catch (e) { S.errors.push('clone: ' + e); }
          }
          return r;
        }, function(e){ note(url, 0); throw e; });
      };

      var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__ppUrl = String(u || ''); return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(){
        var x = this;
        x.addEventListener('loadend', function(){ note(x.__ppUrl || '', x.status); });
        return XS.apply(this, arguments);
      };
    })();
    """#

    /// Rezumatul pentru Diagnostic (rulează în pagină).
    static let reportJS = #"""
    (function(){
      var S = window.__ppMSE;
      if (!S) return JSON.stringify({'MSE fals (test)': 'nu e activ în pagină'});
      var mp = document.getElementById('movie_player');
      var lv = '';
      try { lv = (mp && mp.getAvailableQualityLevels) ? mp.getAvailableQualityLevels().join(', ') : ''; } catch (e) {}
      var o = {};
      o['MSE fals: create / atașate'] = S.created + ' / ' + S.attached;
      o['MSE fals: calități în player'] = lv || '—';
      o['MSE fals: buffere'] = S.buffers.map(function(b){ return b.type + ' — ' + b.n + ' bucăți, ' + Math.round(b.bytes / 1024) + ' KB, interval: ' + (b.range || '—') + ', început: ' + (b.first || '—'); }).join('\n') || '—';
      var fv = document.querySelector('video');
      o['MSE fals: video simulat'] = fv && fv.__ppS ? ('timp ' + fv.__ppS.t.toFixed(1) + ' s, ' + (fv.__ppS.paused ? 'pauză' : (fv.__ppS.playing ? 'rulează' : 'așteaptă')) + ', pregătire ' + fv.__ppS.rs + ', ' + fv.videoWidth + '×' + fv.videoHeight) : '—';
      o['MSE fals: depanare'] = JSON.stringify(S.dbg);
      var q = '';
      try { q = mp && mp.getPlaybackQuality ? mp.getPlaybackQuality() : ''; } catch (e) {}
      o['MSE fals: ecran / calitate'] = (S.screenBefore || '?') + ' · cereri decodingInfo: ' + (S.di || 0) + ' · calitate curentă: ' + (q || '—') + ' · cerută: ' + (window.__ppQ || '—');
      o['MSE fals: total primit'] = S.appends + ' bucăți, ' + Math.round(S.bytes / 1024) + ' KB';
      o['MSE fals: cereri video'] = S.net.n + ' (ok ' + S.net.ok + ', eșuate ' + S.net.bad + ', coduri ' + JSON.stringify(S.net.codes) + ', SABR ' + S.net.sabr + ', pot ' + S.net.pot + ')';
      o['MSE fals: răspunsuri video'] = S.net.resp.join('\n') || '—';
      o['MSE fals: tipuri UMP'] = JSON.stringify(S.net.ump);
      o['MSE fals: tipuri întrebate'] = S.asked.slice(0, 8).join('\n') || '—';
      if (S.errors.length) o['MSE fals: erori'] = S.errors.join(' | ');
      return JSON.stringify(o);
    })()
    """#
}
