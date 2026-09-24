// Кнопка «Скачать» под видео на YouTube. YouTube — одностраничное приложение и
// перерисовывает панель кнопок, поэтому кнопка ставится заново при каждом изменении.
// DOM собирается через createElement: innerHTML на YouTube запрещён политикой Trusted Types.

(() => {
  const WRAP_ID = "vl-download";
  const SVG = "http://www.w3.org/2000/svg";

  function currentVideo() {
    const u = new URL(location.href);
    const v = u.searchParams.get("v");
    if (u.pathname === "/watch" && v) return `https://www.youtube.com/watch?v=${v}`;
    const m = u.pathname.match(/^\/shorts\/([\w-]+)/);
    if (m) return `https://www.youtube.com/shorts/${m[1]}`;
    return null;
  }

  function launch(mode, label, height) {
    const video = currentVideo();
    if (!video) return;
    location.href = `videoloader://download?url=${encodeURIComponent(video)}` +
      (mode ? `&mode=${mode}` : "") + (height ? `&quality=${height}` : "");
    const old = label.textContent;
    label.textContent = "Отправлено";
    setTimeout(() => (label.textContent = old), 2000);
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  function icon() {
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const rect = document.createElementNS(SVG, "rect");
    for (const [k, v] of Object.entries({ x: 1, y: 1, width: 22, height: 22, rx: 7, fill: "#e3262f" })) rect.setAttribute(k, v);
    const path = document.createElementNS(SVG, "path");
    for (const [k, v] of Object.entries({
      d: "M12 6v8.5M8 10.5l4 4 4-4M7.5 18h9",
      stroke: "#fff", "stroke-width": 2.2, fill: "none",
      "stroke-linecap": "round", "stroke-linejoin": "round",
    })) path.setAttribute(k, v);
    svg.append(rect, path);
    return svg;
  }

  // Меню живёт в <body> с position: fixed: контейнер кнопок YouTube (ytd-menu-renderer)
  // обрезает всё, что выходит за его высоту (overflow: hidden).
  let menu = null;
  let menuLabel = null;

  function closeMenu() {
    menu?.classList.remove("open");
  }

  // Список качеств текущего ролика берёт page-bridge.js (он видит плеер YouTube).
  // Событие обрабатывается синхронно, поэтому ответ приходит до выхода из функции.
  function fetchQualities() {
    let list = [];
    const onAnswer = (e) => {
      try { list = JSON.parse(e.detail) || []; } catch (err) {}
    };
    document.addEventListener("vl-qualities", onAnswer);
    document.dispatchEvent(new CustomEvent("vl-request-qualities"));
    document.removeEventListener("vl-qualities", onAnswer);
    return list;
  }

  function addItem(m, title, mode, height, hint) {
    const item = el("button", "", title);
    if (hint) item.append(el("span", "vl-hint", hint));
    item.addEventListener("click", () => {
      closeMenu();
      if (menuLabel) launch(mode, menuLabel, height);
    });
    m.append(item);
  }

  function getMenu() {
    if (!menu || !menu.isConnected) {
      menu = el("div", "vl-menu");
      document.body.append(menu);
    }
    return menu;
  }

  function fillMenu(m) {
    m.replaceChildren();
    const list = fetchQualities();
    m.append(el("div", "vl-menu-title", "Видео"));
    if (list.length) {
      list.forEach((q, i) => addItem(m, q.label, "video", i === 0 ? null : q.height, i === 0 ? "лучшее" : ""));
    } else {
      addItem(m, "Лучшее качество", "video", null);
    }
    m.append(el("div", "vl-menu-sep"));
    m.append(el("div", "vl-menu-title", "Только звук"));
    addItem(m, "m4a", "m4a", null);
    addItem(m, "mp3", "mp3", null);
  }

  function toggleMenu(caret, label) {
    const m = getMenu();
    if (m.classList.contains("open")) return closeMenu();
    menuLabel = label;
    fillMenu(m);
    const r = caret.getBoundingClientRect();
    m.style.top = `${r.bottom + 6}px`;
    m.style.right = `${Math.max(8, document.documentElement.clientWidth - r.right)}px`;
    m.classList.add("open");
  }

  document.addEventListener("click", (e) => {
    if (menu && !menu.contains(e.target) && !e.target.closest?.(".vl-caret")) closeMenu();
  }, true);
  window.addEventListener("scroll", closeMenu, true);
  window.addEventListener("resize", closeMenu);
  document.addEventListener("keydown", (e) => e.key === "Escape" && closeMenu());

  function build() {
    const wrap = el("div", "vl-wrap");
    wrap.id = WRAP_ID;

    const main = el("button", "vl-main");
    main.title = "Скачать в приложении «Загрузка видео» (с его настройками)";
    const label = el("span", "", "Скачать");
    main.append(icon(), label);
    main.addEventListener("click", () => launch("", label));

    const caret = el("button", "vl-caret", "▾");
    caret.title = "Выбрать, что скачать";
    caret.addEventListener("click", (e) => {
      e.stopPropagation();
      toggleMenu(caret, label);
    });

    wrap.append(main, caret);
    return wrap;
  }

  function place() {
    const existing = document.getElementById(WRAP_ID);
    if (!location.pathname.startsWith("/watch")) {
      existing?.remove();
      closeMenu();
      return;
    }
    const target =
      document.querySelector("ytd-watch-metadata #top-level-buttons-computed") ||
      document.querySelector("ytd-watch-metadata #actions-inner");
    if (!target) return;
    if (existing && existing.parentElement === target) return;
    existing?.remove();
    target.append(build());
  }

  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      place();
    });
  }).observe(document.documentElement, { childList: true, subtree: true });

  document.addEventListener("yt-navigate-finish", place);
  place();
})();
