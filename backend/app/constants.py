"""业务层字符串常量。schema 列已是 String，这里集中消灭 magic string。
不用 SQLAlchemy Enum（免迁移/与 schema.sql 一致）。"""
from types import SimpleNamespace

ReviewType = SimpleNamespace(
    SYSTEM_PROMPT="system_prompt",
    CHAT_OUTPUT="chat_output",
)
ReviewTargetType = SimpleNamespace(
    CHARACTER="character",
    CHAT="chat",
)
ReviewStatus = SimpleNamespace(
    PENDING="pending",
    APPROVED="approved",
    REJECTED="rejected",
    EDITED="edited",
)
AdminRole = SimpleNamespace(
    SUPER="super",
    REVIEWER="reviewer",
)
AuditAction = SimpleNamespace(
    CREATE_REVIEW="create_review",
    AUTO_APPROVE_REVIEW="auto_approve_review",
    APPROVE_REVIEW="approve_review",
    REJECT_REVIEW="reject_review",
    EDIT_REVIEW="edit_review",
    TOGGLE_CHARACTER="toggle_character",
    BAN_USER="ban_user",
    UNBAN_USER="unban_user",
    BAN_TOWN="ban_town",
    CLEAR_CHAT_LOGS="clear_chat_logs",
    PURGE_CHAT_LOGS="purge_chat_logs",
)
# Town/Room 状态（rooms 表已废弃，保留 Town 状态定义）
TownStatus = SimpleNamespace(
    WAITING="waiting",
    PLAYING="playing",
    CLOSED="closed",
    BANNED="banned",
)
UserRole = SimpleNamespace(
    PLAYER="player",
    CREATOR="creator",
    RESIDENT="resident",
    OBSERVER="observer",
)
UserStatus = SimpleNamespace(
    ACTIVE="active",
    BANNED="banned",
)
MemoryType = SimpleNamespace(
    PERSONAL="personal",
    INTERACTION="interaction",   # 对话摘要（NPC 互聊结束后 LLM 写的 interaction）
    DECISION="decision",         # NPC 决策记录（内心独白/行动选择 → 可回溯 NPC"当时怎么想的"）
)
ConfigValueType = SimpleNamespace(
    STRING="string",
    INT="int",
    FLOAT="float",
    BOOL="bool",
    JSON="json",
)

# ============================ sqladmin 下拉/中文显示用 ============================
# form_choices 直接用（编辑表单变下拉）；column_formatters 取 dict 显示中文。
ROLE_CHOICES = [
    (UserRole.PLAYER, "玩家"), (UserRole.CREATOR, "创作者"),
    (UserRole.RESIDENT, "居民"), (UserRole.OBSERVER, "观察者"),
]
USER_STATUS_CHOICES = [
    (UserStatus.ACTIVE, "正常"), (UserStatus.BANNED, "封禁"),
]
ADMIN_ROLE_CHOICES = [
    (AdminRole.SUPER, "超级管理员"), (AdminRole.REVIEWER, "审核员"),
]
TaskStatus = SimpleNamespace(
    PENDING="pending", IN_PROGRESS="in_progress", DONE="done", CANCELLED="cancelled",
)
TASK_STATUS_CHOICES = [
    (TaskStatus.PENDING, "待接取"), (TaskStatus.IN_PROGRESS, "进行中"),
    (TaskStatus.DONE, "已完成"), (TaskStatus.CANCELLED, "已取消"),
]
TOWN_STATUS_CHOICES = [
    (TownStatus.WAITING, "等待中"), (TownStatus.PLAYING, "进行中"),
    (TownStatus.CLOSED, "已关闭"), (TownStatus.BANNED, "已封禁"),
]
REVIEW_STATUS_CHOICES = [
    (ReviewStatus.PENDING, "待审"), (ReviewStatus.APPROVED, "已通过"),
    (ReviewStatus.REJECTED, "已拒绝"), (ReviewStatus.EDITED, "已编辑"),
]
REVIEW_TYPE_CHOICES = [
    (ReviewType.SYSTEM_PROMPT, "系统提示词"), (ReviewType.CHAT_OUTPUT, "对话输出"),
]
REVIEW_TARGET_CHOICES = [
    (ReviewTargetType.CHARACTER, "角色"), (ReviewTargetType.CHAT, "对话"),
]
CONFIG_VALUE_TYPE_CHOICES = [
    (ConfigValueType.STRING, "字符串"), (ConfigValueType.INT, "整数"),
    (ConfigValueType.FLOAT, "浮点"), (ConfigValueType.BOOL, "布尔"),
    (ConfigValueType.JSON, "JSON"),
]
MEMORY_TYPE_CHOICES = [
    (MemoryType.PERSONAL, "个人"), (MemoryType.INTERACTION, "互动摘要"),
    (MemoryType.DECISION, "决策记录"),
]
# audit_logs.target_type 多态自由值，覆盖已知取值
AUDIT_TARGET_LABELS = {
    "character": "角色", "chat": "对话", "chat_log": "对话日志",
    "room": "房间", "town": "小镇", "user": "用户",
    "review": "审查", "admin": "管理员",
}
# 便于 column_formatters 取中文：value → label
ROLE_LABELS = dict(ROLE_CHOICES)
USER_STATUS_LABELS = dict(USER_STATUS_CHOICES)
ADMIN_ROLE_LABELS = dict(ADMIN_ROLE_CHOICES)
TOWN_STATUS_LABELS = dict(TOWN_STATUS_CHOICES)
REVIEW_STATUS_LABELS = dict(REVIEW_STATUS_CHOICES)
REVIEW_TYPE_LABELS = dict(REVIEW_TYPE_CHOICES)
REVIEW_TARGET_LABELS = dict(REVIEW_TARGET_CHOICES)
CONFIG_VALUE_TYPE_LABELS = dict(CONFIG_VALUE_TYPE_CHOICES)
AUDIT_ACTION_LABELS = {
    AuditAction.CREATE_REVIEW: "创建审查", AuditAction.AUTO_APPROVE_REVIEW: "自动通过审查",
    AuditAction.APPROVE_REVIEW: "通过审查",
    AuditAction.REJECT_REVIEW: "拒绝审查", AuditAction.EDIT_REVIEW: "编辑审查",
    AuditAction.TOGGLE_CHARACTER: "角色上下架", AuditAction.BAN_USER: "封禁用户",
    AuditAction.UNBAN_USER: "解禁用户", AuditAction.BAN_TOWN: "封禁小镇",
    AuditAction.CLEAR_CHAT_LOGS: "清空对话日志",
    AuditAction.PURGE_CHAT_LOGS: "定时清理对话",
}
