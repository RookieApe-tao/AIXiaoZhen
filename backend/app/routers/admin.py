"""管理业务接口（/admin）：登录 + 审查工作流(#10) + 管理掌控(#11 MVP)。
裁决/上下架/封禁等带状态机或审计副作用的动作走这里；纯 CRUD 留给 Directus。
audit_logs 全程只 INSERT（schema.sql:136 要求 append-only，不 UPDATE/DELETE）。"""
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import constants, models, moderation
from ..services import review
from ..auth import create_access_token, get_current_admin, require_role, verify_password
from ..database import get_db
from ..schemas import (
    AuditLogOut,
    CharacterActiveUpdate,
    CharacterOut,
    LoginRequest,
    ReviewCreate,
    ReviewDecision,
    ReviewOut,
    TokenResponse,
    UserOut,
    UserStatusUpdate,
)

router = APIRouter(prefix="/admin", tags=["admin"])


def _write_audit(db: Session, admin_id: int, action: str, target_type: str,
                 target_id: int | None, before: dict | None = None,
                 after: dict | None = None) -> None:
    db.add(models.AuditLog(
        admin_id=admin_id, action=action, target_type=target_type, target_id=target_id,
        before_json=before, after_json=after,
    ))


# ============================ 登录 ============================

@router.post("/login", response_model=TokenResponse)
def login(body: LoginRequest, db: Session = Depends(get_db)):
    admin = db.scalar(select(models.Admin).where(models.Admin.username == body.username))
    if not admin or not verify_password(body.password, admin.password_hash):
        raise HTTPException(401, "用户名或密码错误")
    token = create_access_token(admin.id, admin.role)
    return TokenResponse(access_token=token, role=admin.role, admin_id=admin.id)


# ============================ #10 审查工作流 ============================

def _bool_cfg(db: Session, key: str, default: bool) -> bool:
    row = db.get(models.SysConfig, key)
    if not row or not row.value:
        return default
    return row.value.strip().lower() in ("1", "true", "yes", "on")


def _float_cfg(db: Session, key: str, default: float) -> float:
    row = db.get(models.SysConfig, key)
    if not row or not row.value:
        return default
    try:
        return float(row.value)
    except ValueError:
        return default


def _system_admin_id(db: Session) -> int:
    """自动动作的审计操作人：取一个 super 管理员 id（兜底 1）。"""
    a = db.scalar(select(models.Admin).where(models.Admin.role == constants.AdminRole.SUPER))
    return a.id if a else 1


def _create_review(db: Session, rtype: str, target_id: int, target_type: str,
                   content: str) -> models.PromptReview:
    """审查自动层：DFA 预筛 + qwen-plus LLM 打分 → 按阈值自动通过 / 否则进人工队列。
    - score = max(dfa_score, llm_score)：DFA 命中与 LLM 任一高风险都计入。
    - LLM 可用且 review_enabled 且 score < threshold → 自动通过（写审计 auto:true）。
    - 否则 pending（人工）。永不自动拒绝——防 LLM 误杀误封。
    - LLM 不可用（key 空/调用失败）→ 一律 pending（安全回退）。"""
    hits = moderation.scan(content)
    dfa_score, dfa_tags = moderation.stub_score(hits)
    llm_score, llm_reason = review.score_text(content)  # (None, None) 表示不可用
    score = max(dfa_score, llm_score or 0.0)
    tags = list(dict.fromkeys(
        (dfa_tags or []) + ([llm_reason] if llm_reason and llm_reason != "无" else [])))

    enabled = _bool_cfg(db, "review_enabled", True)
    threshold = _float_cfg(db, "review_threshold", 0.7)
    can_auto = enabled and review.key_configured() and llm_score is not None
    status = (constants.ReviewStatus.APPROVED
              if (can_auto and score < threshold) else constants.ReviewStatus.PENDING)

    rev = models.PromptReview(
        type=rtype, target_id=target_id, target_type=target_type,
        content=content, ai_score=score, ai_tags_json=tags, status=status,
    )
    db.add(rev)
    db.flush()  # 取 id
    if target_type == constants.ReviewTargetType.CHARACTER:
        char = db.get(models.Character, target_id)
        if char:
            char.review_status = status  # 先玩后审：is_active 默认 true 不动
    if status == constants.ReviewStatus.APPROVED and can_auto:
        _write_audit(db, _system_admin_id(db), constants.AuditAction.AUTO_APPROVE_REVIEW,
                     target_type="review", target_id=rev.id,
                     after={"status": "approved", "auto": True,
                            "score": score, "threshold": threshold})
    return rev


@router.post("/reviews", response_model=ReviewOut)
def submit_review(
    body: ReviewCreate,
    admin: models.Admin = Depends(get_current_admin),  # MVP 经 Swagger/curl 测；生产由内部流程调 _create_review
    db: Session = Depends(get_db),
):
    review = _create_review(db, body.type, body.target_id, body.target_type, body.content)
    db.commit()
    db.refresh(review)
    return review


