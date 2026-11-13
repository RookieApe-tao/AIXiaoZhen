"""sqladmin 管理后台（替代 Directus）：访问 /adminpanel。
- 登录鉴权复用 admins 表 + bcrypt（session），不引入第二套账号
- 13 张业务表自动 CRUD：字段中文(column_labels)、枚举字段下拉(form_choices)+中文显示(column_formatters)、
  外键列显示关联名(relationship)、批量删除(列表勾选)+对话日志清空(@action)
- 敏感列（密码哈希/BYOK 密钥）排除、向量列排除、审计日志只读
- 角色隔离：_super_only 视图（管理员/系统配置/敏感词/审计）仅 super 可见；reviewer 只能审查+封禁运营
- /manage/* session POST 路由（封禁/裁决/清空）加 _same_origin CSRF 校验
- ponytail: admin 列表 relationship 取名字是 N+1，分页小（~20 行）可接受，规模化换 joinedload
"""
import os
from datetime import datetime, timezone
from urllib.parse import urlparse

from markupsafe import Markup
from sqladmin import Admin, ModelView, action
from sqladmin.authentication import AuthenticationBackend
from sqladmin.i18n import I18nConfig
from sqlalchemy import select
from starlette.requests import Request
from wtforms import SelectField
from starlette.responses import HTMLResponse, RedirectResponse
from starlette.exceptions import HTTPException

from . import models
from .auth import verify_password
from .constants import (
    AdminRole, UserStatus, TownStatus, TaskStatus,
    ROLE_CHOICES, USER_STATUS_CHOICES, ADMIN_ROLE_CHOICES,
    TOWN_STATUS_CHOICES, REVIEW_STATUS_CHOICES, REVIEW_TYPE_CHOICES,
    REVIEW_TARGET_CHOICES, CONFIG_VALUE_TYPE_CHOICES,
    TASK_STATUS_CHOICES,
    ROLE_LABELS, USER_STATUS_LABELS, ADMIN_ROLE_LABELS,
    TOWN_STATUS_LABELS, REVIEW_STATUS_LABELS, REVIEW_TYPE_LABELS,
    REVIEW_TARGET_LABELS, CONFIG_VALUE_TYPE_LABELS, AUDIT_ACTION_LABELS,
    MEMORY_TYPE_CHOICES, AUDIT_TARGET_LABELS,
)
from .database import SessionLocal, engine
from .routers.ws import manager as ws_manager

# ponytail: dev 默认密钥；生产由 env 注入强随机值（与 JWT 密钥分开）
_SESSION_SECRET = os.getenv("AIXIAOZHEN_SESSION_SECRET", "aixiaozhen-dev-session-secret-CHANGE-ME")


class AdminAuth(AuthenticationBackend):
    """复用 admins 表登录，session 存 {admin_id, role}。"""

    async def login(self, request: Request) -> bool:
        form = await request.form()
        username, password = form.get("username"), form.get("password")
        if not username or not password:
            return False
        with SessionLocal() as db:
            admin = db.scalar(select(models.Admin).where(models.Admin.username == username))
            if not admin or not verify_password(password, admin.password_hash):
                return False
            request.session.update({"admin_id": admin.id, "role": admin.role})
        return True

    async def logout(self, request: Request) -> bool:
        request.session.clear()
        return True

    async def authenticate(self, request: Request) -> bool:
        return request.session.get("admin_id") is not None


# ============================ 角色隔离 + 显示助手 ============================

class _RoleGatedView(ModelView):
    """所有视图走角色 gate：必须登录；_super_only 视图仅 super 可见。
    ponytail: 不上完整 RBAC（角色-权限 m:n），当前规模二值角色够用。"""
    _super_only = False

    def is_accessible(self, request: Request) -> bool:
        if not request.session.get("admin_id"):
            return False
        if self._super_only and request.session.get("role") != AdminRole.SUPER:
            return False
        return True


def _rel_fmt(attr):
    """外键列显示关联对象名（读 relationship，懒加载）。无值显示 -。"""
    def _fmt(model, _attribute):
        obj = getattr(model, attr, None)
        return str(obj) if obj is not None else "-"
    return _fmt


