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
  chrome.tabs.update(tab.id, { url: "downmax://download?" + q.toString() });
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
  // открыт из плейлиста (…&list=…) — можно взять весь; RD… — бесконечный «микс» YouTube, его не предлагаем
  const list = new URL(tab.url).searchParams.get("list");
  if (list && !list.startsWith("RD")) {
    actionRow(card, "Плейлист", [["Весь плейлист", false,
      () => send(tab, { url: `https://www.youtube.com/playlist?list=${list}`, mode: "video" })]]);
  }
  content.append(card);
}

// --- Плейлисты и каналы ------------------------------------------------------
// Ролики выбираются в окне DownMax: приложение само получает список через yt-dlp. VK в этом списке
// названий не отдаёт — расширение берёт их со страницы и передаёт в приложение (names: id ролика → название).

function playlistPage(raw) {
  try {
    const u = new URL(raw);
    const host = u.hostname.replace(/^(www\.|m\.)/, "");
    if (host === "youtube.com") {
      const list = u.searchParams.get("list");
      if (u.pathname === "/playlist" && list) return { url: `https://www.youtube.com/playlist?list=${list}`, site: "YouTube", channel: false };
      const m = u.pathname.match(/^\/(@[^/]+|(?:channel|c|user)\/[^/]+)/);
      if (m) return { url: `https://www.youtube.com/${m[1]}`, site: "YouTube", channel: true };
    }
    if (/(^|\.)(vk\.com|vk\.ru|vkvideo\.ru)$/.test(u.hostname) && u.pathname.startsWith("/playlist/")) {
      return { url: `https://vkvideo.ru${u.pathname}`, site: "VK Видео", channel: false };
    }
  } catch (e) {}
  return null;
}

// Выполняется внутри страницы: название плейлиста (h1) и названия роликов по ссылкам на них.
function pagePlaylistInfo() {
  const names = {};
  for (const a of document.querySelectorAll('a[href*="video-"], a[href*="video"]')) {
    const id = ((a.getAttribute("href") || "").match(/video(-?\d+_\d+)/) || [])[1];
    if (!id) continue;
    const t = (a.getAttribute("aria-label") || a.textContent || "").trim().replace(/\s+/g, " ");
    if (t.length > (names[id] || "").length) names[id] = t;
  }
  return { names, heading: document.querySelector("h1")?.textContent.trim() || "" };
}