@router.get("/reviews", response_model=list[ReviewOut])
def list_reviews(
    status: str | None = None,
    type: str | None = None,
    skip: int = 0,
    limit: int = Query(50, le=200),
    db: Session = Depends(get_db),
    _admin: models.Admin = Depends(get_current_admin),
):
    q = select(models.PromptReview).order_by(models.PromptReview.created_at.desc())
    if status:
        q = q.where(models.PromptReview.status == status)
    if type:
        q = q.where(models.PromptReview.type == type)
    return db.scalars(q.offset(skip).limit(limit)).all()


@router.get("/reviews/{review_id}", response_model=ReviewOut)
def get_review(review_id: int, db: Session = Depends(get_db),
               _admin: models.Admin = Depends(get_current_admin)):
    r = db.get(models.PromptReview, review_id)
    if not r:
        raise HTTPException(404, "审查记录不存在")
    return r


def apply_review_decision(db: Session, review_id: int, decision: str,
                          admin_id: int, edited_content: str | None = None) -> models.PromptReview:
    """审查裁决核心逻辑（JWT 端点 + 后台 session 按钮共用）。
    同步角色状态 + 写审计。decision ∈ approved/rejected/edited。"""
    r = db.get(models.PromptReview, review_id)
    if not r:
        raise HTTPException(404, "审查记录不存在")
    if r.status != constants.ReviewStatus.PENDING:
        raise HTTPException(409, f"当前状态 {r.status}，仅 pending 可裁决")
    if decision == constants.ReviewStatus.EDITED and not edited_content:
        raise HTTPException(422, "edited 裁决需提供 edited_content")

    before = {"status": r.status, "content": r.content}
    action_map = {
        constants.ReviewStatus.APPROVED: constants.AuditAction.APPROVE_REVIEW,
        constants.ReviewStatus.REJECTED: constants.AuditAction.REJECT_REVIEW,
        constants.ReviewStatus.EDITED: constants.AuditAction.EDIT_REVIEW,
    }
    r.status = decision
    r.reviewer_id = admin_id
    r.reviewed_at = datetime.now(timezone.utc)
    after: dict = {"status": r.status}
    if decision == constants.ReviewStatus.EDITED:
        r.content = edited_content
        after["content"] = edited_content

    if r.target_type == constants.ReviewTargetType.CHARACTER:
        char = db.get(models.Character, r.target_id)
        if char:
            char.review_status = decision
            char.is_active = decision != constants.ReviewStatus.REJECTED  # rejected→下架阻断

    _write_audit(db, admin_id, action_map[decision],
                 target_type="review", target_id=r.id, before=before, after=after)
    db.commit()
    db.refresh(r)
    return r


@router.post("/reviews/{review_id}/decision", response_model=ReviewOut)
def decide_review(
    review_id: int,
    body: ReviewDecision,
    admin: models.Admin = Depends(get_current_admin),
    db: Session = Depends(get_db),
):
    """人工裁决：approved/rejected/edited。"""
    return apply_review_decision(db, review_id, body.decision, admin.id, body.edited_content)


# ============================ #11 管理掌控（MVP） ============================

@router.get("/audit-logs", response_model=list[AuditLogOut])
def list_audit_logs(
    admin_id: int | None = None,
    target_type: str | None = None,
    skip: int = 0,
    limit: int = Query(50, le=200),
    db: Session = Depends(get_db),
    _admin: models.Admin = Depends(get_current_admin),
):
    q = select(models.AuditLog).order_by(models.AuditLog.created_at.desc())
    if admin_id is not None:
        q = q.where(models.AuditLog.admin_id == admin_id)
    if target_type:
        q = q.where(models.AuditLog.target_type == target_type)
    return db.scalars(q.offset(skip).limit(limit)).all()


@router.patch("/characters/{char_id}/active", response_model=CharacterOut)
def toggle_character(
    char_id: int,
    body: CharacterActiveUpdate,
    admin: models.Admin = Depends(get_current_admin),
    db: Session = Depends(get_db),
):
    char = db.get(models.Character, char_id)
    if not char:
        raise HTTPException(404, "角色不存在")
    before = {"is_active": char.is_active}
    char.is_active = body.is_active
    _write_audit(db, admin.id, constants.AuditAction.TOGGLE_CHARACTER,
                 target_type="character", target_id=char.id,
                 before=before, after={"is_active": body.is_active})
    db.commit()
    db.refresh(char)
    return char


@router.patch("/users/{user_id}/status", response_model=UserOut)
def set_user_status(
    user_id: int,
    body: UserStatusUpdate,
    admin: models.Admin = Depends(get_current_admin),
    db: Session = Depends(get_db),
):
    user = db.get(models.User, user_id)
    if not user:
        raise HTTPException(404, "用户不存在")
    before = {"status": user.status}
    user.status = body.status
    user.banned_at = datetime.now(timezone.utc) if body.status == "banned" else None
    action = (constants.AuditAction.BAN_USER if body.status == "banned"
              else constants.AuditAction.UNBAN_USER)
    _write_audit(db, admin.id, action, target_type="user", target_id=user.id,
                 before=before, after={"status": body.status})
    db.commit()
    db.refresh(user)
    return user


@router.post("/moderation/reload")
def reload_sensitive_words(
    admin: models.Admin = Depends(require_role(constants.AdminRole.SUPER)),
    db: Session = Depends(get_db),
):
    """Directus 改敏感词后刷新 FastAPI 内存缓存。"""
    n = moderation.reload(db)
    return {"loaded": n}

