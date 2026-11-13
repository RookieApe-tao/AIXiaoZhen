# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## 项目现状（2026-08-16）

阶段一完成 + 阶段二联机(WebSocket) + 管理后台 + NPC 大脑 + 纯上帝交互 + UI 改版 Phase A/B/C 完成。

- **交互模型**：玩家无自身 avatar，进镇默认上帝视角（WASD 移相机）；`selected_npc_name` 驱动所有面板。点 NPC 选中 / 点空地指挥走 / B 控制角色 / 按住 T 点对方强制对话。Lobby 角色多选 = 带入房间。
- **后端**：FastAPI + PostgreSQL(pgvector)，startup 自动建表（加列用幂等 `ALTER TABLE ... IF NOT EXISTS`）。sqladmin 挂 `/adminpanel`（已中文化），业务审查 `/admin/*`、封禁裁决 `/manage/*`（独立前缀避 sqladmin 遮蔽）。玩家+管理员双 bcrypt+JWT（单端登录 `token_version`）；BYOK AES-256-GCM 存 DB（`app/crypto.py`）。
- **审查**：DFA 敏感词 + LLM(qwen-plus) 双信号；建角色先玩后审（`is_active` 默认 true）；score<0.7 永不自动拒绝。
- **记忆三层**：`chat_logs`(全量流水) / `memory_vectors`(对话结束写摘要) / `core_memories_json`(稳定事实，全量注入 prompt)。embedding 管理员统一配（百炼 text-embedding-v3），不走玩家 BYOK。
- **联机**：WebSocket 中继（`ws://backend:8000/ws/town/{town_id}?token=JWT`），客户端权威（混合权威待做）。
- **NPC 大脑**（`script/net/NetworkNPCBrain.gd`）：25s 决策循环（open prompt→意图 JSON→执行），**两阶段决策**（stage1 瘦身返 action / stage2 `prompt_detail_*` 补复杂能力格式）；状态涌现（mood/health 衰减↔LLM 恢复闭环）；行为可见性（思想气泡/意图标签/行为日志侧栏）。**多端 own NPC**：每客户端跑自己带入角色的 brain（owner 门控 `pid==owner_id`），谁带的谁付 token。
- **言出法随**：LLM 自主放/删家具（`map_data` + `POST /maps/town/{id}/actions` + WS `map_update` 广播 + 进镇 `_load_map_from_backend` 恢复）。
- **导演模式**：房主=导演（改天气/时间流速/世界观/新闻+规则），虚拟时钟 5s tick 广播 `town_time`；`_world_context()` 注入时间/天气/世界观/新闻/规则（纯本地零 HTTP）。
- **任务/关系/记忆植入**：完整任务系统（队列+每日刷新+LLM 生成）；`relations_json`（动态更新+编辑面板）；记忆植入复用 core_memories。
- **每角色 AI 设置**：characters 三列 byok + `GET/PUT /characters/{id}/byok`，brain 6 处按角色名分流（`_parse_api_type(npc.npc_name)` → `get_character_ai_settings`，没配角色 fallback 全局）。
- **UI 改版**：MainTheme.tres 项目默认主题；字号 `theme.default_font_size`（管理员 sysconfig 默认 + 玩家按账号 `users.settings_json["ui"]` 覆盖）；面板动效 `_panel_open/_panel_close`；Lobby/OnlineWorld 静态壳迁 .tscn（`@onready` 收引用 + `_ready` 接信号，动态行留代码）。

### 关键坑（高频复发）

