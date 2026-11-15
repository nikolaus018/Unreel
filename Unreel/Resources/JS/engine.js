/*
 * Unreel page engine. Injected at document start into the page's own JavaScript world.
 *
 * Layers, in order of importance:
 *  1. Data cleaning: YouTube's API responses and the embedded initial data are stripped of ad
 *     placements (and optionally Shorts) *before* YouTube's player code reads them.
 *  2. Filter-list scriptlets and response rewrites (uBlock Origin syntax, subset).
 *  3. Cosmetic hiding (built-in CSS + filter-list selectors, including a few procedural ones).
 *  4. Player fallback: if an ad still starts, it is muted, fast-forwarded and skipped.
 */
(function () {
  'use strict';
  if (window.__unreel) return;

  const boot = window.__unreelBoot || {};
  try { delete window.__unreelBoot; } catch (_) { window.__unreelBoot = undefined; }
  let CFG = boot.config || {};
  const RULES = boot.rules || { cosmetic: [], scriptlets: [], replaces: [] };

  const host = location.hostname;
  const isYouTube = /(^|\.)youtube(-nocookie)?\.com$/.test(host);
  if (!isYouTube) return;

  // Keep references to natives before anything (including YouTube) can touch them.
  const N = {
    parse: JSON.parse,
    stringify: JSON.stringify,
    fetch: window.fetch,
    respJson: Response.prototype.json,
    respText: Response.prototype.text,
    xhrOpen: XMLHttpRequest.prototype.open,
    xhrSend: XMLHttpRequest.prototype.send,
    setTimeout: window.setTimeout.bind(window),
    setInterval: window.setInterval.bind(window),
    defineProperty: Object.defineProperty,
    getOwnPropertyDescriptor: Object.getOwnPropertyDescriptor,
  };

  // ---------------------------------------------------------------------------------------------
  // Native bridge
  // ---------------------------------------------------------------------------------------------
  const post = (msg) => {
    try { window.webkit.messageHandlers.unreel.postMessage(msg); } catch (_) {}
  };
  const ask = (msg) => {
    try { return window.webkit.messageHandlers.unreelAsync.postMessage(msg); } catch (_) { return Promise.resolve(null); }
  };
  const log = (...a) => { if (CFG.debug) post({ type: 'log', message: a.map(String).join(' ') }); };

  let blockedCount = 0;
  let statsTimer = 0;
  const countBlocked = (n) => {
    if (!n) return;
    blockedCount += n;
    if (!statsTimer) statsTimer = N.setTimeout(() => { statsTimer = 0; post({ type: 'blocked', count: blockedCount }); blockedCount = 0; }, 800);
  };

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------
  const hostMatches = (domains) => domains.some((d) => host === d || host.endsWith('.' + d));
  const ruleApplies = (r) => (!r.d.length || hostMatches(r.d)) && !(r.x.length && hostMatches(r.x));

  /** "/re/flags" -> RegExp, anything else -> literal substring RegExp. */
  const toRegExp = (s, flagsDefault = '') => {
    if (s.length > 2 && s.startsWith('/')) {
      const end = s.lastIndexOf('/');
      if (end > 0) { try { return new RegExp(s.slice(1, end), s.slice(end + 1) || flagsDefault); } catch (_) { return null; } }
    }
    return new RegExp(s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flagsDefault);
  };

  /** uBlock-style "needle" with optional leading "!" for negation. */
  const needleTester = (raw) => {
    if (!raw || raw === '*') return () => true;
    let not = false;
    if (raw.startsWith('!')) { not = true; raw = raw.slice(1); }
    const re = toRegExp(raw);
    if (!re) return () => false;
    return (s) => re.test(s) !== not;
  };

  /** Parses `propsToMatch` ("url:/re/ method:POST" or a bare URL pattern). */
  const propsMatcher = (raw) => {
    if (!raw) return null;
    const props = {};
    for (const tok of raw.split(/\s+/)) {
      if (!tok) continue;
      const m = /^(url|method|body|headers|mode|credentials|cache|redirect|referrer|referrerPolicy|integrity|priority):(.*)$/.exec(tok);
      if (m) props[m[1]] = needleTester(m[2]); else props.url = needleTester(tok);
    }
    return (details) => Object.keys(props).every((k) => props[k](String(details[k] ?? '')));
  };

  /** Extra named args after positional ones: [..., 'propsToMatch', 'x', 'times', '1'] */
  const namedArgs = (args, from) => {
    const out = {};
    for (let i = from; i + 1 < args.length; i += 2) out[args[i]] = args[i + 1];
    return out;
  };

  const requestDetails = (input, init) => {
    const d = { url: '', method: 'GET', body: '' };
    try {
      if (typeof input === 'string' || input instanceof URL) d.url = String(input);
      else if (input instanceof Request) { d.url = input.url; d.method = input.method; }
      if (init) {
        if (init.method) d.method = init.method;
        if (typeof init.body === 'string') d.body = init.body;
      }
      d.url = new URL(d.url, location.href).href;
    } catch (_) {}
    return d;
  };

  /** Defines an accessor that composes with any accessor already installed on `prop`. */
  const hookAssign = (owner, prop, transform) => {
    try {
      const desc = N.getOwnPropertyDescriptor(owner, prop);
      if (desc && desc.configurable === false) return;
      let value = desc && 'value' in desc ? transform(desc.value) : undefined;
      const prevGet = desc && desc.get;
      const prevSet = desc && desc.set;
      N.defineProperty(owner, prop, {
        configurable: true,
        enumerable: true,
        get() { return prevGet ? prevGet.call(this) : value; },
        set(v) { v = transform(v); if (prevSet) prevSet.call(this, v); else value = v; },
      });
    } catch (_) {}
  };

  // ---------------------------------------------------------------------------------------------
  // 1. Data cleaning
  // ---------------------------------------------------------------------------------------------
  const AD_KEYS = new Set(['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams']);
  const AD_RENDERERS = new Set([
    'adSlotRenderer', 'promotedSparklesWebRenderer', 'promotedSparklesTextSearchRenderer', 'displayAdRenderer',
    'compactPromotedVideoRenderer', 'promotedVideoRenderer', 'searchPyvRenderer', 'bannerPromoRenderer',
    'statementBannerRenderer', 'brandVideoSingletonRenderer', 'brandVideoShelfRenderer', 'companionSlotRenderer',
    'actionCompanionAdRenderer', 'inFeedAdLayoutRenderer', 'primetimePromoRenderer', 'adBreakServiceRenderer',
    'promotedSparklesCompactRenderer', 'compactPromotedItemRenderer', 'carouselAdRenderer',
  ]);
  const PROMO_RENDERERS = new Set(['mealbarPromoRenderer', 'backgroundPromoRenderer', 'feedNudgeRenderer']);
  const MERCH_RENDERERS = new Set(['merchandiseShelfRenderer', 'ticketShelfRenderer', 'productListRenderer', 'shoppingOverlayRenderer']);
  const SHORTS_RENDERERS = new Set(['reelShelfRenderer', 'shortsLockupViewModel', 'reelItemRenderer']);
  const SHORTS_MARKERS = ['"reelShelfRenderer"', '"shortsLockupViewModel"', '"reelItemRenderer"', '"reelWatchEndpoint"'];

  const containsShorts = (obj) => {
    try { const s = N.stringify(obj); return SHORTS_MARKERS.some((m) => s.includes(m)); } catch (_) { return false; }
  };

  /** Decides whether an array element (usually `{someRenderer: {...}}`) should be dropped. */
  const junkReason = (el) => {
    const keys = Object.keys(el);
    if (keys.length === 0 || keys.length > 4) return null;
    for (const k of keys) {
      const v = el[k];
      if (CFG.adblock) {
        if (AD_RENDERERS.has(k)) return 'ad';
        if (k === 'richItemRenderer' && v && v.content) {
          const inner = Object.keys(v.content)[0];
          if (AD_RENDERERS.has(inner)) return 'ad';
          if (CFG.hideShorts && SHORTS_RENDERERS.has(inner)) return 'shorts';
        }
        if (k === 'command' && v && v.reelWatchEndpoint && v.reelWatchEndpoint.adClientParams && v.reelWatchEndpoint.adClientParams.isAd) return 'ad';
      }
      if (CFG.hidePromos && PROMO_RENDERERS.has(k)) return 'promo';
      if (CFG.hideMerch && MERCH_RENDERERS.has(k)) return 'merch';
      if (CFG.hideShorts) {
        if (SHORTS_RENDERERS.has(k)) return 'shorts';
        if ((k === 'richSectionRenderer' || k === 'gridShelfViewModel' || k === 'shelfRenderer') && containsShorts(v)) return 'shorts';
        if ((k === 'videoWithContextRenderer' || k === 'compactVideoRenderer' || k === 'videoRenderer' || k === 'gridVideoRenderer')
            && v && v.navigationEndpoint && v.navigationEndpoint.reelWatchEndpoint) return 'shorts';
        if (k === 'pivotBarItemRenderer' && v && v.pivotIdentifier === 'FEshorts') return 'shorts';
        if ((k === 'guideEntryRenderer' || k === 'tabRenderer') && v && /\/shorts$|^shorts$/i.test(String(v.title || (v.formattedTitle && v.formattedTitle.simpleText) || ''))) return 'shorts';
      }
    }
    return null;
  };

  /** Removes ads (and optionally Shorts) from a YouTube API object in place. Returns ads removed. */
  const cleanData = (root) => {
    if (!root || typeof root !== 'object' || CFG.noPrune) return 0;
    let ads = 0;
    const stack = [root];
    while (stack.length) {
      const o = stack.pop();
      if (Array.isArray(o)) {
        for (let i = o.length - 1; i >= 0; i--) {
          const el = o[i];
          if (!el || typeof el !== 'object') continue;
          const why = Array.isArray(el) ? null : junkReason(el);
          if (why) { o.splice(i, 1); if (why === 'ad') ads++; continue; }
          stack.push(el);
        }
      } else {
        for (const k in o) {
          if (CFG.adblock && AD_KEYS.has(k)) { delete o[k]; if (k === 'adPlacements' || k === 'playerAds') ads++; continue; }
          if (CFG.adblock && k === 'enforcementMessageViewModel') { delete o[k]; continue; }
          const v = o[k];
          if (v && typeof v === 'object') stack.push(v);
        }
      }
    }
    return ads;
  };

  /** Tells the app when YouTube refuses to play a video, with YouTube's own reason. */
  const checkPlayability = (o) => {
    try {
      const ps = o && (o.playabilityStatus || (o.playerResponse && o.playerResponse.playabilityStatus));
      if (!ps || !ps.status || ps.status === 'OK') return;
      const vd = o.videoDetails || (o.playerResponse && o.playerResponse.videoDetails) || {};
      const text = (t) => !t ? '' : t.simpleText || (t.runs ? t.runs.map((r) => r.text).join('') : '');
      const err = ps.errorScreen && (ps.errorScreen.playerErrorMessageRenderer || ps.errorScreen.playerLegacyDesktopYpcOfferRenderer || {});
      const reason = [ps.reason, text(err && err.reason), text(err && err.subreason)].filter(Boolean).join('\n');
      log('unplayable', ps.status, reason);
      post({ type: 'unplayable', videoId: vd.videoId || null, status: ps.status, reason });
    } catch (_) {}
  };

  const looksLikeYT = (o) => {
    if (!o || typeof o !== 'object') return false;
    if (Array.isArray(o)) return o.length > 0 && o.length < 20 && o.some((e) => e && typeof e === 'object' && ('playerResponse' in e || 'response' in e));
    return 'responseContext' in o || 'playerResponse' in o || 'adPlacements' in o || 'playerAds' in o || 'onResponseReceivedActions' in o;
  };

  const cleanIfYT = (o) => {
    if ((CFG.adblock || CFG.hideShorts) && looksLikeYT(o)) {
      const n = cleanData(o);
      if (n) { countBlocked(n); log('JSON.parse cleaned', n, 'ad objects'); }
    }
    return o;
  };

  // ---------------------------------------------------------------------------------------------
  // JSON path pruning (uBlock Origin "json-prune" semantics, common subset)
  // ---------------------------------------------------------------------------------------------
  const splitPath = (p) => p.split('.').filter((s) => s !== '');

  const existsAt = (o, segs, i) => {
    if (i >= segs.length) return true;
    if (o === null || typeof o !== 'object') return false;
    const seg = segs[i];
    if (seg === '[]' || seg === '*' || seg === '[-]' || seg === '{-}') {
      return Object.keys(o).some((k) => existsAt(o[k], segs, i + 1));
    }
    if (!(seg in o)) return false;
    return existsAt(o[seg], segs, i + 1);
  };

  const pruneAt = (o, segs, i) => {
    if (o === null || typeof o !== 'object' || i >= segs.length) return false;
    const seg = segs[i];
    const last = i === segs.length - 1;
    if (seg === '[-]' || seg === '{-}') {
      let found = false;
      if (Array.isArray(o)) {
        for (let j = o.length - 1; j >= 0; j--) if (existsAt(o[j], segs, i + 1)) { o.splice(j, 1); found = true; }
      } else {
        for (const k of Object.keys(o)) if (existsAt(o[k], segs, i + 1)) { delete o[k]; found = true; }
      }
      return found;
    }
    if (seg === '[]' || seg === '*') {
      let found = false;
      for (const k of Object.keys(o)) {
        if (last) { delete o[k]; found = true; } else if (pruneAt(o[k], segs, i + 1)) found = true;
      }
      return found;
    }
    if (!(seg in o)) return false;
    if (last) { delete o[seg]; return true; }
    return pruneAt(o[seg], segs, i + 1);
  };

  /** Returns a function that prunes an object according to json-prune arguments. */
  const makePruner = (rawPrune, rawNeedles) => {
    const prunePaths = (rawPrune || '').split(/ +/).filter((p) => p && !p.includes('[?')).map(splitPath);
    const needlePaths = (rawNeedles || '').split(/ +/).filter((p) => p && !p.includes('[?')).map(splitPath);
    if (!prunePaths.length) return null;
    return (obj) => {
      if (!obj || typeof obj !== 'object') return false;
      if (needlePaths.length && !needlePaths.every((n) => existsAt(obj, n, 0))) return false;
      let any = false;
      for (const p of prunePaths) if (pruneAt(obj, p, 0)) any = true;
      return any;
    };
  };

  // Registries filled by scriptlets, consulted by the network hooks below.
  const objectPruners = [];      // json-prune: applied to JSON.parse / Response.json results
  const fetchPruners = [];       // { match, prune }
  const xhrPruners = [];
  const fetchReplacers = [];     // { match, re, replacement }
  const xhrReplacers = [];
  const fetchBlockers = [];      // { match, body }
  const xhrBlockers = [];

  // Network replace= rules from filter lists.
  const replaceRules = (RULES.replaces || []).map((r) => {
    try { return { url: new RegExp(r.u, 'i'), find: new RegExp(r.f, r.fl || 'g'), with: r.r }; } catch (_) { return null; }
  }).filter(Boolean);

  const applyObjectPruners = (o) => {
    if (!o || typeof o !== 'object') return o;
    for (const p of objectPruners) { try { p(o); } catch (_) {} }
    return o;
  };

  // ---------------------------------------------------------------------------------------------
  // 2. Scriptlets
  // ---------------------------------------------------------------------------------------------
  const parseConstant = (raw, trusted) => {
    const table = {
      undefined: undefined, false: false, true: true, null: null, "''": '', '': '', emptyStr: '',
      noopFunc: function () {}, trueFunc: () => true, falseFunc: () => false,
      emptyObj: {}, '{}': {}, emptyArr: [], '[]': [], noopCallbackFunc: () => () => {},
      yes: 'yes', no: 'no', on: 'on', off: 'off',
    };
    if (Object.prototype.hasOwnProperty.call(table, raw)) {
      const v = table[raw];
      if (raw === 'emptyObj' || raw === '{}') return {};
      if (raw === 'emptyArr' || raw === '[]') return [];
      return v;
    }
    if (/^-?\d+(\.\d+)?$/.test(raw)) {
      const n = Number(raw);
      if (trusted || Math.abs(n) <= 0x7fff) return n;
    }
    if (trusted) { try { return N.parse(raw); } catch (_) { return raw; } }
    return Symbol.for('unreel.invalid');
  };

  /** Installs `handler` (get/set) at the end of a dotted property chain, waiting for missing links. */
  const trapChain = (owner, chain, handler) => {
    const pos = chain.indexOf('.');
    if (pos === -1) {
      try {
        const desc = N.getOwnPropertyDescriptor(owner, chain);
        if (desc && desc.configurable === false) return;
        N.defineProperty(owner, chain, { configurable: true, enumerable: true, get: handler.get, set: handler.set || function () {} });
      } catch (_) {}
      return;
    }
    const prop = chain.slice(0, pos);
    const rest = chain.slice(pos + 1);
    const v = owner[prop];
    if (v !== null && (typeof v === 'object' || typeof v === 'function')) { trapChain(v, rest, handler); return; }
    hookAssign(owner, prop, (a) => { if (a !== null && (typeof a === 'object' || typeof a === 'function')) trapChain(a, rest, handler); return a; });
  };

  const domReady = (fn) => {
    if (document.readyState !== 'loading') fn(); else document.addEventListener('DOMContentLoaded', fn, { once: true });
  };

  const observeDOM = (fn) => {
    let queued = false;
    const run = () => { queued = false; try { fn(); } catch (_) {} };
    const mo = new MutationObserver(() => { if (!queued) { queued = true; N.setTimeout(run, 120); } });
    const start = () => { mo.observe(document.documentElement, { childList: true, subtree: true, attributes: false }); run(); };
    if (document.documentElement) start(); else domReady(start);
  };

  const SCRIPTLETS = {
    'set-constant'(args, trusted) {
      const [chain, raw] = args;
      if (!chain) return;
      const value = parseConstant(raw ?? '', trusted);
      if (value === Symbol.for('unreel.invalid')) return;
      trapChain(window, chain, { get() { return value; }, set() {} });
    },
    'trusted-set-constant'(args) { SCRIPTLETS['set-constant'](args, true); },

    'json-prune'(args) {
      const p = makePruner(args[0], args[1]);
      if (p) objectPruners.push(p);
    },
    'json-prune-fetch-response'(args) {
      const p = makePruner(args[0], args[1]);
      const named = namedArgs(args, 2);
      if (p) fetchPruners.push({ match: propsMatcher(named.propsToMatch), prune: p });
    },
    'json-prune-xhr-response'(args) {
      const p = makePruner(args[0], args[1]);
      const named = namedArgs(args, 2);
      if (p) xhrPruners.push({ match: propsMatcher(named.propsToMatch), prune: p });
    },
    'trusted-replace-fetch-response'(args) {
      const [pattern, replacement = '', props] = args;
      if (!pattern) return;
      const re = pattern === '*' ? /^[\s\S]*$/ : toRegExp(pattern, 'g');
      if (re) fetchReplacers.push({ match: propsMatcher(props), re, replacement });
    },
    'trusted-replace-xhr-response'(args) {
      const [pattern, replacement = '', props] = args;
      if (!pattern) return;
      const re = pattern === '*' ? /^[\s\S]*$/ : toRegExp(pattern, 'g');
      if (re) xhrReplacers.push({ match: propsMatcher(props), re, replacement });
    },

    'abort-on-property-read'(args) {
      const [chain] = args;
      if (!chain) return;
      trapChain(window, chain, { get() { throw new ReferenceError('unreel'); }, set() {} });
    },
    'abort-on-property-write'(args) {
      const [prop] = args;
      if (!prop) return;
      try { N.defineProperty(window, prop, { configurable: true, get() { return undefined; }, set() { throw new ReferenceError('unreel'); } }); } catch (_) {}
    },
    'abort-current-script'(args) {
      const [chain, needle] = args;
      if (!chain) return;
      const test = needleTester(needle || '');
      const owner = chain.includes('.') ? chain.slice(0, chain.lastIndexOf('.')) : '';
      const base = owner ? owner.split('.').reduce((o, k) => (o ? o[k] : undefined), window) : window;
      const prop = chain.slice(chain.lastIndexOf('.') + 1);
      if (!base) return;
      const desc = N.getOwnPropertyDescriptor(base, prop);
      let value = desc ? (desc.get ? desc.get.call(base) : desc.value) : undefined;
      const validate = () => {
        const e = document.currentScript;
        if (!(e instanceof HTMLScriptElement)) return;
        const text = e.src ? e.src : e.textContent;
        if (test(text)) throw new ReferenceError('unreel');
      };
      try {
        N.defineProperty(base, prop, {
          configurable: true,
          get() { validate(); return value; },
          set(v) { validate(); value = v; },
        });
      } catch (_) {}
    },

    'no-setTimeout-if'(args) { timerDefuser('setTimeout', args); },
    'no-setInterval-if'(args) { timerDefuser('setInterval', args); },
    'nano-setTimeout-booster'(args) { timerBooster('setTimeout', args); },
    'nano-setInterval-booster'(args) { timerBooster('setInterval', args); },

    'addEventListener-defuser'(args) {
      const typeTest = needleTester(args[0] || '');
      const handlerTest = needleTester(args[1] || '');
      const orig = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = new Proxy(orig, {
        apply(target, thisArg, a) {
          let text = '';
          try { text = String(a[1] && (a[1].handleEvent || a[1])); } catch (_) {}
          if (typeTest(String(a[0])) && handlerTest(text)) return undefined;
          return Reflect.apply(target, thisArg, a);
        },
      });
    },

    'remove-attr'(args) {
      const attrs = (args[0] || '').split(/\s*\|\s*/).filter(Boolean);
      if (!attrs.length) return;
      const selector = args[1] || attrs.map((a) => `[${CSS.escape(a)}]`).join(',');
      observeDOM(() => {
        for (const el of document.querySelectorAll(selector)) for (const a of attrs) el.removeAttribute(a);
      });
    },
    'remove-class'(args) {
      const classes = (args[0] || '').split(/\s*\|\s*/).filter(Boolean);
      if (!classes.length) return;
      const selector = args[1] || classes.map((c) => '.' + CSS.escape(c)).join(',');
      observeDOM(() => {
        for (const el of document.querySelectorAll(selector)) el.classList.remove(...classes);
      });
    },

    'no-fetch-if'(args) {
      if (!args[0]) return;
      const match = propsMatcher(args[0]);
      fetchBlockers.push({ match, body: args[1] || '' });
    },
    'no-xhr-if'(args) {
      if (!args[0]) return;
      xhrBlockers.push({ match: propsMatcher(args[0]), body: args[1] || '' });
    },
    'noeval-if'(args) {
      const test = needleTester(args[0] || '');
      window.eval = new Proxy(window.eval, {
        apply(target, thisArg, a) { if (test(String(a[0]))) return undefined; return Reflect.apply(target, thisArg, a); },
      });
    },
    'set-local-storage-item'(args) {
      const [key, raw] = args;
      if (!key) return;
      const allowed = ['', 'undefined', 'null', 'false', 'true', 'on', 'off', 'yes', 'no', '{}', '[]', 'emptyArr', 'emptyObj', '$remove$'];
      if (!allowed.includes(raw) && !/^\d+$/.test(raw)) return;
      try {
        if (raw === '$remove$') localStorage.removeItem(key);
        else localStorage.setItem(key, raw === 'emptyArr' ? '[]' : raw === 'emptyObj' ? '{}' : raw);
      } catch (_) {}
    },
    'remove-node-text'(args) { nodeText(args[0], args[1], ''); },
    'replace-node-text'(args) { nodeText(args[0], args[1], args[2] ?? ''); },
  };

  function timerDefuser(name, args) {
    const test = needleTester(args[0] || '');
    let delayRaw = args[1] || '';
    let notDelay = false;
    if (delayRaw.startsWith('!')) { notDelay = true; delayRaw = delayRaw.slice(1); }
    const delay = delayRaw ? parseInt(delayRaw, 10) : NaN;
    window[name] = new Proxy(window[name], {
      apply(target, thisArg, a) {
        const text = String(a[0]);
        const d = a[1] | 0;
        const delayOK = isNaN(delay) || ((d === delay) !== notDelay);
        if (test(text) && delayOK) a[0] = function () {};
        return Reflect.apply(target, thisArg, a);
      },
    });
  }

  function timerBooster(name, args) {
    const test = needleTester(args[0] || '');
    const delay = args[1] === '*' ? -1 : parseInt(args[1] || '1000', 10);
    let boost = parseFloat(args[2] || '0.05');
    if (isNaN(boost) || !isFinite(boost)) boost = 0.05;
    boost = Math.min(Math.max(boost, 0.001), 50);
    window[name] = new Proxy(window[name], {
      apply(target, thisArg, a) {
        if (test(String(a[0])) && (delay === -1 || (a[1] | 0) === delay)) a[1] = (a[1] | 0) * boost;
        return Reflect.apply(target, thisArg, a);
      },
    });
  }

  function nodeText(nodeName, pattern, replacement) {
    if (!nodeName || !pattern) return;
    const nameTest = needleTester(nodeName.toUpperCase());
    const re = toRegExp(pattern, '');
    if (!re) return;
    const handle = (node) => {
      if (!nameTest(node.nodeName.toUpperCase())) return;
      const text = node.textContent;
      if (re.test(text)) node.textContent = replacement ? text.replace(re, replacement) : '';
    };
    const mo = new MutationObserver((records) => {
      for (const r of records) for (const n of r.addedNodes) handle(n);
    });
    mo.observe(document, { childList: true, subtree: true });
    domReady(() => N.setTimeout(() => mo.disconnect(), 10000));
  }

  if (CFG.adblock && CFG.listScriptlets !== false) {
    for (const s of RULES.scriptlets || []) {
      if (!ruleApplies(s)) continue;
      const fn = SCRIPTLETS[s.n];
      if (!fn) continue;
      try { fn(s.a, s.n.startsWith('trusted-')); log('scriptlet', s.n, s.a.join(' | ').slice(0, 80)); } catch (e) { log('scriptlet failed', s.n, e); }
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Network and parse hooks
  // ---------------------------------------------------------------------------------------------
  const YT_API = /\/youtubei\/v1\/(player|next|browse|search|get_watch|reel\/|guide|resolve_url|navigation|playlist)|\/(watch|playlist)\?|reel_watch_sequence/;

  JSON.parse = new Proxy(N.parse, {
    apply(target, thisArg, args) {
      const result = Reflect.apply(target, thisArg, args);
      if (result && typeof result === 'object') {
        cleanIfYT(result);
        if (objectPruners.length) applyObjectPruners(result);
      }
      return result;
    },
  });

  Response.prototype.json = new Proxy(N.respJson, {
    apply(target, thisArg, args) {
      return Reflect.apply(target, thisArg, args).then((o) => {
        if (o && typeof o === 'object') { cleanIfYT(o); if (objectPruners.length) applyObjectPruners(o); }
        return o;
      });
    },
  });

  /** Applies text-level rewrites and JSON cleaning to a response body. Returns null if unchanged. */
  const transformBody = (text, details, replacers, pruners) => {
    let out = text;
    for (const r of replaceRules) if (r.url.test(details.url)) out = out.replace(r.find, r.with);
    for (const r of replacers) if (!r.match || r.match(details)) out = out.replace(r.re, r.replacement);
    const activePruners = pruners.filter((p) => !p.match || p.match(details));
    const isAPI = YT_API.test(details.url);
    if ((isAPI && (CFG.adblock || CFG.hideShorts)) || activePruners.length) {
      const trimmed = out.trimStart();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          const obj = N.parse(out);
          let changed = false;
          if (/\/player(\?|$)/.test(details.url.split('#')[0])) checkPlayability(obj);
          if (isAPI) { const n = cleanData(obj); if (n) { countBlocked(n); log('cleaned', n, 'ad objects from', details.url.split('?')[0]); } changed = true; }
          for (const p of activePruners) if (p.prune(obj)) changed = true;
          if (changed) out = N.stringify(obj);
        } catch (_) {}
      }
    }
    return out === text ? null : out;
  };

  /** Caption files (json3) the player downloads are handed to the app, which draws them natively. */
  const TIMEDTEXT = /\/api\/timedtext/;
  const forwardCaptions = (url, text) => {
    if (!CFG.playerMode || !text || text.length < 10) return;
    let lang = '', kind = '';
    try { const u = new URL(url, location.href); lang = u.searchParams.get('lang') || ''; kind = u.searchParams.get('kind') || ''; } catch (_) {}
    post({ type: 'captions', videoId, lang, kind, body: text });
  };

  window.fetch = new Proxy(N.fetch, {
    apply(target, thisArg, args) {
      const details = requestDetails(args[0], args[1]);
      if (TIMEDTEXT.test(details.url)) {
        return Reflect.apply(target, thisArg, args).then((resp) => {
          try { Reflect.apply(N.respText, resp.clone(), []).then((t) => forwardCaptions(details.url, t)).catch(() => {}); } catch (_) {}
          return resp;
        });
      }
      for (const b of fetchBlockers) {
        if (b.match(details)) {
          return Promise.resolve(new Response(b.body === 'emptyObj' ? '{}' : b.body === 'emptyArr' ? '[]' : '', { status: 200, statusText: 'OK' }));
        }
      }
      const p = Reflect.apply(target, thisArg, args);
      const interesting = YT_API.test(details.url) || fetchPruners.length || fetchReplacers.length || replaceRules.length;
      if (!interesting) return p;
      return p.then((resp) => {
        if (!resp || resp.type === 'opaque' || !resp.ok) return resp;
        const ct = resp.headers.get('content-type') || '';
        if (ct && !/json|text|javascript/.test(ct)) return resp;
        return Reflect.apply(N.respText, resp.clone(), []).then((text) => {
          const out = transformBody(text, details, fetchReplacers, fetchPruners);
          if (out === null) return resp;
          const replaced = new Response(out, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
          try {
            N.defineProperty(replaced, 'url', { value: resp.url });
            N.defineProperty(replaced, 'type', { value: resp.type });
            N.defineProperty(replaced, 'redirected', { value: resp.redirected });
          } catch (_) {}
          return replaced;
        }).catch(() => resp);
      });
    },
  });

  // XMLHttpRequest: rewrite responseText/response once the request completes.
  const xhrInfo = new WeakMap();
  XMLHttpRequest.prototype.open = new Proxy(N.xhrOpen, {
    apply(target, thisArg, args) {
      try { xhrInfo.set(thisArg, { method: String(args[0] || 'GET'), url: new URL(String(args[1]), location.href).href }); } catch (_) {}
      return Reflect.apply(target, thisArg, args);
    },
  });
  XMLHttpRequest.prototype.send = new Proxy(N.xhrSend, {
    apply(target, xhr, args) {
      const info = xhrInfo.get(xhr);
      if (!info) return Reflect.apply(target, xhr, args);
      if (TIMEDTEXT.test(info.url)) {
        xhr.addEventListener('load', () => {
          try {
            const rt = xhr.responseType;
            const t = rt === '' || rt === 'text' ? xhr.responseText : rt === 'json' ? N.stringify(xhr.response) : null;
            if (t) forwardCaptions(info.url, t);
          } catch (_) {}
        });
      }
      const details = { url: info.url, method: info.method, body: typeof args[0] === 'string' ? args[0] : '' };
      for (const b of xhrBlockers) {
        if (b.match(details)) {
          const body = b.body === 'emptyObj' ? '{}' : b.body === 'emptyArr' ? '[]' : '';
          for (const [k, v] of [['readyState', 4], ['status', 200], ['statusText', 'OK'], ['responseText', body], ['response', body], ['responseURL', info.url]]) {
            try { N.defineProperty(xhr, k, { value: v, configurable: true }); } catch (_) {}
          }
          N.setTimeout(() => {
            for (const ev of ['readystatechange', 'load', 'loadend']) xhr.dispatchEvent(new Event(ev));
          }, 1);
          return undefined;
        }
      }
      const interesting = YT_API.test(info.url) || xhrPruners.length || xhrReplacers.length || replaceRules.length;
      if (interesting) {
        let cached;
        xhr.addEventListener('readystatechange', function () {
          if (xhr.readyState !== 4 || cached !== undefined) return;
          const rt = xhr.responseType;
          if (rt !== '' && rt !== 'text' && rt !== 'json') { cached = null; return; }
          let text;
          try {
            const pd = N.getOwnPropertyDescriptor(XMLHttpRequest.prototype, rt === 'json' ? 'response' : 'responseText');
            const raw = pd.get.call(xhr);
            text = rt === 'json' ? N.stringify(raw) : raw;
          } catch (_) { cached = null; return; }
          const out = typeof text === 'string' ? transformBody(text, details, xhrReplacers, xhrPruners) : null;
          cached = out;
          if (out === null) return;
          const value = rt === 'json' ? (() => { try { return N.parse(out); } catch (_) { return null; } })() : out;
          try {
            N.defineProperty(xhr, 'responseText', { configurable: true, get: () => out });
            N.defineProperty(xhr, 'response', { configurable: true, get: () => value });
          } catch (_) {}
        }, { capture: true });
      }
      return Reflect.apply(target, xhr, args);
    },
  });

  // Embedded initial data ("var ytInitialPlayerResponse = {...}").
  for (const name of ['ytInitialPlayerResponse', 'ytInitialData', 'ytInitialReelWatchSequenceResponse']) {
    hookAssign(window, name, (v) => {
      if (v && typeof v === 'object') {
        if (name === 'ytInitialPlayerResponse') checkPlayability(v);
        const n = cleanData(v); countBlocked(n); applyObjectPruners(v); log('initial', name, 'cleaned', n);
      }
      return v;
    });
  }

  // ---------------------------------------------------------------------------------------------
  // 3. Cosmetic hiding
  // ---------------------------------------------------------------------------------------------
  const HIDE = '{display:none!important}';
  const CSS_ADS = [
    'ad-slot-renderer', 'ytm-ad-slot-renderer', 'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-sparkles-text-search-renderer',
    'ytm-promoted-video-renderer', 'ytm-companion-ad-renderer', 'ytm-companion-slot', 'ytm-statement-banner-renderer',
    'ytm-banner-promo-renderer', 'ytm-brand-video-singleton-renderer', 'ytm-search-pyv-renderer', 'ytm-in-feed-ad-layout-renderer',
    'ytm-rich-item-renderer:has(> ad-slot-renderer)', 'ytm-item-section-renderer:has(> lazy-list > ad-slot-renderer:only-child)',
    '.ytp-ad-overlay-container', '.ytp-ad-image-overlay', '.ytp-ad-text-overlay', '.ytp-ad-action-interstitial', '#player-ads',
    'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-promoted-sparkles-web-renderer', 'ytd-banner-promo-renderer',
    '#masthead-ad', 'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)', 'ytd-companion-slot-renderer',
    'ytd-action-companion-ad-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer', 'ytd-search-pyv-renderer',
    'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]', 'ytd-statement-banner-renderer',
    'ytm-paid-content-overlay-renderer', '.ytp-paid-content-overlay', 'tp-yt-paper-dialog:has(#feedback.ytd-enforcement-message-view-model)',
    'ytd-enforcement-message-view-model',
  ];
  const CSS_SHORTS = [
    'ytm-reel-shelf-renderer', 'ytm-shorts-lockup-view-model', 'ytm-shorts-lockup-view-model-v2',
    'grid-shelf-view-model:has(ytm-shorts-lockup-view-model)', 'grid-shelf-view-model:has(ytm-shorts-lockup-view-model-v2)',
    'ytm-rich-section-renderer:has(ytm-reel-shelf-renderer)', 'ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model)',
    'ytm-rich-section-renderer:has(grid-shelf-view-model)', 'ytm-item-section-renderer:has(> lazy-list > grid-shelf-view-model:only-child)',
    'ytm-video-with-context-renderer:has(a[href^="/shorts/"])', 'ytm-compact-video-renderer:has(a[href^="/shorts/"])',
    'ytm-rich-item-renderer:has(a[href^="/shorts/"])', 'ytm-pivot-bar-item-renderer:has(.pivot-shorts)',
    'ytd-reel-shelf-renderer', 'ytd-rich-shelf-renderer[is-shorts]', 'ytd-rich-section-renderer:has(ytd-rich-shelf-renderer[is-shorts])',
    'ytd-video-renderer:has(a[href^="/shorts/"])', 'ytd-grid-video-renderer:has(a[href^="/shorts/"])',
    'ytd-rich-item-renderer:has(a[href^="/shorts/"])', 'ytd-guide-entry-renderer:has(a[title="Shorts"])',
    'ytd-mini-guide-entry-renderer[aria-label="Shorts"]', 'grid-shelf-view-model:has(a[href^="/shorts/"])',
    'yt-tab-shape[tab-title="Shorts"]', 'ytm-tab-renderer[tab-identifier="shorts"]',
  ];
  const CSS_OPTIONAL = {
    hideComments: [
      'ytm-comments-entry-point-header-renderer', 'ytm-item-section-renderer[section-identifier="comments-entry-point"]',
      'ytm-comment-section-renderer', 'yt-video-metadata-carousel-view-model', 'ytm-video-metadata-carousel-view-model',
      'ytd-comments#comments', '#comments.ytd-watch-flexy',
    ],
    hideRelated: [
      'ytm-item-section-renderer[section-identifier="related-items"]', 'ytm-single-column-watch-next-results-renderer ytm-item-section-renderer:has(ytm-video-with-context-renderer)',
      'ytm-single-column-watch-next-results-renderer ytm-video-with-context-renderer', '#related.ytd-watch-flexy', 'ytd-watch-next-secondary-results-renderer',
    ],
    hideEndscreen: ['.ytp-ce-element', '.ytp-cards-teaser', '.ytp-cards-button', '.iv-branding', '.ytp-endscreen-content', '.ytp-autonav-endscreen-upnext-container', '.ytp-fullscreen-grid'],
    hideMerch: ['ytm-merch-shelf-renderer', 'ytd-merch-shelf-renderer', 'ytm-product-list-renderer', '#ticket-shelf', 'ytd-ticket-shelf-renderer', 'yt-overlay-product-sticker', '.ytp-suggested-action'],
    hidePromos: ['ytm-mealbar-promo-renderer', 'ytm-upsell-dialog-renderer', 'ytd-mealbar-promo-renderer', 'ytm-feed-nudge-renderer', 'ytd-background-promo-renderer', 'ytm-consent-bump-v2-renderer ~ ytm-mealbar-promo-renderer'],
    hidePlayables: ['ytm-rich-section-renderer:has(a[href*="/playables"])', 'ytd-rich-section-renderer:has(a[href*="/playables"])'],
    nativeTabBar: ['ytm-pivot-bar-renderer'],
  };

  // Player mode: the page shows nothing but the video; the native app draws every control.
  const PLAYER_ONLY_CSS = `
    html,body{background:#000!important;overflow:hidden!important;overscroll-behavior:none!important}
    #movie_player,.html5-video-player{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-height:none!important;z-index:2147483646!important;background:#000!important;transform:none!important;margin:0!important;border-radius:0!important}
    #movie_player .html5-video-container{position:absolute!important;inset:0!important;width:100%!important;height:100%!important}
    #movie_player video{position:absolute!important;left:0!important;top:0!important;width:100%!important;height:100%!important;object-fit:contain!important}
    #movie_player > :not(.html5-video-container){display:none!important}
    ytm-mobile-topbar-renderer,header,ytm-pivot-bar-renderer,ytm-consent-bump-v2-renderer,ytm-mealbar-promo-renderer,.ytp-unmute,#player-control-overlay,.player-controls-background,ytm-custom-control,.ytm-autonav-bar,ytm-engagement-panel{display:none!important}
  `;

  const STATIC_CSS = `
    [data-unreel-hide]${HIDE}
    .html5-video-player.ad-showing .html5-video-container, .html5-video-player.ad-interrupting .html5-video-container{opacity:0!important}
    .html5-video-player.ad-showing::after, .html5-video-player.ad-interrupting::after{content:"Skipping ad…";position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#fff;font:600 15px -apple-system,system-ui,sans-serif;letter-spacing:.2px;background:#000;z-index:5;pointer-events:none}
  `;

  const validSelector = (() => {
    const probe = document.createDocumentFragment();
    return (s) => { try { probe.querySelector(s); return true; } catch (_) { return false; } };
  })();

  // Procedural selectors supported: :has-text(), :upward(), :matches-path(), :remove(), :style().
  const PROCEDURAL_OPS = ['has-text', 'upward', 'matches-path', 'remove', 'style', 'min-text-length', 'xpath', 'matches-css', 'matches-css-before',
    'matches-css-after', 'watch-attr', 'others', 'matches-attr', 'matches-prop', 'matches-media', 'if', 'if-not', 'nth-ancestor', 'contains', '-abp-has', '-abp-contains'];
  const parseProcedural = (sel) => {
    const ops = [];
    let base = '';
    let i = 0;
    let found = false;
    while (i < sel.length) {
      if (sel[i] === ':' ) {
        const m = /^:([\w-]+)\(/.exec(sel.slice(i));
        if (m && PROCEDURAL_OPS.includes(m[1])) {
          let depth = 0, j = i + m[0].length - 1;
          for (; j < sel.length; j++) { if (sel[j] === '(') depth++; else if (sel[j] === ')') { depth--; if (depth === 0) break; } }
          ops.push({ op: m[1], arg: sel.slice(i + m[0].length, j) });
          i = j + 1;
          found = true;
          continue;
        }
      }
      if (found) return null;   // CSS after a procedural op isn't supported
      base += sel[i++];
    }
    return found ? { base: base.trim(), ops } : { base: sel, ops: [] };
  };

  let listCSS = '';
  const proceduralRules = [];
  for (const rule of RULES.cosmetic || []) {
    if (!ruleApplies(rule)) continue;
    const parsed = parseProcedural(rule.s);
    if (!parsed) continue;
    if (!parsed.ops.length) { if (validSelector(rule.s)) listCSS += rule.s + HIDE + '\n'; continue; }
    const last = parsed.ops[parsed.ops.length - 1];
    if (parsed.ops.length === 1 && last.op === 'style' && validSelector(parsed.base)) { listCSS += `${parsed.base}{${last.arg}}\n`; continue; }
    if (parsed.ops.length === 1 && last.op === 'remove' && validSelector(parsed.base)) { listCSS += parsed.base + HIDE + '\n'; continue; }
    if (parsed.ops.every((o) => ['has-text', 'upward', 'matches-path', 'remove'].includes(o.op))) {
      if (parsed.base && !validSelector(parsed.base)) continue;
      proceduralRules.push(parsed);
    }
  }

  const runProcedural = () => {
    for (const rule of proceduralRules) {
      let nodes = rule.base ? Array.from(document.querySelectorAll(rule.base)) : [document.documentElement];
      for (const { op, arg } of rule.ops) {
        if (op === 'has-text') { const re = toRegExp(arg); nodes = re ? nodes.filter((n) => re.test(n.textContent)) : []; }
        else if (op === 'upward') {
          const n = parseInt(arg, 10);
          nodes = nodes.map((el) => {
            if (!isNaN(n) && String(n) === arg.trim()) { let e = el; for (let k = 0; k < n && e; k++) e = e.parentElement; return e; }
            try { return el.parentElement && el.parentElement.closest(arg); } catch (_) { return null; }
          }).filter(Boolean);
        } else if (op === 'matches-path') { const re = toRegExp(arg); if (!re || !re.test(location.pathname + location.search)) nodes = []; }
      }
      for (const n of nodes) if (n !== document.documentElement && n !== document.body) n.setAttribute('data-unreel-hide', '');
    }
  };

  const styleEl = document.createElement('style');
  styleEl.id = 'unreel-style';
  const buildCSS = () => {
    let css = STATIC_CSS;
    if (CFG.adblock) css += CSS_ADS.filter(validSelector).join(',\n') + HIDE + '\n' + listCSS;
    if (CFG.hideShorts) css += CSS_SHORTS.filter(validSelector).join(',\n') + HIDE + '\n';
    for (const key of Object.keys(CSS_OPTIONAL)) {
      if (CFG[key]) css += CSS_OPTIONAL[key].filter(validSelector).join(',\n') + HIDE + '\n';
    }
    if (CFG.nativeTabBar) css += 'ytm-app{padding-bottom:0!important}.pivot-bar-visible{--ytm-pivot-bar-height:0px!important}\n';
    if (CFG.playerMode) css += PLAYER_ONLY_CSS;
    styleEl.textContent = css;
  };
  buildCSS();
  const mountStyle = () => {
    const parent = document.head || document.documentElement;
    if (!parent) return;
    if (styleEl.parentNode !== parent || parent.lastElementChild !== styleEl) parent.appendChild(styleEl);
  };
  mountStyle();
  domReady(mountStyle);

  // Elements hidden by text (Shorts chips/tabs) where CSS can't match.
  const hideByText = () => {
    if (!CFG.hideShorts) return;
    for (const el of document.querySelectorAll('ytm-chip-cloud-chip-renderer, yt-chip-cloud-chip-renderer, ytm-search-filter-renderer, .single-column-browse-results-tabs > a, yt-tab-shape, ytm-pivot-bar-item-renderer')) {
      if (/^\s*Shorts\s*$/i.test(el.textContent)) el.setAttribute('data-unreel-hide', '');
    }
  };

  observeDOM(() => {
    mountStyle();
    if (proceduralRules.length) runProcedural();
    hideByText();
  });

  // ---------------------------------------------------------------------------------------------
  // Shorts redirect
  // ---------------------------------------------------------------------------------------------
  const shortsId = (url) => { const m = /\/shorts\/([\w-]{5,})/.exec(String(url)); return m ? m[1] : null; };
  const watchURL = (id) => `/watch?v=${encodeURIComponent(id)}`;

  if (CFG.redirectShorts) {
    const startId = shortsId(location.pathname);
    if (startId) location.replace(watchURL(startId));
  }

  document.addEventListener('click', (e) => {
    if (!CFG.redirectShorts) return;
    const a = e.target && e.target.closest ? e.target.closest('a[href*="/shorts/"]') : null;
    if (!a) return;
    const id = shortsId(a.getAttribute('href'));
    if (!id) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    location.href = watchURL(id);
  }, true);

  for (const method of ['pushState', 'replaceState']) {
    history[method] = new Proxy(history[method], {
      apply(target, thisArg, args) {
        const id = CFG.redirectShorts && args[2] ? shortsId(args[2]) : null;
        if (id) { location.replace(watchURL(id)); return undefined; }
        const r = Reflect.apply(target, thisArg, args);
        post({ type: 'navigated', url: location.href });
        return r;
      },
    });
  }
  window.addEventListener('popstate', () => {
    const id = CFG.redirectShorts ? shortsId(location.pathname) : null;
    if (id) location.replace(watchURL(id));
  });

  // ---------------------------------------------------------------------------------------------
  // Background playback: the page always believes it is visible.
  // ---------------------------------------------------------------------------------------------
  if (CFG.backgroundPlay) {
    try {
      N.defineProperty(Document.prototype, 'hidden', { configurable: true, get: () => false });
      N.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: () => 'visible' });
      N.defineProperty(Document.prototype, 'webkitHidden', { configurable: true, get: () => false });
      N.defineProperty(Document.prototype, 'webkitVisibilityState', { configurable: true, get: () => 'visible' });
    } catch (_) {}
    const stop = (e) => e.stopImmediatePropagation();
    for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
      window.addEventListener(t, stop, true);
      document.addEventListener(t, stop, true);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // 4. Player: ad fallback, preferences, SponsorBlock, media state
  // ---------------------------------------------------------------------------------------------
  let player = null;
  let video = null;
  let videoId = null;
  let adState = null;
  let prefsAppliedFor = null;
  let segments = [];
  let skippedSegments = new Set();
  let lastSkip = null;
  let wasPlayingBeforeBackground = false;
  let lastMediaPost = 0;
  let userMuted = false;
  let captionRequest = null;

  const currentVideoId = () => {
    try { const d = player && player.getVideoData && player.getVideoData(); if (d && d.video_id) return d.video_id; } catch (_) {}
    const m = /[?&]v=([\w-]{6,})/.exec(location.search);
    return location.pathname === '/watch' && m ? m[1] : null;
  };

  const SKIP_SELECTORS = '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button, button.ytp-ad-skip-button-container, [id^="skip-button"] button, .ytm-skip-ad-button';

  const handleAd = () => {
    if (!player || !video) return;
    const isAd = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
    if (isAd && CFG.adblock) {
      if (!adState) { adState = { muted: video.muted }; countBlocked(1); log('player ad detected, skipping'); }
      video.muted = true;
      try { video.playbackRate = 16; } catch (_) {}
      if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.3) {
        try { video.currentTime = video.duration - 0.1; } catch (_) {}
      }
      for (const b of player.querySelectorAll(SKIP_SELECTORS)) { try { b.click(); } catch (_) {} }
      if (video.paused) video.play().catch(() => {});
    } else if (adState) {
      video.muted = adState.muted;
      try { video.playbackRate = CFG.speed || 1; } catch (_) {}
      adState = null;
    }
  };

  const applyPrefs = () => {
    if (!player || !video || !videoId || prefsAppliedFor === videoId || adState) return;
    prefsAppliedFor = videoId;
    const speed = Number(CFG.speed) || 1;
    if (speed !== 1) {
      try { video.playbackRate = speed; } catch (_) {}
      try { player.setPlaybackRate && player.setPlaybackRate(speed); } catch (_) {}
    }
    if (CFG.playerMode && (!CFG.quality || CFG.quality === 'auto')) {
      try { player.setPlaybackQualityRange && player.setPlaybackQualityRange('large', 'hd1080'); } catch (_) {}
    }
    if (CFG.quality && CFG.quality !== 'auto') {
      try {
        const levels = (player.getAvailableQualityLevels && player.getAvailableQualityLevels()) || [];
        const order = ['hd2160', 'hd1440', 'hd1080', 'hd720', 'large', 'medium', 'small', 'tiny'];
        const want = order.indexOf(CFG.quality);
        const pick = levels.find((l) => order.indexOf(l) >= want) || CFG.quality;
        player.setPlaybackQualityRange && player.setPlaybackQualityRange(pick, pick);
        player.setPlaybackQuality && player.setPlaybackQuality(pick);
      } catch (_) {}
    }
    if (CFG.autoplay === false || CFG.playerMode) disableAutoplay();
  };

  const disableAutoplay = () => {
    try { player.setAutonav && player.setAutonav(false); } catch (_) {}
    for (const b of document.querySelectorAll('.ytm-autonav-toggle-button-container, button.ytp-autonav-toggle-button, .ytp-autonav-toggle-button')) {
      const pressed = b.getAttribute('aria-pressed') === 'true' || b.getAttribute('aria-checked') === 'true';
      if (pressed) { try { b.click(); } catch (_) {} }
    }
  };

  const loadSegments = (id) => {
    segments = [];
    skippedSegments = new Set();
    if (!CFG.sponsorBlock || !id) return;
    Promise.resolve(ask({ type: 'sponsorblock', videoId: id })).then((list) => {
      if (videoId !== id || !Array.isArray(list)) return;
      segments = list.filter((s) => s && s.end > s.start);
      post({ type: 'segments', count: segments.length });
    }).catch(() => {});
  };

  const checkSegments = () => {
    if (!segments.length || !video || adState) return;
    const t = video.currentTime;
    for (const s of segments) {
      if (t >= s.start && t < s.end - 0.25 && !skippedSegments.has(s.uuid)) {
        skippedSegments.add(s.uuid);
        lastSkip = { from: s.start, to: s.end };
        try { video.currentTime = s.end; } catch (_) {}
        post({ type: 'skipped', category: s.category, seconds: Math.round(s.end - s.start) });
        break;
      }
    }
  };

  const videoInfo = () => {
    let title = '', author = '';
    try { const d = player && player.getVideoData && player.getVideoData(); if (d) { title = d.title || ''; author = d.author || ''; } } catch (_) {}
    if (!title) title = document.title.replace(/ - YouTube$/, '');
    return { title, author };
  };

  let waiting = false;
  const bufferedEnd = () => {
    try { const b = video.buffered; for (let i = 0; i < b.length; i++) if (b.start(i) <= video.currentTime + 0.5 && b.end(i) >= video.currentTime) return b.end(i); } catch (_) {}
    return 0;
  };
  const qualityInfo = () => {
    try {
      return {
        levels: (player && player.getAvailableQualityLevels && player.getAvailableQualityLevels()) || [],
        quality: (player && player.getPlaybackQuality && player.getPlaybackQuality()) || '',
      };
    } catch (_) { return { levels: [], quality: '' }; }
  };
  const postMedia = (force) => {
    if (!video) return;
    const now = Date.now();
    if (!force && now - lastMediaPost < (CFG.playerMode ? 250 : 4000)) return;
    lastMediaPost = now;
    const info = videoInfo();
    const q = CFG.playerMode ? qualityInfo() : { levels: [], quality: '' };
    post({
      type: 'media',
      playing: !video.paused && !video.ended,
      isAd: !!adState,
      videoId,
      title: info.title,
      author: info.author,
      duration: isFinite(video.duration) ? video.duration : 0,
      time: video.currentTime || 0,
      buffered: bufferedEnd(),
      rate: adState ? 1 : video.playbackRate,
      waiting,
      ended: video.ended,
      muted: video.muted,
      levels: q.levels,
      quality: q.quality,
      pip: video.webkitPresentationMode === 'picture-in-picture',
    });
  };

  /** Fixed positioning only escapes ancestors without transforms or containment. */
  let geometryLogged = false;
  if (CFG.debug && CFG.playerMode) {
    window.addEventListener('resize', () => N.setTimeout(() => {
      const v = document.querySelector('video'); const pl = document.querySelector('#movie_player');
      if (!v || !pl) return;
      const r = (el) => { const b = el.getBoundingClientRect(); return [b.x, b.y, b.width, b.height].map(Math.round).join(','); };
      const cs = getComputedStyle(v);
      log('resize win', innerWidth + 'x' + innerHeight, 'player', r(pl), 'video', r(v), 'fit', cs.objectFit, 'intrinsic', v.videoWidth + 'x' + v.videoHeight, 'transform', cs.transform, 'cls', pl.className.split(' ').filter((c) => /fit|fill|cover/.test(c)).join(' '));
    }, 400));
  }
  const liftPlayer = () => {
    if (!CFG.playerMode || !player) return;
    if (CFG.debug && !geometryLogged && video && video.videoWidth) {
      geometryLogged = true;
      const r = (el) => { const b = el.getBoundingClientRect(); return [Math.round(b.x), Math.round(b.y), Math.round(b.width), Math.round(b.height)].join(','); };
      log('geometry win', innerWidth + 'x' + innerHeight, 'player', r(player), 'video', r(video), 'container', r(video.parentElement), 'style', video.getAttribute('style'));
    }
    for (let el = player.parentElement; el && el !== document.documentElement; el = el.parentElement) {
      for (const [k, v] of [['transform', 'none'], ['contain', 'none'], ['filter', 'none'], ['will-change', 'auto']]) {
        if (el.style.getPropertyValue(k) !== v) el.style.setProperty(k, v, 'important');
      }
    }
  };

  const attachVideo = (v) => {
    video = v;
    if (!v || v.__unreel) return;
    v.__unreel = true;
    v.setAttribute('playsinline', '');
    v.setAttribute('x-webkit-airplay', 'allow');
    if (CFG.playerMode) {
      // YouTube marks its video as not allowed in PiP; the app handles PiP itself.
      const allowPiP = () => { if (v.hasAttribute('disablepictureinpicture')) v.removeAttribute('disablepictureinpicture'); v.disablePictureInPicture = false; };
      allowPiP();
      new MutationObserver(allowPiP).observe(v, { attributes: true, attributeFilter: ['disablepictureinpicture'] });
    }
    v.addEventListener('timeupdate', () => { handleAd(); checkSegments(); postMedia(false); });
    v.addEventListener('playing', () => {
      waiting = false;
      applyPrefs();
      // YouTube starts muted when it thinks autoplay needs it; the app always allows sound.
      if (CFG.playerMode && v.muted && !adState && !userMuted) {
        try { player && player.unMute && player.unMute(); } catch (_) {}
        v.muted = false;
      }
      postMedia(true);
    });
    v.addEventListener('waiting', () => { waiting = true; postMedia(true); });
    v.addEventListener('canplay', () => { waiting = false; postMedia(true); });
    v.addEventListener('ended', () => { if (!adState) post({ type: 'ended', videoId }); });
    for (const ev of ['play', 'pause', 'ended', 'ratechange', 'durationchange', 'loadedmetadata', 'seeked', 'webkitpresentationmodechanged']) {
      v.addEventListener(ev, () => postMedia(true));
    }
  };

  const tick = () => {
    const p = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');
    if (p !== player) {
      player = p;
      if (p) new MutationObserver(handleAd).observe(p, { attributes: true, attributeFilter: ['class'] });
    }
    const v = (p && p.querySelector('video')) || document.querySelector('video');
    if (v !== video) attachVideo(v);
    liftPlayer();
    handleAd();
    const id = currentVideoId();
    if (id !== videoId) {
      videoId = id;
      prefsAppliedFor = null;
      lastSkip = null;
      loadSegments(id);
      post({ type: 'video', videoId: id });
      if (video && !video.paused) applyPrefs();
    }
  };
  N.setInterval(tick, 400);
  domReady(tick);

  // ---------------------------------------------------------------------------------------------
  // API used by the native app
  // ---------------------------------------------------------------------------------------------
  const TAB_TARGETS = {
    home: { cls: 'pivot-w2w', url: '/' },
    subscriptions: { cls: 'pivot-subs', url: '/feed/subscriptions' },
    you: { cls: 'pivot-you', alt: 'pivot-library', url: '/feed/you' },
  };

  window.__unreel = {
    version: 1,
    loadVideo(id, start) {
      start = Number(start) || 0;
      if (player && player.loadVideoById && location.pathname === '/watch') {
        try { player.loadVideoById({ videoId: id, startSeconds: start }); return 'player'; } catch (_) {}
      }
      location.href = '/watch?v=' + encodeURIComponent(id) + (start ? '&t=' + Math.floor(start) + 's' : '');
      return 'navigate';
    },
    setRate(r) {
      r = Number(r) || 1;
      try { player && player.setPlaybackRate && player.setPlaybackRate(r); } catch (_) {}
      if (video) video.playbackRate = r;
    },
    setQuality(q) {
      try {
        player.setPlaybackQualityRange && player.setPlaybackQualityRange(q, q);
        player.setPlaybackQuality && player.setPlaybackQuality(q);
      } catch (_) {}
      postMedia(true);
    },
    setMuted(m) {
      userMuted = !!m;
      if (video) video.muted = !!m;
      try { m ? player.mute() : player.unMute(); } catch (_) {}
    },
    captionTracks() {
      try {
        const pr = player && player.getPlayerResponse && player.getPlayerResponse();
        const tracks = (pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks) || [];
        const text = (t) => !t ? '' : t.simpleText || (t.runs ? t.runs.map((r) => r.text).join('') : '');
        let all = tracks.map((t) => ({ lang: t.languageCode, kind: t.kind || '', name: text(t.name) || t.languageCode }));
        // Only offer what the player can load (it leaves out auto-generated tracks when real ones exist).
        let list = [];
        try { list = player.getOption('captions', 'tracklist') || []; } catch (_) {}
        if (list.length) {
          const isAuto = (t) => t.kind === 'asr' || String(t.vss_id || '').startsWith('a.');
          all = all.filter((a) => list.some((t) => t.languageCode === a.lang && isAuto(t) === (a.kind === 'asr')));
        }
        return all;
      } catch (_) { return []; }
    },
    setCaptions(lang, kind) {
      // Right after a video starts, the player ignores track changes; retry until it takes.
      const wanted = { id: videoId, lang, kind: kind || '' };
      captionRequest = wanted;
      let attempts = 0;
      const attempt = () => {
        if (captionRequest !== wanted || videoId !== wanted.id || !player) return;
        attempts++;
        try {
          player.loadModule && player.loadModule('captions');
          // Prefer the player's own track object: auto-generated tracks need its exact fields.
          let list = [];
          try { list = player.getOption('captions', 'tracklist') || []; } catch (_) {}
          const isAuto = (t) => t.kind === 'asr' || String(t.vss_id || '').startsWith('a.');
          let track = list.find((t) => t.languageCode === lang && (kind === 'asr') === isAuto(t));
          if (!track) { track = { languageCode: lang }; if (kind) track.kind = kind; }
          if (attempts === 1) log('captions list', JSON.stringify(list.map((t) => [t.languageCode, t.kind, t.vss_id])), 'using', JSON.stringify(track).slice(0, 160));
          player.setOption('captions', 'track', track);
        } catch (e) { log('setCaptions failed', e); }
        let current = null;
        try { current = player.getOption && player.getOption('captions', 'track'); } catch (_) {}
        const ok = current && current.languageCode === lang && (current.kind || '') === wanted.kind;
        if (!ok && attempts < 8) N.setTimeout(attempt, 700);
      };
      attempt();
      return true;
    },
    captionsOff() {
      captionRequest = null;
      try { player && player.setOption && player.setOption('captions', 'track', {}); } catch (_) {}
      try { player && player.unloadModule && player.unloadModule('captions'); } catch (_) {}
    },
    applyConfig(next) {
      const prev = CFG;
      CFG = Object.assign({}, CFG, next);
      buildCSS();
      if (prev.sponsorBlock !== CFG.sponsorBlock || String(prev.sbCategories) !== String(CFG.sbCategories)) loadSegments(videoId);
      if (prev.speed !== CFG.speed && video && !adState) { try { video.playbackRate = Number(CFG.speed) || 1; } catch (_) {} }
      if (CFG.autoplay === false && prev.autoplay !== false) disableAutoplay();
      document.querySelectorAll('[data-unreel-hide]').forEach((e) => e.removeAttribute('data-unreel-hide'));
      hideByText();
      if (proceduralRules.length) runProcedural();
    },
    navigate(tab) {
      const t = TAB_TARGETS[tab];
      if (!t) return false;
      const isCurrent = (tab === 'home' && location.pathname === '/') || (t.url !== '/' && location.pathname.startsWith(t.url));
      if (isCurrent) { window.scrollTo({ top: 0, behavior: 'smooth' }); return 'scrolled'; }
      const el = document.querySelector(`.pivot-bar-item-tab.${t.cls}`) || (t.alt && document.querySelector(`.pivot-bar-item-tab.${t.alt}`));
      if (el) { el.click(); return 'clicked'; }
      location.href = t.url;
      return 'loaded';
    },
    openSearch() {
      const b = document.querySelector('ytm-mobile-topbar-renderer button[aria-label*="earch"], button.topbar-menu-button-avatar-button[aria-label*="earch"], #search-icon-legacy, button[aria-label="Search YouTube"]');
      if (b) { b.click(); return true; }
      const input = document.querySelector('input.searchbox-input, input[name="search"], input#search');
      if (input) { input.focus(); return true; }
      return false;
    },
    togglePiP() {
      const v = video || document.querySelector('video');
      if (!v) return 'no-video';
      try {
        v.removeAttribute('disablepictureinpicture');
        v.disablePictureInPicture = false;
        v.setAttribute('autopictureinpicture', '');
        if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
          const next = v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
          v.webkitSetPresentationMode(next);
          return next;
        }
        if (document.pictureInPictureElement) { document.exitPictureInPicture(); return 'inline'; }
        v.requestPictureInPicture();
        return 'picture-in-picture';
      } catch (e) { return 'error: ' + e; }
    },
    play() { if (video) video.play().catch(() => {}); },
    pause() { if (video) video.pause(); },
    toggle() { if (video) { if (video.paused) video.play().catch(() => {}); else video.pause(); } },
    seekBy(s) { if (video && !adState) video.currentTime = Math.max(0, video.currentTime + s); },
    seekTo(t) { if (video && !adState) video.currentTime = t; },
    next() {
      try { if (player && player.nextVideo) { player.nextVideo(); return; } } catch (_) {}
      const b = document.querySelector('.ytp-next-button, button[aria-label="Next video"]');
      if (b) b.click();
    },
    previous() {
      if (video && video.currentTime > 5) { video.currentTime = 0; return; }
      history.back();
    },
    undoSkip() {
      if (!video || !lastSkip) return;
      video.currentTime = Math.max(0, lastSkip.from - 0.5);
      lastSkip = null;
    },
    willResignActive() { wasPlayingBeforeBackground = !!(video && !video.paused && !video.ended); return wasPlayingBeforeBackground; },
    resumeIfNeeded() {
      if (wasPlayingBeforeBackground && video && video.paused) { video.play().catch(() => {}); return true; }
      return false;
    },
    isPlaying() { return !!(video && !video.paused && !video.ended); },
    mediaState() { postMedia(true); },
  };
})();
