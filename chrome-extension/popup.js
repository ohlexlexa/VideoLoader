// Окошко расширения. На YouTube — скачивание текущего ролика. На страницах GetCourse —
// все видео в том порядке, в каком они стоят на странице: с превью, заголовком блока
// и качествами из самого потока.
//
// Откуда что берётся на GetCourse:
// - плееры — iframe «…/sign-player/?json=<base64>» на странице; в json лежит video_hash;
// - страница плеера содержит previewUrl (картинка) и адрес потока …/api/playlist/master/<video_hash>/…;
// - фоновая часть дополнительно ловит потоки, пока видео играет, — запасной путь для
//   страниц, где плееры устроены иначе.

const content = document.getElementById("content");

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function youtubeUrl(raw) {
  try {
    const u = new URL(raw);
    const host = u.hostname.replace(/^(www\.|m\.)/, "");
    if (host !== "youtube.com") return null;
    const v = u.searchParams.get("v");
    if (u.pathname === "/watch" && v) return `https://www.youtube.com/watch?v=${v}`;
    const m = u.pathname.match(/^\/shorts\/([\w-]+)/);
    if (m) return `https://www.youtube.com/shorts/${m[1]}`;
  } catch (e) {}
  return null;
}

// Название урока из заголовка вкладки без хвоста с названием школы.
function cleanTitle(title) {
  return (title || "").replace(/\s*[|—–-]\s*[^|—–-]*$/, "").trim() || title || "Видео";
}

function send(tab, params) {
  const q = new URLSearchParams(params);
  chrome.tabs.update(tab.id, { url: "videoloader://download?" + q.toString() });
  window.close();
}

// --- YouTube -------------------------------------------------------------

function renderYouTube(tab, url) {
  const card = el("div", "card");
  card.append(el("div", "title", cleanTitle(tab.title)));
  card.append(el("div", "meta", "YouTube · качество под видео — в кнопке «Скачать» ▾"));
  const row = el("div", "row");
  const video = el("button", "primary", "Скачать видео");
  video.onclick = () => send(tab, { url });
  const m4a = el("button", "", "Звук m4a");
  m4a.onclick = () => send(tab, { url, mode: "m4a" });
  const mp3 = el("button", "", "Звук mp3");
  mp3.onclick = () => send(tab, { url, mode: "mp3" });
  row.append(video, m4a, mp3);
  card.append(row);
  content.append(card);
}

// --- Карточка с превью (Threads, Instagram) -------------------------------

function mediaCard(title, metaText, thumbUrl) {
  const card = el("div", "card");
  const head = el("div", "head");
  const thumb = el("div", "thumb");
  if (thumbUrl) {
    const img = el("img");
    img.src = thumbUrl;
    img.alt = "";
    img.onerror = () => img.remove();
    thumb.append(img);
  }
  const info = el("div", "info");
  info.append(el("div", "title", title), el("div", "meta", metaText));
  head.append(thumb, info);
  card.append(head);
  content.append(card);
  return card;
}

function actionRow(card, label, buttons) {
  card.append(el("div", "label", label));
  const row = el("div", "row");
  for (const [text, primary, onclick] of buttons) {
    const b = el("button", primary ? "primary" : "", text);
    b.onclick = onclick;
    row.append(b);
  }
  card.append(row);
}

function firstLine(text, max = 80) {
  return (text || "").split("\n").map((l) => l.trim()).find(Boolean)?.slice(0, max) || "";
}

// world "MAIN" — выполнить в контексте самой страницы (нужно, чтобы видеть window.__vlMedia).
async function inPage(tab, func, args = [], world = "ISOLATED") {
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func, args, world });
    return res ? res.result : null;
  } catch (e) {
    return null;
  }
}

// --- Threads ---------------------------------------------------------------
// Видео Threads лежат в JSON внутри страницы: у каждого прямой mp4 (со звуком, если он есть),
// превью, автор и подпись. yt-dlp Threads не знает, поэтому в приложение уходит сам mp4.

