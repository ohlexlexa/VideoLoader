// Ссылка downmax://installed: Chrome спросит, открыть ли DownMax, а приложение отметит, что расширение стоит.
const open = () => { location.href = "downmax://installed"; };
document.getElementById("open").addEventListener("click", open);
setTimeout(open, 600);
