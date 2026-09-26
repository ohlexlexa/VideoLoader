// Кнопка «Скачать» под видео на YouTube. Значок, меню и отправка — в download-button.js (window.VL).

(() => {
  const WRAP_ID = "vl-download";
  const { el, icon, send, toggleMenu, closeMenu, watch } = window.VL;

  function currentVideo() {
    const u = new URL(location.href);
    const v = u.searchParams.get("v");
    if (u.pathname === "/watch" && v) return `https://www.youtube.com/watch?v=${v}`;
    const m = u.pathname.match(/^\/shorts\/([\w-]+)/);
    if (m) return `https://www.youtube.com/shorts/${m[1]}`;
    return null;
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

  function build() {
    const wrap = el("div", "vl-wrap");
    wrap.id = WRAP_ID;

    const main = el("button", "vl-main");
    main.title = "Скачать в приложении «DownMax» (с его настройками)";
    const label = el("span", "", "Скачать");
    main.append(icon(), label);
    main.addEventListener("click", () => send({ url: currentVideo() }, label));

    const caret = el("button", "vl-caret", "▾");
    caret.title = "Выбрать, что скачать";
    caret.addEventListener("click", (e) => {
      e.stopPropagation();
      toggleMenu(caret, fetchQualities(), (mode, height) =>
        send({ url: currentVideo(), mode, quality: height }, label));
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
    // Последней перед «⋯»: сразу после #flexible-item-buttons (там же своя кнопка YouTube
    // «Скачать», её прячет content.css). Запасной вариант — в конец ряда кнопок.
    const flexible = document.querySelector("ytd-watch-metadata ytd-menu-renderer > #flexible-item-buttons");
    const target = flexible?.parentElement || document.querySelector("ytd-watch-metadata #top-level-buttons-computed");
    if (!target) return;
    if (existing && existing.parentElement === target && (!flexible || existing.previousElementSibling === flexible)) return;
    existing?.remove();
    if (flexible) flexible.after(build());
    else target.append(build());
  }

  document.addEventListener("yt-navigate-finish", place);
  watch(place);
})();
