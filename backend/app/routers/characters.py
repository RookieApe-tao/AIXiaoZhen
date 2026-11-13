"""角色 CRUD（玩家端）。所有权：character.owner_id == current_user.id。"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from .. import crypto, models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import ByokSettings, ByokSettingsUpdate, CharacterCreate, CharacterOut, CharacterStatusUpdate, CharacterUpdate, CoreMemoriesAppend
from ..routers.admin import _create_review

router = APIRouter(prefix="/characters", tags=["characters"])


def _owned(char_id: int, user: models.User, db: Session) -> models.Character:
    char = db.get(models.Character, char_id)
    if not char or char.deleted_at is not None:
        raise HTTPException(404, "角色不存在")
    if char.owner_id != user.id:
        raise HTTPException(403, "无权操作该角色")
    return char


@router.post("", response_model=CharacterOut, status_code=201)
def create_character(
    body: CharacterCreate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = models.Character(
        owner_id=user.id,
        name=body.name,
        town_id=body.town_id,
        background=body.background,
        personality_json=body.personality_json or {},
    )
    db.add(char)
    db.flush()  # 取 id
    # 自动提交提示词审查（admin 后台可一键通过/拒绝）
    review_content = _build_review_content(body.name, body.background, body.personality_json)
    _create_review(db, "system_prompt", char.id, "character", review_content)
    db.commit()
    db.refresh(char)
    return char


def _build_review_content(name: str, background: str | None, pj: dict | None) -> str:
    """组合角色信息为审查文本。"""
    parts = [f"角色名：{name}"]
    if pj:
        for key, label in [("position","职位"),("personality","性格"),("speaking_style","说话风格"),
                           ("work_duties","工作职责"),("work_habits","工作习惯"),("notes","补充设定")]:
            v = (pj.get(key) or "").strip()
            if v:
                parts.append(f"{label}：{v}")
    if background and not pj:
        parts.append(f"背景：{background}")
    return "\n".join(parts)


@router.get("", response_model=list[CharacterOut])
def list_characters(
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return db.query(models.Character).filter(
        models.Character.owner_id == user.id,
        models.Character.deleted_at.is_(None),
    ).order_by(models.Character.created_at.desc()).all()


@router.get("/{char_id}", response_model=CharacterOut)
def get_character(
    char_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _owned(char_id, user, db)


@router.patch("/{char_id}", response_model=CharacterOut)
def update_character(
    char_id: int,
    body: CharacterUpdate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = _owned(char_id, user, db)
    if body.name is not None:
        char.name = body.name
    if body.background is not None:
        char.background = body.background
    if body.personality_json is not None:
        char.personality_json = body.personality_json
    if body.relations_json is not None:
        char.relations_json = body.relations_json
    db.commit()
    db.refresh(char)
    return char


# ponytail: 软上限防 prompt 爆炸；FIFO 截断保留最新。超规模再迁独立摘要/分层记忆
CORE_MEMORIES_LIMIT = 30


@router.post("/{char_id}/core_memories", response_model=CharacterOut)
def append_core_memories(
    char_id: int,
    body: CoreMemoriesAppend,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """追加核心事实到 core_memories_json。服务端去重（完全相同/包含关系跳过）+ FIFO 上限。"""
    char = _owned(char_id, user, db)
    existing: list = list(char.core_memories_json or [])
    for fact in body.facts:
        f = (fact or "").strip()
        if not f:
            continue
        fl = f.lower()
        # 去重：与已有任意一条重复或互为包含 → 跳过
        if any(fl == str(e).lower() or fl in str(e).lower() or str(e).lower() in fl for e in existing):
            continue
        existing.append(f)
    if len(existing) > CORE_MEMORIES_LIMIT:
        existing = existing[-CORE_MEMORIES_LIMIT:]
    char.core_memories_json = existing
    db.commit()
    db.refresh(char)
    return char


@router.put("/{char_id}/core_memories", response_model=CharacterOut)
def replace_core_memories(
    char_id: int,
    body: CoreMemoriesAppend,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """整体替换 core_memories_json（删除/编辑用）：客户端传完整新列表。仅 trim + FIFO 上限，不去重。"""
    char = _owned(char_id, user, db)
    facts = [(f or "").strip() for f in body.facts]
    facts = [f for f in facts if f]
    if len(facts) > CORE_MEMORIES_LIMIT:
        facts = facts[-CORE_MEMORIES_LIMIT:]
    char.core_memories_json = facts
    db.commit()
    db.refresh(char)
    return char


@router.delete("/{char_id}", status_code=204)
def delete_character(
    char_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = _owned(char_id, user, db)
    char.deleted_at = datetime.now(timezone.utc)
    db.commit()
    return None


@router.patch("/{char_id}/status", response_model=CharacterOut)
def update_character_status(
    char_id: int,
    body: CharacterStatusUpdate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """更新角色状态数值（心情/金钱/健康）。支持 absolute 设值 + delta 相对变化。
    NPC 大脑 JSON status_change 字段映射到此端点。"""
    char = db.get(models.Character, char_id)
    if not char:
        raise HTTPException(404, "角色不存在")
    # owner 守卫：上帝改状态走本端 token（其 own 的角色），NPC brain 走各自 owner
    if char.owner_id != user.id:
        raise HTTPException(403, "无权操作该角色")
    # 优先 absolute，其次 delta
    if body.mood is not None:
        char.mood = max(0.0, min(1.0, body.mood))
    elif body.mood_delta is not None:
        char.mood = max(0.0, min(1.0, char.mood + body.mood_delta))
    if body.money is not None:
        char.money = max(0, body.money)
    elif body.money_delta is not None:
        char.money = max(0, char.money + body.money_delta)
    if body.health is not None:
        char.health = max(0.0, min(1.0, body.health))
    elif body.health_delta is not None:
        char.health = max(0.0, min(1.0, char.health + body.health_delta))
    char.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(char)
    return char


# 每角色 AI 设置（BYOK）：None 字段=回退账号级 users.byok_*。语义同 /auth/me/byok。
@router.get("/{char_id}/byok", response_model=ByokSettings)
def get_character_byok(
    char_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = _owned(char_id, user, db)
    return ByokSettings(
        api_type=char.byok_api_type,
        model=char.byok_model,
        api_key=crypto.decrypt(char.byok_api_key_enc),
    )


@router.put("/{char_id}/byok", response_model=ByokSettings)
def update_character_byok(
    char_id: int,
    body: ByokSettingsUpdate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    char = _owned(char_id, user, db)
    if body.api_type is not None:
        char.byok_api_type = body.api_type
    if body.model is not None:
        char.byok_model = body.model
    if body.api_key:  # 非空才更新；空/None 保留原值（前台"留空不改"语义）
        char.byok_api_key_enc = crypto.encrypt(body.api_key)
    char.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(char)
    return ByokSettings(
        api_type=char.byok_api_type,
        model=char.byok_model,
        api_key=crypto.decrypt(char.byok_api_key_enc),
    )
