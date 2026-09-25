// Общее для кнопок «Скачать» на сайтах (content.js — YouTube, vk.js — VK): значок, меню
// качеств и отправка ссылки в приложение. Скрипты одного content_scripts работают в общем
// изолированном мире, поэтому всё доступно через window.VL.
// DOM собирается через createElement: innerHTML на YouTube запрещён политикой Trusted Types.

(() => {
  if (window.VL) return;
  const SVG = "http://www.w3.org/2000/svg";

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

  // params: { url, mode, quality, title }. label — элемент, на котором ненадолго пишется «Отправлено».
  function send(params, label) {
    if (!params.url) return;
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v) q.set(k, v);
    location.href = "videoloader://download?" + q.toString();
    if (!label) return;
    const old = label.textContent;
    label.textContent = "Отправлено";
    setTimeout(() => (label.textContent = old), 2000);
  }

  // Меню живёт в <body> с position: fixed: контейнеры кнопок на сайтах обрезают всё,
  // что выходит за их высоту (у YouTube ytd-menu-renderer — overflow: hidden).
  let menu = null;
  let anchor = null;

  function closeMenu() {
    menu?.classList.remove("open");
    anchor = null;
  }

  function getMenu() {
    if (!menu || !menu.isConnected) {
      menu = el("div", "vl-menu");
      document.body.append(menu);
    }
    return menu;
  }

  // qualities: [{height, label}] от лучшего к худшему; пустой список — одна строка «Лучшее качество».
  // onPick(mode, height): mode "" — видео, "m4a" / "mp3" — звук; height null — лучшее.
  function fill(m, qualities, onPick, note) {
    m.replaceChildren();
    const item = (title, mode, height, hint) => {
      const b = el("button", "", title);
      if (hint) b.append(el("span", "vl-hint", hint));
      b.addEventListener("click", () => {
        closeMenu();
        onPick(mode, height);
      });
      m.append(b);
    };
    m.append(el("div", "vl-menu-title", "Видео"));
    if (qualities.length) {
      qualities.forEach((q, i) => item(q.label, "video", i === 0 ? null : q.height, i === 0 ? "лучшее" : ""));
    } else {
      item("Лучшее качество", "video", null, note || "");
    }
    m.append(el("div", "vl-menu-sep"));
    m.append(el("div", "vl-menu-title", "Только звук"));
    item("m4a", "m4a", null);
    item("mp3", "mp3", null);
  }

  // Кнопка обычно у нижнего края экрана: если снизу меню не помещается — открываем вверх,
  // а высоту ограничиваем свободным местом, чтобы меню не уходило за край.
  function position(m, target) {
    const r = target.getBoundingClientRect();
    m.style.right = `${Math.max(8, document.documentElement.clientWidth - r.right)}px`;
    m.style.top = m.style.bottom = m.style.maxHeight = "";
    const viewport = window.innerHeight;
    const below = viewport - r.bottom - 14;
    const above = r.top - 14;
    if (m.scrollHeight > below && above > below) {
      m.style.bottom = `${viewport - r.top + 6}px`;
      m.style.maxHeight = `${above}px`;
    } else {
      m.style.top = `${r.bottom + 6}px`;
      m.style.maxHeight = `${below}px`;
    }
  }

  // qualities — список или промис списка: пока он грузится, в меню «Лучшее качество · проверяю…».
  function toggleMenu(target, qualities, onPick, theme) {
    const m = getMenu();
    if (m.classList.contains("open") && anchor === target) return closeMenu();
    anchor = target;
    m.style.cssText = "";
    for (const [k, v] of Object.entries(theme || {})) m.style.setProperty(k, v);
    const show = (list, note) => {
      if (anchor !== target) return;
      fill(m, list, onPick, note);
      m.classList.add("open");
      position(m, target);
    };
    if (Array.isArray(qualities)) return show(qualities);
    show([], "проверяю…");
    Promise.resolve(qualities).then((list) => show(list || []), () => show([]));
  }

  document.addEventListener("click", (e) => {
    if (menu && anchor && !menu.contains(e.target) && !anchor.contains(e.target)) closeMenu();
  }, true);
  window.addEventListener("scroll", (e) => {
    if (!menu?.contains(e.target)) closeMenu();
  }, true);
  window.addEventListener("resize", closeMenu);
  document.addEventListener("keydown", (e) => e.key === "Escape" && closeMenu());

  // Ставит кнопку заново при каждом изменении страницы: сайты — одностраничные приложения
  // и перерисовывают панели кнопок.
  function watch(place) {
    let scheduled = false;
    new MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        place();
      });
    }).observe(document.documentElement, { childList: true, subtree: true });
    place();
  }

  window.VL = { el, icon, send, toggleMenu, closeMenu, watch };
})();
