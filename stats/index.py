"""Приёмник анонимной статистики DownMax (Yandex Cloud Functions → YDB serverless).

DownMax шлёт пачку событий: POST {"install": "<uuid>", "events": [{"id": "<uuid>", "ts": 1790000000, "name": "open", ...}]}.
Адрес функции зашит в приложение и открыт всем, поэтому всё, что не подходит под схему, молча отбрасывается:
неизвестные события и поля, длинные строки, странные числа. IP не записывается. Повтор той же пачки
(обрыв связи после записи) не удваивает цифры: ключ таблицы — (install, id), запись — UPSERT.
"""
import base64
import json
import math
import os
import re
import time
from datetime import datetime, timezone

import ydb
import ydb.iam

EVENTS = {
    "install", "open", "components",
    "download_start", "download_done", "download_failed", "download_cancelled",
    "pause", "seed", "feedback", "donate_open", "donate_click",
}
TEXT = ["app", "os", "build", "site", "kind", "origin", "quality", "error", "ytdlp", "source"]
NUMBERS = ["duration_s", "size_mb", "convert_s"]
# Прочее — в JSON-колонку props, только эти ключи.
EXTRA_BOOL = ["chrome", "safari", "remote"]
EXTRA_TEXT = ["lang", "missing"]

UUID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
WORD = re.compile(r"^[\w .,+\-]{1,40}$")
MAX_BODY = 64 * 1024
MAX_EVENTS = 100
HOURLY_LIMIT = 500  # событий в час от одной установки (на экземпляр функции — защита от мусора, не от атаки)

COLUMNS = [("install", "Utf8"), ("id", "Utf8"), ("ts", "Timestamp"), ("received", "Timestamp"), ("name", "Utf8")] \
    + [(c, "Utf8?") for c in TEXT] + [("rating", "Int32?")] + [(c, "Double?") for c in NUMBERS] \
    + [("converted", "Bool?"), ("props", "JsonDocument?")]

CREATE = """
CREATE TABLE IF NOT EXISTS events (
    install Utf8, id Utf8, ts Timestamp, received Timestamp, name Utf8,
    app Utf8, os Utf8, build Utf8, site Utf8, kind Utf8, origin Utf8, quality Utf8,
    error Utf8, ytdlp Utf8, source Utf8, rating Int32,
    duration_s Double, size_mb Double, convert_s Double, converted Bool, props JsonDocument,
    PRIMARY KEY (install, id)
)
"""

PRIMITIVE = {"Utf8": ydb.PrimitiveType.Utf8, "Timestamp": ydb.PrimitiveType.Timestamp,
             "Int32": ydb.PrimitiveType.Int32, "Double": ydb.PrimitiveType.Double,
             "Bool": ydb.PrimitiveType.Bool, "JsonDocument": ydb.PrimitiveType.JsonDocument}
ROW = ydb.StructType()
for column, kind in COLUMNS:
    t = PRIMITIVE[kind.rstrip("?")]
    ROW.add_member(column, ydb.OptionalType(t) if kind.endswith("?") else t)
ROWS = ydb.ListType(ROW)
UPSERT = "DECLARE $rows AS List<Struct<" + ", ".join(f"{c}: {k}" for c, k in COLUMNS) + ">>;\n" \
         "UPSERT INTO events SELECT * FROM AS_TABLE($rows);"

_pool = None
_seen = {}  # install → (начало часа, событий)


def pool():
    global _pool
    if _pool is None:
        driver = ydb.Driver(endpoint=os.environ["YDB_ENDPOINT"], database=os.environ["YDB_DATABASE"],
                            credentials=ydb.iam.MetadataUrlCredentials())
        driver.wait(timeout=5, fail_fast=True)
        _pool = ydb.QuerySessionPool(driver)
        _pool.execute_with_retries(CREATE)
    return _pool


def text(value):
    return value if isinstance(value, str) and WORD.match(value) else None


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and 0 <= value <= 10_000_000 else None


def row(install, e, now):
    if not isinstance(e, dict) or e.get("name") not in EVENTS or not UUID.match(str(e.get("id", ""))):
        return None
    ts = e.get("ts")
    if isinstance(ts, bool) or not isinstance(ts, (int, float)) or not (now - 90 * 86400 <= ts <= now + 86400):
        ts = now  # часы на Mac сбиты — берём время приёма
    r = {"install": install.lower(), "id": e["id"].lower(), "name": e["name"],
         "ts": int(ts * 1_000_000), "received": int(now * 1_000_000)}
    for c in TEXT:
        r[c] = text(e.get(c))
    for c in NUMBERS:
        r[c] = number(e.get(c))
    rating = e.get("rating")
    r["rating"] = rating if isinstance(rating, int) and not isinstance(rating, bool) and 1 <= rating <= 5 else None
    r["converted"] = e.get("converted") if isinstance(e.get("converted"), bool) else None
    extra = {k: e[k] for k in EXTRA_BOOL if isinstance(e.get(k), bool)}
    extra.update({k: e[k] for k in EXTRA_TEXT if text(e.get(k))})
    r["props"] = json.dumps(extra, ensure_ascii=False) if extra else None
    return r


def allowed(install, count, now):
    hour = int(now // 3600)
    start, seen = _seen.get(install, (hour, 0))
    if start != hour:
        seen = 0
    if len(_seen) > 50_000:
        _seen.clear()
    _seen[install] = (hour, seen + count)
    return seen + count <= HOURLY_LIMIT


def reply(code, text=""):
    return {"statusCode": code, "headers": {"Content-Type": "text/plain; charset=utf-8"}, "body": text}


def handler(event, context):
    if event.get("httpMethod") != "POST":
        return reply(405)
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8", "replace")
    if len(body) > MAX_BODY:
        return reply(413)
    try:
        data = json.loads(body)
    except ValueError:
        return reply(400)
    install = data.get("install") if isinstance(data, dict) else None
    events = data.get("events") if isinstance(data, dict) else None
    if not isinstance(install, str) or not UUID.match(install) or not isinstance(events, list):
        return reply(400)
    now = time.time()
    rows = [r for r in (row(install, e, now) for e in events[:MAX_EVENTS]) if r]
    if not rows:
        return reply(204)
    if not allowed(install.lower(), len(rows), now):
        return reply(429)
    pool().execute_with_retries(UPSERT, {"$rows": (rows, ROWS)})
    return reply(204)
