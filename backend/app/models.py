"""ORM 模型，对应 backend/db/schema.sql 的 13 张表。SQLAlchemy 2.0 typed 风格。
外键列保留裸 *_id（存 ID 不存名字，避免改名/删除后不一致）；另声明 relationship() 供
后台 sqladmin 列表显示名字 + 表单下拉，及 API 连表取名字（均为读时连表，零冗余）。"""
from datetime import datetime
from sqlalchemy import (
    BigInteger, String, Text, Boolean, Float, SmallInteger, Integer,
    ForeignKey, DateTime, func, text,
)
from sqlalchemy.dialects.postgresql import JSONB, BYTEA
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from pgvector.sqlalchemy import Vector


class Base(DeclarativeBase):
    pass


# ============================ 游戏核心 ============================

class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    email: Mapped[str | None] = mapped_column(String(255), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[str] = mapped_column(String(32), server_default="player", nullable=False)        # player/creator/resident/observer
    status: Mapped[str] = mapped_column(String(32), server_default="active", nullable=False)      # active/banned
    byok_api_type: Mapped[str | None] = mapped_column(String(32))     # BYOK 提供商（APIConfig provider 名：Ollama/OpenAI/DeepSeek/...）
    byok_model: Mapped[str | None] = mapped_column(String(128))       # BYOK 模型名（如 deepseek-chat）
    byok_api_key_enc: Mapped[bytes | None] = mapped_column(BYTEA)     # AES-256 加密的 api_key（脱库保护；GET 解密返回本人）
    token_version: Mapped[int] = mapped_column(Integer, server_default="0", nullable=False)  # 单端登录：登录 ++ 使旧 token 失效（挤掉旧端）
    settings_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))
    banned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    def __str__(self):
        return self.username


class Town(Base):
    """小镇 = 持久世界配置 + 运行时会话（合并原 rooms 概念）。
    一个 town 就是一个游戏房间，host 开房即创建 town，关闭即标记 closed。"""
    __tablename__ = "towns"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    creator_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    host_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("users.id"))   # 当前房主（开房时设，关房时清）
    name: Mapped[str] = mapped_column(String(128), nullable=False)
    port: Mapped[int | None] = mapped_column(Integer)                                  # ponytail: WebSocket 中继后 port 废弃，保留列兼容
    config_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))
    weather: Mapped[str] = mapped_column(String(64), server_default="clear", nullable=False)
    time_scale: Mapped[float] = mapped_column(Float, server_default="1.0", nullable=False)
    status: Mapped[str] = mapped_column(String(32), server_default="waiting", nullable=False)  # waiting/playing/closed/banned
    ban_reason: Mapped[str | None] = mapped_column(Text)
    rooms_json: Mapped[list | None] = mapped_column(JSONB)  # [{name, cx, cy, w, h}, ...] 言出法随改地图后更新
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    # 两个 FK 都指向 users，须显式 foreign_keys 消歧
    creator = relationship("User", foreign_keys=[creator_id], lazy="joined")
    host = relationship("User", foreign_keys=[host_id], lazy="joined")

    def __str__(self):
        return self.name


class Character(Base):
    __tablename__ = "characters"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    owner_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    town_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("towns.id"))
    name: Mapped[str] = mapped_column(String(64), nullable=False)
    appearance_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))
    personality_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))
    background: Mapped[str | None] = mapped_column(Text)
    system_prompt: Mapped[str | None] = mapped_column(Text)
    core_memories_json: Mapped[list] = mapped_column(JSONB, default=list, server_default=text("'[]'"))
    review_status: Mapped[str] = mapped_column(String(32), server_default="pending", nullable=False)  # pending/approved/rejected/edited
    is_active: Mapped[bool] = mapped_column(Boolean, server_default=text("true"), nullable=False)    # 先玩后审：默认可用
    # 角色状态数值（心情/金钱/健康），NPC 自主行为 + 任务系统驱动
    mood: Mapped[float] = mapped_column(Float, server_default="0.6", nullable=False)   # 0-1，心情
    money: Mapped[int] = mapped_column(Integer, server_default="100", nullable=False)  # 金币
    health: Mapped[float] = mapped_column(Float, server_default="1.0", nullable=False) # 0-1，健康
    items_json: Mapped[list] = mapped_column(JSONB, default=list, server_default=text("'[]'"))  # [{name, qty}, ...] NPC 物品栏
    relations_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))  # {"他人名":{"affinity":0.6,"tags":[],"note":""}} 每 NPC 视角动态关系（不必对称）
    byok_api_type: Mapped[str | None] = mapped_column(String(32))     # 角色 BYOK 提供商（None=回退账号级 users.byok_*）
    byok_model: Mapped[str | None] = mapped_column(String(128))       # 角色 BYOK 模型名
    byok_api_key_enc: Mapped[bytes | None] = mapped_column(BYTEA)     # AES-256 加密 key（同 users 范式，GET 解密返回 owner 本人）
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    owner = relationship("User", lazy="joined")
    town = relationship("Town", lazy="joined")

    def __str__(self):
        return self.name