- **sqladmin `Admin(app,base_url)` mount 遮蔽 `/adminpanel/*` 的 404** → 自定义路由用 `/manage/`；主 app 手动装 `SessionMiddleware`。
- **`_wait_http` 用实例变量 `_hr_done/_hr_result`，不可并发**；决策-执行链用 `_waiting_response` 整周期持锁防重入。
- **Godot F5 卡死** = `.godot/uid_cache.bin` 与资源 UID 不一致 → 删 `uid_cache.bin` 重开；角色 `.tscn` 烘焙过期 `.ctex` 要重指向。**改 NPC 脚本后用 preload 探针强制 parse 验证**（主场景 Lobby 不懒加载 NPC 脚本，普通 headless 测不出 parse 错）。
- **编辑 .gd 用 search_and_replace（内容匹配），勿靠行号**；tab 缩进易错。Godot MCP `edit_script`→`confirm_and_execute` 有死循环 bug，改用本地 Edit 工具 + 精确 tab。**勿用 sed 改 .gd**。
- **GDScript 跨 `await` / Variant 运算必须显式类型**：`var x := await signal`、`var d := peer.position - npc.position`（peer 是 Variant）会推断失败 → 整脚本编译崩 → Brain 崩 → 所有 NPC 不决策。validate_scripts 在 autoload 环境漏报，**改完必须跑游戏看运行时日志**。
- **上帝模式 `_input` 吞左键 → 按钮点不动**：`OnlineWorld._input` 在 god_mode 对所有 `InputEventMouseButton` `set_input_as_handled()` 吞左键 → 面板弹不出。修：`if mb.button_index != MOUSE_BUTTON_LEFT` 才 handled。**输入顺序 `_input`→`_gui_input`，handled 阻断后续 GUI 分发**。
- **Godot 4 RichTextLabel bbcode 字号标签是 `[font_size=N]` 不是 `[size]`**（`[size]` 是 Godot 3 标签，4 代不认原文显示）。bbcode 没重解析就改 `clear()+append_text()`（仍需 `bbcode_enabled=true`）。RichTextLabel 在 VBox+expand 里别开 `fit_content`（高度塌缩到 0）。
- **滚轮缩放相机 vs 面板滚动**：`gui_get_hovering_control()` 只要鼠标下有任意非 IGNORE 控件就非空——PASS 级 HBox 铺满边缘，悬「空地」也命中。正解：沿 `get_parent_control()` 链向上找 **STOP 级**（面板/ScrollContainer/按钮）才算 UI。**4.7 方法名是 `gui_get_hovered_control`**。控制 NPC 时滚轮缩 `_controlled_camera()`（当前控制 NPC 的 Camera2D），不是 god_camera。
- **GDScript lambda 三连坑**：① 变量名撞内置方法（`var _set := func(...)` 被解析成 `Object._set`）——**别用 lambda，写普通 helper 方法**。② 跨文件 class_name 在 `--script` headless 探针下解析不稳，共享工具类用 `const X := preload(...)`。③ LineEdit/TextEdit 混用——回填 helper 参数标 `Control` + `edit.set("text", v)` 动态设。
- **RefCounted 静态入口 + 实例方法信号 = 死按钮**：`static func show()` 里 `var t := new()` 局部实例，函数返回即释放；`btn.pressed.connect(t._on_next)` 的 Callable **不强持有** RefCounted（探针实测 emit 后 fired=0）。ConfirmBox 能活是因为 lambda 捕获的是场景树持有的 Node。修：`layer.set_meta("tutorial", self)` 让节点挂住实例，layer 释放时一并释放（Tutorial.gd 现范例）。
- **ConfirmationDialog 是独立 Window 不吃项目 Theme**（黑底蓝字丑）。自制通用确认框 `script/ui/ConfirmBox.gd`（`show_confirm(parent, 标题, 正文, ok, 取消, 回调)`）——主题化 Panel + 半透明遮罩 + 平分按钮。
- **MCP Bridge secret 权限坑**：`icacls ...:R` 收紧只读后改 `:M` 旧文件不重建 → 写不进 secret → bridge abort。修：`icacls <file> /reset` 后删掉，重启客户端自动重建。排查用 `(Get-Acl <file>).Access`。
- **SQLAlchemy JSONB 浅拷贝坑（map_data tiles 不落库）**：`chunk = dict(map_row.chunk_json)` 是浅拷贝，`tiles = chunk.setdefault("tiles", [])` 拿到的是**原 list 引用**，原地 `append` 改了旧 chunk_json 的同一 list → 赋值时 SQLAlchemy 认为「没变」不 UPDATE。修：`copy.deepcopy`。**改任何 JSONB 嵌套 list 原地增删前，先 deepcopy 或用 `flag_modified`**。

### 待办

见 `AI小镇游戏开发流程文档.md` §8 路线图 + memory `aixiaozhen-todo.md`（未排期待办清单）。

> `AI小镇游戏开发流程文档.md` 是 **source of truth**——架构/模块决策先回查文档，变更同步更新。

## 目录结构

```
E:\AiXiaoZhen\
├─ AI小镇游戏开发流程文档.md   # 设计 source of truth（§5.7 后台 / §5.8 管理后台 / §8 路线图+进度）
├─ CLAUDE.md                  # 本文件
├─ .gitignore                 # 忽略 microverse/（独立 git 的二开基线）
├─ microverse/                # 二开基线（KsanaDock/Microverse，SSH clone，只读参考，已 gitignore）——联机层在 script/net/
└─ backend/                   # FastAPI 业务层 + DB（sqladmin 挂 /adminpanel，无独立容器）
   ├─ app/  (main.py / models.py / admin_panel.py / config.py / auth.py / crypto.py / moderation.py / constants.py / schemas.py
   │         routers/{admin,auth,characters,chat,memory,npc_logs,config,maps,tasks,towns,trades,ws}.py
   │         services/{embedding,review}.py)
   ├─ db/schema.sql           # DDL 参考（实际建表由 main.py create_all）
   ├─ docker-compose.yml      # postgres(pgvector)
   └─ requirements.txt / .env / .venv/
```

