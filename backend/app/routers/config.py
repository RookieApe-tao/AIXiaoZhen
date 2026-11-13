"""公开配置（/config/public）：返回客户端需要的非敏感 gameplay 调参。
   无需鉴权；只返回 category=gameplay 且非加密的项（绝不泄露 api_key）。"""
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import models
from ..database import get_db

router = APIRouter(prefix="/config", tags=["config"])


def _coerce(value, value_type: str):
    """sysconfig 存的是字符串，按 value_type 转回原始类型。"""
    if value is None:
        return None
    if value_type == "int":
        return int(value) if value.lstrip("-").isdigit() else value
    if value_type == "float":
        try:
            return float(value)
        except ValueError:
            return value
    if value_type == "bool":
        return value.lower() == "true"
    return value


@router.get("/public")
def public_config(db: Session = Depends(get_db)):
    rows = db.scalars(
        select(models.SysConfig)
        .where(models.SysConfig.category.in_(["gameplay", "prompt", "ui"]))
        .where(models.SysConfig.encrypted.is_(False))
    ).all()
    return {r.key: _coerce(r.value, r.value_type) for r in rows}
