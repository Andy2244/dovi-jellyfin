// ==UserScript==
// @name         Jellyfin menu + hotkey additions (Edge)
// @namespace    dovi-jellyfin
// @version      1.1
// @description  Item context menu: adds "Reset resume", "Mark Watched", and on episodes "Mark Unplayed" (also drops it from Next Up). mpv-style playback hotkeys: a/s = cycle audio/subtitle track, i = stats overlay, q = close player. Gamepad: X = play focused card, Y = its context menu (or the stats overlay while the player is up), LB/RB = skip by the user's skip lengths, right-stick left/right = fine -5/+5s nudge; all seeks skip the OSD.
// @match        *://localhost:8096/*
// @match        *://YOUR-JELLYFIN-HOST:8096/*
// @match        *://*:8096/*
// @run-at       document-start
// @grant        none
// ==/UserScript==
(function () {
  'use strict';
  if (window.__jf_menu_additions) return;
  window.__jf_menu_additions = true;

  // Track the item whose menu is opening: follow mouse clicks AND keyboard/gamepad focus, ignoring
  // events inside an open sheet so its focus-steal can't clobber the captured item.
  let ctx = null;
  function captureCtx(e) {
    const t = e.target;
    if (!t || !t.closest || t.closest('.actionSheet, .dialogContainer')) return;
    const el = t.closest('.card, .listItem') || t.closest('[data-id][data-serverid]');
    ctx = (el && el.getAttribute('data-id') && el.getAttribute('data-serverid'))
      ? { id: el.getAttribute('data-id'), type: el.getAttribute('data-type') || el.getAttribute('data-itemtype') }
      : null;
  }
  document.addEventListener('click', captureCtx, true);
  document.addEventListener('focusin', captureCtx, true);

  function currentItemId() {
    if (ctx) return ctx.id;                                     // the card whose menu we just opened
    const m = location.hash.match(/[?&]id=([0-9a-f]{32})/i);    // detail-page header menu
    return (m && location.hash.indexOf('details') !== -1) ? m[1] : null;
  }

  function toast(msg, big, dur, extra) {
    document.querySelectorAll('.jfdv-toast').forEach(el => el.remove());   // replace, don't stack
    const t = document.createElement('div');
    t.className = 'jfdv-toast';
    t.textContent = msg;
    t.style.cssText = 'position:fixed;bottom:2em;left:50%;transform:translateX(-50%);background:#303030;color:#fff;padding:.6em 1.2em;border-radius:4px;z-index:100000;opacity:0;transition:opacity .2s;pointer-events:none;'
      + (extra || '');
    if (big) t.style.fontSize = (big === true ? '2em' : big);   // true = 2em couch size; or an explicit size string
    document.body.appendChild(t);
    requestAnimationFrame(() => { t.style.opacity = '1'; });
    setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, dur || (big ? 3600 : 1800));
  }

  // Zero the resume position, preserving the rest of the user data (played/playcount/favorite).
  async function resetResume(itemId) {
    const api = window.ApiClient;
    if (!itemId || !api) { toast('Reset resume: no item'); return; }
    try {
      const userId = api.getCurrentUserId();
      const item = await api.getItem(userId, itemId);
      const ud = Object.assign({}, item.UserData || {});
      ud.PlaybackPositionTicks = 0;
      await api.ajax({
        type: 'POST',
        url: api.getUrl('UserItems/' + itemId + '/UserData', { userId }),
        data: JSON.stringify(ud),
        contentType: 'application/json'
      });
      location.reload();   // jellyfin-web doesn't refresh cards on this change; reload to reflect it
    } catch (e) {
      toast('Reset failed');
      console.warn('[JF-menu] reset failed', e);
    }
  }

  // Mark the episode unplayed -> nulls LastPlayedDate (drops it from Next Up) + clears position/playcount.
  async function markUnplayed(itemId) {
    const api = window.ApiClient;
    if (!itemId || !api) { toast('Mark unplayed: no item'); return; }
    try {
      const userId = api.getCurrentUserId();
      await api.ajax({ type: 'DELETE', url: api.getUrl('UserPlayedItems/' + itemId, { userId }) });
      location.reload();
    } catch (e) {
      toast('Mark unplayed failed');
      console.warn('[JF-menu] mark-unplayed failed', e);
    }
  }

  // Mark the item played (POST) -- inverse of markUnplayed's DELETE.
  async function markPlayed(itemId) {
    const api = window.ApiClient;
    if (!itemId || !api) { toast('Mark watched: no item'); return; }
    try {
      const userId = api.getCurrentUserId();
      await api.ajax({ type: 'POST', url: api.getUrl('UserPlayedItems/' + itemId, { userId }) });
      location.reload();
    } catch (e) {
      toast('Mark watched failed');
      console.warn('[JF-menu] mark-played failed', e);
    }
  }

  function makeItem(dataId, icon, label, onClick) {
    const btn = document.createElement('button');
    btn.setAttribute('is', 'emby-button');
    btn.type = 'button';
    btn.className = 'listItem listItem-button actionSheetMenuItem';
    btn.setAttribute('data-id', dataId);
    btn.innerHTML = `<span class="actionsheetMenuItemIcon listItemIcon listItemIcon-transparent material-icons ${icon}" aria-hidden="true"></span>`
      + `<div class="listItemBody actionsheetListItemBody"><div class="listItemBodyText actionSheetItemText">${label}</div></div>`;
    btn.addEventListener('click', onClick);   // bubbles so the native handler closes the sheet
    return btn;
  }

  function injectItems(scroller) {
    const play = scroller.querySelector('.actionSheetMenuItem[data-id="resume"]');
    if (!play) return;                       // playable items only; anchor under Play
    const itemId = currentItemId();          // single source of truth for this menu
    if (!itemId) return;
    let anchor = scroller.querySelector('[data-id="jfdv-resetresume"]');
    if (!anchor) anchor = scroller.insertBefore(makeItem('jfdv-resetresume', 'replay', 'Reset resume', () => resetResume(itemId)), play.nextSibling);
    // Mark Watched: any playable item (the native menu has no mark-played)
    const watched = scroller.querySelector('[data-id="jfdv-markwatched"]');
    if (!watched) anchor = scroller.insertBefore(makeItem('jfdv-markwatched', 'done', 'Mark Watched', () => markPlayed(itemId)), anchor.nextSibling);
    else anchor = watched;
    // Mark Unplayed: episodes only (also drops the episode from Next Up)
    if (ctx && ctx.type === 'Episode' && !scroller.querySelector('[data-id="jfdv-markunplayed"]')) {
      scroller.insertBefore(makeItem('jfdv-markunplayed', 'remove_done', 'Mark Unplayed', () => markUnplayed(itemId)), (anchor || play).nextSibling);
    }
    ctx = null;   // consume: a later menu opened without a fresh click/focus won't reuse this item
  }

  // ---- mpv-style playback hotkeys: a = cycle audio, s = cycle subtitle, i = stats overlay ----
  // A userscript can't reach the bundled playbackManager, so drive the OSD's own buttons and
  // click the wanted item in the resulting action sheet, kept invisible while auto-driven.
  let hkBusy = false;
  function driveSheet(trigger, act) {
    if (hkBusy || !trigger) return;
    hkBusy = true;
    const hide = document.createElement('style');
    hide.textContent = '.actionSheet{visibility:hidden!important}.dialogBackdrop{display:none!important}';
    document.head.appendChild(hide);
    let timer;
    const done = () => {
      obs.disconnect(); clearTimeout(timer);
      setTimeout(() => { hkBusy = false; }, 400);
      // sheet close animation (~100ms) + backdrop removal (~300ms) can outlast the busy window
      setTimeout(() => { hide.remove(); }, 700);
    };
    const obs = new MutationObserver(() => {
      const sheets = document.querySelectorAll('.actionSheet');
      const sheet = sheets[sheets.length - 1];
      if (!sheet || !sheet.querySelector('.actionSheetMenuItem')) return;
      try { act(sheet); } finally { done(); }
    });
    obs.observe(document.body, { childList: true, subtree: true });
    timer = setTimeout(done, 4000);   // fail-safe: unhide even if the sheet never appears (first open cold-imports the actionSheet chunk)
    if (typeof trigger === 'function') trigger(); else trigger.click();
  }

  // click the item after the checked one (wrap around); no check = pick the first
  function cycleSheet(sheet, skipId) {
    const items = [...sheet.querySelectorAll('.actionSheetMenuItem')]
      .filter(b => b.getAttribute('data-id') !== skipId);
    if (!items.length) return;
    const cur = items.findIndex(b => {
      const ic = b.querySelector('.material-icons.check');
      return ic && ic.style.visibility !== 'hidden';
    });
    const next = items[(cur + 1) % items.length];
    const label = next.querySelector('.actionSheetItemText');
    next.click();
    toast(label ? label.textContent : '', true);
  }

  const HK = { a: '.btnAudio', s: '.btnSubtitles', i: '.btnVideoOsdSettings' };
  document.addEventListener('keydown', function (e) {
    if (e.ctrlKey || e.altKey || e.metaKey || e.shiftKey) return;
    const k = (e.key || '').toLowerCase();
    if (!HK[k] && k !== 'q') return;
    const page = document.querySelector('#videoOsdPage:not(.hide)');
    if (!page) return;
    const t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) return;
    if (!hkBusy && document.querySelector('.dialogContainer')) return;   // a real menu/dialog is open
    if (k === 'q') {
      e.preventDefault();
      history.back();   // leaving the video view stops playback (enableStopOnBack)
      return;
    }
    const btn = page.querySelector(HK[k] + ':not(.hide)');   // hidden button = nothing to cycle
    if (!btn) return;
    e.preventDefault();
    if (k === 'i') driveSheet(btn, sheet => { const it = sheet.querySelector('[data-id="stats"]'); if (it) it.click(); });
    else driveSheet(btn, sheet => cycleSheet(sheet, k === 's' ? 'secondarysubtitle' : null));
  }, true);

  // gamepad: X=play card, Y=menu/stats, LB/RB=skip -/+ (user length), right-stick L/R=fine -5/+5s nudge (jellyfin only wires A/B/dpad + left stick)
  const GP_PLAY = 2, GP_MENU = 3, GP_LB = 4, GP_RB = 5;
  const RSTICK_DEAD = 0.6, RSTICK_REL = 0.4, RSTICK_MS = 1000;   // right-stick nudge: activate / release (hysteresis) / hold-repeat
  const padPrev = {};
  let padPending = false;   // a gamepad-opened menu is mid-async-open (dialog not in DOM yet)
  function focusedCard() {
    const a = document.activeElement;
    return (a && a.closest) ? a.closest('.card, .listItem') : null;
  }
  function openCardMenu(card) {
    const id = card.getAttribute('data-id'), sid = card.getAttribute('data-serverid');
    if (id && sid) ctx = { id, type: card.getAttribute('data-type') || card.getAttribute('data-itemtype') };  // seed for injectItems
    padPending = true;
    card.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, view: window }));
    setTimeout(() => { padPending = false; }, 1500);
  }
  function padMenu() {
    if (hkBusy || padPending || document.querySelector('.dialogContainer')) return;   // busy / mid-open / a real sheet
    const player = document.querySelector('#videoOsdPage:not(.hide)');
    if (player) {   // during playback Y = stats overlay (same as the 'i' hotkey)
      const btn = player.querySelector('.btnVideoOsdSettings:not(.hide)');
      if (btn) driveSheet(btn, sheet => { const it = sheet.querySelector('[data-id="stats"]'); if (it) it.click(); });
      return;
    }
    const card = focusedCard();
    if (card) openCardMenu(card);
  }
  function padPlay() {
    if (hkBusy || padPending || document.querySelector('.dialogContainer')) return;
    const card = focusedCard();
    if (!card) return;
    driveSheet(() => openCardMenu(card), sheet => {
      const play = sheet.querySelector('.actionSheetMenuItem[data-id="resume"], .actionSheetMenuItem[data-id="play"]');
      if (play) play.click();                          // starts playback -> sheet closes on navigate
      else (document.activeElement || document.body)   // not playable -> dismiss the hidden sheet
        .dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
    });
  }
  // LB/RB = quick skip without the OSD, using the user's own skip-length settings. currentTime IS jellyfin's seek path.
  function skipLen(name, defSec) {
    const uid = window.ApiClient && window.ApiClient.getCurrentUserId && window.ApiClient.getCurrentUserId();
    const ms = uid && parseInt(localStorage.getItem(uid + '-' + name), 10);
    return (ms && isFinite(ms)) ? ms / 1000 : defSec;   // ms -> s; else jellyfin's default
  }
  function padSkip(sec) {
    if (document.querySelector('.dialogContainer')) return;            // don't seek under an open menu/sheet
    if (!document.querySelector('#videoOsdPage:not(.hide)')) return;   // only while the player is up
    const v = document.querySelector('.videoPlayerContainer video');
    if (!v || !isFinite(v.duration) || !isFinite(v.currentTime)) return;
    v.currentTime = Math.max(0, Math.min(v.duration, v.currentTime + sec));
    // just above the subtitle area, offset slightly toward the seek direction
    toast((sec > 0 ? '+' : '') + sec + 's', '1.3em', 1200,
          'bottom:13%;left:' + (sec > 0 ? '54%' : '46%'));
  }
  let padLoop = false;
  function pollPads() {
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    for (const p of pads) {
      if (!p || !p.buttons) continue;
      const x = !!(p.buttons[GP_PLAY] && p.buttons[GP_PLAY].pressed);
      const y = !!(p.buttons[GP_MENU] && p.buttons[GP_MENU].pressed);
      const lb = !!(p.buttons[GP_LB] && p.buttons[GP_LB].pressed);
      const rb = !!(p.buttons[GP_RB] && p.buttons[GP_RB].pressed);
      const rsx = (p.axes && p.axes.length > 2) ? p.axes[2] : 0;   // right-stick X
      const prev = padPrev[p.index] || {};
      if (x && !prev.x) padPlay();                     // buttons: edge-triggered, once per press
      if (y && !prev.y) padMenu();
      if (lb && !prev.lb) padSkip(-skipLen('skipBackLength', 10));
      if (rb && !prev.rb) padSkip(skipLen('skipForwardLength', 30));
      // right-stick L/R = fine 5s nudge: fires on push, then repeats every RSTICK_MS while held
      let rsNext = prev.rsNext || 0;
      if (Math.abs(rsx) > RSTICK_DEAD) {
        const now = Date.now();
        if (now >= rsNext) { padSkip(rsx > 0 ? 5 : -5); rsNext = now + RSTICK_MS; }
      } else if (Math.abs(rsx) < RSTICK_REL) {
        rsNext = 0;                                    // fully released (hysteresis) -> next push nudges immediately
      }
      padPrev[p.index] = { x, y, lb, rb, rsNext };
    }
    requestAnimationFrame(pollPads);
  }
  function startPads() { if (!padLoop) { padLoop = true; pollPads(); } }
  window.addEventListener('gamepadconnected', startPads);
  if (navigator.getGamepads && [...navigator.getGamepads()].some(Boolean)) startPads();

  new MutationObserver((muts) => {
    for (const m of muts) {
      for (const n of m.addedNodes) {
        if (n.nodeType !== 1) continue;
        // dialogHelper wraps the sheet in a .dialogContainer, so match is-or-contains
        const sheet = (n.matches && n.matches('.actionSheet')) ? n : (n.querySelector && n.querySelector('.actionSheet'));
        const scroller = sheet && sheet.querySelector('.actionSheetScroller');
        // item context menu = Play plus an item-only action; excludes the resume-choice prompt
        if (scroller
          && scroller.querySelector('.actionSheetMenuItem[data-id="resume"]')
          && scroller.querySelector('.actionSheetMenuItem[data-id="delete"], .actionSheetMenuItem[data-id="edit"], .actionSheetMenuItem[data-id="moremediainfo"], .actionSheetMenuItem[data-id="refresh"], .actionSheetMenuItem[data-id="identify"]')) {
          injectItems(scroller);
        }
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });

  console.log('[JF-menu] menu + hotkey additions v1.1 active (reset-resume + mark-watched + mark-unplayed + a/s/i/q hotkeys + gamepad X/Y/LB/RB/right-stick)');
})();
