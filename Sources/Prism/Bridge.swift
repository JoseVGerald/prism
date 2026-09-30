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

  // The *other* side of YouTube Music's Song/Video pair, when the track has one.
  //
  // A song played from an album arrives as an ATV renderer — static art, no
  // picture — even when an official video of the same track exists. The link
  // between the two is not in the renderer we unwrap above: it sits alongside
  // it, in the wrapper's `counterpart` array, and it was being dropped on the
  // floor. That is why a song with a music video showed no way to watch it.
  //
  // The pairing is already in the queue we poll, so nothing extra is fetched.
  const counterpartOf = (it) => {
    const c = it?.playlistPanelVideoWrapperRenderer?.counterpart?.[0]
      ?.counterpartRenderer?.playlistPanelVideoRenderer;
    if (!c || !c.videoId) return null;
    return {
      videoId: c.videoId,
      videoType: c?.navigationEndpoint?.watchEndpoint
        ?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType || null
    };
  };

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
      const other = counterpartOf(it);
      items.push({
        counterpartId: other?.videoId || null,
        counterpartType: other?.videoType || null,
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

    // Which half of a Song/Video pair is on screen, and what the other half is.
    //
    // The queue row keeps naming the song even while the video is playing, so
    // reading `videoType` straight off it would report ATV — no picture — over
    // a music video. Match the player's own id against the pair instead, and
    // report the side actually playing plus the id to switch to.
    let activeType = currentEntry?.videoType || null;
    let counterpartId = currentEntry?.counterpartId || null;
    if (currentEntry && vd && vd.video_id && vd.video_id === currentEntry.counterpartId) {
      activeType = currentEntry.counterpartType;
      counterpartId = currentEntry.videoId;
    }

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
      videoType: activeType,
      counterpartId,
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

  // ---------------------------------------------------- video quality
  //
  // Left alone, YouTube picks 360p and is right to: it sizes the stream to the
  // <video> element, and outside video mode Prism collapses that element to
  // 0x0. Measured on a 63 Mbps connection it served 640x360 (itag 134) while
  // 1080p sat unused in the same manifest, and forcing hd1080 switched it to
  // 1920x1080 (itag 137) within seconds.
  //
  // The preference has to be re-applied per track — loading a video resets the
  // range — so it is held here and pushed on each change of video id.
  let videoQualityPref = 'auto';
  let qualityAppliedTo = '';

  const applyVideoQuality = (videoId) => {
    if (!videoId || videoId === qualityAppliedTo) return;
    const p = PLAYER();
    if (!p || !p.setPlaybackQualityRange) return;
    qualityAppliedTo = videoId;
    try {
      if (videoQualityPref === 'auto') {
        p.setPlaybackQualityRange('auto', 'auto');
      } else {
        p.setPlaybackQualityRange(videoQualityPref, videoQualityPref);
        p.setPlaybackQuality(videoQualityPref);
      }
    } catch (e) {}
  };

  // ------------------------------------------------------ queue tracing
  //
  // Answers one question: when the queue changes, who changed it?
  //
  // Prism's own mutations all announce themselves through `blame`, which holds
  // a label for a couple of seconds — long enough to cover the async settle
  // after a dispatch, short enough that an unrelated change later cannot
  // inherit it. A change with no live label was nobody in this app, which
  // means YouTube did it: autoplay extending the end, a dynamic-queue update,
  // or the server replacing the queue outright.
  //
  // Off unless Swift turns it on, and Swift only does that under PRISM_EVAL.
  let queueTrace = false;
  let blameLabel = null;
  let blameAt = 0;
  const BLAME_TTL = 2500;

  const blame = (label) => { blameLabel = label; blameAt = Date.now(); };

  const currentBlame = () =>
    (blameLabel && Date.now() - blameAt < BLAME_TTL) ? blameLabel : null;

  let lastQueueIds = null;
  let lastQueueIndex = -1;

  const traceQueue = (s) => {
    if (!queueTrace) return;
    const ids = s.queue.map(i => i.videoId);
    const idx = s.queueIndex;
    if (lastQueueIds === null) { lastQueueIds = ids; lastQueueIndex = idx; return; }

    const sameOrder = ids.length === lastQueueIds.length
      && ids.every((v, i) => v === lastQueueIds[i]);
    if (sameOrder && idx === lastQueueIndex) return;

    const before = lastQueueIds, beforeIdx = lastQueueIndex;
    lastQueueIds = ids; lastQueueIndex = idx;

    const beforeSet = new Set(before), afterSet = new Set(ids);
    const added = ids.filter(v => !beforeSet.has(v));
    const removed = before.filter(v => !afterSet.has(v));

    // Same members, different order — the case that reads as "it rearranged
    // itself" and the one a length check would miss entirely.
    const reordered = !sameOrder && added.length === 0 && removed.length === 0;

    let shape;
    if (before.length === ids.length && sameOrder) {
      shape = 'index only (' + beforeIdx + ' -> ' + idx + ')';
    } else if (reordered) {
      shape = 'REORDERED, same ' + ids.length + ' tracks';
    } else {
      shape = before.length + ' -> ' + ids.length + ' tracks'
            + (added.length ? ', +' + added.length : '')
            + (removed.length ? ', -' + removed.length : '');
    }

    const note = Date.now() - stableNoteAt < 1500 ? stableNote : null;
    post({ kind: 'queueChange', trace: {
      cause: currentBlame() || note || 'NOBODY — YouTube changed it',
      shape,
      index: beforeIdx + ' -> ' + idx,
      playing: (s.track && s.track.title) || null,
      added: added.slice(0, 4),
      removed: removed.slice(0, 4),
      head: ids.slice(0, 3)
    }});
  };

  const pushState = (force) => {
    // Runs on every queue-store change (see hookStore) and every tick.
    onQueueStore();
    const s = snapshot();
    traceQueue(s);
    applyVideoQuality(s.track && s.track.videoId);
    // Cheap change detection so we are not shipping identical payloads 4x a
    // second; time is rounded so a playing track still updates the scrubber.
    // Order is part of the identity: a reorder changes neither the length nor
    // the index, so hashing those alone would swallow every move.
    const hash = [s.state, s.track?.videoId, Math.floor(s.currentTime), s.duration,
                  s.queue.length, s.queueIndex, s.repeatMode, s.shuffled,
                  s.volume, s.muted, s.signedIn, s.undoLabel,
                  // The pairing lands a beat after the track does — the queue
                  // re-renders once the wrapper arrives — so without these two
                  // the push carrying it is swallowed as a duplicate and the
                  // Song/Video switcher never appears.
                  s.videoType, s.counterpartId,
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

  // --------------------------------------------------------- stable queue
  //
  // A radio's queue is not yours in the web player: YouTube empties it and
  // refills it with a different fifty songs every track or so — measured, the
  // queue trace logged "0 -> 50 tracks, cause: NOBODY" twenty-eight times, the
  // first song the same each time and the other forty-nine new. So Prism keeps
  // the queue it last agreed to, and when YouTube swaps it out on its own, puts
  // it back.
  //
  // What counts as agreeing: any edit made from Prism (add, remove, reorder,
  // shuffle, play something new, undo) — and, for a few seconds after one, what
  // YouTube fills in, since a new radio arrives in two steps. Moving through the
  // queue (skip, previous, jumping to a row, a crossfade handing over) is not an
  // edit, so a skip no longer reshuffles what comes next. When the kept queue
  // is nearly used up, YouTube's new songs are appended after it, so a radio
  // still never runs dry. Rate-limited: if YouTube insists four times in twenty
  // seconds, its list stands.
  let stableOn = false;
  let kept = null;              // { items, ids }
  let adoptUntil = 0;
  let restoring = false;
  let restores = [];
  let stableNote = null, stableNoteAt = 0;

  const NAVIGATION = /^(next|previous|jump to queue row|crossfade handover)/;
  const editBlame = () => {
    const b = currentBlame();
    return b && !NAVIGATION.test(b) ? b : null;
  };
  const idsOf = (items) => items.map(it => unwrapQueueItem(it)?.videoId || null);

  const onQueueStore = () => {
    if (!stableOn || restoring) return;
    const q = QUEUE(); if (!q) return;
    let items;
    try { items = q.getItems() || []; } catch (e) { return; }
    const ids = idsOf(items);
    const now = Date.now();

    if (editBlame()) adoptUntil = now + 6000;
    if (!kept || now < adoptUntil) {
      if (items.length) kept = { items: items.slice(), ids };
      return;
    }
    if (!items.length) return;              // emptied mid-rebuild: act on the refill
    if (ids.length === kept.ids.length && ids.every((v, i) => v === kept.ids[i])) return;

    const playing = PLAYER()?.getVideoData?.()?.video_id;
    const at = kept.ids.indexOf(playing);
    // Playing something the kept queue never had: not ours to override.
    if (at < 0) { kept = { items: items.slice(), ids }; return; }

    restores = restores.filter(t => now - t < 20000);
    if (restores.length >= 4) { kept = { items: items.slice(), ids }; return; }
    restores.push(now);

    const merged = kept.items.slice();
    if (merged.length - 1 - at < 8) {
      const have = new Set(kept.ids);
      for (const it of items) {
        const id = unwrapQueueItem(it)?.videoId;
        if (id && !have.has(id)) { merged.push(it); have.add(id); }
      }
    }
    restoring = true;
    stableNote = 'stable queue — YouTube rebuilt it, Prism put yours back';
    stableNoteAt = now;
    try {
      q.store.dispatch({ type: 'RESET_ITEMS', payload: merged });
      q.store.dispatch({ type: 'SET_INDEX', payload: at });
    } catch (e) {}
    restoring = false;
    kept = { items: merged, ids: idsOf(merged) };
    pushState(true);
  };

  // ---------------------------------------------------------------- clock
  // The exact playback position, for lyrics, on only while something needs it.
  // Snapshots go out when the whole second changes, so between them Prism was
  // guessing, and a seek, pause or tempo change went unseen until the next.
  // This reads the video itself on every `timeupdate` and at once on a seek,
  // pause, play or rate change, stamped with the wall-clock moment it was read.
  //
  // Media events, not a timer: this page is hidden behind Prism's UI, and
  // WebKit throttles a hidden page's repeating timers to once a second —
  // measured, a 100ms interval ran at 1000ms. `timeupdate` is driven by the
  // media and kept its 250ms pace (measured). Media events do not bubble, so
  // they are caught on the way down (capture) at the document, which also
  // survives the player swapping its <video> element.
  let clockOn = false;
  const clockTick = () => {
    const p = PLAYER();
    const v = p?.querySelector('video');
    if (!v) return;
    let id = null;
    try { id = p.getVideoData()?.video_id || null; } catch (e) {}
    post({
      kind: 'clock', t: v.currentTime, rate: v.playbackRate || 1,
      playing: !v.paused && !v.seeking && v.readyState > 2,
      at: performance.timeOrigin + performance.now(), videoId: id
    });
  };
  const CLOCK_EVENTS = ['timeupdate', 'seeked', 'pause', 'play', 'playing', 'ratechange', 'waiting'];
  const setClock = (on) => {
    if (on === clockOn) return;
    clockOn = on;
    CLOCK_EVENTS.forEach(e => on ? document.addEventListener(e, clockTick, true)
                                 : document.removeEventListener(e, clockTick, true));
    if (on) clockTick();
  };

  // ---------------------------------------------------------------- commands
  const cmds = {
    clock: (on) => setClock(!!on),
    play:  () => { PLAYER()?.playVideo(); },
    pause: () => { PLAYER()?.pauseVideo(); },
    toggle: () => {
      const p = PLAYER(); if (!p) return;
      const s = p.getPlayerState();
      (s === 1 || s === 3) ? p.pauseVideo() : p.playVideo();
    },
    next: () => { blame('next (button, menu or media key)'); PLAYER()?.nextVideo(); },
    prev: () => { blame('previous'); PLAYER()?.previousVideo(); },
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
      blame('jump to queue row ' + i);
      const q = QUEUE(); if (!q) return;
      const items = q.getItems() || [];
      if (i < 0 || i >= items.length) return;
      try { q.selectQueueItem(items[i]); return; } catch (e) {}
      const vid = unwrapQueueItem(items[i])?.videoId;
      if (vid) cmds.playVideo(vid);
    },

    undoQueue: () => {
      blame('undo');
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
      blame('remove row ' + i);
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
      blame('drag row ' + from + ' to ' + to);
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
      blame('clear queue');
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

    // Shuffles what is *coming*, leaving the track you are listening to alone.
    //
    // YouTube's own `shuffle()` reorders the whole list including the current
    // item, so pressing it mid-song threw you somewhere else in the queue —
    // which is not what shuffling a queue means when something is already
    // playing. Everything up to and including the current index is kept in
    // place (so history stays in the order it happened) and only the tail is
    // permuted, with a plain Fisher-Yates.
    shuffle: () => {
      blame('shuffle (Cmd-Shift-S or the shuffle button)');
      const q = QUEUE(); if (!q) return;
      const items = q.getItems() || [];
      const cur = q.getCurrentItemIndex();

      // Nothing playing, or nothing after it: fall back to YouTube's shuffle,
      // which is the right behaviour for an idle queue.
      if (cur < 0 || cur >= items.length - 1) {
        try { q.shuffle(); } catch (e) {}
        return;
      }

      pushUndo('shuffle');
      const head = items.slice(0, cur + 1);
      const tail = items.slice(cur + 1);
      for (let i = tail.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        const t = tail[i]; tail[i] = tail[j]; tail[j] = t;
      }
      try {
        q.store.dispatch({ type: 'RESET_ITEMS', payload: head.concat(tail) });
        q.store.dispatch({ type: 'SET_INDEX', payload: cur });
      } catch (e) {}
      pushState(true);
    },

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
      blame(radio ? 'play track — seeds a RADIO, which replaces the queue'
                  : 'play track (no radio)');
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

    // Lets Swift attribute a change it is about to cause. Used by the
    // crossfade handover, which advances the queue without any button press.
    noteQueueCause: (label) => { blame(String(label)); return true; },

    setQueueTrace: (on) => { queueTrace = !!on; return true; },
    setStableQueue: (on) => {
      stableOn = !!on;
      kept = null;              // start from whatever the queue is now
      if (stableOn) onQueueStore();
      return true;
    },

    // 'auto', or a YouTube quality level such as 'hd1080'. Applied now and
    // again on every track, since loading one resets the range.
    setVideoQuality: (level) => {
      videoQualityPref = level || 'auto';
      qualityAppliedTo = '';
      const p = PLAYER();
      let vd = null;
      try { vd = p && p.getVideoData(); } catch (e) {}
      applyVideoQuality(vd && vd.video_id);
      return true;
    },

    // Switches between the song and its music video.
    //
    // Deliberately YouTube's own control rather than `loadVideoById` on the
    // counterpart, which would restart from zero and drop the queue.
    //
    // Clicking the button carries the position across. Measured against wall
    // clock over a full round trip, each switch loses 0.75-0.93s to loading and
    // nothing else: -1.68s net, song to video and back. (YouTube also ships a
    // `segmentMap` next to the counterpart, for pairs whose timelines really do
    // differ; this pair's do not, so it is not visible in that measurement.)
    setAVMode: (wantVideo) => {
      blame('song/video switch');
      const t = document.querySelector('ytmusic-av-toggle');
      if (!t) return false;
      const b = t.querySelector(wantVideo ? '.video-button' : '.song-button');
      if (!b) return false;
      b.click();
      return true;
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
      blame('play playlist');
      const app = APP();
      if (app) app.resolveCommand({ watchEndpoint: { playlistId } });
    },

    playBrowse: (browseId, playlistId) => {
      blame('play album/artist');
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
  // --------------------------------------------------- audio quality
  //
  // Audio quality is an *account* preference, not a player one. The player
  // exposes `setUserAudioQualitySetting`, and it is inert: every value from 0
  // to 5 was pushed into it live and `getUserAudioQualitySetting` stayed on 2
  // throughout, with the stream still on opus itag 251. There is also no
  // InnerTube surface for it — `browse` on SPaccount_playback returns
  // INVALID_ARGUMENT, and the account menu carries only an
  // `applicationSettingsEndpoint: { hack: true }`, which is a client-side
  // dialog rather than a page.
  //
  // So the dialog is the mechanism. Nothing else moves this setting.
  const AUDIO_QUALITY_LABELS = ['Low', 'Normal', 'High'];

  // What this page has successfully set, which outranks what the dialog says.
  //
  // The settings response is fetched once per document and cached by the app,
  // so a change made during the session is invisible to every later read:
  // measured, setting High reported success, the very next read said Normal,
  // and a full reload said High. Without this the panel silently reverts to the
  // old value the next time it is opened, which looks exactly like the control
  // refusing to take the change.
  //
  // Page-scoped on purpose. The bridge re-injects on every document, so a
  // reload drops it and the freshly fetched value wins again.
  let audioQualityWritten = null;

  const settingsDialog = () => document.querySelector('ytmusic-dialog');

  const settle = (ms) => new Promise(r => setTimeout(r, ms));

  /// Opens the settings dialog on its Playback tab and hands back the row that
  /// owns the audio quality dropdown.
  const openAudioQualityRow = async () => {
    const app = APP();
    if (!app) return null;

    // Always re-issue the endpoint, never reuse a dialog that is already there.
    //
    // Closing the dialog leaves its element in the DOM, holding the data it was
    // built with — so a second read answers from a snapshot of the setting as it
    // was on the first read, forever. That is what made the panel insist the
    // account was on Normal: the reply came back in 103ms (too fast to have
    // opened anything) saying Normal, while the account was on High and the
    // stream was itag 141 at 257kbps. Re-resolving builds a fresh renderer.
    const rowIn = (dlg) => !dlg ? null
      : ([...dlg.querySelectorAll('ytmusic-setting-single-option-menu-renderer')]
          .find(r => /audio quality/i.test(r.innerText || '')) || null);

    // Whatever is on screen now is the thing not to trust. Re-resolving replaces
    // the renderer with a new object, so waiting for the identity to change is
    // what proves the data is fresh — without it a read can land on the old row
    // before the rebuild finishes and report the stale value anyway.
    const stale = rowIn(settingsDialog());
    app.resolveCommand({ applicationSettingsEndpoint: { hack: true } });

    for (let i = 0; i < 40; i++) {
      const dlg = settingsDialog();
      const r = rowIn(dlg);
      if (r && r !== stale) return r;
      // A rebuilt dialog lands on General, where the row does not exist at all;
      // the dropdown only lives under Playback.
      if (dlg) {
        const tab = [...dlg.querySelectorAll('*')].find(
          e => e.children.length === 0 && (e.textContent || '').trim() === 'Playback');
        if (tab) tab.click();
      }
      await settle(200);
    }
    return rowIn(settingsDialog());
  };

  const closeSettings = () => {
    const dlg = settingsDialog();
    if (!dlg) return;
    // Closed, never removed. Tearing the element out leaves the app believing
    // the dialog is still up, and every later attempt to open it does nothing.
    try { dlg.close ? dlg.close() : dlg.removeAttribute('opened'); } catch (e) {}
  };

  /// The setting's options, straight off the renderer's data.
  ///
  /// Not read out of the rendered text, and not set by clicking. The dropdown
  /// is a Polymer `tp-yt-paper-dropdown-menu` that opens on a gesture, and a
  /// synthetic `.click()` does not open it — the listbox stays with a null
  /// `offsetParent` and the option elements underneath are inert `div`s. Every
  /// click-driven attempt reported success and changed nothing.
  ///
  /// The data behind it carries what is needed: each option has a
  /// `setSettingEndpoint` (MUSIC_WEB_AUDIO_QUALITY, item 304, Low/Normal/High
  /// as 1/2/3) and a `selected` flag.
  const audioQualityItems = (row) => {
    try {
      return (row.data.items || [])
        .map(i => i.settingMenuItemRenderer)
        .filter(i => i && AUDIO_QUALITY_LABELS.includes(i.name));
    } catch (e) { return []; }
  };

  const readAudioQuality = (row) => {
    if (audioQualityWritten) return audioQualityWritten;
    const sel = audioQualityItems(row).find(i => i.selected);
    return sel ? sel.name : null;
  };

  const queries = {

    audioQuality: async (reqId, want) => {
      const row = await openAudioQualityRow();
      if (!row) {
        post({ kind: 'audioQuality', requestId: reqId,
               result: { ok: false, current: null, reason: 'no settings dialog' }});
        return;
      }

      const before = readAudioQuality(row);
      if (!want || want === before) {
        closeSettings();
        post({ kind: 'audioQuality', requestId: reqId,
               result: { ok: true, current: before, changed: false }});
        return;
      }

      const option = audioQualityItems(row).find(i => i.name === want);
      if (!option || !option.updateServiceEndpoint) {
        closeSettings();
        post({ kind: 'audioQuality', requestId: reqId,
               result: { ok: false, current: before, reason: 'no endpoint for ' + want }});
        return;
      }

      let dispatched = true;
      try { APP().resolveCommand(option.updateServiceEndpoint); }
      catch (e) { dispatched = false; }
      if (dispatched) audioQualityWritten = want;
      await settle(700);
      closeSettings();

      // Reported as the requested value rather than re-read, because the
      // renderer's own `selected` flags do not move when the endpoint lands —
      // the dialog keeps showing the old choice until the page is reloaded.
      // Confirmed the hard way: after dispatching High the model still said
      // Normal, a reload said High, and the next track came down as itag 141
      // at 257 kbps instead of opus 251 at 130.
      post({ kind: 'audioQuality', requestId: reqId,
             result: { ok: dispatched, current: dispatched ? want : before,
                       changed: dispatched,
                       reason: dispatched ? null : 'YouTube Music rejected the change' }});
    },

    /// What is actually coming down the wire, as opposed to what was asked for.
    streamQuality: async (reqId) => {
      const p = PLAYER();
      let stats = null;
      try { stats = p && p.getStatsForNerds ? p.getStatsForNerds() : null; } catch (e) {}
      // "avc1.4d401e (134) / opus (251)" is video first, audio second — but only
      // when both are being decoded. Outside video mode the element is 0x0 and
      // the string carries the audio alone, so reading by position put an opus
      // itag in the video slot. Each itag is classified against the manifest
      // instead, which cannot be fooled by a missing half.
      const codecs = stats && stats.codecs || '';
      const itags = (codecs.match(/\((\d+)\)/g) || [])
        .map(s => Number(s.replace(/[()]/g, '')));

      let all = [];
      try {
        const r = p.getPlayerResponse ? p.getPlayerResponse() : null;
        all = ((r && r.streamingData && r.streamingData.adaptiveFormats) || [])
          .map(f => ({ itag: f.itag,
                       audio: (f.mimeType || '').indexOf('audio') === 0,
                       bitrate: f.averageBitrate || f.bitrate,
                       codec: ((f.mimeType || '').match(/codecs="([^"]+)"/) || [])[1] || null }));
      } catch (e) {}

      const kindOf = (itag) => all.find(f => f.itag === itag) || null;
      const audio = itags.find(t => kindOf(t) && kindOf(t).audio) ?? null;
      const video = itags.find(t => kindOf(t) && !kindOf(t).audio) ?? null;

      const formats = all.filter(f => f.audio);
      const playing = kindOf(audio);
      post({ kind: 'streamQuality', requestId: reqId, result: {
        audioItag: audio, videoItag: video,
        audioCodec: playing && playing.codec,
        audioBitrate: playing && playing.bitrate,
        bestAudioBitrate: formats.reduce((m, f) => Math.max(m, f.bitrate || 0), 0) || null,
        // "0x0" is what a collapsed video element reports, which is not a
        // resolution and should not be shown as one.
        resolution: (stats && stats.resolution || '').indexOf('0x0') === 0
          ? null : (stats && stats.resolution || null),
        videoQuality: (() => { try { return p.getPlaybackQuality(); } catch (e) { return null; } })()
      }});
    },

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

      blame(atEnd ? 'add to queue' : 'play next');
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

    // YouTube's own lyrics as the web client sees them: plain text. The
    // lyrics page's browseId goes back too — asked for as the Android app,
    // the same page comes back *timed* (Swift makes that request; see
    // LyricsService.youtubeTimed).
    lyrics: async (reqId, videoId) => {
      let text = null, source = null, browseId = null;
      try {
        const nx = await innertube('next', { videoId });
        const tabs = nx?.contents?.singleColumnMusicWatchNextResultsRenderer
          ?.tabbedRenderer?.watchNextTabbedResultsRenderer?.tabs || [];
        const tab = tabs.find(t => /lyric/i.test(runs(t?.tabRenderer?.title) || t?.tabRenderer?.title || ''));
        browseId = tab?.tabRenderer?.endpoint?.browseEndpoint?.browseId || null;
        if (browseId) {
          const lj = await innertube('browse', { browseId });
          const shelf = collect(lj, 'musicDescriptionShelfRenderer', 1)[0];
          text = runs(shelf?.description);
          source = runs(shelf?.footer);
        }
      } catch (e) {}
      post({ kind: 'lyrics', requestId: reqId, result: { text, source, browseId } });
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


    // Your YouTube Music history, from every device you listen on. Shelves
    // are day buckets ("Today", "Yesterday", "This week"…), newest first.
    // Measured before: about two weeks, one entry per song, no times and no
    // continuation — fine for a recently played list, not for statistics.
    history: async (reqId) => {
      const j = await innertube('browse', { browseId: 'FEmusic_history' });
      const sections = [];
      const seen = new Set();
      for (const shelf of collect(j, 'musicShelfRenderer', 20)) {
        const tracks = [];
        for (const row of (shelf.contents || [])) {
          const p = parseListItem(row.musicResponsiveListItemRenderer);
          if (p?.type === 'song' && !seen.has(p.track.videoId)) {
            seen.add(p.track.videoId);
            tracks.push(p.track);
          }
        }
        if (tracks.length) sections.push({ title: runs(shelf.title) || '', tracks });
      }
      post({ kind: 'history', requestId: reqId, sections });
    },

    // Your playlists from the library — the ones songs can be added to.
    // Liked Music (VLLM) is left out: it fills itself from likes.
    myPlaylists: async (reqId) => {
      const j = await innertube('browse', { browseId: 'FEmusic_liked_playlists' });
      const playlists = [];
      const seen = new Set();
      for (const r of collect(j, 'musicTwoRowItemRenderer', 300)) {
        const b = r?.navigationEndpoint?.browseEndpoint?.browseId || '';
        if (!b.startsWith('VL') || b === 'VLLM' || seen.has(b)) continue;
        seen.add(b);
        playlists.push({ playlistId: b.slice(2), title: runs(r.title) || 'Untitled',
                         subtitle: runs(r.subtitle) || null,
                         artworkURL: bestThumb(r?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail, 120) });
      }
      post({ kind: 'myPlaylists', requestId: reqId, playlists });
    },

    // Adds songs to a playlist, skipping any it already holds. The skipping
    // is done here: YouTube's own DEDUPE_OPTION_SKIP is accepted and ignored
    // (measured — a song already in the playlist went in a second time). The
    // check reads the playlist's first page, which covers all but very long
    // playlists.
    addToPlaylist: async (reqId, playlistId, videoIds) => {
      let ok = false, error = null, added = 0, skipped = 0;
      try {
        const page = await innertube('browse', { browseId: 'VL' + playlistId });
        const have = new Set(collect(page, 'musicResponsiveListItemRenderer', 500)
          .map(r => r?.playlistItemData?.videoId).filter(Boolean));
        const fresh = [...new Set(videoIds)].filter(v => !have.has(v));
        skipped = videoIds.length - fresh.length;
        if (!fresh.length) {
          ok = true;
        } else {
          const j = await innertube('browse/edit_playlist', {
            playlistId,
            actions: fresh.map(v => ({ action: 'ACTION_ADD_VIDEO', addedVideoId: v })) });
          ok = j?.status === 'STATUS_SUCCEEDED';
          if (ok) added = fresh.length;
          else error = 'YouTube answered ' + (j?.status || 'without a status');
        }
      } catch (e) { error = String(e && e.message || e); }
      post({ kind: 'addToPlaylist', requestId: reqId, result: { ok, error, added, skipped } });
    },

    // A private playlist in the signed-in account, with these songs in order.
    createPlaylist: async (reqId, title, videoIds) => {
      let playlistId = null, error = null;
      try {
        const j = await innertube('playlist/create', {
          title, description: 'Made in Prism', privacyStatus: 'PRIVATE', videoIds });
        playlistId = j?.playlistId || null;
        if (!playlistId) error = 'YouTube did not return a playlist';
      } catch (e) { error = String(e && e.message || e); }
      post({ kind: 'createPlaylist', requestId: reqId, result: { playlistId, error } });
    },

    // YouTube Music's Home feed — Quick picks, your mixes, Listen again, new
    // releases — as the web app gets it for the signed-in account. Shelves are
    // carousels of either song rows (Quick picks) or two-row cards; a card
    // opens a page (album, playlist, artist) or plays straight away (a song,
    // a video, or a mix that is only a playlist id).
    home: async (reqId) => {
      const shelves = [];
      const read = (j) => {
        for (const car of collect(j, 'musicCarouselShelfRenderer', 30)) {
          const h = car?.header?.musicCarouselShelfBasicHeaderRenderer;
          const title = runs(h?.title) || '';
          const items = [];
          const seen = new Set();
          for (const row of (car.contents || [])) {
            const song = row.musicResponsiveListItemRenderer;
            if (song) {
              const p = parseListItem(song);
              if (p?.type === 'song' && !seen.has(p.track.videoId)) {
                seen.add(p.track.videoId);
                items.push({ kind: 'song', title: p.track.title, subtitle: p.track.artist,
                             artworkURL: p.track.artworkURL, videoId: p.track.videoId,
                             browseId: null, playlistId: null });
              }
              continue;
            }
            const r = row.musicTwoRowItemRenderer;
            if (!r) continue;
            const nav = r.navigationEndpoint || {};
            const browseId = nav.browseEndpoint?.browseId || null;
            const videoId = nav.watchEndpoint?.videoId || null;
            const playlistId = nav.watchPlaylistEndpoint?.playlistId || nav.watchEndpoint?.playlistId || null;
            const key = browseId || videoId || playlistId;
            if (!key || seen.has(key)) continue;
            // Podcasts (shows MPSP…, episodes MPED…) are not music.
            if (browseId && /^MP(SP|ED)/.test(browseId)) continue;
            seen.add(key);
            const wide = /16_9/.test(r.aspectRatio || '');
            const kind = videoId ? (wide ? 'video' : 'song')
                       : browseId ? (browseId.startsWith('UC') ? 'artist'
                                   : browseId.startsWith('MPRE') ? 'album' : 'playlist')
                       : 'mix';
            items.push({ kind, title: runs(r.title) || 'Unknown', subtitle: runs(r.subtitle),
                         artworkURL: bestThumb(r?.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail, 360),
                         videoId, browseId, playlistId });
          }
          if (title && items.length) shelves.push({ title, strapline: runs(h?.strapline) || null, items });
        }
      };
      // The feed arrives in pages, and the good shelves are not on the first:
      // measured on a signed-in account, Quick picks was on the second. Four
      // pages covers what the web app shows before you scroll a long way.
      let page = await innertube('browse', { browseId: 'FEmusic_home' });
      read(page);
      for (let i = 0; i < 3; i++) {
        const token = collect(page, 'nextContinuationData', 1)[0]?.continuation;
        if (!token) break;
        try { page = await innertube('browse', { continuation: token }); read(page); }
        catch (e) { break; }
      }
      post({ kind: 'home', requestId: reqId, shelves });
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
