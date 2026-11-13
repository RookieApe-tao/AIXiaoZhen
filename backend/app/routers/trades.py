"""NPC 交易（以物换物 + 金币换物）。原子操作：双方物品/金币校验 → 转移 → 返回更新后状态。"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from .. import models
from ..auth import get_current_user
from ..database import get_db
from ..schemas import CharacterOut, TradeRequest

router = APIRouter(prefix="/trades", tags=["trades"])


def _find_item(items: list, name: str) -> dict | None:
    for it in items:
        if isinstance(it, dict) and it.get("name", "").strip() == name.strip():
            return it
    return None


def _remove_item(items: list, name: str, qty: int) -> list:
    """从物品列表移除 qty 个 name，返回新列表。调用前已确保够数。"""
    out = []
    remaining = qty
    for it in items:
        if isinstance(it, dict) and it.get("name", "").strip() == name.strip() and remaining > 0:
            cur = it.get("qty", 0)
            if cur <= remaining:
                remaining -= cur
                continue  # 整条删
            else:
                out.append({"name": name, "qty": cur - remaining})
                remaining = 0
                continue
        out.append(it)
    return out


def _add_item(items: list, name: str, qty: int) -> list:
    """加物品，同名 merge。"""
    out = list(items)
    for it in out:
        if isinstance(it, dict) and it.get("name", "").strip() == name.strip():
            it["qty"] = it.get("qty", 0) + qty
            return out
    out.append({"name": name, "qty": qty})
    return out


@router.post("", response_model=dict, status_code=200)
def execute_trade(body: TradeRequest, user=Depends(get_current_user), db: Session = Depends(get_db)):
    """原子交易：校验双方物品/金币 → 转移。返回双方更新后的 Character。"""
    if body.proposer_id == body.target_id:
        raise HTTPException(400, "不能和自己交易")

    proposer = db.get(models.Character, body.proposer_id)
    target = db.get(models.Character, body.target_id)
    if not proposer or not target:
        raise HTTPException(404, "角色不存在")
    if proposer.deleted_at or target.deleted_at:
        raise HTTPException(404, "角色已删除")

    p_items: list = list(proposer.items_json or [])
    t_items: list = list(target.items_json or [])

    # 校验 proposer 有足够物品和金币
    for oi in body.offer_items:
        found = _find_item(p_items, oi.name)
        if not found or found.get("qty", 0) < oi.qty:
            raise HTTPException(400, f"你「{oi.name}」不够（需 {oi.qty}，有 {found.get('qty', 0) if found else 0}）")
    if body.offer_money > proposer.money:
        raise HTTPException(400, f"你的金币不够（需 {body.offer_money}，有 {proposer.money}）")

    # 校验 target 有足够物品和金币
    for ri in body.request_items:
        found = _find_item(t_items, ri.name)
        if not found or found.get("qty", 0) < ri.qty:
            raise HTTPException(400, f"对方「{ri.name}」不够（需 {ri.qty}，有 {found.get('qty', 0) if found else 0}）")
    if body.request_money > target.money:
        raise HTTPException(400, f"对方金币不够（需 {body.request_money}，有 {target.money}）")

    # 执行转移
    for oi in body.offer_items:
        p_items = _remove_item(p_items, oi.name, oi.qty)
        t_items = _add_item(t_items, oi.name, oi.qty)
    for ri in body.request_items:
        t_items = _remove_item(t_items, ri.name, ri.qty)
        p_items = _add_item(p_items, ri.name, ri.qty)

    if body.offer_money > 0:
        proposer.money -= body.offer_money
        target.money += body.offer_money
    if body.request_money > 0:
        target.money -= body.request_money
        proposer.money += body.request_money

    proposer.items_json = p_items
    target.items_json = t_items
    db.commit()
    db.refresh(proposer)
    db.refresh(target)

    return {"proposer": CharacterOut.model_validate(proposer), "target": CharacterOut.model_validate(target)}
