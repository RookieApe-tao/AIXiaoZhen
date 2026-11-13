"""统一 embedding 服务。管理员配置在 sysconfig (embedding_provider/model/api_key/dim)。
走 urllib stdlib 调 dashscope OpenAI 兼容端点，不引 SDK。"""
import json
import urllib.request
import urllib.error
from sqlalchemy.orm import Session
from .. import models

# 模块级缓存，启动 init() 填充
_api_key: str = ""
_model: str = "text-embedding-v3"
_endpoint: str = "https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings"


def init(db: Session) -> None:
    """启动加载：缓存 embedding_api_key + model。"""
    global _api_key, _model
    key_row = db.get(models.SysConfig, "embedding_api_key")
    _api_key = key_row.value.strip() if key_row and key_row.value else ""
    model_row = db.get(models.SysConfig, "embedding_model")
    if model_row and model_row.value:
        _model = model_row.value
    if not _api_key:
        print("[embedding] WARN: embedding_api_key 为空，记忆写入不可用，搜索降级为时序")


def key_configured() -> bool:
    return bool(_api_key)


def embed(text: str) -> list[float]:
    """单文本 embedding → 1024 维 float 列表。key 空时 raise ValueError。"""
    if not _api_key:
        raise ValueError("embedding_api_key 未配置")
    req = urllib.request.Request(
        _endpoint,
        data=json.dumps({"model": _model, "input": text}).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {_api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        return body["data"][0]["embedding"]
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:300]
        raise RuntimeError(f"embedding API {e.code}: {detail}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"embedding API 网络错误: {e.reason}")
