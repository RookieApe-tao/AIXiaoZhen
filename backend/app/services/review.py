"""统一审查 LLM 服务（qwen-plus via dashscope OpenAI 兼容端点，urllib stdlib，不引 SDK）。
管理员配置在 sysconfig (review_provider/review_model/review_api_key/review_threshold/review_enabled)。
启动 init(db) 缓存 key/model；score_text(content) → (score 0-1 | None, reason str | None)。
key 未配 / 调用失败 → (None, None)，审查回退人工（永不因 LLM 异常阻断业务）。"""
import json
import re
import urllib.error
import urllib.request

from sqlalchemy.orm import Session

from .. import models

_api_key: str = ""
_model: str = "qwen-plus"
_endpoint: str = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

_SYSTEM_PROMPT = (
    "你是游戏角色内容安全审核员。评估给定角色设定的合规风险"
    "（涉政/暴力/色情/违法犯罪/歧视/辱骂/自残/隐私泄露等）。"
    '仅返回 JSON：{"score": 0.0-1.0 风险分(0=安全,1=严重违规), "reason": "<=20字中文原因,无风险填\\"无\\""}'
)


def init(db: Session) -> None:
    """启动加载：缓存 review_api_key + review_model。"""
    global _api_key, _model
    key_row = db.get(models.SysConfig, "review_api_key")
    _api_key = key_row.value.strip() if key_row and key_row.value else ""
    model_row = db.get(models.SysConfig, "review_model")
    if model_row and model_row.value:
        _model = model_row.value
    if not _api_key:
        print("[review] WARN: review_api_key 为空，LLM 自动审核不可用，审查全部进人工队列")


def key_configured() -> bool:
    return bool(_api_key)


def score_text(content: str) -> tuple[float | None, str | None]:
    """调 qwen-plus 给内容打合规风险分。返回 (score, reason)。
    key 空 / 任何异常 → (None, None)（调用方据此回退人工）。"""
    if not _api_key or not content or not content.strip():
        return None, None
    body = json.dumps({
        "model": _model,
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": content[:2000]},  # ponytail: 截断防超长；角色设定通常 <2k
        ],
    }).encode("utf-8")
    req = urllib.request.Request(
        _endpoint, data=body,
        headers={"Authorization": f"Bearer {_api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        text = data["choices"][0]["message"]["content"].strip()
        return _parse(text)
    except Exception as e:  # noqa: BLE001 — 审核不能因 LLM 抖动阻断建角色
        print(f"[review] LLM 打分失败，回退人工：{e}")
        return None, None


def _parse(text: str) -> tuple[float | None, str | None]:
    """从模型输出解析 {score, reason}。容错：先 JSON，再正则。"""
    try:
        obj = json.loads(text)
        return float(obj.get("score")), str(obj.get("reason") or "") or None
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
    m = re.search(r'([0-9]*\.?[0-9]+)', text)
    return (float(m.group(1)) if m else None), None
