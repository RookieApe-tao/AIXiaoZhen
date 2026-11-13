"""AI 任务系统（§3.5）：NPC 自主创建/派发/完成。Brain JSON task 字段 → HTTP → DB。"""
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import TaskCreate, TaskOut, TaskUpdate

router = APIRouter(prefix="/tasks", tags=["tasks"])
logger = logging.getLogger("tasks")


def _enrich_task(task: models.Task) -> TaskOut:
    out = TaskOut.model_validate(task)
    out.creator_name = task.creator.name if task.creator else None
    out.assignee_name = task.assignee.name if task.assignee else None
    return out


async def _broadcast_task_update(town_id: int, op: str, task_id: int) -> None:
    """任务变更 WS 广播：owner 端收到后触发 fetch_tasks 重拉（新任务即时进 NPC 队列，不用等跨天刷新）。"""
    from .ws import manager as ws_manager
    msg = json.dumps({"t": "task_update", "town_id": town_id, "op": op, "task_id": task_id}, ensure_ascii=False)
    tp = await ws_manager.get_or_create(town_id)
    sent = await tp.send_all(msg)
    logger.info(f"tasks: town={town_id} op={op} task={task_id} broadcast to {sent} peers")


@router.get("", response_model=list[TaskOut])
def list_tasks(
    town_id: int = Query(..., description="小镇 ID"),
    status: str | None = Query(None, description="过滤状态：pending/in_progress/done"),
    assignee_id: int | None = None,
    limit: int = Query(50, le=200),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    q = db.query(models.Task).filter(models.Task.town_id == town_id)
    if status:
        q = q.filter(models.Task.status == status)
    if assignee_id is not None:
        q = q.filter(models.Task.assignee_id == assignee_id)
    return [_enrich_task(t) for t in q.order_by(models.Task.priority.desc(), models.Task.created_at.desc()).limit(limit).all()]


@router.post("", response_model=TaskOut, status_code=201)
async def create_task(
    body: TaskCreate,
    town_id: int = Query(..., description="小镇 ID"),
    creator_id: int = Query(..., description="创建者角色 ID（NPC brain 传）"),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    town = db.get(models.Town, town_id)
    if not town:
        raise HTTPException(404, "小镇不存在")
    creator = db.get(models.Character, creator_id)
    if not creator:
        raise HTTPException(404, "角色不存在")
    # owner 守卫：只能以自己拥有的角色名义建任务（NPC brain 传 creator_id）
    if creator.owner_id != user.id:
        raise HTTPException(403, "无权以该角色创建任务")
    # 校验 priority 范围
    priority = max(1, min(5, body.priority))

    task = models.Task(
        town_id=town_id, creator_id=creator_id,
        assignee_id=body.assignee_id,
        title=body.title, description=body.description,
        priority=priority, reward_money=body.reward_money,
    )
    db.add(task)
    db.commit()
    db.refresh(task)
    await _broadcast_task_update(town_id, "create", task.id)
    return _enrich_task(task)


@router.get("/{task_id}", response_model=TaskOut)
def get_task(
    task_id: int,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    task = db.get(models.Task, task_id)
    if not task:
        raise HTTPException(404, "任务不存在")
    return _enrich_task(task)


@router.patch("/{task_id}", response_model=TaskOut)
async def update_task(
    task_id: int,
    body: TaskUpdate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    task = db.get(models.Task, task_id)
    if not task:
        raise HTTPException(404, "任务不存在")
    # owner 守卫：只能动自己角色的任务（assignee 是自己 NPC 时才可改）；未指派的允许任意镇内玩家
    if task.assignee_id:
        assignee = db.get(models.Character, task.assignee_id)
        if assignee and assignee.owner_id != user.id:
            raise HTTPException(403, "无权操作该任务")
    if body.status is not None:
        task.status = body.status
        if body.status == "done":
            task.completed_at = datetime.now(timezone.utc)
            # 完成奖励：给 assignee 加钱
            if task.assignee_id and task.reward_money:
                assignee = db.get(models.Character, task.assignee_id)
                if assignee:
                    assignee.money += task.reward_money
        elif body.status == "cancelled":
            task.completed_at = datetime.now(timezone.utc)
    if body.assignee_id is not None:
        task.assignee_id = body.assignee_id
    if body.title is not None:
        task.title = body.title
    if body.description is not None:
        task.description = body.description
    if body.priority is not None:
        task.priority = max(1, min(5, body.priority))
    db.commit()
    db.refresh(task)
    if body.status is not None:
        await _broadcast_task_update(task.town_id, "update", task.id)
    return _enrich_task(task)
