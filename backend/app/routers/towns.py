"""小镇 CRUD + 游戏会话生命周期（合并原 rooms 概念：一个 town 就是一个游戏房间）。"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import TownCreate, TownUpdate, TownOut, TownDetail

router = APIRouter(prefix="/towns", tags=["towns"])


@router.post("", response_model=TownOut, status_code=201)
def create_town(
    body: TownCreate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """创建小镇。WebSocket 中继模式下不需要端口分配。
    可选 map_preset_id：选择预设地图自动复制到 map_data + rooms_json。"""
    town = models.Town(
        creator_id=user.id,
        host_id=user.id,
        name=body.name,
        config_json=body.config_json or {},
    )
    db.add(town)
    db.flush()  # 拿 town.id

    # 如果选了预设地图，复制到 map_data + rooms_json
    if body.map_preset_id:
        preset = db.get(models.MapData, body.map_preset_id)
        if preset and preset.town_id is None:
            db.add(models.MapData(
                town_id=town.id,
                name=preset.name,
                chunk_json=dict(preset.chunk_json or {}),
                prefabs_json=list(preset.prefabs_json or []),
            ))
            rooms = (preset.chunk_json or {}).get("rooms")
            if isinstance(rooms, list) and rooms:
                town.rooms_json = rooms

    db.commit()
    db.refresh(town)
    return town


@router.get("", response_model=list[TownOut])
def list_towns(
    status: str | None = Query(None, description="覆盖默认过滤：我创建的或 playing 中的小镇"),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from sqlalchemy import or_
    q = db.query(models.Town)
    if status:
        q = q.filter(models.Town.status == status)
    else:
        # 只展示：我创建的（任意状态）+ 别人创建且 playing 中的
        q = q.filter(or_(
            models.Town.creator_id == user.id,
            models.Town.status == "playing",
        ))
    return q.order_by(models.Town.created_at.desc()).all()


@router.get("/{town_id}", response_model=TownDetail)
def get_town(
    town_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """小镇详情。"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    return town


@router.patch("/{town_id}", response_model=TownOut)
def update_town(
    town_id: int,
    body: TownUpdate | None = None,
    status: str | None = Query(None, pattern="^(playing|closed|banned)$"),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """更新小镇配置（body）或状态（?status=）。游戏会话：host 进入时设 playing，离开时设 closed。"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")

    # 状态变更（游戏会话生命周期）
    if status:
        if status == "playing":
            town.host_id = user.id
            town.status = "playing"
        elif status == "closed":
            if town.host_id != user.id:
                raise HTTPException(403, "仅房主可关闭")
            town.status = "closed"
            town.host_id = None
            town.closed_at = datetime.now(timezone.utc)
        elif status == "banned":
            raise HTTPException(403, "封禁请用 /manage 路由")
        db.commit()
        db.refresh(town)
        return town

    # 配置更新（创建者或当前房主：waiting 态 creator 编辑，playing 态 host 导演）
    if body is None:
        raise HTTPException(400, "缺少 body 或 status 参数")
    if user.id not in (town.creator_id, town.host_id or 0):
        raise HTTPException(403, "仅创建者或房主可编辑")
    if body.name is not None:
        town.name = body.name
    if body.config_json is not None:
        # 浅合并：房主只传世界观字段不会抹掉 description 等既有 key
        town.config_json = {**(town.config_json or {}), **(body.config_json or {})}
    if body.weather is not None:
        town.weather = body.weather
    if body.time_scale is not None:
        town.time_scale = body.time_scale
    town.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(town)
    return town


@router.get("/{town_id}/rooms")
def get_town_rooms(
    town_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """返回小镇房间定义列表 [{name, cx, cy, w, h}, ...]。
    NPC 大脑启动时拉取用于空间感知；言出法随改地图后更新 rooms_json。"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    return town.rooms_json or []


@router.delete("/{town_id}", status_code=204)
def delete_town(
    town_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """软删除小镇（仅创建者）。"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    if town.creator_id != user.id:
        raise HTTPException(403, "仅创建者可操作")
    town.status = "destroyed"
    town.deleted_at = datetime.now(timezone.utc)
    db.commit()