def _enum_fmt(attr, labels):
    """枚举列显示中文：value → labels[value]，未命中回退原值。"""
    def _fmt(model, _attribute):
        val = getattr(model, attr, None)
        return labels.get(val, val if val is not None else "-")
    return _fmt


def _select(*pairs):
    """sqladmin 0.31 无 form_choices；用 form_overrides(SelectField)+form_args(choices) 实现下拉。
    pairs: (col_name, choices) 序列；返回 (form_overrides, form_args) 供类体解包赋值。"""
    return ({c: SelectField for c, _ in pairs}, {c: {"choices": ch} for c, ch in pairs})


def _require_same_origin(request: Request) -> None:
    """CSRF：/manage/* 的 session POST，若 Origin/Referer 存在且 host 与服务端不符则拒。
    浏览器表单 POST 会带 Origin；无 CORS 授信下跨站无法伪造。两头都没有则放行（内部工具）。"""
    if request.method not in ("POST", "PUT", "PATCH", "DELETE"):
        return
    target = request.headers.get("origin") or request.headers.get("referer")
    if not target:
        return  # ponytail: 内部管理工具，无 Origin 头放行；生产可改强制
    host = (urlparse(target).hostname or "").lower()
    srv = (request.headers.get("host") or "").split(":")[0].lower()
    if host and srv and host != srv:
        raise HTTPException(status_code=403, detail="跨站请求被拒绝（CSRF 校验失败）")


# ============================ 游戏核心 ============================

def _user_status_formatter(model, attribute):
    """用户状态：正常显示「封禁」按钮；封禁显示「解禁」按钮（写 audit + 改 status/banned_at）。"""
    if model.status == UserStatus.BANNED:
        return Markup(
            f'<span class="badge bg-danger">封禁</span>'
            f'<a class="btn btn-success btn-sm ms-2" href="/manage/user/{model.id}/ban?unban=1">解禁</a>'
        )
    return Markup(
        f'<span class="badge bg-success">正常</span>'
        f'<a class="btn btn-danger btn-sm ms-2" href="/manage/user/{model.id}/ban">封禁</a>'
    )


class UserAdmin(_RoleGatedView, model=models.User):
    name = name_plural = "用户"
    icon = "fa-solid fa-users"
    category = "游戏"
    column_list = [models.User.id, models.User.username, models.User.email,
                   models.User.role, models.User.status, models.User.created_at]
    column_searchable_list = [models.User.username, models.User.email]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.User.id: "ID", models.User.username: "用户名", models.User.email: "邮箱",
        models.User.password_hash: "密码哈希", models.User.role: "角色", models.User.status: "状态",
        models.User.byok_api_type: "BYOK 提供商", models.User.byok_model: "BYOK 模型",
        models.User.byok_api_key_enc: "BYOK 密钥(加密)", models.User.settings_json: "设置",
        models.User.banned_at: "封禁时间", models.User.deleted_at: "删除时间",
        models.User.created_at: "创建时间", models.User.updated_at: "更新时间",
    }
    form_excluded_columns = [models.User.password_hash, models.User.byok_api_key_enc]
    column_details_exclude_list = [models.User.password_hash, models.User.byok_api_key_enc]
    form_overrides, form_args = _select(("role", ROLE_CHOICES), ("status", USER_STATUS_CHOICES))
    column_formatters = {"role": _enum_fmt("role", ROLE_LABELS), "status": _user_status_formatter}


def _town_status_formatter(model, attribute):
    """小镇状态：已封禁显示红色 badge，否则旁边加「封禁」按钮（走 /manage/town/{id}/ban 写审计）。"""
    if model.status == TownStatus.BANNED:
        return Markup(f'<span class="badge bg-danger">已封禁</span>')
    return Markup(
        f'{TOWN_STATUS_LABELS.get(model.status, model.status)} '
        f'<a class="btn btn-danger btn-sm ms-2" href="/manage/town/{model.id}/ban">封禁</a>'
    )


