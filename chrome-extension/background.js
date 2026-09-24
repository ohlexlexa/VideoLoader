// Фоновая часть расширения:
// 1) пункты контекстного меню для YouTube — отправляют ролик в приложение;
// 2) ловит HLS-потоки GetCourse, пока на странице урока играет видео, и помнит их
//    для окошка расширения (popup). На иконке — счётчик найденных видео.
// В приложение всё уходит ссылкой videoloader://download?url=…&mode=…&quality=…&title=…

const MODES = [
  { id: "", title: "Скачать видео" },
  { id: "m4a", title: "Скачать звук m4a" },
  { id: "mp3", title: "Скачать звук mp3" },
];

const VIDEO_PAGES = [
  "https://www.youtube.com/watch*",
  "https://www.youtube.com/shorts/*",
  "https://m.youtube.com/watch*",
  "https://m.youtube.com/shorts/*",
];

const VIDEO_LINKS = [
  "*://*.youtube.com/watch*",
  "*://*.youtube.com/shorts/*",
  "*://*.youtube.com/live/*",
  "*://youtu.be/*",
  "*://*.instagram.com/p/*",
  "*://*.instagram.com/reel/*",
  "*://*.instagram.com/reels/*",
  "*://*.instagram.com/*/p/*",
  "*://*.instagram.com/*/reel/*",
  "*://vimeo.com/*",
  "*://*.vimeo.com/*",
];

// Приводит ссылку на ролик YouTube или пост Instagram к короткому виду без меток.
function videoUrl(raw) {
  // Vimeo: ссылку приложение само переделает в ссылку плеера
  if (/^https?:\/\/([\w-]+\.)?vimeo\.com\/(.*\/)?\d{6,}/.test(raw || "")) return raw;
  const ig = (raw || "").match(/instagram\.com\/(?:[\w.]+\/)?(p|reels?|tv)\/([\w-]+)/);
  if (ig) return `https://www.instagram.com/${ig[1] === "p" ? "p" : ig[1] === "tv" ? "tv" : "reel"}/${ig[2]}/`;
  try {
    const u = new URL(raw);
    const host = u.hostname.replace(/^(www\.|m\.|music\.)/, "");
    if (host === "youtu.be") {
      const id = u.pathname.slice(1).split("/")[0];
      return id ? `https://www.youtube.com/watch?v=${id}` : null;
    }
    if (host !== "youtube.com") return null;
    const v = u.searchParams.get("v");
    if (u.pathname === "/watch" && v) return `https://www.youtube.com/watch?v=${v}`;
    const m = u.pathname.match(/^\/(shorts|live)\/([\w-]+)/);
    if (m) return m[1] === "shorts"
      ? `https://www.youtube.com/shorts/${m[2]}`
      : `https://www.youtube.com/watch?v=${m[2]}`;
  } catch (e) {}
  return null;
}

function appLink(url, mode) {
  return `videoloader://download?url=${encodeURIComponent(url)}` + (mode ? `&mode=${mode}` : "");
}

// Переход на внешнюю схему не уводит со страницы: браузер спросит, открыть ли приложение.
function send(tab, url, mode) {
  const video = videoUrl(url || "");
  if (!video) {
    flash(tab.id, "нет");
    return;
  }
  chrome.tabs.update(tab.id, { url: appLink(video, mode) });
  flash(tab.id, "✓");
}

function flash(tabId, text) {
  chrome.action.setBadgeBackgroundColor({ color: text === "✓" ? "#1e8e3e" : "#5f6368", tabId });
  chrome.action.setBadgeText({ text, tabId });
  setTimeout(() => updateBadge(tabId), 2000);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    for (const m of MODES) {
      chrome.contextMenus.create({
        id: "page:" + m.id,
        title: m.title,
        contexts: ["page", "video"],
        documentUrlPatterns: VIDEO_PAGES,
      });
      chrome.contextMenus.create({
        id: "link:" + m.id,
        title: m.title,
        contexts: ["link"],
        targetUrlPatterns: VIDEO_LINKS,
      });
    }
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const [kind, mode] = String(info.menuItemId).split(":");
  send(tab, kind === "link" ? info.linkUrl : (info.pageUrl || tab.url), mode);
});

// --- GetCourse ---------------------------------------------------------------
// Плеер GetCourse берёт видео как HLS через собственный API без «.m3u8» в адресе:
// /api/playlist/master/<id>/<подпись>. Такие запросы идут с домена плеера, а не школы,
// поэтому слушаем все адреса. Служебный воркер может засыпать — список хранится
// в chrome.storage.session, а не в памяти.

const GC_MASTER = /\/api\/playlist\/master\//i;

async function getStreams(tabId) {
  const key = "gc:" + tabId;
  return (await chrome.storage.session.get(key))[key] || [];
}

async function setStreams(tabId, list) {
  await chrome.storage.session.set({ ["gc:" + tabId]: list });
  updateBadge(tabId, list);
}

async function updateBadge(tabId, list) {
  const streams = list || (await getStreams(tabId));
  chrome.action.setBadgeBackgroundColor({ color: "#e3262f", tabId }).catch(() => {});
  chrome.action.setBadgeText({ text: streams.length ? String(streams.length) : "", tabId }).catch(() => {});
}

// Запросы одного и того же видео приходят с разными подписями — различаем по пути без подписи.
function streamKey(url) {
  const m = new URL(url).pathname.match(/\/api\/playlist\/master\/([^/]+)/i);
  return m ? m[1] : url;
}

let queue = Promise.resolve();

chrome.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.tabId < 0) return;
    let path;
    try {
      path = new URL(details.url).pathname;
    } catch (e) {
      return;
    }
    if (!GC_MASTER.test(path)) return;
    // Цепочка промисов: запросы идут пачкой, без неё записи затирали бы друг друга.
    queue = queue.then(async () => {
      const list = await getStreams(details.tabId);
      const key = streamKey(details.url);
      const existing = list.find((s) => s.key === key);
      if (existing) {
        existing.url = details.url; // свежая подпись
      } else {
        const tab = await chrome.tabs.get(details.tabId).catch(() => null);
        list.push({ key, url: details.url, pageTitle: tab ? tab.title : "", at: Date.now() });
      }
      await setStreams(details.tabId, list);
    }).catch(() => {});
  },
  { urls: ["<all_urls>"], types: ["xmlhttprequest", "media", "other"] }
);

// Новая страница — новый урок: старые потоки забываем.
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === "loading" && info.url) {
    queue = queue.then(() => setStreams(tabId, [])).catch(() => {});
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  chrome.storage.session.remove("gc:" + tabId).catch(() => {});
});