class Task(Base):
    """AI 任务系统（§3.5）：NPC 自主创建/派发/完成。"""
    __tablename__ = "tasks"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    town_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("towns.id"), nullable=False)
    creator_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("characters.id"), nullable=False)
    assignee_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("characters.id"))
    title: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    priority: Mapped[int] = mapped_column(SmallInteger, server_default="3", nullable=False)  # 1-5，越高越重要
    status: Mapped[str] = mapped_column(String(32), server_default="pending", nullable=False)  # pending/in_progress/done/cancelled
    reward_money: Mapped[int] = mapped_column(Integer, server_default="0", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    town = relationship("Town", lazy="joined")
    creator = relationship("Character", foreign_keys=[creator_id], lazy="joined")
    assignee = relationship("Character", foreign_keys=[assignee_id], lazy="joined")

    def __str__(self):
        return self.title or f"Task#{self.id}"


class TownEvent(Base):
    """房主叙事事件（导演模式）：情境新闻 + 规则两类独立、不关联。
    news=渲染氛围（台风/吸血鬼），rule=约束行为（规则怪谈式，天黑别出门）。"""
    __tablename__ = "town_events"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    town_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("towns.id"), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False)  # news | rule
    title: Mapped[str | None] = mapped_column(String(128))
    content: Mapped[str] = mapped_column(Text, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, server_default=text("true"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    deactivated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    town = relationship("Town", lazy="joined")

    def __str__(self):
        return f"[{self.kind}] {self.title or self.content[:20]}"


class MapData(Base):
    """地图数据。town_id=NULL 为预设模板（创建小镇时可选用）；town_id 非空为小镇专属地图（1:1）。"""
    __tablename__ = "map_data"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    town_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("towns.id"), nullable=True)
    name: Mapped[str | None] = mapped_column(String(128))        # 预设名称（town_id=NULL 时必填）
    chunk_json: Mapped[dict] = mapped_column(JSONB, default=dict, server_default=text("'{}'"))
    prefabs_json: Mapped[list] = mapped_column(JSONB, default=list, server_default=text("'[]'"))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    town = relationship("Town", lazy="joined")

    def __str__(self):
        return self.name or f"Map#{self.id}"


class ChatLog(Base):
    __tablename__ = "chat_logs"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    town_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("towns.id"))
    speaker_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("characters.id"))
    listener_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("characters.id"))
    content: Mapped[str] = mapped_column(Text, nullable=False)
    ai_score: Mapped[float | None] = mapped_column(Float)
    is_flagged: Mapped[bool] = mapped_column(Boolean, server_default=text("false"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    # speaker/listener 都指向 characters，须显式 foreign_keys 消歧
    speaker = relationship("Character", foreign_keys=[speaker_id], lazy="joined")
    listener = relationship("Character", foreign_keys=[listener_id], lazy="joined")
    town = relationship("Town", lazy="joined")
    # ponytail: room relationship 已删除（rooms 表废弃）


class MemoryVector(Base):
    __tablename__ = "memory_vectors"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    character_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("characters.id"), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    embedding = mapped_column(Vector(1024), nullable=False)  # pgvector，向量列不用 Mapped 注解
    memory_type: Mapped[str] = mapped_column(String(32), server_default="personal", nullable=False)
    importance: Mapped[int] = mapped_column(SmallInteger, server_default="3", nullable=False)
    emotion_weight: Mapped[float] = mapped_column(Float, server_default="1.0", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    character = relationship("Character", lazy="joined")


class NpcLog(Base):
    """NPC 内部活动日志：决策记录 + 内心独白 + 状态变更。不入 RAG 向量检索（不接 embedding）。
    独立轻量表，与 memory_vectors（带 embedding）和 chat_logs（对话流水）职责分开。"""
    __tablename__ = "npc_logs"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    character_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("characters.id"), nullable=False)
    log_type: Mapped[str] = mapped_column(String(32), server_default="other", nullable=False)  # decision/inner_thought/other
    content: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    character = relationship("Character", lazy="joined")


# ============================ 管理后台 ============================

class Admin(Base):
    __tablename__ = "admins"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[str] = mapped_column(String(32), server_default="reviewer", nullable=False)  # super/reviewer
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    def __str__(self):
        return self.username


class PromptReview(Base):
    __tablename__ = "prompt_reviews"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    type: Mapped[str] = mapped_column(String(32), nullable=False)            # system_prompt/chat_output
    target_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    target_type: Mapped[str] = mapped_column(String(32), nullable=False)     # character/chat
    content: Mapped[str] = mapped_column(Text, nullable=False)
    ai_score: Mapped[float | None] = mapped_column(Float)
    ai_tags_json: Mapped[list] = mapped_column(JSONB, default=list, server_default=text("'[]'"))
    status: Mapped[str] = mapped_column(String(32), server_default="pending", nullable=False)  # pending/approved/rejected/edited
    reviewer_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("admins.id"))
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    reviewer = relationship("Admin", lazy="joined")


class AuditLog(Base):
    __tablename__ = "audit_logs"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    admin_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("admins.id"), nullable=False)
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    target_type: Mapped[str] = mapped_column(String(32), nullable=False)
    target_id: Mapped[int | None] = mapped_column(BigInteger)
    before_json: Mapped[dict | None] = mapped_column(JSONB)
    after_json: Mapped[dict | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    admin = relationship("Admin", lazy="joined")


class SensitiveWord(Base):
    __tablename__ = "sensitive_words"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    word: Mapped[str] = mapped_column(String(128), nullable=False)
    category: Mapped[str | None] = mapped_column(String(64))
    level: Mapped[int] = mapped_column(SmallInteger, server_default="1", nullable=False)
    enabled: Mapped[bool] = mapped_column(Boolean, server_default=text("true"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SysConfig(Base):
    __tablename__ = "sysconfig"
    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    value: Mapped[str | None] = mapped_column(Text)
    value_type: Mapped[str] = mapped_column(String(32), server_default="string", nullable=False)  # string/int/float/bool/json
    category: Mapped[str | None] = mapped_column(String(64))
    description: Mapped[str | None] = mapped_column(Text)
    encrypted: Mapped[bool] = mapped_column(Boolean, server_default=text("false"), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
