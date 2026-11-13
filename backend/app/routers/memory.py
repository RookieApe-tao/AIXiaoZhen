"""记忆系统（/memories）：写入(embed→pgvector) + 检索(cosine→三维重排打分)。
需 player token（所有权验证 character.owner_id == current_user.id）。
§5.7.4: embedding 管理员统一配，不走 BYOK。"""
import math
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import MemoryCreate, MemoryOut, MemorySearchRequest, MemorySearchResult
from ..services import embedding as emb

router = APIRouter(prefix="/memories", tags=["memory"])


@router.get("", response_model=list[MemoryOut])
def list_memories(
    character_id: int,
    limit: int = Query(15, le=50),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取角色最近的记忆列表（按时间倒序，不走 embedding 语义搜索）。
    用于 NPC 大脑启动时加载近期记忆上下文，配合 core_memories_json 长期事实。"""
    _owned_character(character_id, user, db)
    return db.scalars(
        select(models.MemoryVector)
        .where(models.MemoryVector.character_id == character_id)
        .order_by(models.MemoryVector.created_at.desc())
        .limit(limit)
    ).all()


def _owned_character(char_id: int, user: models.User, db: Session) -> models.Character:
    char = db.get(models.Character, char_id)
    if not char:
        raise HTTPException(404, "角色不存在")
    if char.owner_id != user.id:
        raise HTTPException(403, "无权操作该角色的记忆")
    return char


@router.post("", response_model=MemoryOut, status_code=201)
def create_memory(
    body: MemoryCreate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _owned_character(body.character_id, user, db)
    if not emb.key_configured():
        raise HTTPException(503, "embedding 服务未配置，请在 sysconfig 设置 embedding_api_key")
    try:
        vec = emb.embed(body.content)
    except ValueError:
        raise HTTPException(503, "embedding 服务未配置")
    except RuntimeError as e:
        raise HTTPException(502, str(e))
    mem = models.MemoryVector(
        character_id=body.character_id,
        content=body.content,
        embedding=vec,
        memory_type=body.memory_type,
        importance=body.importance,
        emotion_weight=body.emotion_weight,
    )
    db.add(mem)
    db.commit()
    db.refresh(mem)
    return mem


@router.post("/search", response_model=list[MemorySearchResult])
def search_memories(
    body: MemorySearchRequest,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _owned_character(body.character_id, user, db)
    now = datetime.now(timezone.utc)

    if emb.key_configured():
        try:
            vec = emb.embed(body.query_text)
        except RuntimeError as e:
            raise HTTPException(502, str(e))
        dist_expr = models.MemoryVector.embedding.cosine_distance(vec).label("distance")
        rows = db.execute(
            select(models.MemoryVector, dist_expr)
            .where(models.MemoryVector.character_id == body.character_id)
            .order_by(dist_expr)
            .limit(body.top_k * 3)
        ).all()
        candidates = [(r[0], r[1]) for r in rows]  # (MemoryVector, float distance)
    else:
        # ponytail: 无 embedding key → 降级为时序，可测基本链路；配 key 后自动切语义搜索
        rows = db.scalars(
            select(models.MemoryVector)
            .where(models.MemoryVector.character_id == body.character_id)
            .order_by(models.MemoryVector.created_at.desc())
            .limit(body.top_k)
        ).all()
        candidates = [(m, 0.5) for m in rows]  # 占位距离

    # 三维重排：importance × time_decay × cosine_similarity
    row = db.get(models.SysConfig, "memory_decay_days")
    decay_days = float(row.value) if row and row.value else 30.0

    scored = []
    for mem, cos_dist in candidates:
        cos_sim = max(0.0, 1.0 - cos_dist)
        days_old = max(0.0, (now - mem.created_at).total_seconds() / 86400.0)
        importance_norm = mem.importance / 5.0
        time_decay = math.exp(-days_old / decay_days)
        score = importance_norm * time_decay * cos_sim
        scored.append((score, mem, cos_sim, time_decay))

    scored.sort(key=lambda x: x[0], reverse=True)
    top = scored[: body.top_k]
    return [
        MemorySearchResult(
            id=m[1].id,
            character_id=m[1].character_id,
            content=m[1].content,
            memory_type=m[1].memory_type,
            importance=m[1].importance,
            emotion_weight=m[1].emotion_weight,
            similarity=round(m[2], 4),
            time_decay=round(m[3], 4),
            score=round(m[0], 4),
            created_at=m[1].created_at,
        )
        for m in top
    ]
