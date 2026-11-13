"""对话日志（/chat_logs）：玩家角色发言落库 + 敏感词扫描。
§5.7.5 行为结果持久化：客户端说话时 POST，既存档又给审查提供数据源。
实时气泡广播走 ENet/RPC（客户端），本端点只管持久化——双通道各司其职。"""
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .. import models, moderation
from ..auth import get_current_user
from ..database import get_db
from ..schemas import ChatLogCreate, ChatLogOut

router = APIRouter(prefix="/chat_logs", tags=["chat"])


def _resolve_names(db: Session, logs: list[models.ChatLog]) -> dict[int, str]:
    """批量解析 logs 涉及的 character 名，避免 N+1。返回 char_id→name。
    ponytail: room_name 已废弃（rooms 表删除），不再解析。"""
    char_ids = {l.speaker_id for l in logs if l.speaker_id} | {l.listener_id for l in logs if l.listener_id}
    return {c.id: c.name for c in db.scalars(
        select(models.Character).where(models.Character.id.in_(char_ids)))} if char_ids else {}


def _enrich(log: models.ChatLog, cnames: dict[int, str]) -> ChatLogOut:
    out = ChatLogOut.model_validate(log)
    out.speaker_name = cnames.get(log.speaker_id) if log.speaker_id else None
    out.listener_name = cnames.get(log.listener_id) if log.listener_id else None
    out.room_name = None  # ponytail: rooms 表已删除
    return out


@router.get("", response_model=list[ChatLogOut])
def list_chat_logs(
    town_id: int | None = Query(None, description="按小镇过滤（推荐）"),
    character_id: int | None = Query(None, description="过滤含该角色的对话（speaker 或 listener）"),
    speaker_id: int | None = None,
    listener_id: int | None = None,
    limit: int = Query(50, le=200),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """查询对话日志。返回带 speaker_name 等连表名。"""
    q = select(models.ChatLog).order_by(models.ChatLog.created_at.desc()).limit(limit)
    if town_id:
        q = q.where(models.ChatLog.town_id == town_id)
    if character_id is not None:
        q = q.where(or_(
            models.ChatLog.speaker_id == character_id,
            models.ChatLog.listener_id == character_id,
        ))
    if speaker_id is not None:
        q = q.where(models.ChatLog.speaker_id == speaker_id)
    if listener_id is not None:
        q = q.where(models.ChatLog.listener_id == listener_id)
    rows = list(reversed(db.execute(q).scalars().all()))  # 客户端展示用正序（旧→新）
    cnames = _resolve_names(db, rows)
    return [_enrich(l, cnames) for l in rows]


@router.post("", response_model=ChatLogOut, status_code=201)
def create_chat_log(
    body: ChatLogCreate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = db.get(models.Character, body.speaker_id)
    if not char or char.deleted_at is not None:
        raise HTTPException(404, "角色不存在")
    if char.owner_id != user.id:
        raise HTTPException(403, "无权用该角色发言")
    # 复用 #10 的 DFA 敏感词引擎：命中则 is_flagged，stub_score 留 ai_score
    hits = moderation.scan(body.content)
    score, _tags = moderation.stub_score(hits)
    log = models.ChatLog(
        speaker_id=body.speaker_id,
        listener_id=body.listener_id,
        town_id=body.town_id,
        content=body.content,
        ai_score=score,
        is_flagged=len(hits) > 0,
    )
    db.add(log)
    db.commit()
    db.refresh(log)
    cnames = _resolve_names(db, [log])
    return _enrich(log, cnames)