function threadsCode(url) {
  const m = (url || "").match(/threads\.(?:com|net)\/@[^/]+\/post\/([\w-]+)/);
  return m ? m[1] : null;
}

// Выполняется внутри страницы Threads.
function collectThreads() {
  const found = [];
  const seen = new Set();
  function walk(o, owner) {
    if (!o || typeof o !== "object") return;
    if (Array.isArray(o)) { o.forEach((x) => walk(x, owner)); return; }
    const code = o.code || owner;
    if (Array.isArray(o.video_versions) && o.video_versions.length) {
      const best = [...o.video_versions].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
      const key = o.pk || o.id || best.url;
      if (best.url && !seen.has(key)) {
        seen.add(key);
        const cand = (o.image_versions2 && o.image_versions2.candidates) || [];
        found.push({
          code, user: (o.user && o.user.username) || null,
          url: best.url, width: best.width || null, height: best.height || null,
          hasAudio: o.has_audio !== false,
          thumb: cand.length ? cand[0].url : null,
          caption: (o.caption && o.caption.text) || "",
        });
      }
    }
    for (const k in o) walk(o[k], code);
  }
  for (const s of document.querySelectorAll('script[type="application/json"]')) {
    try { walk(JSON.parse(s.textContent)); } catch (e) {}
  }
  return found;
}

async function renderThreads(tab) {
  const items = (await inPage(tab, collectThreads)) || [];
  if (!items.length) return renderEmpty();
  const main = threadsCode(tab.url);
  // пост из адреса — первым; подпись и автор у вложенных видео наследуются от поста
  items.sort((a, b) => (b.code === main) - (a.code === main));
  const byCode = {};
  for (const it of items) {
    const parent = items.find((x) => x.code === it.code && (x.caption || x.user));
    it.user = it.user || (parent && parent.user);
    it.caption = it.caption || (parent && parent.caption) || "";
  }
  for (const it of items) {
    const n = (byCode[it.code] = (byCode[it.code] || 0) + 1);
    const caption = firstLine(it.caption);
    const base = it.user ? `@${it.user}` : "Threads";
    const title = (caption ? `${base} — ${caption}` : `${base} — ${it.code}`) + (n > 1 ? ` (${n})` : "");
    const where = it.code === main ? "Этот пост" : "Со страницы";
    const size = it.width && it.height ? ` · ${it.width}×${it.height}` : "";
    const card = mediaCard(title, `Threads · ${where}${size}${it.hasAudio ? "" : " · без звука"}`, it.thumb);
    actionRow(card, "Видео", [["Скачать видео", true, () => send(tab, { url: it.url, mode: "video", title })]]);
    if (it.hasAudio) {
      actionRow(card, "Только звук", [
        ["mp3", false, () => send(tab, { url: it.url, mode: "mp3", title })],
        ["m4a", false, () => send(tab, { url: it.url, mode: "m4a", title })],
      ]);
    }
  }
}

// --- Instagram -------------------------------------------------------------
// Видео Instagram играет через blob, прямой ссылки на странице нет — в приложение уходит
// адрес поста, дальше работает yt-dlp. Заголовок и превью — из метатегов страницы.

function instagramPost(url) {
  const m = (url || "").match(/instagram\.com\/(?:[\w.]+\/)?(p|reels?|tv)\/([\w-]+)/);
  if (!m) return null;
  const kind = m[1] === "p" ? "p" : m[1] === "tv" ? "tv" : "reel";
  return { code: m[2], url: `https://www.instagram.com/${kind}/${m[2]}/` };
}

// Выполняется внутри страницы Instagram.
function instagramMeta() {
  const meta = (p) => document.querySelector(`meta[property="${p}"]`)?.content || "";
  return { title: meta("og:title"), desc: meta("og:description"), image: meta("og:image"), url: meta("og:url") };
}

