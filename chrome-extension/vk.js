// Кнопка «Скачать» на VK Видео (vkvideo.ru, vk.com, vk.ru): на странице ролика — в ряду
// «Нравится · Поделиться» под плеером, у клипов — круглая кнопка в столбце справа.
// Ролик определяется по адресу страницы (/video-1_2, /clip-1_2 или ?z=video-1_2 поверх ленты).
// Качества берёт фоновая часть расширения из встраиваемого плеера VK (vk-info в background.js).
// Значок, меню и отправка — в download-button.js (window.VL).

(() => {
  const WRAP_ID = "vl-vk-download";
  const { el, icon, send, toggleMenu, closeMenu, watch } = window.VL;

  function currentVideo() {
    const m = (location.pathname + location.search).match(/(video|clip)(-?\d+)_(\d+)/);
    if (!m) return null;
    return { kind: m[1], oid: m[2], id: m[3], url: `https://vkvideo.ru/${m[1]}${m[2]}_${m[3]}` };
  }

  const cache = new Map();
  function qualities(video) {
    const key = video.oid + "_" + video.id;
    if (!cache.has(key)) {
      cache.set(key, chrome.runtime.sendMessage({ type: "vk-info", oid: video.oid, id: video.id })
        .then((info) => (info?.heights || []).map((h) => ({ height: h, label: `${h}p` })))
        .catch(() => []));
    }
    return cache.get(key);
  }

  // Цвета меню — от страницы: у VK светлая и тёмная темы, а своих переменных цветов
  // он наружу не даёт.
  function theme() {
    const body = getComputedStyle(document.body);
    return {
      "--vl-menu": body.backgroundColor,
      "--vl-text": body.color,
      "--vl-hover": "rgba(128, 128, 128, 0.2)",
      "--vl-divider": "rgba(128, 128, 128, 0.3)",
      "--vl-menu-border": "1px solid rgba(128, 128, 128, 0.3)",
    };
  }

  function openMenu(target, label) {
    const video = currentVideo();
    if (!video) return;
    toggleMenu(target, qualities(video), (mode, height) =>
      send({ url: video.url, mode, quality: height }, label), theme());
  }

  // --- Страница ролика -------------------------------------------------------

  function build() {
    const wrap = el("div", "vl-wrap vl-vk");
    wrap.id = WRAP_ID;

    const main = el("button", "vl-main");
    main.title = "Скачать в приложении «DownMax» (с его настройками)";
    const label = el("span", "", "Скачать");
    main.append(icon(), label);
    main.addEventListener("click", () => send({ url: currentVideo()?.url }, label));

    const caret = el("button", "vl-caret", "▾");
    caret.title = "Выбрать, что скачать";
    caret.addEventListener("click", (e) => {
      e.stopPropagation();
      openMenu(caret, label);
    });

    wrap.append(main, caret);
    return wrap;
  }

  // Цвета кнопки — как у соседней «Поделиться» (обновляются при смене темы).
  function matchNeighbour(wrap, neighbour) {
    const cs = getComputedStyle(neighbour);
    const text = neighbour.querySelector(".vkuiFootnote__host") || neighbour;
    wrap.style.setProperty("--vl-bg", cs.backgroundColor);
    wrap.style.setProperty("--vl-text", getComputedStyle(text).color);
  }

  function placeOnPage() {
    const share = document.querySelector('[data-testid="video_page_share_button"]');
    let existing = document.getElementById(WRAP_ID);
    if (!share) return existing?.remove();
    const row = share.parentElement;
    if (!existing || existing.parentElement !== row || existing !== row.lastElementChild) {
      existing?.remove();
      existing = build();
      row.append(existing);
    }
    matchNeighbour(existing, share);
  }

  // --- Клипы -----------------------------------------------------------------

  function buildClipButton() {
    const item = el("div", "vl-clip");
    const button = el("button", "vl-clip-button");
    button.title = "Скачать в приложении «DownMax»";
    button.append(icon());
    const label = el("span", "vl-clip-label", "Скачать");
    button.addEventListener("click", (e) => {
      e.stopPropagation();
      openMenu(button, label);
    });
    item.append(button, label);
    return item;
  }

  // В столбце кнопок клипа — перед «⋯» (или в конец, если его нет).
  function placeOnClips() {
    for (const share of document.querySelectorAll('[data-testid="clips-controls-share-button"]')) {
      const group = share.closest('[data-testid="roundedgroup"]');
      if (!group || group.querySelector(":scope > .vl-clip")) continue;
      const more = group.querySelector('[data-testid="clips-controls-more-actions-button"]');
      const moreItem = more && [...group.children].find((c) => c.contains(more));
      group.insertBefore(buildClipButton(), moreItem || null);
    }
  }

  function place() {
    if (!currentVideo()) {
      document.getElementById(WRAP_ID)?.remove();
      closeMenu();
      return;
    }
    placeOnPage();
    placeOnClips();
  }

  watch(place);
})();
