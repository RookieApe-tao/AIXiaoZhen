"""AI小镇 后端（业务 API 层）。管理后台由 sqladmin 承担：/admin（挂载在同一 app）。"""
import asyncio
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from sqlalchemy import select, text

from .database import engine, SessionLocal
from . import models, moderation
from .config import SYS_CONFIG_DEFAULTS
from .auth import hash_password
from .services import embedding, review
from .routers import admin, auth as auth_router, characters as characters_router, chat as chat_router, config as config_router, maps as maps_router, memory as memory_router, npc_logs as npc_logs_router, tasks as tasks_router, narrative as narrative_router, towns as towns_router, trades as trades_router, ws as ws_router
from .admin_panel import setup_admin

app = FastAPI(title="AI小镇 后端 API")
app.include_router(admin.router)
app.include_router(auth_router.router)
app.include_router(characters_router.router)
app.include_router(chat_router.router)
app.include_router(config_router.router)
app.include_router(maps_router.router)
app.include_router(memory_router.router)
app.include_router(npc_logs_router.router)
app.include_router(tasks_router.router)
app.include_router(towns_router.router)
app.include_router(trades_router.router)
app.include_router(narrative_router.router)
app.include_router(ws_router.router)

setup_admin(app)  # sqladmin 管理后台 → /adminpanel（替代 Directus；业务 API 仍用 /admin）