class TownAdmin(_RoleGatedView, model=models.Town):
    name = name_plural = "小镇"
    icon = "fa-solid fa-map-location-dot"
    category = "游戏"
    column_list = [models.Town.id, models.Town.name, models.Town.creator_id,
                   models.Town.host_id, models.Town.status,
                   models.Town.weather, models.Town.created_at]
    column_searchable_list = [models.Town.name]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.Town.id: "ID", models.Town.creator_id: "创建者", models.Town.host_id: "房主",
        models.Town.name: "名称", models.Town.config_json: "配置",
        models.Town.weather: "天气", models.Town.time_scale: "时间流速", models.Town.status: "状态",
        models.Town.ban_reason: "封禁原因", models.Town.closed_at: "关闭时间",
        models.Town.deleted_at: "删除时间", models.Town.created_at: "创建时间",
        models.Town.updated_at: "更新时间",
    }
    form_overrides, form_args = _select(("status", TOWN_STATUS_CHOICES))
    form_excluded_columns = [models.Town.creator_id, models.Town.host_id]  # 关系由后台逻辑管，不在表单编辑
    column_formatters = {
        "creator_id": _rel_fmt("creator"), "host_id": _rel_fmt("host"),
        "status": _town_status_formatter,
    }


class CharacterAdmin(_RoleGatedView, model=models.Character):
    name = name_plural = "角色"
    icon = "fa-solid fa-user-astronaut"
    category = "游戏"
    column_list = [models.Character.id, models.Character.name, models.Character.owner_id,
                   models.Character.review_status, models.Character.is_active,
                   models.Character.created_at]
    column_searchable_list = [models.Character.name]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.Character.id: "ID", models.Character.owner_id: "归属用户",
        models.Character.town_id: "所在小镇", models.Character.name: "名称",
        models.Character.appearance_json: "外观", models.Character.personality_json: "性格",
        models.Character.background: "背景故事", models.Character.system_prompt: "系统提示词",
        models.Character.core_memories_json: "核心记忆",
        models.Character.review_status: "审查状态", models.Character.is_active: "是否上架",
        models.Character.deleted_at: "删除时间",
        models.Character.created_at: "创建时间", models.Character.updated_at: "更新时间",
    }
    form_overrides, form_args = _select(("review_status", REVIEW_STATUS_CHOICES))
    column_formatters = {
        "owner_id": _rel_fmt("owner"), "town_id": _rel_fmt("town"),
        "review_status": _enum_fmt("review_status", REVIEW_STATUS_LABELS),
    }


class MapDataAdmin(_RoleGatedView, model=models.MapData):
    name = name_plural = "地图数据"
    icon = "fa-solid fa-map"
    category = "游戏"
    column_list = [models.MapData.id, models.MapData.name, models.MapData.town_id,
                   models.MapData.updated_at]
    column_searchable_list = [models.MapData.name]
    column_default_sort = ("updated_at", True)
    column_labels = {
        models.MapData.id: "ID", models.MapData.name: "名称",
        models.MapData.town_id: "绑定小镇（空=预设）",
        models.MapData.chunk_json: "区块数据(rooms/tilemap)",
        models.MapData.prefabs_json: "预制件",
        models.MapData.updated_at: "更新时间",
    }
    column_formatters = {"town_id": _rel_fmt("town")}


class TaskAdmin(_RoleGatedView, model=models.Task):
    name = name_plural = "任务"
    icon = "fa-solid fa-list-check"
    category = "游戏"
    column_list = [models.Task.id, models.Task.title, models.Task.creator_id,
                   models.Task.assignee_id, models.Task.priority, models.Task.status,
                   models.Task.reward_money, models.Task.created_at]
    column_searchable_list = [models.Task.title]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.Task.id: "ID", models.Task.town_id: "小镇", models.Task.creator_id: "创建者",
        models.Task.assignee_id: "执行者", models.Task.title: "标题",
        models.Task.description: "描述", models.Task.priority: "优先级",
        models.Task.status: "状态", models.Task.reward_money: "奖励金币",
        models.Task.created_at: "创建时间", models.Task.completed_at: "完成时间",
    }
    form_overrides, form_args = _select(("status", TASK_STATUS_CHOICES))
    column_formatters = {
        "creator_id": _rel_fmt("creator"), "assignee_id": _rel_fmt("assignee"),
        "town_id": _rel_fmt("town"),
    }


