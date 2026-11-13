"""NPC 内部活动日志（/npc_logs）：决策记录 + 内心独白 + 状态变更。
不入 embedding，不占 RAG 向量检索。与 memory_vectors（带 pgvector）和 chat_logs（对话流水）职责分开。"""
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import NpcLogCreate, NpcLogOut

router = APIRouter(prefix="/npc_logs", tags=["npc_logs"])


def _resolve_names(db: Session, logs: list[models.NpcLog]) -> dict[int, str]:
    cids = {l.character_id for l in logs}
    if not cids:
        return {}
    return {c.id: c.name for c in db.scalars(select(models.Character).where(models.Character.id.in_(cids)))}


@router.post("", response_model=NpcLogOut, status_code=201)
def create_npc_log(body: NpcLogCreate, user: models.User = Depends(get_current_user), db: Session = Depends(get_db)):
    char = db.get(models.Character, body.character_id)
    if not char or char.deleted_at is not None:
        raise HTTPException(404, "角色不存在")
    if char.owner_id != user.id:
        raise HTTPException(403, "无权为该角色写日志")
    log = models.NpcLog(character_id=body.character_id, log_type=body.log_type, content=body.content)
    db.add(log)
    db.commit()
    db.refresh(log)
    out = NpcLogOut.model_validate(log)
    cnames = _resolve_names(db, [log])
    out.character_name = cnames.get(log.character_id)
    return out


@router.get("", response_model=list[NpcLogOut])
def list_npc_logs(
    character_id: int | None = None,
    log_type: str | None = None,
    limit: int = Query(50, le=200),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    q = select(models.NpcLog).order_by(models.NpcLog.created_at.desc()).limit(limit)
    if character_id is not None:
        q = q.where(models.NpcLog.character_id == character_id)
    if log_type:
        q = q.where(models.NpcLog.log_type == log_type)
    rows = list(db.scalars(q).all())
    cnames = _resolve_names(db, rows)
    out = []
    for r in rows:
        o = NpcLogOut.model_validate(r)
        o.character_name = cnames.get(r.character_id)
        out.append(o)
    return out
