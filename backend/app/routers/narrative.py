"""房主叙事控制（导演模式）：事件 CRUD + WS 广播。
事件两类独立：news(情境新闻，渲染氛围) / rule(规则怪谈式，约束行为)。
房主发布 → 落库 + send_all 广播 town_event → 全端（含房主自己）事件流刷新。"""
import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import TownEventCreate, TownEventOut

router = APIRouter(prefix="/narrative", tags=["narrative"])


def _require_host(town: models.Town, user: models.User) -> None:
    """房主或创建者才能导演（与 towns.py 配置权限一致：waiting 态 creator / playing 态 host）。"""
    if user.id not in (town.creator_id, town.host_id or 0):
        raise HTTPException(403, "仅创建者或房主可操作")


async def _broadcast_event(town_id: int, op: str, ev: models.TownEvent) -> int:
    """广播事件增量给同镇所有在线玩家（send_all 含房主自己 → 免本地重复构造）。"""
    from .ws import manager as ws_manager
    msg = json.dumps({
        "t": "town_event", "op": op, "id": ev.id, "kind": ev.kind,
        "title": ev.title or "", "content": ev.content,
    }, ensure_ascii=False)
    tp = await ws_manager.get_or_create(town_id)
    return await tp.send_all(msg)


@router.get("/events", response_model=list[TownEventOut])
def list_events(
    town_id: int = Query(...),
    kind: str | None = Query(None),
    active_only: bool = Query(True),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """列事件（默认仅 active，供客户端事件流注入 prompt + UI 展示）。"""
    q = db.query(models.TownEvent).filter(models.TownEvent.town_id == town_id)
    if kind:
        q = q.filter(models.TownEvent.kind == kind)
    if active_only:
        q = q.filter(models.TownEvent.is_active.is_(True))
    return q.order_by(models.TownEvent.created_at.desc()).limit(100).all()


@router.post("/events", response_model=TownEventOut, status_code=201)
async def create_event(
    body: TownEventCreate,
    town_id: int = Query(...),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """房主发布事件 → 落库 + WS 广播 town_event op=add。"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    if town.status == "banned":
        raise HTTPException(403, "小镇已被封禁")
    _require_host(town, user)

    ev = models.TownEvent(
        town_id=town_id, kind=body.kind, title=body.title, content=body.content,
    )
    db.add(ev)
    db.commit()
    db.refresh(ev)
    await _broadcast_event(town_id, "add", ev)
    return ev


@router.patch("/events/{event_id}/deactivate", response_model=TownEventOut)
async def deactivate_event(
    event_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """停用事件（news 归档不再注入 / rule 解除约束）→ 广播 op=deactivate。"""
    ev = db.get(models.TownEvent, event_id)
    if not ev:
        raise HTTPException(404, "事件不存在")
    town = db.get(models.Town, ev.town_id)
    if town:
        _require_host(town, user)
    ev.is_active = False
    ev.deactivated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(ev)
    await _broadcast_event(ev.town_id, "deactivate", ev)
    return ev


@router.delete("/events/{event_id}", status_code=204)
def delete_event(
    event_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """房主删除事件（清理；不广播，客户端下次拉事件流自然消失）。"""
    ev = db.get(models.TownEvent, event_id)
    if not ev:
        raise HTTPException(404, "事件不存在")
    town = db.get(models.Town, ev.town_id)
    if town:
        _require_host(town, user)
    db.delete(ev)
    db.commit()