def _review_status_formatter(model, attribute):
    """审查列表 status 列：pending 显示「通过/拒绝」快捷按钮（走业务接口写审计+同步角色）；否则显示状态。"""
    status_map = {"approved": ("已通过", "success"), "rejected": ("已拒绝", "danger"),
                  "edited": ("已编辑", "primary"), "pending": ("待审", "warning")}
    label, color = status_map.get(model.status, (model.status, "secondary"))
    if model.status == "pending":
        return Markup(
            f'<span class="badge bg-{color}">{label}</span> '
            f'<a class="btn btn-success btn-sm ms-1" href="/manage/review/{model.id}/decision?d=approved">通过</a>'
            f'<a class="btn btn-danger btn-sm ms-1" href="/manage/review/{model.id}/decision?d=rejected" '
            f'onclick="return confirm(\'确认拒绝？该角色将被下架。\')">拒绝</a>'
        )
    return Markup(f'<span class="badge bg-{color}">{label}</span>')


async def _delete_chat_logs(request: Request, ids: list[int] | None) -> int:
    """删除对话日志：ids=None 删全部，否则删指定 id。写审计，返回删除条数。"""
    admin_id = request.session.get("admin_id")
    if not admin_id:
        return 0
    with SessionLocal() as db:
        if ids is None:
            count = db.query(models.ChatLog).count()
            db.query(models.ChatLog).delete()
        else:
            count = db.query(models.ChatLog).filter(models.ChatLog.id.in_(ids)).count()
            db.query(models.ChatLog).filter(models.ChatLog.id.in_(ids)).delete(synchronize_session=False)
        db.add(models.AuditLog(
            admin_id=admin_id, action="clear_chat_logs",
            target_type="chat_log", target_id=None,
            after_json={"count": count, "scope": "all" if ids is None else "selected"}))
        db.commit()
        return count


class ChatLogAdmin(_RoleGatedView, model=models.ChatLog):
    name = name_plural = "对话日志"
    icon = "fa-solid fa-comments"
    category = "游戏"
    column_list = [models.ChatLog.id, models.ChatLog.speaker_id,
                   models.ChatLog.listener_id, models.ChatLog.is_flagged,
                   models.ChatLog.created_at]
    column_searchable_list = [models.ChatLog.content]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.ChatLog.id: "ID",
        models.ChatLog.speaker_id: "说话者", models.ChatLog.listener_id: "听众",
        models.ChatLog.town_id: "小镇", models.ChatLog.content: "内容",
        models.ChatLog.ai_score: "AI 评分",
        models.ChatLog.is_flagged: "命中敏感词", models.ChatLog.created_at: "时间",
    }
    can_edit = False  # 日志不可改
    column_formatters = {
        "town_id": _rel_fmt("town"),
        "speaker_id": _rel_fmt("speaker"), "listener_id": _rel_fmt("listener"),
        "is_flagged": lambda m, a: Markup('<span class="badge bg-danger">命中</span>')
        if m.is_flagged else Markup('<span class="badge bg-secondary">-</span>'),
    }

    @action(name="clear_selected", label="删除选中", confirmation_message="确认删除选中的对话日志？")
    async def action_clear_selected(self, request: Request, pks: list[str]):
        await _delete_chat_logs(request, [int(p) for p in pks])
        return RedirectResponse(url=request.headers.get("referer") or "/adminpanel/chat-log/list", status_code=303)

    @action(name="clear_all", label="清空全部", confirmation_message="将删除【全部】对话日志，不可恢复，确认？")
    async def action_clear_all(self, request: Request, pks: list[str]):
        await _delete_chat_logs(request, None)
        return RedirectResponse(url="/adminpanel/chat-log/list", status_code=303)


