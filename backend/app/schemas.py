"""Pydantic 入参/出参（FastAPI / Pydantic v2）。"""
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    admin_id: int


class ReviewCreate(BaseModel):
    type: Literal["system_prompt", "chat_output"]
    target_id: int
    target_type: Literal["character", "chat"]
    content: str


class ReviewOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    type: str
    target_id: int
    target_type: str
    content: str
    ai_score: float | None = None
    ai_tags_json: list[Any] = []
    status: str
    reviewer_id: int | None = None
    reviewed_at: datetime | None = None
    created_at: datetime


class ReviewDecision(BaseModel):
    decision: Literal["approved", "rejected", "edited"]
    edited_content: str | None = None  # decision=edited 时必填（端点校验）
    note: str | None = None


class CharacterActiveUpdate(BaseModel):
    is_active: bool


class CharacterCreate(BaseModel):
    name: str
    town_id: int | None = None
    background: str | None = None
    personality_json: dict[str, Any] | None = None   # 结构化五字段人设（position/personality/speaking_style/work_duties/work_habits/notes）


class CharacterUpdate(BaseModel):
    name: str | None = None
    background: str | None = None
    personality_json: dict[str, Any] | None = None
    relations_json: dict[str, Any] | None = None


class CharacterStatusUpdate(BaseModel):
    """NPC/系统更新角色状态数值。delta 字段可为正负（相对变化），absolute 为设为指定值。
    优先 absolute，其次 delta，均不传则不变。"""
    mood: float | None = None          # absolute: 设为目标值 (0-1)
    mood_delta: float | None = None    # relative: +/- 变化量
    money: int | None = None
    money_delta: int | None = None
    health: float | None = None
    health_delta: float | None = None


class CoreMemoriesAppend(BaseModel):
    """对话结束后从记忆摘要提炼的稳定核心事实，追加到 character.core_memories_json。
    每次全量注入 prompt（不检索）；服务端做去重 + FIFO 上限。"""
    facts: list[str]


class CharacterOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    owner_id: int
    town_id: int | None = None
    background: str | None = None
    personality_json: dict[str, Any] = {}   # 结构化五字段人设（替代 background 存 JSON 字符串的旧方案）
    core_memories_json: list[Any] = []   # 从 memory_vectors 晋升的稳定核心事实，每次全量注入 prompt
    mood: float = 0.6
    money: int = 100
    health: float = 1.0
    items_json: list[Any] = []
    relations_json: dict[str, Any] = {}
    review_status: str
    is_active: bool
    created_at: datetime


class UserStatusUpdate(BaseModel):
    status: Literal["active", "banned"]


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    username: str
    role: str
    status: str
    banned_at: datetime | None = None


class AuditLogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    admin_id: int
    action: str
    target_type: str
    target_id: int | None = None
    before_json: Any = None
    after_json: Any = None
    created_at: datetime


# ============================ 玩家鉴权 ============================

class ByokSettings(BaseModel):
    """玩家 BYOK 配置（GET /auth/me/byok）。api_key 解密回明文——客户端发起 AI 请求要用，
    JWT 鉴权仅本人可取；DB 加密只为防脱库。"""
    api_type: str | None = None
    model: str | None = None
    api_key: str | None = None


class ByokSettingsUpdate(BaseModel):
    """玩家 BYOK 配置（PUT /auth/me/byok）。各字段 None=不改；api_key 空/None 时保留原值。"""
    api_type: str | None = None
    model: str | None = None
    api_key: str | None = None


class PlayerRegisterRequest(BaseModel):
    username: str
    password: str
    email: str | None = None


class PlayerLoginRequest(BaseModel):
    username: str
    password: str


class PlayerTokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    user: "UserOut"


# ============================ 记忆系统 ============================

class MemoryCreate(BaseModel):
    character_id: int
    content: str
    memory_type: str = "personal"
    importance: int = 3
    emotion_weight: float = 1.0


class MemorySearchRequest(BaseModel):
    character_id: int
    query_text: str
    top_k: int = 5


class MemoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    character_id: int
    content: str
    memory_type: str
    importance: int
    emotion_weight: float
    created_at: datetime


class MemorySearchResult(MemoryOut):
    similarity: float      # cosine similarity = 1 - distance
    time_decay: float      # exp(-days / decay_days)
    score: float           # final = importance_norm × time_decay × similarity


# ============================ 对话日志 ============================

# ============================ 小镇（rooms 表已废弃删除，房间概念由 towns.rooms_json 接管） ============================

class TownCreate(BaseModel):
    name: str
    config_json: dict[str, Any] | None = None
    map_preset_id: int | None = None   # 可选：选择预设地图，自动复制到 map_data + rooms_json


class TownUpdate(BaseModel):
    name: str | None = None
    config_json: dict[str, Any] | None = None
    weather: str | None = None
    time_scale: float | None = None


