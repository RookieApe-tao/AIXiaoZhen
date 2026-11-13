# AGENTS.md

## 项目上下文

**AI 小镇（AiXiaoZhen）**：Godot 4.x 2D 模拟经营/社交游戏 + FastAPI 后端。玩家为上帝视角，NPC 由 LLM 驱动决策。

- 技术栈：客户端 Godot 4.7.1（GDScript）；后端 Python 3.11 FastAPI + PostgreSQL(pgvector) + sqladmin；WebSocket 实时中继 + HTTP REST。
- 详细架构、进度、坑记录见 `CLAUDE.md`（与本文件同级，内容更全）。
- 设计 source of truth：`AI小镇游戏开发流程文档.md`——架构/模块决策变更须同步更新。

### 目录结构

```
AiXiaoZhen/
├─ AI小镇游戏开发流程文档.md   # 设计 source of truth
├─ CLAUDE.md / AGENTS.md       # 工作指引
├─ docs/                       # 文档（含 pitfalls.md 坑记录）
├─ backend/                    # FastAPI 业务层（app/ + db/ + docker-compose.yml + .venv/）
├─ microverse/                 # Godot 客户端（KsanaDock/Microverse 二开基线）
├─ net_proto/                  # 网络协议原型
└─ .gitignore / .mcp.json / HANDOFF.md
```

### 常用命令（开发环境）

```bash
# 1. 数据库（需 VPN）
cd backend && docker compose up -d          # PostgreSQL 127.0.0.1:5432 aixiaozhen/aixiaozhen_dev

# 2. FastAPI（首次启动自动建表 + seed admin/admin）
cd backend && .venv/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
#   Swagger http://127.0.0.1:8000/docs   管理后台 http://127.0.0.1:8000/adminpanel

# 3. Godot 客户端
"D:\Godot\Godot_v4.7.1-stable_win64.exe" --path <项目>\microverse
```

## 坑记录

**规则：遇到问题先读 `docs/pitfalls.md`；每次问题解决后，必须把坑（现象/原因/解决）追加进去。**

高频坑摘要（详见 `docs/pitfalls.md` 与 `CLAUDE.md`「关键坑」区块）：
- sqladmin mount 遮蔽 `/adminpanel/*` → 自定义审查路由用 `/manage/` 前缀。
- SQLAlchemy JSONB 嵌套 list 原地改不触发 UPDATE → 先 `copy.deepcopy`。
- GDScript 跨 `await`/Variant 运算须显式类型，否则整脚本编译崩；改 .gd 用内容匹配编辑，勿用 sed/行号。
- Godot F5 卡死 = 删 `.godot/uid_cache.bin`。