class MemoryVectorAdmin(_RoleGatedView, model=models.MemoryVector):
    name = name_plural = "记忆向量"
    icon = "fa-solid fa-brain"
    category = "游戏"
    column_list = [models.MemoryVector.id, models.MemoryVector.character_id,
                   models.MemoryVector.memory_type, models.MemoryVector.importance,
                   models.MemoryVector.created_at]
    column_searchable_list = [models.MemoryVector.content]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.MemoryVector.id: "ID", models.MemoryVector.character_id: "角色",
        models.MemoryVector.content: "记忆内容", models.MemoryVector.embedding: "向量(pgvector)",
        models.MemoryVector.memory_type: "记忆类型", models.MemoryVector.importance: "重要性",
        models.MemoryVector.emotion_weight: "情感权重", models.MemoryVector.created_at: "创建时间",
    }
    # pgvector Vector(1024) 类型后台无法编辑，直接排除
    form_excluded_columns = [models.MemoryVector.embedding]
    column_details_exclude_list = [models.MemoryVector.embedding]
    form_overrides, form_args = _select(("memory_type", MEMORY_TYPE_CHOICES))
    column_formatters = {
        "character_id": _rel_fmt("character"),
        "memory_type": _enum_fmt("memory_type", dict(MEMORY_TYPE_CHOICES)),
    }


class NpcLogAdmin(_RoleGatedView, model=models.NpcLog):
    name = name_plural = "NPC 日志"
    icon = "fa-solid fa-brain"
    category = "游戏"
    column_list = [models.NpcLog.id, models.NpcLog.character_id, models.NpcLog.log_type,
                   models.NpcLog.content, models.NpcLog.created_at]
    column_searchable_list = [models.NpcLog.content]
    column_default_sort = ("created_at", True)
    can_edit = False
    column_labels = {
        models.NpcLog.id: "ID", models.NpcLog.character_id: "角色", models.NpcLog.log_type: "类型",
        models.NpcLog.content: "内容", models.NpcLog.created_at: "时间",
    }
    form_overrides, form_args = _select(("log_type", [
        ("decision", "决策"), ("inner_thought", "内心独白"), ("other", "其他")]))
    column_formatters = {
        "character_id": _rel_fmt("character"),
        "log_type": _enum_fmt("log_type", {"decision": "决策", "inner_thought": "内心独白", "other": "其他"}),
        "content": lambda m, a: (m.content[:80] + "…") if m.content and len(m.content) > 80 else (m.content or ""),
    }


# ============================ 管理 ============================

class AdminAdmin(_RoleGatedView, model=models.Admin):
    name = name_plural = "管理员"
    icon = "fa-solid fa-user-shield"
    category = "管理"
    _super_only = True   # 仅超级管理员可管理管理员账号
    column_list = [models.Admin.id, models.Admin.username, models.Admin.role,
                   models.Admin.created_at]
    column_searchable_list = [models.Admin.username]
    column_labels = {
        models.Admin.id: "ID", models.Admin.username: "用户名",
        models.Admin.password_hash: "密码哈希", models.Admin.role: "角色",
        models.Admin.created_at: "创建时间", models.Admin.updated_at: "更新时间",
    }
    # 改密码走业务接口，后台不直接编辑哈希
    form_excluded_columns = [models.Admin.password_hash]
    column_details_exclude_list = [models.Admin.password_hash]
    form_overrides, form_args = _select(("role", ADMIN_ROLE_CHOICES))
    column_formatters = {"role": _enum_fmt("role", ADMIN_ROLE_LABELS)}


