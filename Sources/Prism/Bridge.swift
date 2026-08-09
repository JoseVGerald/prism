import Foundation

/// The JavaScript we inject into music.youtube.com. It owns three jobs:
///  1. push a snapshot of player + queue state up to Swift on every change
///  2. expose control functions Swift can call via evaluateJavaScript
///  3. talk to YouTube's private InnerTube API for search / library / playlists
///
/// Everything here was verified against the live site before being written; the
/// selectors and the shape of `queueAddEndpoint` in particular come from
/// YouTube's own menu payloads rather than guesswork.
enum Bridge {
    static let source: String = #"""
(function () {
  if (window.__prism) return;

  // ---------------------------------------------------------------- helpers
  const APP    = () => document.querySelector('ytmusic-app');
  const PLAYER = () => document.querySelector('#movie_player');
  const QUEUE  = () => document.querySelector('ytmusic-player-queue')?.queue;


  const post = (msg) => {
    try { window.webkit.messageHandlers.prism.postMessage(JSON.stringify(msg)); }
    catch (e) { /* bridge not attached yet */ }
  };

  const runs = (o) => {
    if (!o) return null;
    if (o.runs) return o.runs.map(r => r.text).join('');
    if (o.simpleText) return o.simpleText;
    return null;
  };

  // YTM hands back tiny thumbnails; rewriting the size params gets us art that
  // does not look like mush on a Retina display.
  const upscale = (url, size) => {
    if (!url) return null;
    size = size || 544;
    // Keep the source's aspect ratio. Forcing a square was fine for cover art,
    // which is square already, but an artist page's immersive header is a wide
    // banner crop (`w540-h225`) and asking the CDN for a square of it returns a
    // 200 with a *fully black* JPEG — verified by sampling the decoded pixels,
    // average brightness 0. Every artist page had a black header photo because
    // of this one rewrite.
    const scaled = (w, h) => {
      const ratio = size / Math.max(w, h);
      return [Math.round(w * ratio), Math.round(h * ratio)];
    };
    let m = url.match(/=w(\d+)-h(\d+)/);
    if (m) {
      const [w, h] = scaled(+m[1], +m[2]);
      return url.replace(/=w\d+-h\d+/, '=w' + w + '-h' + h);
    }
    m = url.match(/\/w(\d+)-h(\d+)\//);
    if (m) {
      const [w, h] = scaled(+m[1], +m[2]);
      return url.replace(/\/w\d+-h\d+\//, '/w' + w + '-h' + h + '/');
    }
    return url;
  };

  const bestThumb = (t, size) => {
    const arr = t?.thumbnails || t?.musicThumbnailRenderer?.thumbnail?.thumbnails;
    if (!arr || !arr.length) return null;
    return upscale(arr[arr.length - 1].url, size);
  };

  const unwrapQueueItem = (it) =>
    it?.playlistPanelVideoRenderer ||
    it?.playlistPanelVideoWrapperRenderer?.primaryRenderer?.playlistPanelVideoRenderer ||
    null;

  const parseDuration = (text) => {
    if (!text) return null;
    const parts = text.split(':').map(Number);
    if (parts.some(isNaN)) return null;
    return parts.reduce((acc, p) => acc * 60 + p, 0);
  };

  // Real queueAddEndpoint objects, keyed by videoId. YouTube ships one with
  // every song it renders and synthesised copies do not reliably work, so we
  // keep the originals whenever we see them.
  const endpointCache = new Map();

  const cacheEndpoints = (videoId, menu) => {
    if (!videoId || !menu) return;
    const items = menu?.menuRenderer?.items || [];
    const entry = endpointCache.get(videoId) || {};
    for (const mi of items) {
      // Download has its own renderer with no text label at all — it is
      // identified by key, carries an offlineVideoEndpoint, and only appears on
      // queue and library items, never on search results.
      if (mi.menuServiceItemDownloadRenderer?.serviceEndpoint) {
        entry.download = mi.menuServiceItemDownloadRenderer.serviceEndpoint;
        continue;
      }
      // Toggle items (Download / Remove download) keep their text and endpoint
      // under different keys than the plain service items.
      const x = mi.menuServiceItemRenderer || mi.menuNavigationItemRenderer
             || mi.toggleMenuServiceItemRenderer;
      if (!x) continue;
      const label = runs(x.text) || runs(x.defaultText) || '';
      const ep = x.serviceEndpoint || x.navigationEndpoint || x.defaultServiceEndpoint;
      if (!ep) continue;
      if (/^add to queue$/i.test(label)) entry.addToQueue = ep;
      else if (/^play next$/i.test(label)) entry.playNext = ep;
      else if (/^remove from queue$/i.test(label)) entry.removeFromQueue = ep;
      else if (/^download$/i.test(label)) entry.download = ep;
      else if (/^remove download$/i.test(label)) entry.removeDownload = ep;
      // YouTube's own "Start radio" carries the real mix playlistId. Taking it
      // from the menu beats constructing one, because the prefix it uses is not
      // the same for every kind of item.
      else if (/^start radio$/i.test(label)) entry.startRadio = ep;
    }
    if (Object.keys(entry).length) endpointCache.set(videoId, entry);
  };

  // `onEmptyQueue` is a watchEndpoint fallback. It is what you want when there
  // is nothing playing, but if the add is rejected on a queue that already has
  // items it fires anyway and *replaces* playback with the song. So it is only
  // included when the queue really is empty.
  const synthAdd = (videoId, position, allowStart) => ({
    queueAddEndpoint: {
      queueTarget: allowStart
        ? { videoId, onEmptyQueue: { watchEndpoint: { videoId } } }
        : { videoId },
      queueInsertPosition: position,
      commands: [{ addToToastAction: { item: { notificationTextRenderer: {
        successResponseText: { runs: [{ text: 'Added to queue' }] } } } } }]
    }
  });

  // ------------------------------------------------------------- state push
  let lastHash = '';

  const readQueue = () => {
    const q = QUEUE();
    if (!q) return { items: [], index: -1 };
    let raw = [];
    try { raw = q.getItems() || []; } catch (e) { raw = []; }
    const items = [];
    raw.forEach((it, i) => {
      const r = unwrapQueueItem(it);
      if (!r) return;
      cacheEndpoints(r.videoId, r.menu);
      items.push({
        index: i,
        videoId: r.videoId || '',
        title: runs(r.title) || 'Unknown',
        artist: runs(r.shortBylineText) || runs(r.longBylineText) || '',
        durationText: runs(r.lengthText),
        artworkURL: bestThumb(r.thumbnail, 120),
        selected: !!r.selected,
        explicit: isExplicit(r),
        // ATV is the audio-track version (static art); OMV/UGC carry real
        // picture, which is what makes video mode worth offering.
        videoType: r?.navigationEndpoint?.watchEndpoint
          ?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType || null
      });
    });
    let index = -1;
    try { index = q.getCurrentItemIndex(); } catch (e) {}
    return { items, index };
  };

  const snapshot = () => {
    const p = PLAYER();
    const q = QUEUE();
    let store = null;
    try { store = q?.store?.getState?.()?.queue || null; } catch (e) {}

    let vd = null, state = -1, t = 0, d = 0, vol = 100, muted = false;
    if (p) {
      try { vd = p.getVideoData(); } catch (e) {}
      try { state = p.getPlayerState(); } catch (e) {}
      try { t = p.getCurrentTime() || 0; } catch (e) {}
      try { d = p.getDuration() || 0; } catch (e) {}
      try { vol = p.getVolume(); } catch (e) {}
      try { muted = !!p.isMuted?.(); } catch (e) {}
    }

    const { items, index } = readQueue();
    const currentEntry = index >= 0 ? items[index] : null;

    let track = null;
    if (vd && vd.video_id) {
      // Only borrow from the queue row when it is describing the *same* track.
      //
      // `currentEntry` is the queue's selected item and `vd` is the player's
      // own video data, and the two update on different ticks. During a
      // transition they disagree, so every field taken from the queue row
      // belonged to a different song for a moment. That is how a finished play
      // ended up logged with the *next* track's artwork: correct videoId,
      // correct title, thumbnail from the song after it.
      //
      // The title/artist half of this was fixed on the History side by taking
      // the newest snapshot rather than the first, but that could only choose
      // between snapshots — it could not repair a snapshot that was internally
      // inconsistent. This fixes it at the source, so every field in a `track`
      // describes one track.
      const entry = currentEntry && currentEntry.videoId === vd.video_id
        ? currentEntry : null;
      track = {
        videoId: vd.video_id,
        title: vd.title || entry?.title || 'Unknown',
        artist: vd.author || entry?.artist || '',
        album: null,
        durationText: entry?.durationText || null,
        durationSeconds: d || null,
        // Falls back to the thumbnail derived from the id itself, which cannot
        // disagree with the track it belongs to.
        artworkURL: upscale(entry?.artworkURL, 544)
          || ('https://i.ytimg.com/vi/' + vd.video_id + '/maxresdefault.jpg')
      };
    }

    return {
      kind: 'snapshot',
      ready: !!p,
      signedIn: !!(window.ytcfg && ytcfg.get('LOGGED_IN')),
      state, currentTime: t, duration: d, volume: vol, muted,
      repeatMode: store?.repeatMode || 'NONE',
      shuffled: !!store?.shuffleEnabled,
      videoType: currentEntry?.videoType || null,
      videoMode: !!document.getElementById('__prism_video_css'),
      // Where the picture actually is, in CSS px, plus the viewport it sits in.
      // Swift uses this to slide the whole webview so the video covers the app
      // window — the only reliable way to fill, since the page will not.
      videoRect: (() => {
        try {
          const vv = document.querySelector('video');
          if (!vv) return null;
          const r = vv.getBoundingClientRect();
          if (r.width < 40 || r.height < 40) return null;
          // The box is the picture, because video mode makes it so.
          //
          // It is not so by default. YouTube sizes the <video> to its
          // container and lets `object-fit: contain` letterbox inside it — a
          // 1280x720 video in a 402x338 box — and *where* the picture lands in
          // that box could not be deduced. `getComputedStyle` reported
          // `50% 50%` and the picture measurably was not centred; a mask built
          // on the centred assumption left a black band below the picture, one
          // built on the top-left corner left a smaller one, and the shortfall
          // moved (0.78, 0.82, 0.84 of the box) every time the page re-laid
          // itself out. Four separate attempts to model it all missed.
          //
          // So the letterbox is removed rather than measured. Video mode sets
          // `object-fit: cover`, which fills the box by definition, and sizes
          // the box to the video's own aspect ratio so that filling it crops
          // nothing. Then the painted rect *is* `getBoundingClientRect()`, with
          // nothing left to infer.
          return { x: r.left, y: r.top, w: r.width, h: r.height,
                   vw: window.innerWidth, vh: window.innerHeight };
        } catch (e) { return null; }
      })(),
      track,
      queue: items,
      queueIndex: index,
      undoLabel: undoStack.length ? undoStack[undoStack.length - 1].label : null
    };
  };

  // Set by setVideoMode; see there.
  let tightVideo = false;

  const pushState = (force) => {
    const s = snapshot();
    // Cheap change detection so we are not shipping identical payloads 4x a
    // second; time is rounded so a playing track still updates the scrubber.
    // Order is part of the identity: a reorder changes neither the length nor
    // the index, so hashing those alone would swallow every move.
    const hash = [s.state, s.track?.videoId, Math.floor(s.currentTime), s.duration,
                  s.queue.length, s.queueIndex, s.repeatMode, s.shuffled,
                  s.volume, s.muted, s.signedIn, s.undoLabel,
                  s.queue.map(i => i.videoId).join(',')].join('|');
    if (!force && hash === lastHash) return;
    lastHash = hash;
    post(s);
  };

  setInterval(() => pushState(false), 250);

  // Redux store changes (queue edits, repeat/shuffle toggles) push immediately.
  const hookStore = () => {
    const q = QUEUE();
    if (!q || !q.store || q.__prismHooked) return;
    try {
      q.store.subscribe(() => pushState(true));
      q.__prismHooked = true;
    } catch (e) {}
  };
  setInterval(hookStore, 1500);
  hookStore();

  // --------------------------------------------------------------- InnerTube
  const innertube = async (endpoint, body) => {
    const key = ytcfg.get('INNERTUBE_API_KEY');
    const ctx = {
      client: {
        clientName: ytcfg.get('INNERTUBE_CLIENT_NAME'),
        clientVersion: ytcfg.get('INNERTUBE_CLIENT_VERSION'),
        hl: 'en', gl: 'US'
      }
    };
    const headers = { 'Content-Type': 'application/json' };
    const vd = ytcfg.get('VISITOR_DATA');
    if (vd) headers['X-Goog-Visitor-Id'] = vd;

    // Personalised (library) calls need the SAPISIDHASH the web app itself sends.
    const sapisid = (document.cookie.match(/(?:^|;\s*)(?:__Secure-3PAPISID|SAPISID)=([^;]+)/) || [])[1];
    if (sapisid) {
      const ts = Math.floor(Date.now() / 1000);
      const origin = 'https://music.youtube.com';
      const digest = await crypto.subtle.digest(
        'SHA-1', new TextEncoder().encode(ts + ' ' + sapisid + ' ' + origin));
      const hex = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
      headers['Authorization'] = 'SAPISIDHASH ' + ts + '_' + hex;
      headers['X-Origin'] = origin;
    }

    const res = await fetch('/youtubei/v1/' + endpoint + '?key=' + key + '&prettyPrint=false', {
      method: 'POST', credentials: 'include', headers,
      body: JSON.stringify(Object.assign({ context: ctx }, body))
    });
    if (!res.ok) throw new Error('InnerTube ' + endpoint + ' -> HTTP ' + res.status);
    return res.json();
  };

  // A queue entry needs a full playlistPanelVideoRenderer. Search results are a
  // different shape (musicResponsiveListItemRenderer), so the renderer has to
  // come from /next before anything can be pushed into the queue.
  const fetchQueueRenderer = async (videoId) => {
    try {
      const j = await innertube('next', { videoId, isAudioOnly: true });
      let found = null;
      (function walk(o, d) {
        if (!o || d > 18 || found) return;
        if (Array.isArray(o)) { for (const x of o) walk(x, d + 1); return; }
        if (typeof o === 'object') {
          if (o.playlistPanelVideoRenderer && o.playlistPanelVideoRenderer.videoId === videoId) {
            found = o; return;
          }
          for (const k in o) walk(o[k], d + 1);
        }
      })(j, 0);
      return found;
    } catch (e) { return null; }
  };

  const collect = (root, key, cap) => {
    const found = [];
    (function walk(o, depth) {
      if (!o || depth > 16 || found.length >= (cap || 200)) return;
      if (Array.isArray(o)) { for (const x of o) walk(x, depth + 1); return; }
      if (typeof o === 'object') {
        if (o[key]) found.push(o[key]);
        for (const k in o) walk(o[k], depth + 1);
      }
    })(root, 0);
    return found;
  };

  const flexText = (r, i) => {
    try { return runs(r.flexColumns[i].musicResponsiveListItemFlexColumnRenderer.text); }
    catch (e) { return null; }
  };

  // YouTube marks explicit tracks with an inline badge rather than a field, and
  // the badge lives in different places on different renderers, so this looks
  // for the icon type anywhere within the item's own badge list.
  const isExplicit = (r) => {
    const badges = r?.badges || r?.subtitleBadges || [];
    for (const b of badges) {
      const icon = b?.musicInlineBadgeRenderer?.icon?.iconType
                || b?.metadataBadgeRenderer?.style;
      if (icon && /EXPLICIT/i.test(icon)) return true;
    }
    return false;
  };

  const parseListItem = (r) => {
    const videoId = r?.playlistItemData?.videoId
      || r?.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer
           ?.playNavigationEndpoint?.watchEndpoint?.videoId
      || null;
    const browseId = r?.navigationEndpoint?.browseEndpoint?.browseId || null;
    const title = flexText(r, 0);
    const subtitle = flexText(r, 1);
    const art = bestThumb(r?.thumbnail?.musicThumbnailRenderer?.thumbnail, 240)
             || bestThumb(r?.thumbnail, 240);

    // An album or artist row is decided by its browseId, *before* the videoId
    // is considered. Both are present: an album's play button carries the
    // videoId of its first track, and checking videoId first therefore filed
    // every album under Songs. That is why the Albums row was always empty
    // while twenty album entries quietly padded the song list. These prefixes
    // are unambiguous — a real song's navigationEndpoint is a watchEndpoint and
    // has no browseEndpoint at all.
    if (browseId && /^(MPRE|UC|VL|PL|OLAK)/.test(browseId)) {
      const kind = browseId.startsWith('UC') ? 'artist'
                 : browseId.startsWith('MPRE') ? 'album' : 'playlist';
      return { type: kind, shelf: {
        browseId, title: title || 'Unknown', subtitle, artworkURL: art, kind } };
    }

    if (videoId) {
      cacheEndpoints(videoId, r.menu);
      // Subtitle looks like "Song • Artist • Album • 4:21". The leading token is
      // a result-type label, not the artist, and library songs put their
      // duration in a fixed column instead of the subtitle.
      const bits = (subtitle || '').split('•').map(s => s.trim()).filter(Boolean);
      if (bits.length && /^(song|video|album|single|ep|artist|playlist)$/i.test(bits[0])) bits.shift();
      let durText = bits.length && /^\d+:\d{2}/.test(bits[bits.length - 1]) ? bits.pop() : null;
      if (!durText) {
        try { durText = runs(r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text); }
        catch (e) {}
      }
      // "1.7B views" is metadata, not an album.
      const album = bits.length > 1 && !/\bviews?\b/i.test(bits[1]) ? bits[1] : null;
      return { type: 'song', track: {
        videoId, title: title || 'Unknown',
        artist: bits[0] || '', album,
        durationText: durText, durationSeconds: parseDuration(durText),
        artworkURL: art, explicit: isExplicit(r) } };
    }
    if (browseId) {
      const kind = browseId.startsWith('UC') ? 'artist'
                 : browseId.startsWith('MPRE') ? 'album' : 'playlist';
      return { type: kind, shelf: {
        browseId, title: title || 'Unknown', subtitle, artworkURL: art, kind } };
    }
    return null;
  };

  // ------------------------------------------------------------------- undo
  //
  // Every destructive queue edit snapshots the raw items array first. Undo is
  // then a single `RESET_ITEMS` dispatch that restores it exactly — no /next
  // round-trips, and it works for a clear just as cheaply as for a remove.
  const undoStack = [];
  const pushUndo = (label) => {
    const q = QUEUE(); if (!q) return;
    try {
      undoStack.push({ label,
                       items: (q.getItems() || []).slice(),
                       index: q.getCurrentItemIndex() });
      if (undoStack.length > 20) undoStack.shift();
    } catch (e) {}
  };

  // ---------------------------------------------------------------- commands
  const cmds = {
    play:  () => { PLAYER()?.playVideo(); },
    pause: () => { PLAYER()?.pauseVideo(); },
    toggle: () => {
      const p = PLAYER(); if (!p) return;
      const s = p.getPlayerState();
      (s === 1 || s === 3) ? p.pauseVideo() : p.playVideo();
    },
    next: () => { PLAYER()?.nextVideo(); },
    prev: () => { PLAYER()?.previousVideo(); },
    seek: (t) => { PLAYER()?.seekTo(t, true); },
    setVolume: (v) => { PLAYER()?.setVolume(v); },
    mute:   () => { PLAYER()?.mute?.(); },
    unmute: () => { PLAYER()?.unMute?.(); },

    // Tempo, for AutoMix's glide.
    //
    // Set on the media element rather than through the player API: YouTube's
    // setPlaybackRate only accepts its own menu of rates (0.25, 0.5, 0.75, 1,
    // …), and beat-matching needs 1.0164, not 1.25. The element takes any
    // value, and `preservesPitch` — supported here and on by default — keeps
    // the track from changing key while its tempo moves.
    //
    // Every change costs roughly 350–500 ms of frozen audio whatever its size,
    // so callers must spend these sparingly and hide them. See TempoRamp.
    setRate: (r) => {
      const v = document.querySelector('video');
      if (!v) return;
      v.preservesPitch = true;
      v.playbackRate = Math.max(0.5, Math.min(2, r));
    },

    // Queue edits all go through `store.dispatch`, for the same reason adding
    // does (see `queries.enqueue`). The public methods take *item objects*, not
    // indices: `removeItem(n)` and `selectQueueItem(n)` look the argument up
    // with `getItems().findIndex(c => c === n)`, so an index matches nothing —
    // remove silently did nothing and jump threw. The store actions below are
    // exactly what YouTube's own handlers dispatch.
    jump: (i) => {
      const q = QUEUE(); if (!q) return;
      const items = q.getItems() || [];
      if (i < 0 || i >= items.length) return;
      try { q.selectQueueItem(items[i]); return; } catch (e) {}
      const vid = unwrapQueueItem(items[i])?.videoId;
      if (vid) cmds.playVideo(vid);
    },

    undoQueue: () => {
      const q = QUEUE(); if (!q) return;
      const snap = undoStack.pop();
      if (!snap) return;
      try {
        q.store.dispatch({ type: 'RESET_ITEMS', payload: snap.items });
        // Point the selection at whatever is *actually* playing rather than at
        // the old index: undo restores the list, it does not rewind playback.
        const playing = PLAYER()?.getVideoData?.()?.video_id;
        let at = snap.index;
        if (playing) {
          const found = snap.items.findIndex(it => unwrapQueueItem(it)?.videoId === playing);
          if (found >= 0) at = found;
        }
        q.store.dispatch({ type: 'SET_INDEX', payload: at });
      } catch (e) {}
      pushState(true);
    },

    removeAt: (i) => {
      const q = QUEUE(); if (!q) return;
      const items = q.getItems() || [];
      if (i < 0 || i >= items.length) return;
      const item = items[i];
      pushUndo('remove');

      // Dropping the track that is playing has to hand playback on first —
      // YouTube's own removeItem does the same — or the player is left pointing
      // at a song that is no longer in the queue.
      if (i === q.getCurrentItemIndex()) {
        if (items.length > 1) {
          try { q.selectQueueItem(items[i + 1 < items.length ? i + 1 : i - 1]); } catch (e) {}
        } else {
          try { PLAYER()?.stopVideo(); } catch (e) {}
        }
      }

      const now = q.getItems() || [];
      const at = now.indexOf(item) >= 0 ? now.indexOf(item) : i;
      const cur = q.getCurrentItemIndex();
      // Keep the server-side queue in step; this is the one server call the
      // queue object exposes publicly.
      try { if (q.serverQueuesEnabled) q.serverQueueApi.removeItem(item); } catch (e) {}
      try { q.store.dispatch({ type: 'REMOVE_ITEM', payload: at }); } catch (e) {}
      // Nothing renumbers the selection, so removing above the playing track
      // would leave the highlight — and "what plays next" — one row out.
      if (at < cur) { try { q.store.dispatch({ type: 'SET_INDEX', payload: cur - 1 }); } catch (e) {} }
    },

    // `toIndex` is applied *after* the item is spliced out, so it is a final
    // position rather than a pre-removal one.
    moveItem: (from, to) => {
      const q = QUEUE(); if (!q) return;
      const n = (q.getItems() || []).length;
      if (from < 0 || from >= n) return;
      to = Math.max(0, Math.min(to, n - 1));
      if (from === to) return;
      pushUndo('move');
      const cur = q.getCurrentItemIndex();
      try { q.store.dispatch({ type: 'MOVE_ITEM', payload: { fromIndex: from, toIndex: to } }); }
      catch (e) { return; }

      let next = cur;
      if (cur === from) next = to;
      else if (from < cur && to >= cur) next = cur - 1;
      else if (from > cur && to <= cur) next = cur + 1;
      if (next !== cur) { try { q.store.dispatch({ type: 'SET_INDEX', payload: next }); } catch (e) {} }
    },

    // CLEAR's payload is the list of indices to *keep*, so the playing track
    // survives and everything queued behind it goes. Passing no payload at all
    // is a full wipe — an empty array is not, it makes `nextQueueItemId` -Inf.
    clearQueue: () => {
      const q = QUEUE(); if (!q) return;
      const items = q.getItems() || [];
      const cur = q.getCurrentItemIndex();
      if (!items.length) return;
      pushUndo('clear');
      try {
        if (cur >= 0 && cur < items.length) {
          q.store.dispatch({ type: 'CLEAR', payload: [cur] });
          q.store.dispatch({ type: 'SET_INDEX', payload: 0 });
        } else {
          q.store.dispatch({ type: 'CLEAR' });
          q.store.dispatch({ type: 'SET_INDEX', payload: -1 });
        }
      } catch (e) {}
    },

    shuffle: () => { try { QUEUE()?.shuffle(); } catch (e) {} },

    // Cycle NONE -> ALL -> ONE by driving YTM's own repeat button, which keeps
    // its internal state and our snapshot in agreement.
    cycleRepeat: () => {
      const btn = document.querySelector('ytmusic-player-bar tp-yt-paper-icon-button.repeat')
               || document.querySelector('ytmusic-player-bar .repeat');
      btn?.click();
    },

    // Play a single track, optionally as the seed of a radio.
    //
    // A bare `watchEndpoint: { videoId }` produces a queue of exactly one, which
    // is a dead end: nothing plays afterwards, and crossfade cannot arm because
    // there is no next track to preload. Seeding a radio is what YouTube itself
    // does when you press play on a search result, so it is the better default.
    //
    // The radio endpoint is taken from the item's own "Start radio" menu entry
    // where possible. The fallback builds the conventional `RDAMVM` mix id,
    // which YouTube Music accepts for a song seed.
    playVideo: (videoId, radio) => {
      const app = APP();
      if (!app) { location.href = '/watch?v=' + videoId; return; }
      if (radio) {
        const known = endpointCache.get(videoId)?.startRadio;
        if (known) { app.resolveCommand(known); return; }
        app.resolveCommand({ watchEndpoint: { videoId, playlistId: 'RDAMVM' + videoId } });
        return;
      }
      app.resolveCommand({ watchEndpoint: { videoId } });
    },

    // Strips YouTube's chrome and blows the <video> up to fill the viewport, so
    // the webview itself becomes the app's video surface. Only the player is
    // repositioned — hiding anything inside it risks stopping playback.
    setVideoMode: (on, keepPlayerChrome, tight) => {
      // Whether the <video> element's box should be trimmed to the picture.
      //
      // Only a phone needs it. On a Mac the webview is enlarged until the
      // video covers the window, so YouTube's letterbox bands end up off
      // screen and there is nothing to trim; on a phone the video is a band in
      // the middle and those bands are plainly visible. Gated rather than
      // applied everywhere because the macOS placement is a measured feedback
      // loop, and changing the element it measures is not a change to make
      // untested.
      tightVideo = !!tight;
      const ID = '__prism_video_css';
      const existing = document.getElementById(ID);

      // The player page has to actually be open. Prism normally leaves YouTube
      // on whatever view it loaded with, where the video surface is collapsed
      // into the mini player — which is why restyling alone only ever produced
      // a black rectangle while the audio played on. Setting the property is
      // not enough; the real UI opens it by clicking the player bar, so do
      // that, and only hide the chrome once the page has had time to open.
      const layout = document.querySelector('ytmusic-app-layout');

      if (!on) {
        if (existing) existing.remove();
        try { if (layout) layout.playerPageOpen = false; } catch (e) {}
        setTimeout(() => window.dispatchEvent(new Event('resize')), 80);
        return;
      }
      if (existing) return;

      try {
        if (layout && !layout.playerPageOpen) {
          const trigger = document.querySelector(
            'ytmusic-player-bar .thumbnail-image-wrapper, ytmusic-player-bar .image, ' +
            'ytmusic-player-bar .content-info-wrapper, ytmusic-player-bar .middle-controls');
          if (trigger) trigger.click(); else layout.playerPageOpen = true;
        }
      } catch (e) {}
      const s = document.createElement('style');
      s.id = ID;
      // Kept deliberately minimal. Hiding YouTube's containers, resizing the
      // inner video wrappers, or touching the <video> itself all left the
      // picture black while audio kept playing — the player rebuilds its
      // surface and never recovers. Only two things are safe: raise the player
      // to fill the viewport, and clear the ancestor transforms that would
      // otherwise make position:fixed resolve against YouTube's layout box
      // (which offset the video by exactly the guide width and nav height).
      s.textContent = [
        // Transparent, not black. The video layer does not paint the whole
        // viewport, and whatever it leaves uncovered shows the page behind it —
        // black there looks like a bug, so Prism's blurred artwork backdrop is
        // rendered under the webview and shows through instead.
        'html, body { background: transparent !important; overflow: hidden !important; }',

        // Every ancestor of the player, by structure rather than by name. A
        // transformed or filtered ancestor becomes the containing block for
        // position:fixed, which pinned the video to YouTube's layout box —
        // offset by exactly the guide width and nav height (240, 64). Naming
        // the elements individually kept missing one.
        '*:has(#movie_player) {',
        '  transform: none !important; filter: none !important;',
        '  perspective: none !important; will-change: auto !important;',
        '  contain: none !important; backdrop-filter: none !important; }',

        'ytmusic-app, ytmusic-app-layout, #layout, #content, ytmusic-player-page,',
        '#player-page, #main-panel, .content { background: transparent !important; }',

        // The player's own black, all the way down to the video's container.
        //
        // This is what makes the picture the only thing the page contributes,
        // and it replaces a much worse idea: Prism used to transform the
        // webview so the video landed on a reserved slot and then mask the
        // rest away. That needed page coordinates to mean points, and on a
        // phone they do not — a 100x100 CSS px probe drawn by the page itself
        // measured 98x84 on screen, horizontally 1:1 and vertically squashed
        // to 0.84. No arithmetic survives a non-uniform mapping you cannot
        // observe, and four attempts at it left a black band under the video.
        //
        // With every container transparent there is nothing to mask: whatever
        // the page does not paint shows Prism's backdrop, wherever it happens
        // to be. No measurement, nothing to drift.
        '#movie_player, #player, .html5-video-player, .html5-video-container,',
        'ytmusic-player, #song-video, #player-container, #main-panel > #player',
        '  { background: transparent !important; }',

        // Fill the element box instead of letterboxing inside it.
        //
        // Prism masks the webview down to the picture, so it has to know
        // exactly where the picture is. With `contain` it could not be worked
        // out — see the note in `videoRect`. `cover` fills the box by
        // definition, and the snapshot keeps the box at the video's own aspect
        // ratio, so filling it crops nothing and the box *is* the picture.
        //
        // Safe in a way the old note implies it would not be. That warning is
        // about geometry the player owns — `setSize()` and the width — which
        // blanks the picture. Setting only the height, and only when it has
        // drifted, was measured live: state stayed 1, `currentTime` kept
        // advancing, frames kept coming.
        // Give the picture the whole viewport, cropped rather than boxed.
        //
        // On a phone the video should bleed off every edge, which the page
        // will not do by itself: it lays the <video> out inside its own player
        // furniture, and in landscape that furniture left the picture as a
        // small band in the middle of the screen. Pinning the element to the
        // viewport and letting `object-fit: cover` crop is the one instruction
        // that produces a full-bleed picture in both orientations without any
        // coordinate conversion — the page's own units, applied to the page's
        // own viewport.
        //
        // Safe in a way the older note implies it would not be. That warning
        // is about `setSize()`, which blanks the picture. Setting the element's
        // own width, height and position was measured live in landscape:
        // state stayed 1 and `currentTime` kept advancing across the change.
        (tight ? '#movie_player video {'
                 + ' position: fixed !important; left: 0 !important;'
                 + ' top: 0 !important; width: 100vw !important;'
                 + ' height: 100dvh !important;'
                 + ' object-fit: cover !important;'
                 + ' object-position: 50% 50% !important; }' : ''),

        // No repositioning of the player at all — see the note in the README.
        // Moving it in CSS moves its layout box while the picture keeps
        // painting where YouTube's compositor decides, and setSize() plus any
        // direct styling of the <video> blanks it. The page is left to lay
        // itself out; Prism measures where the video actually lands and offsets
        // the *webview* so that region covers the window.

        // Chrome that sits outside the player, so hiding it is safe. The side
        // panel and suggestion overlays matter specifically because the webview
        // gets enlarged past the window in video mode, which would otherwise
        // reveal YouTube's related-videos list along the right edge.
        'ytmusic-nav-bar, ytmusic-player-bar, #mini-guide, #guide,',
        'ytmusic-guide-renderer, tp-yt-app-drawer,',
        '#side-panel, .side-panel, ytmusic-player-page #right-panel,',
        'ytmusic-tab-renderer, #tabsContent, ytmusic-playlist-panel-renderer,',
        '.ytp-suggestion-set, .ytp-suggested-action, .ytp-suggested-action-badge,',
        '.ytp-ce-element, .ytp-endscreen-content { display: none !important; }',

        // Player-internal overlays only; safe because they are chrome, not the
        // video surface.
        //
        // Kept on macOS, where Prism draws its own transport over a video that
        // covers the whole window. NOT on a phone: there the video is a band in
        // the middle, YouTube's player page draws a perfectly good touch
        // transport around it, and hiding it only to draw a second one on top
        // produced two scrubbers and two play buttons overlapping each other.
        (keepPlayerChrome ? '' :
          '.ytp-chrome-bottom, .ytp-chrome-top, .ytp-gradient-bottom,' +
          '.ytp-gradient-top, .ytp-pause-overlay,' +
          // Only visible when the video is *not* playing, which is why the
          // first pass missed all three: every check had been made mid-song.
          // Found on a player left buffering — a poster frame with YouTube's
          // big play button in the middle of it and an info button in the
          // corner, none of which Prism's transport has any use for.
          '.ytp-cued-thumbnail-overlay, .ytp-large-play-button,' +
          '.ytp-cards-button, .ytp-title, .ytp-watermark' +
          ' { display: none !important; }'),

        // Chrome that only shows itself on a narrow screen.
        //
        // On a Mac the webview is enlarged past the window so the video covers
        // it and these end up off-screen. On a phone the video is a band in the
        // middle and everything else is plainly visible, which is how a
        // measurement found them: the *backgrounds* are separate elements from
        // the components already hidden above — `#nav-bar-background` (65pt at
        // the top) and `#player-bar-background` (64pt at the bottom) survive
        // hiding `ytmusic-nav-bar` and `ytmusic-player-bar`. The promo is
        // YouTube's Premium upsell, and the player page's own title and
        // transport duplicate the ones Prism draws over the top.
        //
        // `:not(:has(#movie_player))` is the safety catch: nothing that
        // contains the player can be hidden by this rule however the page is
        // restructured, because hiding an ancestor of the video kills playback.
        // Written on one line on purpose. Split across lines and joined with a
        // newline, the whitespace between `:is(...)` and `:not(...)` becomes a
        // *descendant* combinator, so the rule quietly matches the children of
        // these elements instead of the elements themselves — measured: eight
        // overlays became three rather than none.
        ':is(#nav-bar-background,#player-bar-background,ytmusic-mealbar-promo-renderer,'
          + 'ytmusic-popup-container'
          + (keepPlayerChrome ? '' :
              ',ytmusic-player-page .middle-controls'
              + ',ytmusic-player-page .content-info-wrapper'
              + ',ytmusic-player-page ytmusic-player-page-header'
              + ',ytmusic-player-page .play-pause-button-wrapper'
              // The player *page* has a transport of its own, separate from
              // the player bar and from the `.ytp-` chrome inside the video.
              // Nothing named it, so on a phone it drew a second scrubber and
              // a second set of skip buttons straight across Prism's — found
              // by walking the DOM for anything visible in the band where the
              // duplicates appeared, which is how it should have been found
              // the first time rather than by listing selectors from memory.
              + ',ytmusic-player-controls,#player-controls'
              + ',ytmusic-player-page #collapse-button'
              + ',ytmusic-player-page ytmusic-menu-renderer'
              + ',ytmusic-player-page yt-button-shape')
          + ')'
          + ':not(:has(#movie_player)) { display: none !important; }'
      ].join('\n');
      // Delayed so the player page finishes opening first; hiding the chrome
      // any earlier removes the very control that opens it.
      setTimeout(() => {
        if (document.getElementById(ID)) return;
        document.documentElement.appendChild(s);

        [80, 400, 1000].forEach(d =>
          setTimeout(() => window.dispatchEvent(new Event('resize')), d));
      }, 700);
    },

    // The player only re-fits on resize, and switching in or out of compact
    // changes the layout around it without the page ever seeing one.
    nudgeVideo: () => {
      [0, 250, 700].forEach(d =>
        setTimeout(() => window.dispatchEvent(new Event('resize')), d));
    },

    playPlaylist: (playlistId) => {
      const app = APP();
      if (app) app.resolveCommand({ watchEndpoint: { playlistId } });
    },

    playBrowse: (browseId, playlistId) => {
      const app = APP();
      if (!app) return;
      if (playlistId) app.resolveCommand({ watchEndpoint: { playlistId } });
      else app.resolveCommand({ browseEndpoint: { browseId } });
    },

  };

// The unfiltered "All" search: songs from the main query plus albums,
// artists and playlists fetched with their own filters, and YouTube's
// top-result card promoted to the front.
const allScopeSearch = async (reqId, query) => {
    // Albums, artists and playlists need asking for separately.
    //
    // The unfiltered search returns songs and videos and nothing else — the
    // response for "Power" carried 29 `musicResponsiveListItemRenderer`s and
    // *zero* `musicTwoRowItemRenderer`, so the Albums and Artists rows in the
    // UI were always empty and looked like a rendering bug. They were not
    // being dropped; they were never requested. These filter params are what
    // the web client's own filter chips send, and each returns 20 results as
    // ordinary list items that `parseListItem` already understands.
    const FILTER = {
      albums:    'EgWKAQIYAWoKEAkQChAFEAMQBA==',
      artists:   'EgWKAQIgAWoKEAkQChAFEAMQBA==',
      playlists: 'EgWKAQIoAWoKEAkQAxAEEAkQBQ=='
    };
    // Concurrent, so four requests cost one round trip rather than four. A
    // filter that fails must not take the songs down with it.
    const quiet = (p) => p.catch(() => null);
    const [j, jAlbums, jArtists, jPlaylists] = await Promise.all([
      innertube('search', { query }),
      quiet(innertube('search', { query, params: FILTER.albums })),
      quiet(innertube('search', { query, params: FILTER.artists })),
      quiet(innertube('search', { query, params: FILTER.playlists }))
    ]);

    const out = { songs: [], albums: [], artists: [], playlists: [] };
    const seen = new Set();

    const shelves = [];
    (function walk(o, depth) {
      if (!o || depth > 18) return;
      if (Array.isArray(o)) { for (const x of o) walk(x, depth + 1); return; }
      if (typeof o !== 'object') return;
      const shelf = o.musicShelfRenderer || o.musicCardShelfRenderer;
      if (shelf) {
        const label = (runs(shelf.title) || '').trim();
        const rows = shelf.contents || shelf.contents === undefined ? (shelf.contents || []) : [];
        shelves.push({ label, rows });
        // A card shelf (the "Top result" block) holds its item inline.
        if (o.musicCardShelfRenderer) shelves[shelves.length - 1].card = o.musicCardShelfRenderer;
      }
      for (const k in o) walk(o[k], depth + 1);
    })(j, 0);

    const take = (r, label) => {
      const it = parseListItem(r);
      if (!it) return;
      if (it.type === 'song') {
        if (seen.has(it.track.videoId)) return;
        seen.add(it.track.videoId);
        it.track.shelf = label;
        out.songs.push(it.track);
      } else {
        if (!it.shelf.browseId || seen.has(it.shelf.browseId)) return;
        seen.add(it.shelf.browseId);
        (it.type === 'album' ? out.albums : it.type === 'artist' ? out.artists : out.playlists)
          .push(it.shelf);
      }
    };

    // Ordered so the trustworthy shelves are consumed first and therefore win
    // the de-duplication above.
    const rank = (label) => {
      const l = (label || '').toLowerCase();
      if (!l || l.includes('top result')) return 0;
      if (l.includes('song')) return 1;
      if (l.includes('album') || l.includes('artist')) return 2;
      if (l.includes('video')) return 4;          // user uploads and reposts
      if (l.includes('community') || l.includes('podcast') || l.includes('episode')) return 5;
      return 3;
    };
    shelves.sort((a, b) => rank(a.label) - rank(b.label));

    for (const shelf of shelves) {
      for (const row of shelf.rows) {
        const r = row.musicResponsiveListItemRenderer;
        if (r) take(r, shelf.label);
      }
      if (out.songs.length > 60) break;
    }

    // Anything the shelf walk missed still gets in, just last.
    for (const r of collect(j, 'musicResponsiveListItemRenderer', 120)) take(r, null);

    // The filtered responses, each of which is only ever one kind. Their
    // items are read after the main pass so a song that also appears there
    // keeps its place in the song list.
    for (const [doc, label] of [[jAlbums, 'Albums'], [jArtists, 'Artists'],
                                [jPlaylists, 'Playlists']]) {
      if (!doc) continue;
      for (const r of collect(doc, 'musicResponsiveListItemRenderer', 40)) take(r, label);
    }

    // YouTube's own "Top result" — the thing it decided you meant.
    //
    // It arrives as a `musicCardShelfRenderer`, which is a different shape to
    // everything else and is why it was being ignored: its title is the
    // result's name rather than a shelf label, and its item is inline instead
    // of in `contents`. Searching "octane" ought to lead with the album, not
    // with a track that happens to sit inside it, and this is the only field
    // that knows which.
    const card = collect(j, 'musicCardShelfRenderer', 1)[0];
    if (card) {
      const bid = card?.title?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId
               || card?.onTap?.browseEndpoint?.browseId;
      const vid = card?.title?.runs?.[0]?.navigationEndpoint?.watchEndpoint?.videoId
               || card?.onTap?.watchEndpoint?.videoId;
      const title = runs(card.title) || '';
      const subtitle = runs(card.subtitle);
      const art = bestThumb(card?.thumbnail?.musicThumbnailRenderer?.thumbnail, 320);
      if (bid && /^(MPRE|UC|VL|PL|OLAK)/.test(bid)) {
        out.topShelf = {
          browseId: bid, title: title || 'Unknown', subtitle, artworkURL: art,
          kind: bid.startsWith('UC') ? 'artist' : bid.startsWith('MPRE') ? 'album' : 'playlist'
        };
      } else if (vid) {
        out.topTrack = out.songs.find(s => s.videoId === vid)
          || { videoId: vid, title: title || 'Unknown',
               artist: (subtitle || '').split('•').map(s => s.trim()).filter(Boolean)[1] || '',
               album: null, durationText: null, durationSeconds: null, artworkURL: art };
      }
    }

    post({ kind: 'search', requestId: reqId, results: out });
  };

  // ----------------------------------------------------------- async queries
  const queries = {
    // Adding to the queue is a query, not a fire-and-forget command, because
    // YouTube's dispatcher returns true even when it quietly drops the request.
    // The only trustworthy signal is whether the queue actually grew, so we
    // measure it and report back rather than claiming success.
    // Queue mutation goes through the Redux store, not through endpoints.
    //
    // `queueAddEndpoint` is a dead end: resolveCommand, handleServiceEndpoint
    // and a yt-service-request event all accept it, return success, and change
    // nothing — while its onEmptyQueue fallback hijacks playback. Watching what
    // a genuine menu click dispatches shows the real mechanism is an ADD_ITEMS
    // action carrying a full playlistPanelVideoRenderer, which /next provides.
    enqueue: async (reqId, videoId, atEnd) => {
      const q = QUEUE();
      const count = () => { try { return q.getItems().length; } catch (e) { return -1; } };
      const before = count();

      // Nothing queued yet: adding to an empty queue and leaving it stopped is
      // not what anyone means by "play next", so just play it.
      if (before <= 0) {
        cmds.playVideo(videoId);
        post({ kind: 'enqueue', requestId: reqId, result: {
          ok: true, before, after: 1, usedRealEndpoint: true, hijackedPlayback: false }});
        return;
      }

      pushUndo(atEnd ? 'add' : 'play next');
      const renderer = await fetchQueueRenderer(videoId);
      if (!renderer) {
        post({ kind: 'enqueue', requestId: reqId, result: {
          ok: false, before, after: before, usedRealEndpoint: false, hijackedPlayback: false }});
        return;
      }

      try {
        const state = q.store.getState().queue;
        q.store.dispatch({ type: 'ADD_ITEMS', payload: {
          nextQueueItemId: state.nextQueueItemId,
          index: atEnd ? q.getItems().length : q.getCurrentItemIndex() + 1,
          items: [renderer],
          shouldAssignIds: true }});
      } catch (e) {}

      await new Promise(r => setTimeout(r, 500));
      const after = count();
      post({ kind: 'enqueue', requestId: reqId, result: {
        ok: after > before, before, after,
        usedRealEndpoint: true, hijackedPlayback: false }});
    },

    // Premium offline download. Only YouTube's own endpoint works here; there
    // is nothing sensible to synthesise, so absence is reported as unsupported
    // rather than silently doing nothing.
    download: async (reqId, videoId, remove) => {
      const app = APP();
      const cached = endpointCache.get(videoId) || {};
      const ep = remove ? cached.removeDownload : cached.download;
      if (!ep) {
        post({ kind: 'download', requestId: reqId, result: {
          supported: false, ok: false,
          reason: ytcfg.get('LOGGED_IN')
            ? 'This item has no download action — the web player may not offer offline downloads on this account.'
            : 'Sign in to download.' }});
        return;
      }
      let ok = true;
      try { app.resolveCommand(ep); } catch (e) { ok = false; }
      await new Promise(r => setTimeout(r, 1200));
      post({ kind: 'download', requestId: reqId, result: {
        supported: true, ok, reason: '' }});
    },

    // YouTube's own lyrics: plain text only. Every client context returns the
    // same shape — no `timedLyrics`, no cue ranges — so this is the fallback
    // for tracks LRCLIB has never seen, not the primary source.
    lyrics: async (reqId, videoId) => {
      let text = null, source = null;
      try {
        const nx = await innertube('next', { videoId });
        const tabs = nx?.contents?.singleColumnMusicWatchNextResultsRenderer
          ?.tabbedRenderer?.watchNextTabbedResultsRenderer?.tabs || [];
        const tab = tabs.find(t => /lyric/i.test(runs(t?.tabRenderer?.title) || t?.tabRenderer?.title || ''));
        const browseId = tab?.tabRenderer?.endpoint?.browseEndpoint?.browseId;
        if (browseId) {
          const lj = await innertube('browse', { browseId });
          const shelf = collect(lj, 'musicDescriptionShelfRenderer', 1)[0];
          text = runs(shelf?.description);
          source = runs(shelf?.footer);
        }
      } catch (e) {}
      post({ kind: 'lyrics', requestId: reqId, result: { text, source } });
    },

    // Search, keeping the shelf each result came from *when there is one*.
    //
    // Measured on a real "Power" search, the response contained one
    // `sectionListRenderer`, one `musicCardShelfRenderer` (the top-result card)
    // and **29 `itemSectionRenderer` blocks with no `musicShelfRenderer` and no
    // shelf titles at all**. So on that shape this walk finds nothing and the
    // flat fallback below does the collecting — the shelf pass is worth keeping
    // because filtered and browse-style searches do still come back grouped,
    // but it must not be relied on. The real re-ranking happens in Swift, where
    // the listening history is, and that is what moved Kanye West's "POWER"
    // above a Monkey Safari remix and a reupload titled "Kanye West - POWER".
    search: async (reqId, query, scopeParams) => {
      // A scoped search is a single filtered request and nothing else — the
      // chips are YouTube's own, so its own filtered ranking is what shows.
      if (!scopeParams) return await allScopeSearch(reqId, query);

      const doc = await innertube('search', { query, params: scopeParams });
      const out = { songs: [], albums: [], artists: [], playlists: [] };
      const seen = new Set();
      for (const r of collect(doc, 'musicResponsiveListItemRenderer', 60)) {
        const it = parseListItem(r);
        if (!it) continue;
        if (it.type === 'song') {
          if (seen.has(it.track.videoId)) continue;
          seen.add(it.track.videoId);
          out.songs.push(it.track);
        } else {
          if (!it.shelf.browseId || seen.has(it.shelf.browseId)) continue;
          seen.add(it.shelf.browseId);
          (it.type === 'album' ? out.albums : it.type === 'artist' ? out.artists : out.playlists)
            .push(it.shelf);
        }
      }
      post({ kind: 'search', requestId: reqId, results: out });
    },


    library: async (reqId) => {
      const sections = [];
      const grab = async (browseId, label) => {
        try {
          const j = await innertube('browse', { browseId });
          const shelves = [];
          const seen = new Set();
          for (const r of collect(j, 'musicTwoRowItemRenderer', 200)) {
            const browse = r?.navigationEndpoint?.browseEndpoint?.browseId;
            if (!browse || seen.has(browse)) continue;
            seen.add(browse);
            shelves.push({
              browseId: browse,
              title: runs(r.title) || 'Unknown',
              subtitle: runs(r.subtitle),
              artworkURL: bestThumb(r?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail, 240),
              kind: browse.startsWith('UC') ? 'artist' : browse.startsWith('MPRE') ? 'album' : 'playlist'
            });
          }
          if (shelves.length) sections.push({ title: label, items: shelves });
        } catch (e) { /* a missing shelf should not kill the whole library */ }
      };
      await grab('FEmusic_offline', 'Downloads');
      await grab('FEmusic_liked_playlists', 'Playlists');
      await grab('FEmusic_liked_albums', 'Albums');
      await grab('FEmusic_library_corpus_track_artists', 'Artists');
      post({ kind: 'library', requestId: reqId, sections });
    },

    playlist: async (reqId, browseId) => {
      const j = await innertube('browse', { browseId });
      const tracks = [];
      const seen = new Set();
      for (const r of collect(j, 'musicResponsiveListItemRenderer', 400)) {
        const parsed = parseListItem(r);
        if (parsed?.type === 'song' && !seen.has(parsed.track.videoId)) {
          seen.add(parsed.track.videoId);
          tracks.push(parsed.track);
        }
      }

      // An artist page is a different document to an album page and was being
      // read as if it were one. It carries a `musicImmersiveHeaderRenderer`
      // rather than a detail header, so the title fell through to the literal
      // string "Playlist" and the artwork came out empty; and its albums live
      // in carousels of `musicTwoRowItemRenderer`, which nothing here looked
      // at, so opening an artist showed five songs and nothing else.
      const isArtist = /^UC/.test(browseId || '');
      const immersive = collect(j, 'musicImmersiveHeaderRenderer', 1)[0];
      const header = collect(j, 'musicDetailHeaderRenderer', 1)[0]
                  || collect(j, 'musicResponsiveHeaderRenderer', 1)[0]
                  || immersive;

      // Carousels: "Albums", "Singles & EPs", "Videos", "Featured on"…
      const sections = [];
      for (const car of collect(j, 'musicCarouselShelfRenderer', 12)) {
        const title = runs(car?.header?.musicCarouselShelfBasicHeaderRenderer?.title) || '';
        const items = [];
        const pushed = new Set();
        for (const row of (car.contents || [])) {
          const r = row.musicTwoRowItemRenderer;
          if (!r) continue;
          const bid = r?.navigationEndpoint?.browseEndpoint?.browseId;
          if (!bid || pushed.has(bid)) continue;
          pushed.add(bid);
          items.push({
            browseId: bid,
            title: runs(r.title) || 'Unknown',
            subtitle: runs(r.subtitle),
            artworkURL: bestThumb(r?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail, 240),
            kind: bid.startsWith('UC') ? 'artist' : bid.startsWith('MPRE') ? 'album' : 'playlist'
          });
        }
        if (title && items.length) sections.push({ title, items });
      }
      // Playing a whole album via its playlistId lets YouTube build the queue
      // in one shot, instead of us enqueueing every track one request at a time.
      let playlistId = null;
      for (const btn of collect(j, 'musicPlayButtonRenderer', 8)) {
        const pid = btn?.playNavigationEndpoint?.watchEndpoint?.playlistId;
        if (pid) { playlistId = pid; break; }
      }
      post({ kind: 'playlist', requestId: reqId, detail: {
        title: runs(header?.title) || (isArtist ? 'Artist' : 'Playlist'),
        subtitle: runs(header?.subtitle) || runs(header?.description),
        playlistId,
        // An immersive header keeps its picture under a different key again.
        artworkURL: bestThumb(header?.thumbnail?.musicThumbnailRenderer?.thumbnail
                           || header?.thumbnail?.croppedSquareThumbnailRenderer?.thumbnail
                           || immersive?.thumbnail?.musicThumbnailRenderer?.thumbnail, 544),
        tracks,
        sections,
        kind: isArtist ? 'artist' : (browseId || '').startsWith('MPRE') ? 'album' : 'playlist'
      }});
    }
  };

  window.__prism = {
    cmd: (name, ...args) => { try { return cmds[name]?.(...args); } catch (e) { return false; } },
    query: (name, reqId, ...args) => {
      const fn = queries[name];
      if (!fn) { post({ kind: 'error', requestId: reqId, message: 'unknown query ' + name }); return; }
      fn(reqId, ...args).catch(e =>
        post({ kind: 'error', requestId: reqId, message: String(e && e.message || e) }));
    },
    ping: () => pushState(true)
  };

  pushState(true);
})();
"""#
}
