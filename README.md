# AI 小镇（AiXiaoZhen）

一个 **LLM 驱动的 AI 小镇模拟游戏**：玩家以上帝视角经营一座小镇，镇上的 NPC 由大语言模型驱动，拥有自主决策、记忆、社交关系与任务系统。

![tech](https://img.shields.io/badge/Godot-4.7-blue) ![tech](https://img.shields.io/badge/FastAPI-Python%203.11-green) ![tech](https://img.shields.io/badge/DB-PostgreSQL%20%2B%20pgvector-blue)

## ✨ 核心特性

- **上帝视角 + NPC 选中交互**：WASD 移动相机，点选 NPC 查看状态、指挥行动、强制对话（按住 T 点对方）
- **NPC 大脑**：25s 决策循环（LLM 两阶段决策：意图 → 复杂能力格式），状态涌现（情绪/健康衰减 ↔ LLM 恢复闭环），思想气泡与行为日志可视化
- **三层记忆**：全量对话流水 `chat_logs` / 向量摘要 `memory_vectors`(pgvector RAG) / 稳定事实 `core_memories_json`
- **联机**：WebSocket 实时中继（客户端权威），多端各跑自己带入角色的 Brain
- **言出法随**：LLM 自主摆放/删除家具，实时广播 + 落库恢复
- **导演模式**：房主控制天气/时间流速/世界观/新闻，虚拟时钟广播驱动 NPC 世界上下文
- **任务 / 关系 / 记忆植入**：完整任务系统（每日刷新 + LLM 生成）、动态关系图谱、核心记忆注入
- **管理后台**：sqladmin 中文化后台 + 内容审查（DFA 敏感词 + LLM 双信号）+ 封禁裁决 + 审计日志
- **BYOK（自带 Key）**：玩家自带 AI API Key，AES-256-GCM 加密存储，按角色可单独配置

## 🏗️ 技术架构

```
Godot 4.7 客户端 (microverse/)          FastAPI 后端 (backend/)
├─ 2D 小镇场景 / 相机                   ├─ REST API（认证/角色/地图/任务/交易/审查）
├─ NetworkNPCBrain（LLM 决策循环）  ⇄   ├─ WebSocket 中继 (/ws/town/{id})
├─ Lobby / OnlineWorld UI               ├─ sqladmin 管理后台 (/adminpanel)
└─ MCP Bridge（开发调试）               └─ PostgreSQL + pgvector（记忆 RAG）
```

**技术栈**：Godot 4.7.1（GDScript）· Python 3.11 + FastAPI · PostgreSQL + pgvector · WebSocket · Docker Compose · sqladmin

## 📁 目录结构

```
AiXiaoZhen/
├─ AI小镇游戏开发流程文档.md   # 设计 source of truth（架构 / 进度 / 路线图）
├─ backend/                    # FastAPI 业务层 + 数据库
│  ├─ app/                     #   main / models / routers / services
│  ├─ db/schema.sql            #   DDL 参考
│  └─ docker-compose.yml       #   PostgreSQL(pgvector)
├─ microverse/                 # Godot 客户端（KsanaDock/Microverse 二开）
│  └─ script/net/              #   联机层 / NPC Brain
├─ net_proto/                  # 网络协议原型
└─ docs/                       # 文档（内测玩家 BYOK 指南等）
```

## 🚀 快速开始

### 环境要求

- Godot 4.7+
- Python 3.11
- Docker（PostgreSQL）

### 启动

```bash
# 1. 数据库
cd backend && docker compose up -d
#   PostgreSQL 127.0.0.1:5432  db: aixiaozhen  user: aixiaozhen_dev

# 2. 后端（首次启动自动建表 + seed 管理员 admin/admin）
cd backend
python -m venv .venv && .venv/Scripts/pip install -r requirements.txt
.venv/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
#   Swagger    http://127.0.0.1:8000/docs
#   管理后台   http://127.0.0.1:8000/adminpanel

# 3. Godot 客户端（用 Godot 4.7 打开 microverse/project.godot）
```

### 配置 AI Key

后端首次启动前，在 `backend/` 复制并填写 `.env`（数据库连接、JWT 密钥、管理员配置的 embedding/AI Key）。玩家侧支持 BYOK——在游戏内「设置 → AI 配置」填入自己的 API Key（AES-256-GCM 加密落库，仅发起 AI 请求时解密使用）。

## 🗺️ 路线图

- [x] 阶段一：单机玩法 + 后端业务层
- [x] 阶段二：WebSocket 联机 + 管理后台 + NPC 大脑 + 纯上帝交互
- [ ] 混合权威（服务端校验 AI 行为合法性）
- [ ] 部署上线（Docker Compose：FastAPI + PG + Redis + Nginx → 阿里云 ECS）

详见 [AI小镇游戏开发流程文档.md](AI小镇游戏开发流程文档.md) §8。

## 📄 许可

仅供学习交流使用。