class PromptReviewAdmin(_RoleGatedView, model=models.PromptReview):
    name = name_plural = "提示词审查"
    icon = "fa-solid fa-clipboard-check"
    category = "管理"
    # 列表含 content（审查要看内容）；status 列渲染快捷裁决按钮（见 column_formatters）
    column_list = [models.PromptReview.id, models.PromptReview.type,
                   models.PromptReview.target_type, models.PromptReview.content,
                   models.PromptReview.ai_score, models.PromptReview.status,
                   models.PromptReview.created_at]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.PromptReview.id: "ID",
        models.PromptReview.type: "类型",
        models.PromptReview.target_id: "目标 ID", models.PromptReview.target_type: "目标类型",
        models.PromptReview.content: "内容", models.PromptReview.ai_score: "AI 评分",
        models.PromptReview.ai_tags_json: "AI 标签",
        models.PromptReview.status: "状态",
        models.PromptReview.reviewer_id: "审查员", models.PromptReview.reviewed_at: "审查时间",
        models.PromptReview.created_at: "提交时间",
    }
    form_overrides, form_args = _select(
        ("type", REVIEW_TYPE_CHOICES), ("target_type", REVIEW_TARGET_CHOICES),
        ("status", REVIEW_STATUS_CHOICES))
    column_formatters = {
        "status": _review_status_formatter,
        "type": _enum_fmt("type", REVIEW_TYPE_LABELS),
        "target_type": _enum_fmt("target_type", REVIEW_TARGET_LABELS),
        "reviewer_id": _rel_fmt("reviewer"),
        "content": lambda m, a: (m.content[:60] + "…") if m.content and len(m.content) > 60 else (m.content or ""),
    }


class AuditLogAdmin(_RoleGatedView, model=models.AuditLog):
    name = name_plural = "审计日志"
    icon = "fa-solid fa-list-check"
    category = "管理"
    _super_only = True   # 审计仅超级管理员可读
    column_list = [models.AuditLog.id, models.AuditLog.admin_id, models.AuditLog.action,
                   models.AuditLog.target_type, models.AuditLog.target_id,
                   models.AuditLog.created_at]
    column_searchable_list = [models.AuditLog.action]
    column_default_sort = ("created_at", True)
    column_labels = {
        models.AuditLog.id: "ID", models.AuditLog.admin_id: "操作管理员",
        models.AuditLog.action: "动作", models.AuditLog.target_type: "目标类型",
        models.AuditLog.target_id: "目标 ID", models.AuditLog.before_json: "修改前",
        models.AuditLog.after_json: "修改后", models.AuditLog.created_at: "时间",
    }
    can_create = can_edit = can_delete = False  # 审计日志只读
    column_formatters = {
        "admin_id": _rel_fmt("admin"),
        "action": _enum_fmt("action", AUDIT_ACTION_LABELS),
        "target_type": _enum_fmt("target_type", AUDIT_TARGET_LABELS),
    }


class SensitiveWordAdmin(_RoleGatedView, model=models.SensitiveWord):
    name = name_plural = "敏感词"
    icon = "fa-solid fa-ban"
    category = "管理"
    _super_only = True   # 敏感词库仅超级管理员可改（影响全局审查）
    column_list = [models.SensitiveWord.id, models.SensitiveWord.word,
                   models.SensitiveWord.category, models.SensitiveWord.level,
                   models.SensitiveWord.enabled]
    column_searchable_list = [models.SensitiveWord.word]
    column_labels = {
        models.SensitiveWord.id: "ID", models.SensitiveWord.word: "敏感词",
        models.SensitiveWord.category: "分类", models.SensitiveWord.level: "等级",
        models.SensitiveWord.enabled: "启用", models.SensitiveWord.created_at: "创建时间",
    }


class SysConfigAdmin(_RoleGatedView, model=models.SysConfig):
    name = name_plural = "系统配置"
    icon = "fa-solid fa-gear"
    category = "管理"
    _super_only = True   # 系统配置含密钥，仅超级管理员可改
    column_list = [models.SysConfig.key, models.SysConfig.value,
                   models.SysConfig.category, models.SysConfig.description,
                   models.SysConfig.encrypted]
    column_searchable_list = [models.SysConfig.key]
    column_labels = {
        models.SysConfig.key: "键", models.SysConfig.value: "值",
        models.SysConfig.value_type: "值类型", models.SysConfig.category: "分类",
        models.SysConfig.description: "说明", models.SysConfig.encrypted: "是否加密",
        models.SysConfig.updated_at: "更新时间",
    }
    form_overrides, form_args = _select(("value_type", CONFIG_VALUE_TYPE_CHOICES))
    column_formatters = {"value_type": _enum_fmt("value_type", CONFIG_VALUE_TYPE_LABELS)}