// Выполняется внутри страницы Instagram: пост из JSON страницы — карусель или одиночное фото/видео.
// Берётся первый вариант картинки (исходник) и самый крупный mp4.
function instagramMedia(code) {
  let post = (window.__vlMedia && window.__vlMedia.get(code)) || null;
  function walk(o) {
    if (post || !o || typeof o !== "object") return;
    if (Array.isArray(o)) { o.forEach(walk); return; }
    if (o.code === code && (o.carousel_media || o.image_versions2 || o.video_versions)) { post = o; return; }
    for (const k in o) walk(o[k]);
  }
  if (!post) {
    for (const s of document.querySelectorAll('script[type="application/json"]')) {
      try { walk(JSON.parse(s.textContent)); } catch (e) {}
    }
  }
  if (!post) return null;
  const ext = (url, fallback) => ((url.split("?")[0].match(/\.(\w{3,4})$/) || [])[1] || fallback).toLowerCase();
  const pick = (m) => {
    const videos = m.video_versions || [];
    if (videos.length) {
      const v = [...videos].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
      return { u: v.url, k: ext(v.url, "mp4") };
    }
    const c = m.image_versions2 && m.image_versions2.candidates && m.image_versions2.candidates[0];
    return c ? { u: c.url, k: ext(c.url, "jpg") } : null;
  };
  const media = post.carousel_media || [post];
  const first = media[0] && media[0].image_versions2 && media[0].image_versions2.candidates;
  return {
    user: post.user ? post.user.username : null,
    caption: (post.caption && post.caption.text) || "",
    carousel: !!post.carousel_media,
    items: media.map(pick).filter(Boolean),
    thumb: first && first.length ? first[first.length - 1].url : null,
  };
}

// Выполняется в контексте страницы (MAIN) на ленте, в профиле, в «Интересном».
// Посты, которые сейчас на экране, — первыми; к каждому — данные, пойманные instagram-bridge.js.
function instagramFeed() {
  if (window.__vlScan) window.__vlScan();
  const store = window.__vlMedia || new Map();
  const ext = (url, fallback) => ((url.split("?")[0].match(/\.(\w{3,4})$/) || [])[1] || fallback).toLowerCase();
  const pick = (m) => {
    const videos = m.video_versions || [];
    if (videos.length) {
      const v = [...videos].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
      return { u: v.url, k: ext(v.url, "mp4") };
    }
    const c = m.image_versions2 && m.image_versions2.candidates && m.image_versions2.candidates[0];
    return c ? { u: c.url, k: ext(c.url, "jpg") } : null;
  };
  const summarize = (post) => {
    if (!post) return null;
    const list = post.carousel_media || [post];
    const cands = list[0] && list[0].image_versions2 && list[0].image_versions2.candidates;
    return {
      user: post.user ? post.user.username : null,
      caption: (post.caption && post.caption.text) || "",
      carousel: !!post.carousel_media,
      items: list.map(pick).filter(Boolean),
      thumb: cands && cands.length ? cands[cands.length - 1].url : null,
    };
  };
  const height = window.innerHeight;
  const seen = new Set();
  const posts = [];
  for (const a of document.querySelectorAll('a[href*="/p/"], a[href*="/reel/"]')) {
    const m = (a.getAttribute("href") || "").match(/\/(p|reels?)\/([\w-]+)/);
    if (!m || seen.has(m[2])) continue;
    const box = (a.closest("article") || a).getBoundingClientRect();
    if (!box.height) continue;
    seen.add(m[2]);
    posts.push({ code: m[2], kind: m[1] === "p" ? "p" : "reel", top: box.top, bottom: box.bottom });
  }
  const onScreen = (p) => p.bottom > 0 && p.top < height;
  posts.sort((a, b) => (onScreen(b) - onScreen(a)) || Math.abs(a.top) - Math.abs(b.top));
  return posts.slice(0, 8).map((p) => ({ code: p.code, kind: p.kind, onScreen: onScreen(p), info: summarize(store.get(p.code)) }));
}