## 起服务（开发环境）

```bash
# 1. 数据库（需先开 VPN，Docker Hub 国内直连超时）
cd backend && docker compose up -d
#   PostgreSQL  127.0.0.1:5432   aixiaozhen / aixiaozhen_dev

# 2. FastAPI 业务层（首次启动自动建表 + seed sysconfig + seed admin admin/admin）
cd backend && .venv/Scripts/python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
#   Swagger  http://127.0.0.1:8000/docs   管理后台 http://127.0.0.1:8000/adminpanel（admin/admin）

# 3. Godot 客户端
"D:\Godot\Godot_v4.7.1-stable_win64.exe" --path E:\AiXiaoZhen\microverse
```

## 关键架构决策

- **管理后台 = sqladmin**（非 Directus）：挂同一 FastAPI（`/adminpanel`），零改动 CRUD + 字段中文；业务审查/管控 API 用 `/admin/*`（避免 /admin/login 冲突）。§5.8.3
- **embedding 管理员统一配**，不走玩家 BYOK（便宜+统一维度）；AI 对话推理才走玩家 BYOK。§5.7.4
- **建角色先玩后审**：`is_active` 默认 TRUE，审查异步；违规靠敏感词实时拦截。§5.8.2
- **PG+pgvector**（非 MySQL）：向量检索靠 pgvector 支撑记忆 RAG。
- **客户端权威 + AI 推理 BYOK**（混合权威是后续升级）。§2.1
- **sysconfig 表**：系统配置，默认值在 `backend/app/config.py`，启动 seed 缺失项。

## 环境注意事项（本机踩过的坑）

- **Docker Hub 需 VPN**；**DB 连接用 127.0.0.1**（非 localhost，避 IPv6 `::1`）；**GitHub 远程走 SSH**（HTTPS 被重置）。
- **Python 3.11**，`backend/` 用独立 `.venv`（不污染 conda）；**清华镜像装 pip**（PyPI 国内不通）。
- **Godot 4.7.1** 在 `D:\Godot\`。
- **Chrome DevTools MCP 可用**：可浏览器操作管理后台（http://127.0.0.1:8000/adminpanel，admin/admin）。
- **Godot MCP Bridge**：手动装在 microverse（`script/net/mcp_bridge.gd` autoload），监听 127.0.0.1:9081，secret 在 `.godot/mcp_bridge_9081.secret`；`confirm_and_execute` 有死循环 bug，抓 print 日志改用「Bash 起 Godot > 日志文件」再 tail。设 `GODOT_MCP_BRIDGE_PERSISTENT_SECRET=true` 固定 secret。

## 目标技术栈（以文档为准）

客户端 Godot 4.x（2D, GDScript）；后端 Python FastAPI（异步）；网络 WebSocket 中继（实时状态）+ HTTP REST（AI 网关/持久化）；DB PostgreSQL+pgvector；部署 Docker Compose（FastAPI + PG + Redis + Nginx），目标阿里云 ECS。

## 核心数据表（见 §6.3）

游戏：`users` / `characters` / `towns` / `rooms` / `map_data` / `chat_logs` / `memory_vectors`(pgvector) / `npc_logs` / `tasks` / `trades`
管理：`admins` / `prompt_reviews` / `audit_logs` / `sensitive_words` / `sysconfig`

## 开发约定

- **语言**：项目文档与提交信息用中文。
- **Token 安全**：玩家 BYOK Token AES-256 加密存储，仅发起 AI 请求时解密。
- **AI 输出校验**：服务器对 AI 行为结果做合法性/Schema/合规校验后再广播（不校验思考过程）。
- **改前台必查持久化**：改客户端任何功能，先判断是否要落库——**实时广播**（WS，位置/气泡，只过内存）vs **持久化**（HTTP→DB，对话/角色/记忆/行为日志）。只广播没落库 = 数据丢失。典型：说话既 WS 广播气泡、又 POST `/chat_logs` 落库、还 POST `/npc_logs` 落行为日志。
- **文档同步**：架构/模块决策变更，同步更新 `AI小镇游戏开发流程文档.md`。
- **验证/驱动 NPC 行为：改角色设定而非代码**：想让 NPC 回复/决策/关系演化按预期方向走，直接改 `characters.personality_json`（position/personality/speaking_style/work_duties/work_habits/gender/**crush**/**dislike**/notes）或 `relations_json` 基线——经 sqladmin / `PATCH /characters/{id}` / DB 脚本改，**重进镇生效**。thin 设定=泛回复；补 notes 或加 crush/dislike 钩子=回复有区分度、好感方向可观测。
