"""地图数据 CRUD：预设管理 + 小镇绑定（1:1）+ NPC 改地图（言出法随 §3.4/5.3）。"""
import asyncio
import copy
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import MapActionsRequest, MapDataCreate, MapDataOut, MapPresetItem

logger = logging.getLogger("maps")
router = APIRouter(prefix="/maps", tags=["maps"])

# 地图修改允许的 action 类型（§5.3 JSON Schema）
_ALLOWED_ACTIONS = {
    "place_tile", "remove_tile", "place_prefab", "remove_prefab",
    "add_room", "remove_room", "update_room",
}


def _room_count(chunk_json: dict | None) -> int:
    rooms = (chunk_json or {}).get("rooms")
    return len(rooms) if isinstance(rooms, list) else 0


@router.get("/presets", response_model=list[MapPresetItem])
def list_presets(
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """列出所有预设地图（town_id=NULL）。"""
    rows = db.query(models.MapData).filter(
        models.MapData.town_id.is_(None)
    ).order_by(models.MapData.updated_at.desc()).all()
    return [
        MapPresetItem(
            id=r.id, name=r.name, room_count=_room_count(r.chunk_json),
            updated_at=r.updated_at,
        )
        for r in rows
    ]


@router.get("/{map_id}", response_model=MapDataOut)
def get_map(
    map_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    m = db.get(models.MapData, map_id)
    if not m:
        raise HTTPException(404, "地图不存在")
    return m


@router.get("/town/{town_id}", response_model=MapDataOut)
def get_town_map(
    town_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """获取小镇的专属地图（1:1，不存在则 404）。"""
    m = db.query(models.MapData).filter(
        models.MapData.town_id == town_id
    ).first()
    if not m:
        raise HTTPException(404, "该小镇暂无地图")
    return m


@router.post("/{map_id}/apply/{town_id}", response_model=MapDataOut, status_code=201)
def apply_preset_to_town(
    map_id: int,
    town_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """将预设地图复制到小镇（新建 map_data 记录，town_id 绑定目标小镇）。
    同时将预设 rooms 列表写入 towns.rooms_json（NPC 空间感知）。"""
    preset = db.get(models.MapData, map_id)
    if not preset:
        raise HTTPException(404, "预设地图不存在")
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")

    # 如果小镇已有地图，先删旧（1:1）
    db.query(models.MapData).filter(models.MapData.town_id == town_id).delete()

    new_map = models.MapData(
        town_id=town_id,
        name=preset.name,
        chunk_json=dict(preset.chunk_json or {}),
        prefabs_json=list(preset.prefabs_json or []),
    )
    db.add(new_map)

    # 同步 rooms_json 到小镇（NPC 空间感知用）
    rooms = (preset.chunk_json or {}).get("rooms")
    if isinstance(rooms, list) and rooms:
        town.rooms_json = rooms
    else:
        town.rooms_json = []
    town.updated_at = datetime.now(timezone.utc)

    db.commit()
    db.refresh(new_map)
    return new_map


def _apply_actions(map_row: models.MapData, actions: list) -> list[dict]:
    """将 actions 应用到 map_data 内存对象（不提交 DB）。返回实际生效的 action 列表（用于广播）。
    校验失败/越界的 action 跳过并记日志，不阻断其余。"""
    # 深拷贝：place_tile 原地 append chunk["tiles"]，若浅拷贝则改动共享到旧 chunk_json，
    # SQLAlchemy 赋值时认为「没变」不落库（JSONB 无 MutableDict 的经典坑）。
    chunk = copy.deepcopy(map_row.chunk_json or {})
    prefabs = list(map_row.prefabs_json or [])
    rooms: list = list(chunk.get("rooms") or [])
    applied: list[dict] = []

    for a in actions:
        act = a.action if isinstance(a, dict) else getattr(a, "action", "")
        if act not in _ALLOWED_ACTIONS:
            logger.warning(f"maps: unknown action={act}, skip")
            continue

        # pos 取值（兼容 Pydantic model 和 plain dict）
        pos = a.get("pos") if isinstance(a, dict) else getattr(a, "pos", None)
        if pos is None:
            pos = a["pos"] if isinstance(a, dict) else None

        try:
            if act == "place_tile":
                tile_type = a.get("tile_type") if isinstance(a, dict) else getattr(a, "tile_type", "")
                tiles = chunk.setdefault("tiles", [])
                tiles.append({"pos": pos, "type": tile_type})
                applied.append({"action": act, "pos": pos, "tile_type": tile_type})

            elif act == "remove_tile":
                tile_type = a.get("tile_type") if isinstance(a, dict) else getattr(a, "tile_type", "")
                tiles = chunk.get("tiles", [])
                chunk["tiles"] = [t for t in tiles if not (t.get("pos") == pos and (not tile_type or t.get("type") == tile_type))]
                applied.append({"action": act, "pos": pos, "tile_type": tile_type})

            elif act == "place_prefab":
                prefab_name = a.get("prefab_name") if isinstance(a, dict) else getattr(a, "prefab_name", "")
                prefabs.append({"name": prefab_name, "pos": pos})
                applied.append({"action": act, "pos": pos, "prefab_name": prefab_name})

            elif act == "remove_prefab":
                prefab_name = a.get("prefab_name") if isinstance(a, dict) else getattr(a, "prefab_name", "")
                # 删最近一个同名的（ponytail: O(n) scan，预制件数量不大）。pos 可选：
                # NPC 只知物品名不知坐标，不带 pos 按名删最近一个；带 pos 则精确删。
                for i in range(len(prefabs) - 1, -1, -1):
                    if prefabs[i].get("name") == prefab_name and (pos is None or prefabs[i].get("pos") == pos):
                        prefabs.pop(i)
                        applied.append({"action": act, "prefab_name": prefab_name})
                        break

            elif act == "add_room":
                room = a.get("room") if isinstance(a, dict) else getattr(a, "room", None)
                if isinstance(room, dict) and room.get("name"):
                    rooms.append(dict(room))
                    applied.append({"action": act, "room": dict(room)})

            elif act == "remove_room":
                room_name = a.get("room_name") if isinstance(a, dict) else getattr(a, "room_name", "")
                rooms = [r for r in rooms if r.get("name") != room_name]
                applied.append({"action": act, "room_name": room_name})

            elif act == "update_room":
                room = a.get("room") if isinstance(a, dict) else getattr(a, "room", None)
                if isinstance(room, dict) and room.get("name"):
                    for i, r in enumerate(rooms):
                        if r.get("name") == room["name"]:
                            rooms[i] = dict(room)
                            applied.append({"action": act, "room": dict(room)})
                            break

        except Exception:
            logger.exception(f"maps: action failed: {a}")

    chunk["rooms"] = rooms
    map_row.chunk_json = chunk
    map_row.prefabs_json = prefabs
    map_row.updated_at = datetime.now(timezone.utc)
    return applied


@router.post("/town/{town_id}/actions")
async def submit_map_actions(
    town_id: int,
    body: MapActionsRequest,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """NPC/玩家提交地图修改（言出法随核心）。
    1. 校验 action 类型合法性
    2. 持久化到 map_data（无已有地图则新建空地图）
    3. 同步 rooms 到 towns.rooms_json
    4. WebSocket 广播给同镇所有在线玩家"""
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    # 被禁的小镇拒绝修改
    if town.status == "banned":
        raise HTTPException(403, "小镇已被封禁，无法修改")
    # owner 守卫：以某角色名义改地图时，该角色须属于请求用户（NPC brain 走各自 owner 的 BYOK token）
    if body.character_id:
        actor = db.get(models.Character, body.character_id)
        if actor and actor.owner_id != user.id:
            raise HTTPException(403, "无权以该角色修改地图")

    # 取或创建小镇地图（1:1）
    map_row = db.query(models.MapData).filter(models.MapData.town_id == town_id).first()
    if not map_row:
        map_row = models.MapData(town_id=town_id, name=town.name)
        db.add(map_row)
        db.flush()

    # 应用所有 actions
    applied = _apply_actions(map_row, body.actions)

    # 同步 rooms → towns.rooms_json（NPC 空间感知）
    rooms = (map_row.chunk_json or {}).get("rooms")
    if isinstance(rooms, list):
        town.rooms_json = rooms
    town.updated_at = datetime.now(timezone.utc)

    db.commit()
    db.refresh(map_row)

    # WebSocket 广播给同镇所有在线玩家
    from .ws import manager as ws_manager
    msg = json.dumps({
        "t": "map_update",
        "town_id": town_id,
        "actions": applied,
        "chunk_json": map_row.chunk_json,
        "prefabs_json": map_row.prefabs_json,
        "character_id": body.character_id,
        "sender_id": user.id,
    }, ensure_ascii=False)

    tp = await ws_manager.get_or_create(town_id)
    sent = await tp.send_all(msg)
    logger.info(f"maps: town={town_id} applied={len(applied)} actions, broadcast to {sent} peers")

    return {
        "applied": len(applied),
        "total": len(body.actions),
        "broadcast_to": sent,
        "chunk_json": map_row.chunk_json,
        "prefabs_json": map_row.prefabs_json,
    }