async function renderInstagramFeed(tab) {
  const posts = (await inPage(tab, instagramFeed, [], "MAIN")) || [];
  if (!posts.length) return renderEmpty();
  for (const p of posts) {
    const info = p.info;
    const postUrl = `https://www.instagram.com/${p.kind}/${p.code}/`;
    const caption = info ? firstLine(info.caption) : "";
    const base = info && info.user ? `@${info.user}` : "Instagram";
    const title = caption ? `${base} — ${caption}` : `${base} — ${p.code}`;
    const where = p.onScreen ? "На экране" : "В ленте ниже или выше";
    const videos = info ? info.items.filter((i) => i.k === "mp4").length : 0;
    const photos = info ? info.items.length - videos : 0;
    if (info && info.items.length && (info.carousel || photos)) {
      const parts = [photos ? `${photos} фото` : "", videos ? `${videos} видео` : ""].filter(Boolean).join(" и ");
      const card = mediaCard(title, `${where} · ${info.carousel ? "карусель, " : ""}${parts}`, info.thumb);
      actionRow(card, info.items.length > 1 ? "В отдельную папку" : "Файл",
        [[info.items.length > 1 ? "Скачать всё в папку" : "Скачать", true, () => sendGallery(tab, title, info.items)]]);
    } else {
      const kind = info ? "видео" : "пост — откройте его, если это фото";
      const card = mediaCard(title, `${where} · ${kind}`, info ? info.thumb : null);
      actionRow(card, "Видео", [["Скачать видео", true, () => send(tab, { url: postUrl, mode: "video", title })]]);
      actionRow(card, "Только звук", [
        ["mp3", false, () => send(tab, { url: postUrl, mode: "mp3", title })],
        ["m4a", false, () => send(tab, { url: postUrl, mode: "m4a", title })],
      ]);
    }
  }
}

function sendGallery(tab, title, items) {
  const q = new URLSearchParams({ title, items: JSON.stringify(items) });
  chrome.tabs.update(tab.id, { url: "videoloader://gallery?" + q.toString() });
  window.close();
}

async function renderInstagram(tab, post) {
  // Карусель или фото — набором файлов по прямым ссылкам из данных страницы.
  // Одиночное видео — через yt-dlp (у него 1080p; приложение перекодирует VP9 для QuickTime).
  const media = await inPage(tab, instagramMedia, [post.code], "MAIN");
  const photosInside = media && media.items.some((i) => i.k !== "mp4");
  if (media && media.items.length && (media.carousel || photosInside)) {
    const caption = firstLine(media.caption);
    const base = media.user ? `@${media.user}` : "Instagram";
    const title = caption ? `${base} — ${caption}` : `${base} — ${post.code}`;
    const videos = media.items.filter((i) => i.k === "mp4").length;
    const photos = media.items.length - videos;
    const parts = [photos ? `${photos} фото` : "", videos ? `${videos} видео` : ""].filter(Boolean).join(" и ");
    const what = media.carousel ? `Карусель · ${parts}` : `Instagram · ${parts}`;
    const card = mediaCard(title, what, media.thumb);
    const label = media.items.length > 1 ? "Скачать всё в папку" : "Скачать";
    actionRow(card, media.items.length > 1 ? `В папку «${title.slice(0, 40)}${title.length > 40 ? "…" : ""}»` : "Файл",
      [[label, true, () => sendGallery(tab, title, media.items)]]);
    return;
  }

  const m = (await inPage(tab, instagramMeta)) || {};
  // при переходах внутри Instagram метатеги могут остаться от прошлого поста
  const fresh = m.url ? m.url.includes(post.code) : false;
  const user = fresh ? ((m.desc || "").match(/ - ([A-Za-z0-9._]+) /) || [])[1] : null;
  const quoted = fresh ? ((m.title || "").match(/"([\s\S]*)"/) || [])[1] : "";
  const caption = firstLine(quoted);
  const base = user ? `@${user}` : "Instagram";
  const title = caption ? `${base} — ${caption}` : `${base} — ${post.code}`;
  const card = mediaCard(title, "Instagram", fresh ? m.image : null);
  actionRow(card, "Видео", [["Скачать видео", true, () => send(tab, { url: post.url, mode: "video", title })]]);
  actionRow(card, "Только звук", [
    ["mp3", false, () => send(tab, { url: post.url, mode: "mp3", title })],
    ["m4a", false, () => send(tab, { url: post.url, mode: "m4a", title })],
  ]);
}

