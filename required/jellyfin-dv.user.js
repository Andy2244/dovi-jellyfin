// ==UserScript==
// @name         Jellyfin Dolby Vision (Edge)
// @namespace    dovi-jellyfin
// @version      8.6
// @description  DV movies direct-play (strip VideoRangeType); force >2ch Opus to transcode; video-passthrough. Display gate: on a real PlaybackInfo request, DEFER it, preflight the item's range+fps, flip desktop HDR + refresh, then release -- so Edge builds the decode chain in the stable mode (no phantom plane). Flag-launched Edge only.
// @match        *://localhost:8096/*
// @match        *://YOUR-JELLYFIN-HOST:8096/*
// @match        *://*:8096/*
// @run-at       document-start
// @grant        none
// ==/UserScript==
(function () {
  'use strict';
  if (window.__jf_dv_shim) return;
  window.__jf_dv_shim = true;
  const DV = /dvh1|dvhe|dvav|dva1/i;

  // ---- HDR gate (preflight) ----
  // defer the PlaybackInfo request -> flip -> release, so the decode chain builds post-flip (mid-flip = "phantom" plane).
  const GATE = 'http://127.0.0.1:17999';
  const GATE_TIMEOUT_MS = 12000;             // hard cap on the whole preflight; release the request regardless
  let authHeader = null;                     // captured Authorization value, replayed on our own item GET

  const rangeToHdr = (vrt) => /^(DOVI|HDR10|HLG)/i.test(vrt || '') ? 1 : 0;
  const videoStream = (src) => ((src && src.MediaStreams) || []).find(s => s.Type === 'Video');

  // itemId + chosen source + IsPlayback, parsed from the PlaybackInfo request (URL + JSON body).
  function parsePb(url, body) {
    const m = /\/Items\/([0-9a-fA-F-]+)\/PlaybackInfo(\?|$)/.exec(url || '');
    if (!m) return null;
    let dto = {};
    try { dto = JSON.parse(body || '{}'); } catch {}
    return { itemId: m[1], sourceId: dto.MediaSourceId || null, userId: dto.UserId || null, isPlayback: dto.IsPlayback === true };
  }

  // range + fps for the source jellyfin-web will play. Exact match on the chosen MediaSourceId;
  // ambiguous multi-source with no id -> conservative: HDR if ANY version is HDR/DV (never phantom).
  function pickInfo(mediaSources, sourceId) {
    if (!Array.isArray(mediaSources) || !mediaSources.length) return null;
    const rf = (v) => ({ range: v.VideoRangeType || v.VideoRange || null, fps: v.RealFrameRate || v.AverageFrameRate || 0 });
    let src = sourceId ? mediaSources.find(s => s.Id === sourceId) : null;
    if (!src && mediaSources.length === 1) src = mediaSources[0];
    if (src) { const v = videoStream(src); return v ? rf(v) : null; }
    let hdr = 0, fps = 0;
    for (const s of mediaSources) { const v = videoStream(s); if (!v) continue; if (!fps) fps = v.RealFrameRate || v.AverageFrameRate || 0; if (rangeToHdr(v.VideoRangeType || v.VideoRange)) hdr = 1; }
    return { range: hdr ? 'HDR10' : 'SDR', fps };
  }

  // GET the item's sources (authed), decide, flip + settle. Skips the flip if the preflight went stale
  // (timeout or the play was canceled) so we never flip late or for a dead play.
  async function flipForItem(pb, stale) {
    const q = pb.userId ? ('userId=' + encodeURIComponent(pb.userId) + '&') : '';
    const url = location.origin + '/Items/' + pb.itemId + '?' + q + 'Fields=MediaSources,MediaStreams';
    const item = await fetch(url, { headers: authHeader ? { Authorization: authHeader } : {} }).then(r => r.json());
    const info = pickInfo(item.MediaSources, pb.sourceId);
    if (!info || !info.range) { console.log('[JF-DV] preflight: no range -> no flip'); return; }
    if (stale()) { console.log('[JF-DV] preflight stale (timeout/cancel) -> skip flip'); return; }
    const hdr = rangeToHdr(info.range);
    console.log('[JF-DV] preflight: range=' + info.range + ' fps=' + info.fps + ' -> hdr=' + hdr);
    const qs = 'hdr=' + hdr + '&range=' + encodeURIComponent(info.range) + '&fps=' + encodeURIComponent(info.fps || 0);
    const r = await fetch(GATE + '/gate?' + qs, { method: 'POST' }).then(x => x.json());
    console.log('[JF-DV] gate done', r);
  }

  // hard-capped preflight; always resolves so the caller releases. isAborted() = the play was canceled.
  function preflight(pb, isAborted) {
    const s = { t: false };
    const stale = () => s.t || (isAborted && isAborted());
    return Promise.race([
      flipForItem(pb, stale).catch(e => console.log('[JF-DV] preflight err (fail-open):', (e && e.message) || e)),
      new Promise(res => setTimeout(() => { s.t = true; res(); }, GATE_TIMEOUT_MS)),
    ]);
  }

  // stream-timing diagnostics: loadeddata = first-frame data ready, playing = playback actually started.
  document.addEventListener('loadeddata', () => { console.log('[JF-DV] loadeddata (stream ready)'); }, true);
  document.addEventListener('playing', () => { console.log('[JF-DV] playing (playback start)'); }, true);

  // ---- codec/profile shims (unchanged from v6) ----
  const can = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (t) {
    return (t && (DV.test(t) || /matroska/i.test(t))) ? 'probably' : can.call(this, t);
  };
  if (window.MediaSource && typeof MediaSource.isTypeSupported === 'function') {
    const sup = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = function (t) { return (t && DV.test(t)) ? true : sup(t); };
  }

  function patchProfile(p) {
    if (!p) return p;
    // LPCM stays OUT of direct-play: MF renders pcm_s24le-in-MKV as white noise (tested v8.2); let it transcode.
    // DV direct-play: drop the VideoRangeType condition (keeps other constraints).
    if (Array.isArray(p.CodecProfiles)) {
      for (const cp of p.CodecProfiles) {
        if (cp && Array.isArray(cp.Conditions)) {
          cp.Conditions = cp.Conditions.filter(c => !(c && c.Property === 'VideoRangeType'));
        }
      }
    }
    // Force >2ch Opus to transcode -- Edge's MF Opus decoder is stereo-only.
    p.CodecProfiles = p.CodecProfiles || [];
    p.CodecProfiles.push({
      Type: 'VideoAudio', Codec: 'opus',
      Conditions: [{ Condition: 'LessThanEqual', Property: 'AudioChannels', Value: '2', IsRequired: false }]
    });
    // Video passthrough: allow copying HEVC/AV1/H264 into HLS (transcode only audio).
    if (Array.isArray(p.TranscodingProfiles)) {
      for (const tp of p.TranscodingProfiles) {
        if (!tp || tp.Type !== 'Video' || !tp.VideoCodec) continue;
        const set = new Set(tp.VideoCodec.split(',').filter(Boolean).concat(['hevc', 'av1', 'h264']));
        tp.VideoCodec = [...set].join(',');
      }
    }
    return p;
  }
  function patchBody(body) {
    try {
      const o = JSON.parse(body);
      if (o && o.DeviceProfile) { patchProfile(o.DeviceProfile); return JSON.stringify(o); }
      if (o && (o.CodecProfiles || o.DirectPlayProfiles || o.TranscodingProfiles)) { patchProfile(o); return JSON.stringify(o); }
    } catch {}
    return body;
  }
  const RX = /\/(PlaybackInfo|LiveStreams\/Open)(\?|$)/i;
  const PBRX = /\/PlaybackInfo(\?|$)/i;

  const of = window.fetch;
  window.fetch = function (input, init) {
    const url = (typeof input === 'string') ? input : (input && (input.url || input.href));
    try {   // capture auth so our own item GET is authenticated
      const h = (init && init.headers) || (typeof input === 'object' && input && input.headers);
      const a = h && (h.get ? h.get('Authorization') : (h.Authorization || h.authorization));
      if (a) authHeader = a;
    } catch {}
    try {
      if (url && RX.test(url) && init && typeof init.body === 'string') init = Object.assign({}, init, { body: patchBody(init.body) });
    } catch {}
    if (url && PBRX.test(url)) {
      const pb = parsePb(url, (init && typeof init.body === 'string') ? init.body : null);
      if (pb && pb.isPlayback) {
        const self = this, args = init;
        const aborted = () => !!(args && args.signal && args.signal.aborted);
        return preflight(pb, aborted).then(() => {
          if (aborted()) return Promise.reject(new DOMException('Aborted', 'AbortError'));
          return of.call(self, input, args);
        });
      }
    }
    return of.call(this, input, init);
  };
  const oOpen = XMLHttpRequest.prototype.open, oSend = XMLHttpRequest.prototype.send;
  const oSRH = XMLHttpRequest.prototype.setRequestHeader, oAbort = XMLHttpRequest.prototype.abort;
  XMLHttpRequest.prototype.open = function (m, u) { this.__dvurl = u; this.__dvAborted = false; return oOpen.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
    try { if (/^authorization$/i.test(name) && value) authHeader = value; } catch {}
    return oSRH.apply(this, arguments);
  };
  XMLHttpRequest.prototype.abort = function () { this.__dvAborted = true; return oAbort.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function (body) {
    const xhr = this;
    try { if (xhr.__dvurl && RX.test(xhr.__dvurl) && typeof body === 'string') body = patchBody(body); } catch {}
    if (xhr.__dvurl && PBRX.test(xhr.__dvurl)) {
      const pb = parsePb(xhr.__dvurl, typeof body === 'string' ? body : null);
      if (pb && pb.isPlayback) {
        preflight(pb, () => xhr.__dvAborted).then(() => { if (!xhr.__dvAborted) oSend.call(xhr, body); });   // defer send until the flip settles
        return;
      }
    }
    return oSend.call(xhr, body);
  };

  console.log('[JF-DV] DV shim v8.6 active (DV direct-play + >2ch-Opus transcode + video passthrough + HDR/refresh preflight gate)');
})();
