"""WebSocket 中继：按 town_id 分组转发 JSON 消息。替代 ENet P2P，消除 NAT 问题。
所有客户端连 ws://backend:8000/ws/town/{town_id}?token=JWT，后台按同 town 转发。"""
import asyncio
import json
import logging
from typing import Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query
from sqlalchemy.orm import Session

from .. import models
from ..auth import _decode_player
from ..database import SessionLocal
from datetime import datetime, timezone

logger = logging.getLogger("ws")
router = APIRouter()


def _close_town_if_playing(town_id: int) -> None:
    """最后一个 peer 离开时自动关小镇（覆盖正常退出 + 客户端进程崩溃/网络断开）。"""
    with SessionLocal() as db:
        town = db.get(models.Town, town_id)
        if town and town.status == "playing":
            town.status = "closed"
            town.host_id = None
            town.closed_at = datetime.now(timezone.utc)
            db.commit()
            logger.info(f"town={town_id} auto-closed (all peers left)")


class TownPeers:
    """单 town 内所有 WebSocket 连接。"""

    def __init__(self) -> None:
        self._peers: dict[int, WebSocket] = {}  # {peer_id: ws}
        self._next_pid: int = 1
        self._lock = asyncio.Lock()

    async def add(self, ws: WebSocket) -> int:
        async with self._lock:
            pid = self._next_pid
            self._next_pid += 1
            self._peers[pid] = ws
            return pid

    async def remove(self, pid: int) -> None:
        async with self._lock:
            self._peers.pop(pid, None)

    async def broadcast(self, sender_pid: int, data: str) -> None:
        """广播给同 town 所有其他 peer。"""
        async with self._lock:
            dead: list[int] = []
            for pid, ws in self._peers.items():
                if pid == sender_pid:
                    continue
                try:
                    await ws.send_text(data)
                except Exception:
                    dead.append(pid)
            for pid in dead:
                self._peers.pop(pid, None)

    async def send_to(self, pid: int, data: str) -> None:
        async with self._lock:
            ws = self._peers.get(pid)
            if ws:
                try:
                    await ws.send_text(data)
                except Exception:
                    self._peers.pop(pid, None)

    async def send_all(self, data: str) -> int:
        """推送给本镇所有 peer（含自己，无 sender 概念）——服务端推送用，如封禁踢人。"""
        async with self._lock:
            dead: list[int] = []
            for pid, ws in self._peers.items():
                try:
                    await ws.send_text(data)
                except Exception:
                    dead.append(pid)
            for pid in dead:
                self._peers.pop(pid, None)
            return len(self._peers)

    @property
    def peer_count(self) -> int:
        return len(self._peers)

    @property
    def peer_ids(self) -> list[int]:
        return list(self._peers.keys())


class ConnectionManager:
    """全局 WebSocket 连接管理：{town_id: TownPeers}。"""

    def __init__(self) -> None:
        self._towns: dict[int, TownPeers] = {}
        self._lock = asyncio.Lock()

    async def get_or_create(self, town_id: int) -> TownPeers:
        async with self._lock:
            if town_id not in self._towns:
                self._towns[town_id] = TownPeers()
            return self._towns[town_id]

    async def cleanup(self, town_id: int) -> None:
        async with self._lock:
            tp = self._towns.get(town_id)
            if tp and tp.peer_count == 0:
                self._towns.pop(town_id, None)

    async def kick_town(self, town_id: int, reason: str) -> int:
        """封禁时推 kick_all 给该镇所有在线 peer。客户端 _do_kick 收到后自关 WS 回大厅。
        不服务端强关——避免与消息竞态；客户端自关触发服务端 receive 断开走正常清理。返回推送数。"""
        async with self._lock:
            tp = self._towns.get(town_id)
        if not tp:
            return 0
        msg = json.dumps({"t": "kick_all", "reason": "小镇被封禁：" + reason})
        return await tp.send_all(msg)


manager = ConnectionManager()


def _auth_ws(token: str | None) -> models.User | None:
    """WebSocket 鉴权：从 query param 取 token，解码验证。返回 User 或 None。"""
    if not token:
        return None
    try:
        payload = _decode_player(token)
    except Exception:
        return None
    user_id = int(payload.get("sub", 0))
    with SessionLocal() as db:
        user = db.get(models.User, user_id)
        if not user:
            return None
        if int(payload.get("tv", -1)) != user.token_version:
            return None
        # detach from session so we can use it after session closes
        db.expunge(user)
        return user


@router.websocket("/ws/town/{town_id}")
async def ws_town(
    websocket: WebSocket,
    town_id: int,
    token: Optional[str] = Query(None),
) -> None:
    # 鉴权
    user = _auth_ws(token)
    if not user:
        await websocket.close(code=4001, reason="未登录或 token 过期")
        return

    # 验证小镇存在
    with SessionLocal() as db:
        town = db.get(models.Town, town_id)
        if not town:
            await websocket.close(code=4004, reason="小镇不存在")
            return
        if town.status == "banned":
            await websocket.close(code=4003, reason="小镇已被封禁：" + (town.ban_reason or ""))
            return
        db.expunge(town)

    await websocket.accept()

    tp = await manager.get_or_create(town_id)
    pid = await tp.add(websocket)
    is_host = (pid == 1)
    # 第一个连接自动激活小镇（creator 重进 / 其他人先进都生效；不需客户端手动 PATCH）
    if is_host:
        with SessionLocal() as db:
            town = db.get(models.Town, town_id)
            if town and town.status != "playing":
                town.status = "playing"
                town.host_id = user.id
                db.commit()
                logger.info(f"town={town_id} auto-set playing (host={user.username})")
    logger.info(f"ws town={town_id} pid={pid} user={user.username} host={is_host} total={tp.peer_count}")

    # 通知所有人（含自己）新 peer 加入
    join_msg = json.dumps({"t": "peer_join", "pid": pid, "name": user.username,
                           "char_id": getattr(user, "character_id", 0), "host": is_host})
    # 先发给自己（告知 pid）
    await tp.send_to(pid, join_msg)
    # 再发给其他人（不含自己）
    await tp.broadcast(pid, join_msg)

    try:
        while True:
            data = await websocket.receive_text()
            # 支持 to_pid 单播：{"t":"...","to_pid":N} → 只发给指定 peer
            try:
                msg = json.loads(data)
                target = msg.get("to_pid")
                if target is not None and isinstance(target, int):
                    await tp.send_to(target, data)
                else:
                    await tp.broadcast(pid, data)
            except (json.JSONDecodeError, TypeError):
                await tp.broadcast(pid, data)
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        await tp.remove(pid)
        leave_msg = json.dumps({"t": "peer_leave", "pid": pid})
        await tp.broadcast(pid, leave_msg)
        remaining = tp.peer_count
        logger.info(f"ws town={town_id} pid={pid} left, remaining={remaining}")
        if remaining == 0:
            _close_town_if_playing(town_id)
        await manager.cleanup(town_id)