// --- Vimeo -------------------------------------------------------------------
// Качает приложение (оно само переделывает ссылку vimeo.com в ссылку плеера — так yt-dlp
// работает без входа). Здесь — название, превью и качества: название и поток берутся
// из настроек плеера (window.playerConfig в его странице), превью — из метатегов страницы.

function vimeoVideo(url) {
  try {
    const u = new URL(url);
    if (!/(^|\.)vimeo\.com$/.test(u.hostname) || u.hostname === "player.vimeo.com") return null;
    const parts = u.pathname.split("/").filter(Boolean);
    const i = parts.map((p) => /^\d{6,}$/.test(p)).lastIndexOf(true);
    if (i < 0) return null;
    const hash = /^[0-9a-f]{6,}$/i.test(parts[i + 1] || "") ? parts[i + 1] : u.searchParams.get("h");
    return { id: parts[i], hash, page: `https://vimeo.com/${parts[i]}${hash ? "/" + hash : ""}` };
  } catch (e) {
    return null;
  }
}

async function vimeoPlayerInfo(video) {
  const html = await fetchText(`https://player.vimeo.com/video/${video.id}${video.hash ? "?h=" + video.hash : ""}`);
  const m = html.match(/window\.playerConfig\s*=\s*(\{[\s\S]*?\})\s*(?:;|<\/script>)/);
  if (!m) throw new Error("Vimeo не отдал настройки плеера");
  const config = JSON.parse(m[1]);
  const hls = (config.request && config.request.files && config.request.files.hls) || {};
  const cdn = hls.cdns && (hls.cdns[hls.default_cdn] || Object.values(hls.cdns)[0]);
  let heights = [];
  if (cdn && cdn.url) {
    const master = await fetchText(cdn.url);
    heights = [...new Set([...master.matchAll(/RESOLUTION=\d+x(\d+)/g)].map((x) => Number(x[1])))].sort((a, b) => b - a);
  }
  return { title: config.video && config.video.title, heights };
}

async function renderVimeo(tab, video) {
  const meta = (await inPage(tab, instagramMeta)) || {};
  const card = mediaCard(meta.title || cleanTitle(tab.title), "Vimeo · проверяю качество…", meta.image || null);
  const metaEl = card.querySelector(".meta");
  const titleEl = card.querySelector(".title");
  try {
    const info = await vimeoPlayerInfo(video);
    const title = info.title || meta.title || cleanTitle(tab.title);
    titleEl.textContent = title;
    metaEl.textContent = "Vimeo" + (info.heights.length ? ` · до ${info.heights[0]}p` : "");
    const url = video.page;
    const qualities = info.heights.length
      ? info.heights.map((h, j) => [`${h}p`, j === 0, () => send(tab, { url, mode: "video", title, ...(j ? { quality: h } : {}) })])
      : [["Скачать видео", true, () => send(tab, { url, mode: "video", title })]];
    actionRow(card, "Видео", qualities);
    actionRow(card, "Только звук", [
      ["mp3", false, () => send(tab, { url, mode: "mp3", title })],
      ["m4a", false, () => send(tab, { url, mode: "m4a", title })],
    ]);
  } catch (e) {
    metaEl.textContent = "Vimeo";
    card.append(el("div", "error", "Не получилось: " + e.message + "."));
  }
}

// --- GetCourse: плееры на странице -----------------------------------------