@app.on_event("startup")
def init_db() -> None:
    # 建扩展 + 表（sqladmin 管理后台依赖这些表存在；create_all 幂等，已存在则跳过）
    with engine.begin() as conn:
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))
    models.Base.metadata.create_all(engine)
    # create_all 不给已存在表加列（项目无 Alembic），幂等补 users 的 BYOK 三列
    with engine.begin() as conn:
        conn.execute(text(
            "ALTER TABLE users "
            "ADD COLUMN IF NOT EXISTS byok_api_type VARCHAR(32), "
            "ADD COLUMN IF NOT EXISTS byok_model VARCHAR(128), "
            "ADD COLUMN IF NOT EXISTS byok_api_key_enc BYTEA, "
            "ADD COLUMN IF NOT EXISTS token_version INTEGER DEFAULT 0"
        ))
    # 幂等补 towns 的运行时列（小镇=房间合并，2026-08-12；rooms 表已废弃删除）
    with engine.begin() as conn:
        conn.execute(text(
            "ALTER TABLE towns "
            "ADD COLUMN IF NOT EXISTS host_id BIGINT REFERENCES users(id), "
            "ADD COLUMN IF NOT EXISTS port INTEGER, "
            "ADD COLUMN IF NOT EXISTS ban_reason TEXT, "
            "ADD COLUMN IF NOT EXISTS closed_at TIMESTAMPTZ"
        ))
        # 修 status 列默认值（旧建表可能遗留 'active' 默认，与模型 waiting 不一致）
        conn.execute(text("ALTER TABLE towns ALTER COLUMN status SET DEFAULT 'waiting'"))
        # rooms_json：小镇房间定义（言出法随改地图后更新；客户端/brain 启动时拉取）
        conn.execute(text("ALTER TABLE towns ADD COLUMN IF NOT EXISTS rooms_json JSONB"))
    # 幂等补 map_data 言出法随改造：town_id 改可空（预设）、加 name 列
    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE map_data ALTER COLUMN town_id DROP NOT NULL"))
        conn.execute(text("ALTER TABLE map_data ADD COLUMN IF NOT EXISTS name VARCHAR(128)"))
    # 幂等补 characters 状态数值列（心情/金钱/健康，AI 任务+决策系统驱动）
    with engine.begin() as conn:
        conn.execute(text("ALTER TABLE characters ADD COLUMN IF NOT EXISTS mood FLOAT DEFAULT 0.6"))
        conn.execute(text("ALTER TABLE characters ADD COLUMN IF NOT EXISTS money INTEGER DEFAULT 100"))
        conn.execute(text("ALTER TABLE characters ADD COLUMN IF NOT EXISTS health FLOAT DEFAULT 1.0"))
        # 补齐存量 NULL 值到默认
        conn.execute(text("UPDATE characters SET mood=0.6 WHERE mood IS NULL"))
        conn.execute(text("UPDATE characters SET money=100 WHERE money IS NULL"))
        conn.execute(text("UPDATE characters SET health=1.0 WHERE health IS NULL"))
        conn.execute(text("ALTER TABLE characters ADD COLUMN IF NOT EXISTS items_json JSONB DEFAULT '[]'"))
        conn.execute(text("UPDATE characters SET items_json='[]' WHERE items_json IS NULL"))
        conn.execute(text("ALTER TABLE characters ADD COLUMN IF NOT EXISTS relations_json JSONB DEFAULT '{}'"))
        conn.execute(text("UPDATE characters SET relations_json='{}' WHERE relations_json IS NULL"))
        # 每角色 AI 设置（BYOK）：None=回退账号级 users.byok_*（2026-08-15）
        conn.execute(text(
            "ALTER TABLE characters "
            "ADD COLUMN IF NOT EXISTS byok_api_type VARCHAR(32), "
            "ADD COLUMN IF NOT EXISTS byok_model VARCHAR(128), "
            "ADD COLUMN IF NOT EXISTS byok_api_key_enc BYTEA"
        ))
    with engine.begin() as conn:
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_memory_embedding "
            "ON memory_vectors USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
        ))
    with engine.begin() as conn:
        conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_chat_logs_created_at ON chat_logs (created_at DESC)"
        ))

    with SessionLocal() as db:
        # seed 业务管理员（sqladmin 后台登录 + 业务接口鉴权共用此账号 admin/admin）
        admin_row = db.scalar(select(models.Admin).where(models.Admin.username == "admin"))
        if not admin_row:
            db.add(models.Admin(username="admin", password_hash=hash_password("admin"), role="super"))
            print("[seed] 业务管理员 admin/admin")
        elif not admin_row.password_hash.startswith("$2"):
            # 迁移早期 SHA-256 占位哈希 → bcrypt（dev 默认密码 admin）
            admin_row.password_hash = hash_password("admin")
            print("[seed] 迁移 admin 密码哈希 SHA-256 → bcrypt")
        db.commit()

        # seed sysconfig 默认配置（缺失项才插）
        existing = set(r[0] for r in db.query(models.SysConfig.key).all())
        new_items = [models.SysConfig(**c) for c in SYS_CONFIG_DEFAULTS if c["key"] not in existing]
        if new_items:
            db.add_all(new_items)
            db.commit()
            print(f"[seed] sysconfig 补 {len(new_items)} 项")

        # seed 样本敏感词（表空时），便于测 DFA；真实词库走 Directus 维护
        if db.query(models.SensitiveWord).count() == 0:
            db.add_all([models.SensitiveWord(word=w, category=c, level=l)
                        for w, c, l in [("敏感测试", "测试", 2), ("bannedtest", "测试", 1)]])
            db.commit()
            print("[seed] 样本敏感词 2 条")

        # seed Office 预设地图（map_data 预设表无数据时自动插入）
        if db.query(models.MapData).filter(models.MapData.town_id.is_(None)).count() == 0:
            db.add(models.MapData(
                town_id=None,
                name="Office 办公室",
                chunk_json={
                    "name": "Office 办公室",
                    "description": "现代化办公室，包含 9 个功能区域：工作区、会议室、休息区、茶水间等。适合 5-8 人小镇。",
                    "rooms": [
                        {"name": "办公室A", "cx": 400, "cy": 335, "w": 120, "h": 70},
                        {"name": "办公室B", "cx": 550, "cy": 335, "w": 120, "h": 70},
                        {"name": "会议室",   "cx": 700, "cy": 335, "w": 100, "h": 70},
                        {"name": "开放工位", "cx": 400, "cy": 415, "w": 150, "h": 80},
                        {"name": "经理室",   "cx": 575, "cy": 415, "w": 90,  "h": 80},
                        {"name": "打印室",   "cx": 695, "cy": 415, "w": 80,  "h": 80},
                        {"name": "休息区",   "cx": 400, "cy": 485, "w": 120, "h": 70},
                        {"name": "茶水间",   "cx": 550, "cy": 485, "w": 120, "h": 70},
                        {"name": "前台",     "cx": 700, "cy": 485, "w": 90,  "h": 70},
                    ],
                },
                prefabs_json=[],
            ))
            db.commit()
            print("[seed] Office 预设地图 1 条")

        # seed 室外小镇预设 =「AI 造镇」：纯草坪空地图，建筑/路/房间全由两个建造工 NPC 言出法随自建。
        if not db.query(models.MapData).filter(
            models.MapData.town_id.is_(None),
            models.MapData.name == "室外小镇",
        ).first():
            db.add(models.MapData(
                town_id=None,
                name="室外小镇",
                chunk_json={
                    "name": "室外小镇",
                    "scene": "outdoor_town",  # 客户端按此选数据驱动场景（草地底 + tiles 重放）
                    "description": "纯草坪空地图：建筑/路/墙/家具全部由两个建造工 NPC 用 place_tile + place_prefab 自主建造。",
                    "rooms": [],  # 无预置房间，NPC 用 add_room 自建
                    "tiles": [],  # 纯草坪（无预置建筑），建筑全由 AI 建造
                },
                prefabs_json=[],
            ))
            db.commit()
            print("[seed] 室外小镇预设地图 1 条")

        # 预热敏感词内存缓存
        n = moderation.load(db)
        print(f"[moderation] 加载 {n} 条敏感词")

        # 初始化 embedding 服务（缓存 key + model；无 key 时降级）
        embedding.init(db)
        # 初始化审查 LLM 服务（缓存 review_api_key + model；无 key 时审查回退人工）
        review.init(db)


@app.get("/")
def root():
    return {"msg": "AI小镇 API", "admin_panel": "/adminpanel", "admin_api": "/admin"}


def _purge_chat_logs_once() -> int:
    """删 created_at 早于 chat_log_retention_days 的 chat_logs，返回删除条数。retention<=0 不删。"""
    with SessionLocal() as db:
        cfg = db.get(models.SysConfig, "chat_log_retention_days")
        try:
            days = int(cfg.value) if cfg and cfg.value else 30
        except (TypeError, ValueError):
            days = 30
        if days <= 0:
            return 0
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        deleted = db.query(models.ChatLog).filter(models.ChatLog.created_at < cutoff).delete(synchronize_session=False)
        db.commit()
        return deleted


async def _purge_loop():
    # ponytail: 单进程无锁的定时清理循环；多实例部署换 APScheduler + 分布式锁。每小时扫一次。
    while True:
        await asyncio.sleep(3600)
        try:
            n = await asyncio.to_thread(_purge_chat_logs_once)
            if n:
                print(f"[purge] 清理过期 chat_logs {n} 条")
        except Exception as e:  # noqa: BLE001 — 后台循环不能挂
            print(f"[purge] 清理失败：{e}")


@app.on_event("startup")
async def _start_purge_task():
    asyncio.create_task(_purge_loop())