class TownOut(BaseModel):
    """小镇 = 持久世界 + 运行时会话（合并了原 rooms 概念）。
    ponytail: port 已废弃（WebSocket 中继不需端口）；host_ip 移除。"""
    model_config = ConfigDict(from_attributes=True)
    id: int
    creator_id: int
    host_id: int | None = None
    name: str
    config_json: dict[str, Any] = {}
    weather: str
    time_scale: float
    status: str           # waiting/playing/closed/banned
    ban_reason: str | None = None
    rooms_json: list[Any] | None = None  # [{name, cx, cy, w, h}, ...] 房间空间定义
    closed_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class TownDetail(TownOut):
    """小镇详情（兼容旧 active_room 字段，实际就是自身）。"""
    pass


# ============================ 对话日志 ============================

class ChatLogCreate(BaseModel):
    speaker_id: int
    content: str
    listener_id: int | None = None
    town_id: int | None = None


class ChatLogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    speaker_id: int | None = None
    listener_id: int | None = None
    content: str
    ai_score: float | None = None
    is_flagged: bool
    created_at: datetime
    # 连表名（读时解析，非冗余存储）：客户端对话面板直接显示，不必再自己维护 ID→名映射
    speaker_name: str | None = None
    listener_name: str | None = None
    room_name: str | None = None


# ============================ NPC 日志 ============================

# ============================ 地图数据 ============================

class MapDataCreate(BaseModel):
    """创建地图预设（town_id 不传，后端设 NULL）。"""
    name: str
    chunk_json: dict[str, Any] | None = None
    prefabs_json: list[Any] | None = None


class MapDataOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    town_id: int | None = None
    name: str | None = None
    chunk_json: dict[str, Any] = {}
    prefabs_json: list[Any] = []
    updated_at: datetime


class MapPresetItem(BaseModel):
    """预设列表项（轻量，不含完整 chunk/prefabs）。"""
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str | None = None
    room_count: int = 0     # chunk_json.rooms 数组长度
    updated_at: datetime


class MapAction(BaseModel):
    """单条地图修改指令（§5.3 落地）。action: place_tile/remove_tile/place_prefab/remove_prefab/add_room/remove_room/update_room。"""
    action: str
    pos: list[float] | None = None     # [x, y]，place_tile/remove_tile/place_prefab/remove_prefab 用
    tile_type: str | None = None       # place_tile/remove_tile 用
    prefab_name: str | None = None     # place_prefab/remove_prefab 用
    room: dict[str, Any] | None = None  # add_room/update_room 用 {name, cx, cy, w, h, indoor?}（indoor 可选布尔，室内外分区）
    room_name: str | None = None       # remove_room 用


class MapActionsRequest(BaseModel):
    """NPC/玩家提交地图修改批量指令。"""
    actions: list[MapAction]
    character_id: int | None = None    # 谁改的（审计用）


class NpcLogCreate(BaseModel):
    character_id: int
    log_type: str = "other"        # decision / inner_thought / other
    content: str


class NpcLogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    character_id: int
    log_type: str
    content: str
    created_at: datetime
    # 连表名
    character_name: str | None = None


# ============================ 任务系统 ============================

class TaskCreate(BaseModel):
    """NPC 创建任务（Brain JSON task.create 映射）。"""
    title: str
    description: str | None = None
    priority: int = 3             # 1-5
    assignee_id: int | None = None  # 指派给谁（可选）
    reward_money: int = 0


class TaskUpdate(BaseModel):
    """更新任务状态（接受/完成/取消）。"""
    status: Literal["in_progress", "done", "cancelled"] | None = None
    assignee_id: int | None = None
    title: str | None = None
    description: str | None = None
    priority: int | None = None


class TaskOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    town_id: int
    creator_id: int
    assignee_id: int | None = None
    title: str
    description: str | None = None
    priority: int
    status: str
    reward_money: int
    created_at: datetime
    completed_at: datetime | None = None
    # 连表名（_enrich_task 填充）
    creator_name: str | None = None
    assignee_name: str | None = None


# ============================ 房主叙事（导演模式）============================

class TownEventCreate(BaseModel):
    """房主发布叙事事件（导演控制台）。news=情境新闻, rule=规则怪谈式约束（两类独立、不关联）。"""
    kind: Literal["news", "rule"]
    title: str | None = None
    content: str


class TownEventOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    town_id: int
    kind: str
    title: str | None = None
    content: str
    is_active: bool
    created_at: datetime


# ============================ NPC 交易系统 ============================

class TradeItem(BaseModel):
    """单条物品（交易用）。"""
    name: str
    qty: int = 1


class TradeRequest(BaseModel):
    """发起交易。proposer 提供 offer_items + offer_money，请求 target 的 request_items + request_money。"""
    proposer_id: int
    target_id: int
    offer_items: list[TradeItem] = []     # 我给的物品
    offer_money: int = 0                  # 我加的金币
    request_items: list[TradeItem] = []   # 我要的物品
    request_money: int = 0                # 我要的金币


class CharacterItems(BaseModel):
    """物品栏摘要。"""
    items_json: list[TradeItem] = []
    money: int = 0
