// Работает в контексте самой страницы YouTube (world: MAIN): только отсюда виден плеер
// и его данные. По запросу "vl-request-qualities" отвечает событием "vl-qualities"
// со списком качеств текущего ролика в виде JSON-строки: [{height, label}], от лучшего к худшему.

(() => {
  const LEVELS = {
    highres: 4320, hd2880: 2880, hd2160: 2160, hd1440: 1440, hd1080: 1080,
    hd720: 720, large: 480, medium: 360, small: 240, tiny: 144,
  };

  function qualities() {
    const player = document.getElementById("movie_player");
    const videoId = new URL(location.href).searchParams.get("v");
    const byHeight = new Map();

    // Основной источник — форматы из ответа плеера. Высоту берём из подписи («1080p60» → 1080):
    // у вертикальных роликов поле height больше, а yt-dlp считает по меньшей стороне, как и подпись.
    const response = player?.getPlayerResponse?.();
    if (response?.videoDetails?.videoId === videoId) {
      for (const f of response.streamingData?.adaptiveFormats || []) {
        if (!f.mimeType?.startsWith("video/")) continue;
        const height = parseInt(f.qualityLabel || "", 10);
        if (!height) continue;
        const fps = f.fps > 30 ? f.fps : 0;
        const prev = byHeight.get(height);
        if (!prev || fps > prev.fps) byHeight.set(height, { height, fps });
      }
    }

    // Запасной источник — уровни качества, которые плеер показывает в своём меню.
    if (!byHeight.size) {
      for (const level of player?.getAvailableQualityLevels?.() || []) {
        const height = LEVELS[level];
        if (height) byHeight.set(height, { height, fps: 0 });
      }
    }

    return [...byHeight.values()]
      .sort((a, b) => b.height - a.height)
      .map(({ height, fps }) => ({ height, label: `${height}p${fps || ""}` }));
  }

  document.addEventListener("vl-request-qualities", () => {
    let list = [];
    try {
      list = qualities();
    } catch (e) {}
    document.dispatchEvent(new CustomEvent("vl-qualities", { detail: JSON.stringify(list) }));
  });
})();