async function renderPlaylist(tab, list) {
  const info = list.site === "VK Видео" ? await inPage(tab, pagePlaylistInfo) : null;
  const name = info?.heading || cleanTitle(tab.title);
  const card = el("div", "card");
  card.append(el("div", "title", name));
  card.append(el("div", "meta", `${list.site} · ${list.channel ? "канал" : "плейлист"}`));
  const params = (mode) => {
    const p = { url: list.url, mode, title: name };
    if (info && Object.keys(info.names).length) p.names = JSON.stringify(info.names);
    return p;
  };
  actionRow(card, "DownMax покажет список роликов, в нём отметите нужные", [
    ["Выбрать видео", true, () => send(tab, params("video"))],
    ["Звук mp3", false, () => send(tab, params("mp3"))],
    ["Звук m4a", false, () => send(tab, params("m4a"))],
  ]);
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

// Выполняется внутри страницы Threads (world MAIN). Посты, ссылки на которые есть на странице,
// и видео каждого. Данные поста — из JSON страницы или из фоновых запросов ленты, которые
// запомнил instagram-bridge.js (window.__vlMedia): после прокрутки и переходов внутри Threads
// в HTML их нет. Видео без данных (пост не попал ни туда, ни туда) не показываются.
function threadsPosts() {
  const byCode = new Map(window.__vlMedia || []);
  const hasVideo = (o) => (o.video_versions || []).length > 0 ||
    (o.carousel_media || []).some((m) => (m.video_versions || []).length > 0);
  // один пост бывает в данных несколько раз, иногда урезанной копией — копия с видео важнее
  function walk(o, depth) {
    if (!o || typeof o !== "object" || depth > 60) return;
    if (Array.isArray(o)) { for (const x of o) walk(x, depth + 1); return; }
    if (typeof o.code === "string" && (o.video_versions || o.carousel_media)) {
      const prev = byCode.get(o.code);
      if (!prev || (!hasVideo(prev) && hasVideo(o))) byCode.set(o.code, o);
    }
    for (const k in o) walk(o[k], depth + 1);
  }
  for (const s of document.querySelectorAll('script[type="application/json"]')) {
    try { walk(JSON.parse(s.textContent), 0); } catch (e) {}
  }
  const videos = (post) => (post.carousel_media || [post])
    .filter((m) => Array.isArray(m.video_versions) && m.video_versions.length)
    .map((m) => {
      const best = [...m.video_versions].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
      const cand = (m.image_versions2 && m.image_versions2.candidates) || [];
      return {
        url: best.url, width: best.width || null, height: best.height || null,
        hasAudio: (m.has_audio ?? post.has_audio) !== false,
        thumb: cand.length ? cand[0].url : null,
      };
    });
  const height = window.innerHeight;
  const seen = new Set();
  const posts = [];
  for (const a of document.querySelectorAll('a[href*="/post/"]')) {
    const m = (a.getAttribute("href") || "").match(/\/@([^/?#]+)\/post\/([\w-]+)/);
    if (!m || seen.has(m[2])) continue;
    const box = (a.closest('[data-pressable-container="true"]') || a).getBoundingClientRect();
    if (!box.height) continue;
    seen.add(m[2]);
    const post = byCode.get(m[2]);
    posts.push({
      code: m[2],
      user: (post && post.user && post.user.username) || m[1],
      caption: (post && post.caption && post.caption.text) || "",
      onScreen: box.bottom > 0 && box.top < height,
      top: box.top,
      videos: post ? videos(post) : [],
    });
  }
  return { href: location.href, posts };
}

// Разбирает загруженную заново страницу поста (см. threadsFetchPost): видео поста code.
function threadsFromHtml(html, code) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  let post = null;
  function walk(o, depth) {
    if (post || !o || typeof o !== "object" || depth > 60) return;
    if (Array.isArray(o)) { for (const x of o) walk(x, depth + 1); return; }
    if (o.code === code && (o.video_versions || o.carousel_media)) { post = o; return; }
    for (const k in o) walk(o[k], depth + 1);
  }
  for (const s of doc.querySelectorAll('script[type="application/json"]')) {
    try { walk(JSON.parse(s.textContent), 0); } catch (e) {}
  }
  if (!post) return null;
  return {
    code,
    user: (post.user && post.user.username) || null,
    caption: (post.caption && post.caption.text) || "",
    onScreen: true,
    videos: (post.carousel_media || [post])
      .filter((m) => Array.isArray(m.video_versions) && m.video_versions.length)
      .map((m) => {
        const best = [...m.video_versions].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
        const cand = (m.image_versions2 && m.image_versions2.candidates) || [];
        return {
          url: best.url, width: best.width || null, height: best.height || null,
          hasAudio: (m.has_audio ?? post.has_audio) !== false, thumb: cand.length ? cand[0].url : null,
        };
      }),
  };
}

// Выполняется внутри страницы Threads: заново загружает открытый пост. Запрос идёт со страницы
// (свой домен), а не из окошка — Safari не пускает окошко расширения на threads.com.
// Без Accept: text/html Threads отдаёт страницу без данных поста.
function threadsFetchPost() {
  const post = location.href.match(/^https:\/\/(?:www\.)?threads\.(?:com|net)\/@[^/]+\/post\/[\w-]+/);
  if (!post) return { href: location.href };
  return fetch(post[0], { headers: { Accept: "text/html" } })
    .then((r) => r.text())
    .then((html) => ({ href: location.href, html }), () => ({ href: location.href }));
}

// На странице поста — сначала его видео (если данных нет, пост загружается заново), потом
// видео из ответов. В ленте и профиле — посты, которые на экране, затем соседние.
async function renderThreads(tab) {
  const page = (await inPage(tab, threadsPosts, [], "MAIN")) || { href: tab.url, posts: [] };
  const main = threadsCode(page.href);
  let posts = page.posts;
  if (main && !posts.some((p) => p.code === main && p.videos.length)) {
    const fresh = await inPage(tab, threadsFetchPost);
    const post = fresh && fresh.html && threadsFromHtml(fresh.html, main);
    if (post) posts = [post, ...posts.filter((p) => p.code !== main)];
  }
  if (main) {
    posts.sort((a, b) => (b.code === main) - (a.code === main));
  } else {
    posts.sort((a, b) => (b.onScreen - a.onScreen) || Math.abs(a.top) - Math.abs(b.top));
  }
  posts = posts.filter((p) => p.videos.length).slice(0, 8);
  if (!posts.length) return renderEmpty();

  for (const p of posts) {
    const caption = firstLine(p.caption);
    const base = p.user ? `@${p.user}` : "Threads";
    const where = p.code === main ? "Этот пост" : main ? "Со страницы" : p.onScreen ? "На экране" : "В ленте выше или ниже";
    // Ссылка на пост — для панели подробностей в приложении: ссылка на само видео временная.
    const page = p.user ? `https://www.threads.com/@${p.user}/post/${p.code}` : tab.url;
    p.videos.forEach((v, i) => {
      const title = (caption ? `${base} — ${caption}` : `${base} — ${p.code}`) + (p.videos.length > 1 ? ` (${i + 1})` : "");
      const size = v.width && v.height ? ` · ${v.width}×${v.height}` : "";
      const card = mediaCard(title, `Threads · ${where}${size}${v.hasAudio ? "" : " · без звука"}`, v.thumb);
      actionRow(card, "Видео", [["Скачать видео", true, () => send(tab, { url: v.url, mode: "video", title, page })]]);
      if (v.hasAudio) {
        actionRow(card, "Только звук", [
          ["mp3", false, () => send(tab, { url: v.url, mode: "mp3", title, page })],
          ["m4a", false, () => send(tab, { url: v.url, mode: "m4a", title, page })],
        ]);
      }
    });
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
        [[info.items.length > 1 ? "Скачать всё в папку" : "Скачать", true, () => sendGallery(tab, title, info.items, postUrl)]]);
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

function sendGallery(tab, title, items, page) {
  const q = new URLSearchParams({ title, items: JSON.stringify(items), page: page || tab.url });
  chrome.tabs.update(tab.id, { url: "downmax://gallery?" + q.toString() });
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

// --- VK Видео ----------------------------------------------------------------
// Ролик — по адресу вкладки (/video-1_2, /clip-1_2, ?z=video-1_2 поверх ленты). Качества
// и превью отдаёт фоновая часть (vk-info в background.js), название — заголовок вкладки.
// Файл называет yt-dlp по названию ролика.

function vkVideo(url) {
  if (!/^https:\/\/([\w-]+\.)?(vk\.com|vk\.ru|vkvideo\.ru)\//.test(url || "")) return null;
  const m = url.match(/(video|clip)(-?\d+)_(\d+)/);
  return m && { kind: m[1], oid: m[2], id: m[3], url: `https://vkvideo.ru/${m[1]}${m[2]}_${m[3]}` };
}

async function renderVK(tab, video) {
  const clip = video.kind === "clip";
  const pageTitle = (tab.title || "").replace(/\s*[|—–-]\s*VK( Видео)?$/i, "").trim();
  const title = clip || !pageTitle ? (clip ? "Клип VK" : "Видео VK") : pageTitle;
  const card = mediaCard(title, "VK Видео · проверяю качество…", null);
  const metaEl = card.querySelector(".meta");
  const info = await chrome.runtime.sendMessage({ type: "vk-info", oid: video.oid, id: video.id }).catch(() => null);
  const heights = info?.heights || [];
  if (info?.image) {
    const img = el("img");
    img.src = info.image;
    img.alt = "";
    img.onerror = () => img.remove();
    card.querySelector(".thumb").append(img);
  }
  metaEl.textContent = (clip ? "Клип VK" : "VK Видео") + (heights.length ? ` · до ${heights[0]}p` : "");
  const url = video.url;
  actionRow(card, "Видео", heights.length
    ? heights.map((h, j) => [`${h}p`, j === 0, () => send(tab, { url, mode: "video", ...(j ? { quality: h } : {}) })])
    : [["Скачать видео", true, () => send(tab, { url, mode: "video" })]]);
  actionRow(card, "Только звук", [
    ["mp3", false, () => send(tab, { url, mode: "mp3" })],
    ["m4a", false, () => send(tab, { url, mode: "m4a" })],
  ]);
  if (!heights.length) {
    card.append(el("div", "hint", "Если ролик закрытый (для друзей, в закрытой группе), приложение его не скачает: yt-dlp заходит в VK без вашего аккаунта."));
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
      b.onclick = () => send(tab, { url: playlistUrl, mode: "video", title, page: tab.url, ...(j ? { quality: h } : {}) });
      row.append(b);
    });
  } else {
    const b = el("button", "primary", "Скачать");
    b.onclick = () => send(tab, { url: playlistUrl, mode: "video", title, page: tab.url });
    row.append(b);
  }
  card.append(row);

  card.append(el("div", "label", "Только звук"));
  const audio = el("div", "row");
  for (const mode of ["mp3", "m4a"]) {
    const b = el("button", "", mode);
    b.onclick = () => send(tab, { url: playlistUrl, mode, title, page: tab.url });
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

// --- Другие сайты (их качает сам yt-dlp) --------------------------------------
// Страница с видео узнаётся по адресу; что внутри, окошко не смотрит — ссылку разбирает yt-dlp в приложении.

const SITES = [
  ["TikTok", /(^|\.)tiktok\.com$/, /\/video\/\d+|^\/t\/|^\/@[^/]+\/photo\//],
  ["Rutube", /(^|\.)rutube\.ru$/, /^\/(video|shorts)\/[\w-]+/],
  ["Дзен", /(^|\.)dzen\.ru$/, /^\/(video\/watch|shorts)\/|^\/a\/|^\/media\//],
  ["X", /(^|\.)(x|twitter)\.com$/, /^\/[^/]+\/status\/\d+/],
  ["Pinterest", /(^|\.)pinterest\.[a-z.]+$/, /^\/pin\/\d+/],
  ["Telegram", /^t\.me$/, /^\/(s\/)?[\w]+\/\d+/],
  ["Twitch", /(^|\.)twitch\.tv$/, /\/clip\/|^\/videos\/\d+/],  // клипы и записи; прямой эфир бесконечен
];

function otherSite(raw) {
  try {
    const u = new URL(raw);
    const host = u.hostname.replace(/^(www\.|m\.)/, "");
    if (host === "clips.twitch.tv") return "Twitch";
    for (const [name, hostRe, pathRe] of SITES) {
      if (hostRe.test(host) && pathRe.test(u.pathname)) return name;
    }
  } catch (e) {}
  return null;
}

function renderOtherSite(tab, site) {
  const url = tab.url;
  const card = el("div", "card");
  card.append(el("div", "title", cleanTitle(tab.title)));
  card.append(el("div", "meta", site));
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

function renderEmpty(tab) {
  const card = el("div", "card hint");
  const p1 = el("p");
  p1.append("Видео на этой странице не найдено.");
  const p2 = el("p");
  p2.append("Откройте ролик на ", el("b", null, "YouTube"), ", ", el("b", null, "VK Видео"), ", ",
    el("b", null, "TikTok"), ", ", el("b", null, "Rutube"), ", ", el("b", null, "Дзене"), ", ", el("b", null, "Vimeo"),
    ", пост ", el("b", null, "Instagram"), ", ", el("b", null, "Threads"), ", ", el("b", null, "X"), " или урок ",
    el("b", null, "GetCourse"), ".");
  const p3 = el("p");
  p3.append("Если урок открыт, а видео здесь нет — запустите его на пару секунд и нажмите на значок ещё раз.");
  card.append(p1, p2, p3);
  // Другой сайт: DownMax (yt-dlp) знает сотни сайтов — можно попробовать, не получится — скажет в строке загрузки.
  if (tab && /^https?:\/\//.test(tab.url || "")) {
    const row = el("div", "row");
    const any = el("button", "", "Попробовать скачать со страницы");
    any.onclick = () => send(tab, { url: tab.url });
    row.append(any);
    card.append(row);
  }
  content.append(card);
}

(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return renderEmpty();
  const yt = youtubeUrl(tab.url || "");
  if (yt) return renderYouTube(tab, yt);
  if (/^https:\/\/(www\.)?threads\.(com|net)\//.test(tab.url || "")) return renderThreads(tab);
  const vk = vkVideo(tab.url);
  if (vk) return renderVK(tab, vk);  // ролик поверх плейлиста (?z=video…) — важнее самого плейлиста
  const list = playlistPage(tab.url || "");
  if (list) return renderPlaylist(tab, list);
  const vimeo = vimeoVideo(tab.url);
  if (vimeo) return renderVimeo(tab, vimeo);
  const ig = instagramPost(tab.url);
  if (ig) return renderInstagram(tab, ig);
  if (/^https:\/\/(www\.)?instagram\.com\//.test(tab.url || "")) return renderInstagramFeed(tab);
  const site = otherSite(tab.url || "");
  if (site) return renderOtherSite(tab, site);
  const [players, stored] = await Promise.all([
    pagePlayers(tab),
    chrome.storage.session.get("gc:" + tab.id),
  ]);
  const streams = stored["gc:" + tab.id] || [];
  if (players.length || streams.length) return renderGetCourse(tab, players, streams);
  renderEmpty(tab);
})();