// Выполняется внутри страницы. Возвращает плееры в порядке на странице
// и текст заголовка блока над каждым.
function collectPlayers() {
  const out = [];
  const textOf = (node) => (node.innerText || "").trim().replace(/\s+/g, " ");
  const skip = /^(STYLE|SCRIPT|NOSCRIPT|LINK|META|TEMPLATE)$/i;
  function headingBefore(frame) {
    let node = frame;
    for (let depth = 0; node && node !== document.body && depth < 10; depth++, node = node.parentElement) {
      for (let p = node.previousElementSibling; p; p = p.previousElementSibling) {
        if (skip.test(p.tagName)) continue;
        // дошли до предыдущего видео — у этого своего заголовка нет
        if (p.tagName === "IFRAME" || p.querySelector("iframe")) return null;
        const hs = [...(p.matches("h1,h2,h3,h4,h5") ? [p] : p.querySelectorAll("h1,h2,h3,h4,h5"))].reverse();
        const h = hs.find((x) => textOf(x));
        if (h) return textOf(h).slice(0, 140);
        const t = textOf(p);
        if (t) return t.slice(0, 140);
      }
    }
    return null;
  }
  for (const f of document.querySelectorAll('iframe[src*="/sign-player/"]')) {
    try {
      const json = JSON.parse(atob(new URL(f.src).searchParams.get("json")));
      if (json.video_hash) out.push({ hash: json.video_hash, src: f.src, heading: headingBefore(f) });
    } catch (e) {}
  }
  return out;
}

async function pagePlayers(tab) {
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: collectPlayers });
    return (res && res.result) || [];
  } catch (e) {
    return []; // служебные страницы браузера, магазин расширений и т.п.
  }
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`сервер ответил ${res.status}`);
  return (await res.text()).trim();
}