_VIEWS = [
    UserAdmin, TownAdmin, CharacterAdmin, MapDataAdmin, TaskAdmin, ChatLogAdmin,
    MemoryVectorAdmin, NpcLogAdmin, AdminAdmin, PromptReviewAdmin, AuditLogAdmin,
    SensitiveWordAdmin, SysConfigAdmin,
]


def setup_admin(app) -> None:
    """挂载 sqladmin 到 FastAPI app。传 authentication_backend 后 sqladmin 自动加 SessionMiddleware。
    base_url 用 /adminpanel：业务 admin router 已占 /admin（/admin/login 等审查 API），避免冲突。"""
    # 主 app 装 SessionMiddleware：sqladmin 把它装在 mount 子应用（/adminpanel/*）上，
    # 但 /manage/* 等非 mount 路径也要读 admin session（封禁按钮等）。secret 与 sqladmin 一致。
    from starlette.middleware.sessions import SessionMiddleware
    if not any(m.cls.__name__ == "SessionMiddleware" for m in app.user_middleware):
        app.add_middleware(SessionMiddleware, secret_key=_SESSION_SECRET)
    _tpl = os.path.join(os.path.dirname(__file__), "templates")
    admin = Admin(
        app, engine,
        base_url="/adminpanel",
        title="AI小镇 管理后台",
        authentication_backend=AdminAuth(secret_key=_SESSION_SECRET),
        templates_dir=_tpl,
        i18n_config=I18nConfig(default_locale="zh"),  # 界面中文化（zh 翻译目录随 venv 提供）
    )
    for view in _VIEWS:
        admin.add_view(view)

    # 用户封禁/解禁（列表页「封禁/解禁」按钮 → 表单 → POST 写 audit + 改 status/banned_at）
    @app.get("/manage/user/{user_id}/ban", include_in_schema=False)
    async def _ban_user_form(user_id: int, request: Request, unban: int = 0):
        if not request.session.get("admin_id"):
            return RedirectResponse(url="/adminpanel/login", status_code=303)
        with SessionLocal() as db:
            u = db.get(models.User, user_id)
            name = u.username if u else f"#{user_id}"
        if unban:
            html = f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5/dist/css/bootstrap.min.css">
