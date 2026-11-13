"""敏感词 DFA 引擎（ponytail 版：内存词表 + 子串扫描）。
启动 load() 载入 enabled 词；scan() 做子串匹配；stub_score() 规则化映射 0-1（待接 qwen-plus）。
§5.8.2 自动层的本地敏感词预筛部分；AI 打分见 stub_score。"""
from threading import Lock
from sqlalchemy.orm import Session
from . import models

_lock = Lock()
# word -> (category, level)；仅 enabled 词
_words: dict[str, tuple[str | None, int]] = {}


def load(db: Session) -> int:
    """从 DB 重新载入 enabled 词到内存，返回词数。"""
    global _words
    rows = db.query(models.SensitiveWord).filter(models.SensitiveWord.enabled.is_(True)).all()
    with _lock:
        _words = {r.word: (r.category, int(r.level)) for r in rows}
    return len(_words)


def reload(db: Session) -> int:
    """Directus 改词后刷新缓存。"""
    return load(db)


def scan(text: str) -> list[dict]:
    """子串扫描，返回命中列表 [{word, category, level}]。
    ponytail: O(n*m) 子串匹配，dev 词表(<1万)够用；词表大或延迟敏感时换 Aho-Corasick。"""
    if not text:
        return []
    with _lock:
        words = dict(_words)
    return [
        {"word": w, "category": cat, "level": lvl}
        for w, (cat, lvl) in words.items()
        if w in text
    ]


def stub_score(hits: list[dict]) -> tuple[float, list[str]]:
    """规则化映射到 0-1 可疑度 + 返回 tag 列表。用于 chat_logs 实时标记 is_flagged
    （每句对话都调，必须便宜——DFA 规则，不调 LLM）。审查管道的 LLM 打分见 services/review.py。"""
    if not hits:
        return 0.0, []
    max_level = max(h["level"] for h in hits)
    score = min(1.0, max_level / 3.0 + 0.3 * len(hits))
    tags = sorted({h["category"] or "敏感词" for h in hits})
    return round(score, 3), tags