// Страница плеера: превью и адрес потока лежат в её JSON-настройках.
async function inspectPlayer(src) {
  const html = (await fetchText(src)).replace(/\\u0026/g, "&").replace(/\\\//g, "/");
  const preview = (html.match(/"previewUrl"\s*:\s*"([^"]+)"/) || [])[1] || null;
  const master = (html.match(/https?:\/\/[^"'\s<>]+\/api\/playlist\/master\/[^"'\s<>]+/) || [])[0] || null;
  return { preview, master };
}

// API GetCourse иногда отдаёт не m3u8, а JSON со ссылкой на плейлист внутри.
function urlFromJson(text) {
  try {
    let found = null;
    const visit = (v) => {
      if (found) return;
      if (typeof v === "string" && /^https?:\/\//i.test(v) && /\.m3u8|\/playlist\//i.test(v)) found = v;
      else if (Array.isArray(v)) v.forEach(visit);
      else if (v && typeof v === "object") Object.values(v).forEach(visit);
    };
    visit(JSON.parse(text));
    return found;
  } catch (e) {
    return null;
  }
}

// Адрес настоящего m3u8 и доступные высоты кадра, от большей к меньшей.
async function inspectStream(url) {
  let playlistUrl = url;
  let text = await fetchText(url);
  if (!text.startsWith("#EXTM3U")) {
    const inner = urlFromJson(text);
    if (!inner) throw new Error("непонятный ответ плеера");
    playlistUrl = new URL(inner, url).toString();
    text = await fetchText(playlistUrl);
  }
  if (/#EXT-X-KEY:(?![^\n]*METHOD=NONE)/.test(text)) throw new Error("поток зашифрован, такой скачать не получится");
  const heights = new Set();
  for (const m of text.matchAll(/RESOLUTION=\d+x(\d+)/g)) heights.add(Number(m[1]));
  return { playlistUrl, heights: [...heights].sort((a, b) => b - a) };
}

function buttonsFor(card, tab, playlistUrl, heights, title) {
  card.append(el("div", "label", "Видео"));
  const row = el("div", "row");
  if (heights.length) {
    heights.forEach((h, j) => {
      const b = el("button", j === 0 ? "primary" : "", `${h}p`);
      b.onclick = () => send(tab, { url: playlistUrl, mode: "video", title, ...(j ? { quality: h } : {}) });
      row.append(b);
    });
  } else {
    const b = el("button", "primary", "Скачать");
    b.onclick = () => send(tab, { url: playlistUrl, mode: "video", title });
    row.append(b);
  }
  card.append(row);

  card.append(el("div", "label", "Только звук"));
  const audio = el("div", "row");
  for (const mode of ["mp3", "m4a"]) {
    const b = el("button", "", mode);
    b.onclick = () => send(tab, { url: playlistUrl, mode, title });
    audio.append(b);
  }
  card.append(audio);
}

async function renderGetCourseItem(tab, item) {
  const card = el("div", "card");
  const head = el("div", "head");
  const thumb = el("div", "thumb");
  const info = el("div", "info");
  info.append(el("div", "title", item.title), el("div", "meta", `${item.index} · проверяю…`));
  head.append(thumb, info);
  card.append(head);
  content.append(card);
  const meta = info.querySelector(".meta");

  try {
    let master = item.stream ? item.stream.url : null;
    if (item.src) {
      const player = await inspectPlayer(item.src).catch(() => ({}));
      if (player.preview) {
        const img = el("img");
        img.src = player.preview;
        img.alt = "";
        img.onerror = () => img.remove();
        thumb.append(img);
      }
      master = player.master || master;
    }
    if (!master) throw new Error("не нашёл поток — запустите это видео на пару секунд и откройте окно снова");
    const { playlistUrl, heights } = await inspectStream(master);
    meta.textContent = `${item.index}` + (heights.length ? ` · до ${heights[0]}p` : "");
    buttonsFor(card, tab, playlistUrl, heights, item.title);
  } catch (e) {
    meta.textContent = `${item.index}`;
    card.append(el("div", "error", "Не получилось: " + e.message + "."));
  }
}

async function renderGetCourse(tab, players, streams) {
  const base = cleanTitle(tab.title);
  const items = players.map((p) => ({
    src: p.src,
    heading: p.heading,
    stream: streams.find((s) => s.key === p.hash) || null,
  }));
  // потоки, пойманные в сети, но без плеера на странице (другая вёрстка) — в конец
  for (const s of streams) {
    if (!players.some((p) => p.hash === s.key)) items.push({ src: null, heading: null, stream: s });
  }
  const total = items.length;
  items.forEach((item, i) => {
    item.index = total > 1 ? `Видео ${i + 1} из ${total}` : "GetCourse";
    item.title = item.heading || (total > 1 ? `${base} — видео ${i + 1}` : base);
  });
  // превью и качества грузятся параллельно, карточки уже стоят по порядку
  await Promise.all(items.map((item) => renderGetCourseItem(tab, item)));
}

function renderEmpty() {
  const card = el("div", "card hint");
  const p1 = el("p");
  p1.append("Видео на этой странице не найдено.");
  const p2 = el("p");
  p2.append("Откройте урок ", el("b", null, "GetCourse"), ", ролик на ", el("b", null, "YouTube"),
    ", пост ", el("b", null, "Threads"), ", ", el("b", null, "Instagram"), " или видео на ", el("b", null, "Vimeo"), ".");
  const p3 = el("p");
  p3.append("Если урок открыт, а видео здесь нет — запустите его на пару секунд и нажмите на значок ещё раз.");
  card.append(p1, p2, p3);
  content.append(card);
}

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return renderEmpty();
  const yt = youtubeUrl(tab.url || "");
  if (yt) return renderYouTube(tab, yt);
  if (/^https:\/\/(www\.)?threads\.(com|net)\//.test(tab.url || "")) return renderThreads(tab);
  const vimeo = vimeoVideo(tab.url);
  if (vimeo) return renderVimeo(tab, vimeo);
  const ig = instagramPost(tab.url);
  if (ig) return renderInstagram(tab, ig);
  if (/^https:\/\/(www\.)?instagram\.com\//.test(tab.url || "")) return renderInstagramFeed(tab);
  const [players, stored] = await Promise.all([
    pagePlayers(tab),
    chrome.storage.session.get("gc:" + tab.id),
  ]);
  const streams = stored["gc:" + tab.id] || [];
  if (players.length || streams.length) return renderGetCourse(tab, players, streams);
  renderEmpty();
})();