<title>解禁用户</title></head><body class="p-4"><h3>解禁用户：{name}</h3>
<form method="post" action="/manage/user/{user_id}/ban?unban=1">
<p class="text-muted">解禁后用户可重新登录，旧 token 仍失效（需重新登录）。</p>
<button class="btn btn-success" type="submit">确认解禁</button>
<a class="btn btn-secondary" href="/adminpanel/user/list">取消</a></form></body></html>"""
        else:
            html = f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5/dist/css/bootstrap.min.css">
<title>封禁用户</title></head><body class="p-4"><h3>封禁用户：{name}</h3>
<form method="post" action="/manage/user/{user_id}/ban">
<div class="mb-3"><label class="form-label">封禁原因（记录在案，用户重登会看到「账号已被封禁」）</label>
<textarea name="reason" class="form-control" rows="3" placeholder="如：发布违规内容"></textarea></div>
<button class="btn btn-danger" type="submit">确认封禁</button>
<a class="btn btn-secondary" href="/adminpanel/user/list">取消</a></form></body></html>"""
        return HTMLResponse(html)

    @app.post("/manage/user/{user_id}/ban", include_in_schema=False)
    async def _ban_user(user_id: int, request: Request, unban: int = 0):
        if not request.session.get("admin_id"):
            return RedirectResponse(url="/adminpanel/login", status_code=303)
        _require_same_origin(request)
        form = await request.form()
        reason = (form.get("reason") or "").strip()
        with SessionLocal() as db:
            u = db.get(models.User, user_id)
            if u:
                before = {"status": u.status}
                if unban:
                    u.status = "active"
                    u.banned_at = None
                    u.token_version += 1   # 使旧 token 失效，强制重登
                    db.add(models.AuditLog(
                        admin_id=request.session["admin_id"], action="unban_user",
                        target_type="user", target_id=u.id, before_json=before,
                        after_json={"status": "active"}))
                else:
                    u.status = "banned"
                    u.banned_at = datetime.now(timezone.utc)
                    u.token_version += 1   # 挤掉在线端；get_current_user 的 status 校验拒后续请求
                    db.add(models.AuditLog(
                        admin_id=request.session["admin_id"], action="ban_user",
                        target_type="user", target_id=u.id, before_json=before,
                        after_json={"status": "banned", "reason": reason or "管理员封禁"}))
                db.commit()
        return RedirectResponse(url="/adminpanel/user/list", status_code=303)

    # 小镇封禁（列表页「封禁」按钮 → 表单填原因 → POST 写审计 + ban_reason）
    @app.get("/manage/town/{town_id}/ban", include_in_schema=False)
    async def _ban_town_form(town_id: int, request: Request):
        if not request.session.get("admin_id"):
            return RedirectResponse(url="/adminpanel/login", status_code=303)
        with SessionLocal() as db:
            t = db.get(models.Town, town_id)
            name = t.name if t else f"#{town_id}"
        html = f"""<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5/dist/css/bootstrap.min.css">
<title>封禁小镇</title></head><body class="p-4"><h3>封禁小镇：{name}</h3>
<form method="post" action="/manage/town/{town_id}/ban">
<div class="mb-3"><label class="form-label">封禁原因（客户端进入检测到即提示并退出）</label>
<textarea name="reason" class="form-control" rows="3" required placeholder="如：小镇内存在违规内容"></textarea></div>
<button class="btn btn-danger" type="submit">确认封禁</button>
<a class="btn btn-secondary" href="/adminpanel/town/list">取消</a></form></body></html>"""
        return HTMLResponse(html)

    @app.post("/manage/town/{town_id}/ban", include_in_schema=False)
    async def _ban_town(town_id: int, request: Request):
        if not request.session.get("admin_id"):
            return RedirectResponse(url="/adminpanel/login", status_code=303)
        _require_same_origin(request)
        form = await request.form()
        reason = (form.get("reason") or "").strip() or "管理员封禁"
        with SessionLocal() as db:
            t = db.get(models.Town, town_id)
            if t and t.status != "banned":
                before = {"status": t.status}
                t.status = "banned"
                t.ban_reason = reason
                t.closed_at = datetime.now(timezone.utc)
                db.add(models.AuditLog(
                    admin_id=request.session["admin_id"], action="ban_town",
                    target_type="town", target_id=t.id,
                    before_json=before, after_json={"status": "banned", "reason": reason}))
                db.commit()
        # 推 kick_all 给该镇所有在线玩家（客户端 _do_kick 自关 WS 回大厅，显示封禁原因）
        kicked = await ws_manager.kick_town(town_id, reason)
        if kicked:
            print(f"[admin] town={town_id} 封禁，已踢 {kicked} 个在线连接")
        return RedirectResponse(url="/adminpanel/town/list", status_code=303)

    # 审查一键裁决（列表页「通过/拒绝」按钮 → 调业务逻辑 apply_review_decision → 跳回列表）
    @app.get("/manage/review/{review_id}/decision", include_in_schema=False)
    async def _review_decision(review_id: int, request: Request, d: str = "approved"):
        if not request.session.get("admin_id"):
            return RedirectResponse(url="/adminpanel/login", status_code=303)
        if d not in ("approved", "rejected"):
            return RedirectResponse(url="/adminpanel/prompt-review/list", status_code=303)
        from .routers.admin import apply_review_decision
        with SessionLocal() as db:
            apply_review_decision(db, review_id, d, request.session["admin_id"])
        return RedirectResponse(url="/adminpanel/prompt-review/list", status_code=303)
