// Работает в контексте самой страницы Instagram (world: MAIN) с самого начала загрузки.
// Лента, профили и переходы между постами подгружаются фоновыми запросами (GraphQL, /api/v1/),
// а не лежат в HTML. Скрипт подсматривает ответы этих запросов и запоминает посты по коду
// (window.__vlMedia: код → объект поста с video_versions / image_versions2 / carousel_media),
// чтобы окошко расширения знало, что за видео и фото сейчас на экране.

(() => {
  if (window.__vlMedia) return;
  const media = new Map();
  window.__vlMedia = media;

  const isPost = (o) => typeof o.code === "string" && (o.video_versions || o.image_versions2 || o.carousel_media);

  function walk(o, depth) {
    if (!o || typeof o !== "object" || depth > 60) return;
    if (Array.isArray(o)) {
      for (const x of o) walk(x, depth + 1);
      return;
    }
    if (isPost(o)) {
      const prev = media.get(o.code);
      // запись с каруселью или видео ценнее урезанной копии того же поста
      if (!prev || (o.carousel_media && !prev.carousel_media) || (o.video_versions && !prev.video_versions)) {
        media.set(o.code, o);
      }
    }
    for (const k in o) walk(o[k], depth + 1);
  }

  // Ответ бывает одним JSON или несколькими JSON построчно.
  function ingest(text) {
    if (!text || text.length > 30e6) return;
    try {
      walk(JSON.parse(text), 0);
    } catch (e) {
      for (const line of text.split("\n")) {
        const t = line.trim();
        if (t.startsWith("{")) {
          try { walk(JSON.parse(t), 0); } catch (err) {}
        }
      }
    }
  }

  const interesting = (url) => /\/graphql|\/api\/v1\//.test(url || "");

  const originalFetch = window.fetch;
  window.fetch = async function (...args) {
    const response = await originalFetch.apply(this, args);
    try {
      const url = typeof args[0] === "string" ? args[0] : args[0] && args[0].url;
      if (interesting(url)) response.clone().text().then(ingest).catch(() => {});
    } catch (e) {}
    return response;
  };

  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    this.__vlUrl = String(url);
    return originalOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function (...args) {
    if (interesting(this.__vlUrl)) {
      this.addEventListener("load", () => {
        try {
          if (this.responseType === "" || this.responseType === "text") ingest(this.responseText);
        } catch (e) {}
      });
    }
    return originalSend.apply(this, args);
  };

  // Данные первой загрузки страницы лежат в <script type="application/json">.
  window.__vlScan = () => {
    for (const s of document.querySelectorAll('script[type="application/json"]')) {
      if (s.__vlSeen) continue;
      s.__vlSeen = true;
      ingest(s.textContent);
    }
  };
  document.addEventListener("DOMContentLoaded", window.__vlScan);
})();
