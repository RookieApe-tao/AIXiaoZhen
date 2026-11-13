# AI小镇游戏开发流程文档：打造涌现式社交模拟世界

## 一、项目概述

### 1.1 项目愿景与核心理念
本项目旨在打造一款基于"斯坦福小镇"理念的 2D AI 社交模拟游戏。核心理念为"人人皆可创造 AI 角色"，通过赋予 AI 角色记忆、情感与自主行为能力，让 AI 与 AI、AI 与人类之间产生不可预测的涌现性社交互动。项目采用 BYOK（Bring Your Own Key）模式，玩家自带 API Token，服务器仅作为数据中转与状态同步枢纽，确保低成本与高扩展性。

### 1.2 目标用户画像
- **核心玩家**：喜欢沙盒模拟、角色扮演及观察 AI 行为的硬核玩家。
- **内容创作者**：热衷于设定剧本、构建世界观、测试 AI 极限的"造物主"型玩家。
- **开发者 / 极客**：对 AI Agent、Prompt 工程及开源技术感兴趣的开发者。

### 1.3 核心卖点（USP）
- **零推理成本**：BYOK 模式免除服务器高昂的 GPU 推理费用，降低运营门槛。
- **言出法随的 AI 造物**：AI 不仅是 NPC，更是地图与规则的创造者。
- **涌现式社交生态**：流言、经济、悬疑等复杂社会行为由 AI 自发演化。

### 1.4 项目范围界定（MVP vs 完整版）
- **MVP 阶段**：实现基础 2D 小镇、角色创建、AI 对话、基础记忆系统、BYOK 网关及 5 人同服测试。
- **完整版**：支持 20 人同服、AI 地图生成、复杂经济系统、剧本杀模式、Steam 成就与云存档集成。

## 二、技术架构总览

### 2.1 整体架构描述
系统采用**混合权威（Hybrid Authority）架构**，按职责划分信任边界：

- **游戏状态层 —— 服务器权威（Server Authoritative）**：玩家位置、动作、地图状态、小镇配置等所有影响多人一致性与公平性的状态，均由 FastAPI 后端裁决与同步，服务器为唯一权威源；客户端的同类请求仅作预测 / 插值，最终以服务器为准，防止作弊与状态分叉。
- **AI 推理层 —— 客户端执行（BYOK）**：AI 的"思考"（生成对话、决策、记忆、地图指令等）由客户端使用玩家自带的 BYOK Token 直接调用大模型完成；服务器仅接收并广播 AI 产出的**行为结果**（如一句台词、一次移动决策、一条地图修改指令），不承载、也不转发完整的推理过程。
- **数据层**：状态与持久化数据写入 PostgreSQL，记忆向量写入 pgvector。

> **信任边界与升级路径说明**：服务器不对 AI 的"思考过程"做权威校验，但会对 AI 输出的"行为结果"做合法性与合规性校验（移动是否合法、是否触发敏感词、是否符合 Schema 等）。这意味着 AI 行为的可信度依赖客户端，适用于"信任房主与玩家"的合作 / 沙盒场景。若未来需要强竞技或更强反作弊，可将 AI 推理迁移至服务器端——**BYOK 模式同样支持由服务器代为调用玩家 Token 计费，成本仍由玩家承担**，因此架构升级路径清晰，不构成对 BYOK 的破坏。

### 2.2 技术栈选型与理由
- **游戏引擎**：Godot 4.x（2D）。轻量级，GDScript 开发效率高，对开源生态支持极佳。
- **后端框架**：Python FastAPI。异步非阻塞，契合高并发 AI 网关代理与状态同步。
- **网络协议**（双通道）：
  - **实时状态同步**：UDP（ENet），保障 20 人同服下移动与状态同步的低延迟。
  - **AI 网关通信**：HTTP（REST / SSE 流式），客户端 ↔ FastAPI 网关 ↔ 大模型。
- **数据库**：PostgreSQL + pgvector。关系型数据与向量检索一体化，降低运维复杂度。

### 2.3 核心模块划分
包含角色编辑器、AI 对话与记忆系统、AI 地图生成系统、小镇生命周期管理、AI 网关代理、用户与权限系统。

### 2.4 数据流向说明
- **玩家输入流**：玩家输入 → Godot 客户端 → ENet → FastAPI 后端 → 校验与状态更新 → 写入 PostgreSQL → 广播给客户端。
- **AI 行为流**：触发 AI 行为 → 客户端用 BYOK Token 调用大模型（经 AI 网关路由）→ 解析 JSON / 文本响应 → 将"行为结果"提交服务器校验 → 服务器更新世界状态并广播。

## 三、核心玩法设计

### 3.1 角色创建系统
提供可视化捏脸与装扮系统。核心在于"灵魂注入"：通过性格测试或自由文本，利用 Prompt 模板自动生成角色的 System Prompt 与核心记忆，确保 AI 行为符合设定。

### 3.2 小镇管理系统
房主拥有"造物主"权限，可实时调整天气、时间流速与环境参数。其他玩家仅能创建并控制自己的 AI 分身。

### 3.3 AI 社交模拟
内置流言制造机与情绪系统。AI 会根据对话内容生成"流言"标签并在社交网络中传播；情绪值影响对话倾向与行为决策。

### 3.4 AI 地图创造
支持 AI 造物主模式。AI 通过输出受约束的 JSON 数据，动态修改 TileMapLayer 或实例化 PackedScene 预制体，实现"言出法随"的私人领地生成。

### 3.5 经济与生存系统
引入信息差赚钱机制。AI 对特定物品有动态需求，玩家可利用信息差进行倒卖；支持 NPC 雇佣系统，玩家可支付游戏币让 AI 执行特定任务。

### 3.6 剧本杀与解谜模式
支持人类主导的剧本杀流程。引入"记忆黑客"玩法，允许特定角色篡改或读取其他 AI 的记忆碎片，推动悬疑剧情。

### 3.7 观察模式（楚门的世界）
提供不干预观察视角。玩家可切换为纯观察者，记录 AI 在天灾、恩赐等极端环境下的生态演化与应激反应。

## 四、开源项目集成指南

### 4.1 Microverse 集成方案
- **集成方式**：作为核心框架直接 Fork 并二次开发。
- **保留模块**：情绪状态机、自主行为决策（任务 / 对话 / 移动）、多模型适配层（`APIConfig`，在客户端完成）、对话气泡 UI。
- **改造方向**：① **记忆系统需重做**——现状为内存级 `Node meta` + 关键词子串匹配，无 Embedding / 向量检索 / 持久化，需自建 embedding + pgvector；② 本地 JSON 存储迁移至 PostgreSQL；③ 单机架构改造为混合权威多人；④ 多人对话广播。
- **架构澄清**：Microverse 的 LLM 调用已是"客户端用 api_key 直连厂商"（`APIManager` + `APIConfig`），即 BYOK 客户端执行，**非本地推理**，无需"剥离本地 LLM 推理逻辑"。

### 4.2 Godot-MCP 集成方案
利用 Model Context Protocol，让 AI 通过标准接口直接操作 Godot 场景树。主要用于 AI 地图生成模块，实现 TileMap 的动态绘制与物件摆放。

### 4.3 其他参考项目价值
- **Nobody**：参考其本地 LLM 对话插件的上下文管理策略。
- **AI Town（a16z）**：重点参考其角色身份设定、计划生成（Reflection / Planning）及记忆检索的学术级实现逻辑。

### 4.4 重新开发 vs 基于开源二开评估

#### 4.4.1 核心对比：二开 vs 从零开发

| 维度 | 基于 Microverse 二开 | 从零开发 |
|------|---------------------|---------|
| AI 社交模拟 | 部分实现（对话/情绪/任务完整；记忆仅内存级关键词匹配，需重做） | 需从零搭建，最耗时 |
| 多人联机 | 无（单机上帝视角） | 需从零搭建 |
| 角色编辑器 | 无 | 需从零搭建 |
| 地图生成 | 有 TileMap 基础，但无 AI 生成 | 需从零搭建 |
| 多模型支持 | 已支持 OpenAI/Claude/DeepSeek/Kimi/Ollama 等 | 需从零适配 |
| BYOK 网关 | 无 | 需从零搭建 |
| 代码可控性 | 需理解他人代码，改造有约束 | 完全自主，架构随意调整 |
| 预估开发周期（MVP） | 6–8 周 | 14–18 周 |
| 许可证风险 | MIT，可商用 | 无风险 |

#### 4.4.2 结论：推荐基于 Microverse 二开
1. **AI 社交模拟是项目最复杂的模块**：Microverse 已实现多智能体自主行为（移动、对话、任务、情绪）、多模型适配（`APIConfig` 在客户端适配 OpenAI、Claude、DeepSeek、Kimi、Ollama 等）、对话气泡 UI + 多轮交互——可直接复用。**但记忆系统需重做**：现状为内存级 `Node meta` 存储 + 关键词子串匹配检索，**无 Embedding、无向量检索、不持久化**（`GameSaveManager` 存档不含记忆字段，重启即丢），需自建 embedding 生成 + pgvector 存储 + 向量检索 + 持久化。综合评估，二开仍比从零省时（行为 / 对话 / Prompt / 多模型适配可复用），但"记忆系统"工作量需单列，不能笼统计入"可跳过"。
2. **需新增模块边界清晰**：多人联机（Godot 内置 ENet + RPC）、角色编辑器 UI（Godot 原生控件）、BYOK 网关（FastAPI + LiteLLM 独立服务）、房主权限系统（天气 / 时间 / 环境编辑）。这些模块与 Microverse 原有 AI 社交逻辑松耦合，无需改动其核心 AI 代码，仅需在外层封装联机与用户系统。
3. **已有可行性验证**：已有案例将 Microverse 多智能体逻辑拆分为独立插件，与联机底座合并，实现多人联机 + AI 社交，说明其代码结构支持此类改造。
4. **个人开发者时间最稀缺**：二开省下的 6–8 周 AI 开发时间，可投入到真正差异化的功能：角色编辑器体验、多人房间管理、AI 地图生成的玩法设计。

#### 4.4.3 需关注的风险
- **风险一：Microverse 为单机架构，联机改造量较大**  
  Microverse 目前是"上帝视角单机模拟"，需改造为"20 人客户端-服务器"模式。本方案采用**混合权威**：AI 推理保留在客户端（BYOK），服务器对位置、地图、配置等状态保持权威以防止作弊，并处理多玩家并发的 AI 行为结果。详见 §2.1。
- **风险二：数据存储为本地 JSON**  
  需将本地 JSON 存储替换为云端 PostgreSQL + pgvector，改造量中等、逻辑清晰。
- **风险三：Microverse 项目活跃度**  
  Microverse 已有 Steam 页面（App ID: 3902630），作者持续开发。需关注其更新频率，若停更则自行维护 fork。采用下文"插件化拆分"策略可降低此类依赖风险。

#### 4.4.4 落地策略（已实施）
基于 Microverse 二开：联机层独立在 `microverse/script/net/`（WebSocket 中继），AI 网关在 `backend/`（FastAPI），不直接改 Microverse 核心——即使其停更，核心架构不受影响，仅需替换 AI 插件。

## 五、核心模块详细设计

### 5.1 角色编辑器（Character Creator）
- **前端 UI**：分为外观、性格标签、背景故事、核心记忆四个 Tab。
- **后端数据结构**：采用 JSON Schema 定义，包含 `appearance`、`personality_traits`、`background`、`core_memories` 字段。
- **Prompt 生成**：后端接收表单数据，拼接 System Prompt 模板，生成结构化角色设定。

### 5.2 AI 对话系统
- **BYOK 请求流程**：客户端 / 后端获取用户加密 Token → 组装 Messages → 路由至对应模型提供商 → 流式返回。
- **多模型适配**：设计统一接口 `BaseLLMProvider`，实现通义千问、智谱、Kimi、DeepSeek、Ollama 等 Adapter。
- **记忆管理**：短期对话保留最近 N 轮 Context；长期记忆通过 Embedding 存入向量库，对话前进行 RAG 检索。
- **安全过滤**：在网关层增加敏感词与合规性校验中间件。

### 5.3 地图生成系统
- **动态生成逻辑**：AI 输出 JSON 格式的地图指令（如 `{"action": "place_tile", "pos": [x,y], "type": "grass"}`）。
- **Prompt 约束**：在 System Prompt 中严格限定 JSON Schema，并提供 Few-Shot 示例。
- **预制体管理**：将常用建筑、地形封装为 PackedScene，AI 仅传递参数。

### 5.4 记忆系统
- **向量库集成**：使用 pgvector 扩展，在 PostgreSQL 中直接存储 Embedding。
- **读写机制**：对话结束后异步提取关键事实写入向量表；检索时结合时间衰减与相关性打分。
- **情绪关联**：高情绪强度的记忆赋予更高权重，更易被召回。

### 5.5 小镇管理系统
- **生命周期**：基于 Redis 或内存管理房间状态，支持创建、销毁、暂停。
- **权限系统**：基于 RBAC 模型，区分造物主、居民、观察者。
- **状态同步**：20 人上限，ENet 协议每 100ms 同步一次关键状态（位置、动作、天气）。

### 5.6 AI 网关
- **统一接口**：`POST /v1/chat/completions`，兼容 OpenAI 格式。
- **模型适配**：内置国内主流模型 API 转换层。
- **限流防刷**：基于用户 Token 与 IP 的滑动窗口限流，防止 API 费用失控。

### 5.7 后台系统设计

> 依据 Microverse 代码审查结论（客户端已用 `APIConfig` 直连各 LLM 厂商，BYOK 客户端执行天然成立）与 §2.1 混合权威架构界定。本节是服务端落地蓝图。

#### 5.7.1 后端职责：三件事，不做 AI 推理

| 层 | 职责 | 是否承载 LLM |
|---|---|---|
| 状态权威层 | 位置 / 动作 / 对话 / 地图 / 小镇配置的裁决与广播（防作弊、防分叉） | 否 |
| 数据持久化层 | `users` / `characters` / `towns` / `map_data` / `chat_logs` / `memory_vectors` 的 CRUD | 否 |
| 记忆检索层 | `memory_vectors` 的向量近邻检索（pgvector） | 否 |

LLM 推理全程在客户端（BYOK）。**后端零 GPU、零推理成本**，仅做状态同步、数据路由与行为结果校验。AI 网关（§5.6）降为可选，MVP 跳过。

#### 5.7.2 服务模块划分（FastAPI）

| 模块 | 职责 | 关键端点 |
|---|---|---|
| 认证 | 注册 / 登录 / JWT、RBAC（造物主 / 居民 / 观察者） | `POST /auth/register` `POST /auth/login` |
| 小镇 | 创建 / 列表 / 详情 / 更新 / 软删除；`towns` 是持久世界配置，`rooms` 是运行时会话（room 通过 `town_id` FK 归属小镇） | `POST /towns` `GET /towns` `GET /towns/{id}`（含 active_room） `PATCH /towns/{id}` `DELETE /towns/{id}` |
| 房间 | ENet 联机会话登记；房主开房登记、列表浏览、状态变更（waiting→playing→closed/banned） | `POST /rooms`（含 `town_id`） `GET /rooms` `GET /rooms/{id}` `PATCH /rooms/{id}` |
| 角色 | 角色 JSON 设定 CRUD、所有者绑定 | `GET/POST /characters` |
| 记忆 | 写入（含 embedding）、向量检索 | `POST /memories` `POST /memories/search` |
| 对话日志 | `chat_logs` 持久化、回放（按 `room_id` 隔离） | `POST /chat_logs` `GET /chat_logs?room_id=` |
| 行为校验 | AI 行为结果的 Schema / 合法性 / 合规校验后入广播队列 | `POST /towns/{id}/actions`（待实现） |

#### 5.7.3 双通道（§2.2 落地）

- **HTTP（REST，FastAPI）**：认证、CRUD、记忆写入 / 检索、行为结果提交，请求需 JWT。
- **ENet（Godot 内置）**：实时状态同步。客户端发输入 → 服务器裁决 → 每 ~100ms 广播权威状态（位置 / 动作 / 对话气泡）给同房 20 人。

#### 5.7.4 记忆系统后端（对应 §5.4 重设计，关键）

记忆是后端做向量检索的环节。**embedding 由管理员统一配置**（`admin_settings` 里的全局 embedding 模型 + API Key，默认通义 `text-embedding-v3`、1024 维），**不走玩家 BYOK**——理由：embedding 极便宜（相比 AI 对话推理可忽略），管理员包下来换取所有记忆维度统一、pgvector 单列检索不乱；贵的 AI 对话推理才走玩家 BYOK。

- **写入**：客户端 `POST /memories`（content + character_id + importance）→ 后端调全局 embedding 模型生成向量 → 存 `memory_vectors`。
- **检索**：客户端 `POST /memories/search`（query_text + top_k）→ 后端生成查询向量 → pgvector 近邻搜索，按 `重要性 × 时间衰减 × 相似度` 打分返回。
- 客户端只传文本，向量计算全在后端。

#### 5.7.5 AI 行为结果校验与广播（§2.4 落地）

```
客户端 BYOK 调 LLM → 产出行为结果（台词 / 移动决策 / 地图指令）
  → POST /towns/{id}/actions（服务器校验：Schema 合法性 + 移动可达性 + 敏感词合规）
  → 通过 → 写 chat_logs / 更新权威状态 → ENet 广播同房客户端
  → 不通过 → 拒绝回错（客户端降级为默认行为，参照 AIAgent._execute_default_decision）
```

服务器**不校验 AI 思考过程**，只校验行为结果。

#### 5.7.6 多小镇架构（2026-08-12 落地）

**模型关系**：`towns` 是持久世界配置，`rooms` 是运行时会话。一个 town 同时最多 1 个活跃 room（`rooms.town_id` FK）。

```
towns (持久世界)          rooms (运行时会话)
┌─────────────────┐       ┌─────────────────┐
│ id              │◄──────│ town_id (FK)    │
│ creator_id      │       │ host_id         │
│ name            │       │ port            │
│ config_json     │       │ config_json     │
│ weather         │       │ status          │
│ time_scale      │       │ ban_reason      │
│ status          │       │ created_at      │
└─────────────────┘       └─────────────────┘
```

**客户端流程**（Lobby）：
1. 登录 → 拉角色列表 + 拉小镇列表
2. 选小镇 → 查看详情（含 `active_room`）
3. 有活跃房间 → 加入（ENet 直连 host:port）
4. 无活跃房间 → 开房（POST `/rooms` 带 `town_id`）
5. 创建小镇 → 弹面板填名称/描述 → POST `/towns`

**API 汇总**：
| 端点 | 说明 |
|---|---|
| `POST /towns` | 创建小镇（name + config_json） |
| `GET /towns` | 列表（默认 active，可 ?status=） |
| `GET /towns/{id}` | 详情 + active_room |
| `PATCH /towns/{id}` | 更新（仅创建者） |
| `DELETE /towns/{id}` | 软删除（仅创建者） |
| `POST /rooms` | 开房（新增 `town_id` 字段） |
| `GET /rooms?town_id=` | 按小镇过滤房间 |

**数据隔离**：角色/对话/记忆当前按 `room_id` 隔离，后续可按 `town_id` 跨会话聚合。

#### 5.7.7 多人化改造硬骨头（源自代码审查 §5.7 对应）

| Microverse 现状 | 多人化改造 |
|---|---|
| `CharacterManager` 单机上帝视角，所有角色在 `controllable_characters` 组可任意点选 | 区分"本地玩家角色"与"远程镜像"，控制权收归本地玩家自有角色；点选 / 移动走 ENet 请求服务器裁决 |
| 状态散落 `get_meta`（money / mood / health / relations / tasks / memories） | 统一为角色数据模型，权威副本在服务器 DB，客户端持缓存 |
| 三套 memories 写入不一致（MemoryManager / DialogManager / AIAgent 各写不同结构） | 记忆系统重设计时统一为单一结构（§5.4），经后端 `memory_vectors` |
| 对话距离 / 感知半径硬编码多处（100 / 200） | 空间判定移至服务器权威 |
| AI 每 60s / 角色决策 | 并发行为结果校验需异步 + 限流 |

#### 5.7.7 MVP 最小后端集 与 升级路径

- **MVP（5 人同服）**：认证 + 小镇 / 角色 CRUD + ENet 状态同步 + 记忆向量存储 / 检索 + 行为校验。**不含 AI 网关**（客户端直连厂商）。
- **升级路径**：若需强反作弊或统一限流 / 合规，启用 AI 网关（§5.6）——客户端只需把 `APIConfig` 指向自建网关（`OpenAICompatible` provider 已支持自定义 endpoint，**客户端零代码改动**），由网关代调玩家 BYOK Token，成本仍归玩家，不破坏 BYOK。

### 5.8 管理后台（绝对掌控层）

> 定位：区别于 §5.7 面向**玩家**的游戏后端 API，本节是面向**运营管理员**的全量掌控控制台。管理员对游戏内所有实体拥有**超越所有者**的读写控制权——这是「端到端玩家流程」之外的管理面，确保运营对游戏世界有绝对掌控。

#### 5.8.1 掌控范围（管理员对每个实体的操作）

| 实体 | 查看 | 编辑 | 删除/重置 | 实时控制 |
|---|---|---|---|---|
| 用户 | 列表/搜索/详情 | 改角色(造物主/居民/观察者)、改权限 | 封禁/解封 | 重置 BYOK Token、强制下线 |
| AI 角色 | 设定 JSON、System Prompt | 编辑设定/Prompt | 删除 | 启停、强制改状态(位置/情绪) |
| 记忆 | 搜索 memory_vectors | 编辑记忆内容 | 删除单条/批量清除 | 重置某角色全部记忆 |
| 对话 | 全量 chat_logs | — | 删除违规 | 强制结束进行中的对话 |
| 小镇 | 配置/成员 | 改天气/时间/环境参数 | 销毁 | 暂停/踢人 |
| 服务器 | 在线玩家、活跃对话、资源 | — | — | 运行状态监控 |

#### 5.8.2 提示词审查工作流（建角色 + 运行时，AI 审查 + 人工审查）

两层串联：
1. **自动层**：本地敏感词 DFA 预筛 → **AI 审查**（LLM 对内容打违规标签 + 0–1 可疑度评分）
2. **人工层**：管理员复核队列 → 通过 / 拒绝 / 编辑后放行

触发点：
- **建角色**：玩家提交的性格/背景/System Prompt → 入 `prompt_reviews`（type=system_prompt）→ 自动层审查 → 高分进人工队列。**先玩后审**：角色立即可用（`characters.is_active=TRUE`），审查异步进行，发现问题再封禁 / 编辑 / 下线。
- **运行时**：AI 产出的台词/行为结果 → 实时敏感词拦截 + 异步 AI 审查 → 可疑入队列（type=chat_output）

处置规则：敏感词命中或 AI 高分 → 阻断或标记入人工队列；人工通过→放行，拒绝→阻断并通知玩家，编辑→改后放行。

AI 审查模型：管理员在后台配置专用 API Key（独立于玩家 BYOK），不占玩家额度。

> **落地（2026-08-12）**：自动层已接真实 qwen-plus——`services/review.py`（urllib 调 dashscope OpenAI 兼容 chat 端点），`_create_review` 用 `score=max(dfa_score, llm_score)`（DFA+LLM 双信号），`review_enabled 且 key 配通 且 score<阈值(默认0.7)` **自动通过**（写审计 `auto_approve_review`），否则进人工队列；**永不自动拒绝**（防 LLM 误封）。chat_logs 实时标记仍走 DFA（每句调，便宜）。已验证：良性 score=0.0 自动通过、涉暴犯罪 score=1.0 进队列。

#### 5.8.3 技术形态：sqladmin（挂 FastAPI `/adminpanel`）

> 形态已从 Directus 换成 **sqladmin**（Directus 中文字段名支持差且太重）。sqladmin 连同一 FastAPI + PostgreSQL，业务表零改动 CRUD、字段中文（column_labels）、session 鉴权复用 admins 表。审查队列/封禁/权限等增强见 §5.8.6。业务审查与管控 API 走 `/admin/*` 与 `/manage/*`（独立前缀，免被 sqladmin mount 子应用遮蔽）。

#### 5.8.4 数据表（扩展 §6.3）

- `prompt_reviews`（新）：审查队列 — type、target_id、content、ai_score、ai_tags、status(pending/approved/rejected/edited)、reviewer_id、reviewed_at
- `audit_logs`（新）：管理操作审计 — admin_id、action、target_type、target_id、before、after、at（仅追加，不可删）
- `sensitive_words`（新）：敏感词库 — word、category、level、enabled
- `admin_settings`（新）：AI 审查配置 + 全局 embedding 模型配置 — 审查模型/Key/阈值、embedding 模型/Key
- 扩展：`users` 加 role/status/banned_at；`characters` 加 review_status + is_active（先玩后审）

#### 5.8.5 安全与隔离

- 管理后台（Directus，8055 端口）独立鉴权：Directus 管理员账号（`directus_users`）+ 细粒度 RBAC，与玩家 JWT 隔离
- **所有**管理操作写 `audit_logs`（不可删，仅追加），可追溯
- 危险操作（删除/封禁/记忆重置）二次确认 + 软删除优先
- 管理后台不裸暴露公网：IP 白名单 / VPN（§7.4）

#### 5.8.6 管理后台增强（2026-08-12，sqladmin 落地）

> 形态已从 Directus 换成 sqladmin（§5.8.3）。本次增强围绕"看得清、改得对、控得住"，**零 DB 迁移**——全是 ORM 声明 / sqladmin config / 新路由 / sysconfig seed。

- **ID→名（读时连表，不冗余存名）**：`models.py` 给被引用模型加 `relationship()` + `__str__`；sqladmin 外键列（创建者/房主/归属用户/所在小镇/说话者/听众/审查员/操作管理员/角色）显示关联名而非裸 ID。API `ChatLogOut` 补 `speaker_name/listener_name/room_name`（`routers/chat.py` 批量解析免 N+1）——客户端对话面板 `_char_names` 改由后端返回，一劳永逸。
- **下拉 + 中文**：枚举字段（`users.role/status`、`characters.review_status`、`rooms/towns.status`、`prompt_reviews.type/target_type/status`、`admins.role`、`sysconfig.value_type`）`form_choices` 变下拉、`column_formatters` 显示中文；常量集中到 `constants.py` 的 `*_CHOICES`/`*_LABELS`。
- **批量删除 / 对话清空**：sqladmin 列表勾选批量删（`can_delete=True`）；对话日志加 `@action`「删除选中」「清空全部」（写 audit）。
- **封禁补齐**：`/manage/user/{id}/ban`（封/解，`++token_version` 挤掉在线端，`get_current_user` 加 `status==banned`→403 让封禁即时生效）、`/manage/town/{id}/ban`（封后 `ws_manager.kick_town` 推 `kick_all` 给该镇所有在线 WS peer，客户端 `_do_kick` 自关连接回大厅；WS 连接时校验 `status==banned`→close 4003 防重入）；UserAdmin/TownAdmin 列表加按钮。房间封禁（`/manage/room/{id}/ban`）已有。
- **定时清理**：sysconfig `chat_log_retention_days`（默认 30）；startup 起 asyncio `_purge_loop` 每小时删过期 chat_logs（单进程无锁，多实例换 APScheduler + DB 锁）。
- **权限（评估：不上完整 RBAC，YAGNI）**：`admins.role` 仅 `super/reviewer` 二值。`_RoleGatedView.is_accessible` 读 session role，`_super_only` 隔离 管理员/系统配置/敏感词/审计 四个视图——reviewer 只能审查 + 封禁运营。当前规模二值角色够用；规模化（多团队、细粒度权限）再上角色-权限 m:n。
- **鉴权（评估：JWT+session 够用，补 CSRF）**：`/admin/*` 走 admin JWT bearer（浏览器不会自动携带，天然免 CSRF）；`/adminpanel/*` + `/manage/*` 走 session cookie——`/manage/*` 的状态变更 POST 加 `_require_same_origin`（Origin/Referer host 不符则 403）。rate-limit / IP 白名单判定 YAGNI（dev），生产由 Nginx 限流 + 改默认 `admin/admin`。
- **未验证（待回归）**：下拉/中文/名字列肉眼验、reviewer 看不到 super_only 视图、用户封禁后旧端被踢、purge 实删数据。

## 六、数据库选型评估

### 6.1 方案对比
- **PostgreSQL + pgvector**：关系型 + 向量一体，事务支持好，运维成本低。（推荐）
- **MongoDB + 向量插件**：Schema 灵活，但复杂查询与事务支持较弱。
- **Supabase / Firebase**：BaaS 服务，开发快，但 BYOK 模式下数据隐私与成本控制受限。

### 6.2 推荐方案及理由
推荐 PostgreSQL + pgvector。个人开发者应尽量减少维护的数据库实例数量。PG 既能处理用户、小镇等关系数据，又能高效处理记忆向量，且阿里云 RDS 支持良好。

### 6.3 核心数据表设计
- 游戏：**users**（用户、加密 Token、BYOK）/ **characters**（人设 personality_json、所有者、审查状态）/ **towns**（小镇）/ **rooms**（房间会话、status、config_json）/ **map_data**（地图区块+预制体，预设/小镇 1:1）/ **chat_logs**（对话流水，town_id 隔离）/ **memory_vectors**（记忆向量 pgvector）/ **npc_logs**（NPC 行为日志：决策/独白/移动等）/ **tasks** / **trades**。
- 管理：**admins** / **prompt_reviews**（审查队列）/ **audit_logs** / **sensitive_words**（DFA 词库）/ **sysconfig**（系统配置，默认值在 `config.py`）。

## 七、服务器与部署方案

### 7.1 BYOK 架构下的服务器角色
服务器不再是算力中心，而是状态同步中心与数据路由中心。无需 GPU，重点保障 CPU 单核性能与网络带宽。

### 7.2 阿里云部署方案
- **ECS 选型**：4 核 8G 或 8 核 16G 计算型实例（如 c7），普通 SSD 云盘。
- **网络配置**：5Mbps–10Mbps 按量付费带宽，绑定弹性公网 IP。
- **安全组**：仅开放游戏端口（UDP）、API 端口（TCP 443/80）及 SSH。

### 7.3 容器化部署
使用 Docker Compose 编排：FastAPI 服务、PostgreSQL、Redis、Nginx 反向代理。便于本地开发与云端一键部署。

### 7.4 安全与监控策略
- **Token 安全**：用户 API Token 使用 AES-256 加密存储，仅在发起 AI 请求时解密。
- **防刷机制**：网关层限制单 Token 每分钟请求数。
- **监控**：接入阿里云云监控，配置 CPU、内存、带宽告警；FastAPI 接入 Prometheus 记录 API 延迟与错误率。

## 八、开发路线图

> **实现进度（2026-08-16 更新，任务级状态见 §8.y 表，完整流水账见 git commit）**
> - ✅ 阶段一（08-11）：Microverse 单机跑通、代码审查、后台设计（§5.7/§5.8）
> - ✅ 阶段二·基建（08-11）：`net_proto/` 联机骨架 + DB schema（PG+pgvector 11 表自动建表）+ FastAPI 业务层
> - ✅ 阶段二·业务 MVP（08-11）：#10 提示词审查 + #11 管理掌控（bcrypt+JWT / DFA 敏感词 / 审查全链路 / 封禁）
> - ✅ #7 记忆系统 + 玩家鉴权（08-11）：RAG（embedding→pgvector→三维重排）+ 角色 CRUD + 所有权
> - ✅ Microverse 联机 MVP（08-11）：Lobby + OnlineWorld + NetworkPlayer（客户端权威，混合权威后置）
> - ✅ AI 对话闭环 MVP（08-11）：手动/自主说话，双通道（气泡广播 + `chat_logs` 落库）
> - ✅ 多小镇架构（08-12）：towns 持久世界 + Lobby 小镇列表
> - ✅ WebSocket 联机迁移（08-12）：WS 中继替代 ENet，18 项测试通过
> - ✅ 两阶段决策 prompt（08-13）：stage1 瘦身 + stage2 detail，prompt 省 64%
> - ✅ UI 打磨 + 交互增量（08-15）：滚轮缩放/气泡截断/天气中文化/AI 优化按钮/ConfirmBox
> - ✅ 低状态恢复闭环 + 双窗同步（08-15，e2e）：mood/health 恢复通路 + 气泡跨端定位 + 移动插值
> - ✅ 跨 owner 守卫 + 意图跨端 + 上帝点击（08-15，e2e）：post_* 守卫 / intent 广播 / 点选指挥
> - ✅ AI 设置下拉 + 体验修（08-16）：① AI 类型下拉改遍历 `SettingsManager.api_types`（=APIConfig 注册表全量，不再硬编码脱节）+ 注册表新增 **DashScope** provider（修 DB `byok_api_type=DashScope` 时预选回落 Ollama 的「预选不从数据库加载」）；② OpenAICompatible 选型时新增「请求地址」LineEdit 存 `custom_api_url`，`APIConfig.get_url` 非空直用、APIManager 发请求时传入；③ 上帝相机改纯 WASD 全时可控（不跟选中 NPC）；④ 对话记录面板「看不到刷新」根因修——5s 定时刷新重建列表后 ScrollContainer 回顶而后端按时间升序（最新在最底），修为刷新后等一帧滚到 max_value；⑤ 植入记忆保存改 `await post_core_memories` 后再刷列表（修异步 fire-and-forget 读旧缓存）；对话记录 / NPC 日志面板维持 **limit=50**（降服务器压力，后端默认 50、上限 200）
> - ✅ 后续功能（08-13~16，详见 §8.y 表）：言出法随 / 任务系统 / relations / 记忆植入 / 多端 own NPC / 每角色 AI / UI 改版 A·B·C / T-L 对话
> - ⏳ 教程系统（待做，设计已定）：Lobby 小镇列表页新手引导，6 步（账号角色→小镇→上帝视角 WASD/滚轮/拖拽→交互点选/指挥/B 控制/T 强制对话→面板→导演模式）；首次自动弹出、可跳过、帮助可重复；纯客户端零后端。
> - ⏳ 待办清单：见 §8.y 任务池 + memory `aixiaozhen-todo.md`
> - ✅ 关键决策变更：sqladmin、embedding 统一配、先玩后审、PG+pgvector、多小镇

### 阶段一：Microverse 代码熟悉与环境搭建（第 1–2 周）
- **目标**：跑通 Microverse 单机版，搭建开发环境。
- **任务**：Fork Microverse 项目，搭建 Godot 4.x + Python 开发环境。
- **任务**：完整跑通 Microverse 单机版，理解代码架构（AI 行为树、记忆系统、对话系统、情绪状态机）。
- **任务**：分析 Microverse 的本地 JSON 存储逻辑，规划 PostgreSQL + pgvector 迁移方案。
- **任务**：搭建 FastAPI 基础框架，实现 BYOK Token 加密存储与 LiteLLM 转发原型。
- **任务**：创建 Steamworks 开发者账号与 Steam 商店页（胶囊图、描述、标签），尽早开启愿望单积累（对齐 §9.1 第一层）。
- **验收**：本地可运行 Microverse 单机版；FastAPI 能使用用户 Token 转发 AI 请求；Steam 商店页上线。

### 阶段二：核心改造 —— 单机转联机与数据库迁移（第 3–6 周）
- **目标**：将 Microverse 单机架构改造为 20 人客户端-服务器模式。
- **任务**：落地 §2.1 的混合权威架构 —— 服务器对位置 / 地图 / 配置等状态保持权威以防止作弊；AI 推理保留在客户端（BYOK 天然支持），服务器负责状态同步与行为结果校验。
- **任务**：实现 Godot 内置 ENet + RPC 多人同步（位置、动作、地图状态广播）。
- **任务**：将 Microverse 的本地 JSON 存储替换为 PostgreSQL + pgvector（用户、角色、小镇、记忆）。
- **任务**：实现 AI 网关（FastAPI + LiteLLM），统一适配国内主流模型（通义千问、智谱、Kimi、DeepSeek、Ollama）。
- **任务**：实现请求限流与 Token 安全存储。
- **验收**：5 人同服稳定运行，AI 对话通过 BYOK 网关路由，记忆持久化到云端。

### 阶段三：差异化功能开发（第 7–12 周）
- **目标**：完成角色编辑器、房主权限、AI 地图生成等核心差异化功能。
- **任务**：角色编辑器 —— 外观 + 性格标签 + 背景故事 + 核心记忆，自动生成 System Prompt。
- **任务**：房主"造物主"权限系统 —— 天气、时间流速、环境参数实时编辑。
- **任务**：AI 地图生成系统 —— JSON Schema 约束 + TileMapLayer 动态绘制。
- **任务**：小镇生命周期管理 —— 创建 / 加入 / 销毁 / 暂停，RBAC 权限模型。
- **任务**：对话气泡 UI 改造，适配多人场景。
- **验收**：20 人同服流畅，房主可编辑小镇，AI 可生成地图，角色创建流程完整。

#### 8.x 客户端功能缺口（2026-08-12：联机版 vs Microverse 原版对比）

> 联机版（`microverse/script/net/`）在原版（`microverse/script/`）基础上做了联机+鉴权+后端持久化，但**剥离/未移植**了一批原版单机特性。下列为"原版有、联机版无"，按价值排序，纳入阶段三/四任务池。每项标注原版实现脚本。

- **AI 行为深度**（最高价值）：任务系统（`AIAgent.gd` 优先级任务 + 每日刷新 + AI 生成）、60s 决策循环（`make_decision`）、内心独白（`generate_thinking_content`）。联机 NPC 仅 30s 独白 + 固定区漫游 + 近距互聊。
- **状态量/涌现**：心情/金钱/健康（疾病）/角色间关系（`meta("mood"/"money"/"health"/"relations")`，原版注入 prompt + GodUI 可改）。联机 NPC 无这些状态列。
- **God 控制台**：`GodUI.gd/.tscn`（角色详情 + 植入记忆/疾病/金钱/情感/任务/背景按钮 + 头像动画）。联机版主动剥离了 CanvasLayer。
- **交互**：点击选人/移步/坐椅子（`CharacterManager.gd` + `Chair.gd`）、T/L 邻近角色多轮对话（`DialogManager/DialogService`，AI 决定是否继续、生成告别语、双向写记忆）。联机仅 Enter 自由文本发言。
- **感知**：房间感知（`RoomManager/RoomArea`，AI 知道所在房间 + 物品 + 同房角色）、物品交互语义（`get_object_info`）。联机 NPC 用硬编码 `WANDER_BOUNDS` + 扫兄弟节点。
- **背景规则**：`BackgroundStoryManager`（地图专属公司信息 + 社交规则，注入每条 prompt）。联机 prompt 仅 persona + town_context。
- **相机/输入**：跟随/拖拽/缩放/Space 归位（`CameraController.gd`）；坐/对话/设置/存档按键。联机仅 NPC 各自 Camera2D + God 模式 WASD 平移。
- **每角色 AI 设置**：`CharacterAISettings`（每角色不同模型/API）。联机仅全局 BYOK。
- **8 个原版人格**：`CharacterPersonality.gd`（Alice 等 SleepySheep/CountSheep 办公室叙事）。联机仅当贴图用，人格走用户 `personality_json`。
- **本地存档 UI / 全局设置 UI / 主菜单**：被后端 HTTP 持久化 + Lobby 取代（设计如此，非缺陷）。

> 两者都**没有**：昼夜/时钟、音频系统（BGM/SFX）、背包/任务日志 UI/小游戏/建造。

#### 8.y 后期任务池（2026-08-12，按价值排序）

本批只做 NPC 大脑升级（统一决策循环 + 内心独白 + 状态机 + 卡住检测）。以下功能原版 Microverse 均有完整实现，联机版移植需逐个评估网络改造量，排入阶段三/四。

| 任务 | 原版 | 联机改造量 |
|---|---|---|
| 完整任务系统（优先级队列+每日刷新+LLM生成） | AIAgent.gd | ✅ 已做（2026-08-14：NetworkNPC `current_tasks` 队列 + fetch/post_task_complete_by_id；brain `_maybe_daily_refresh` 游戏时钟跨天刷新 + `_generate_task_batch` LLM 补足 + `_task_block` 前置注入决策 prompt；两阶段 task detail 复用。**2026-08-15 端到端验证通过**：加载/每日刷新/完成落库全通） |
| 心情/金钱/健康/关系（状态量注入 prompt） | meta 体系 | 中（✅ 心情/金钱/健康已做 2026-08-13：状态 HUD + 上帝改状态 + patch status；relations 情感已做 2026-08-13：relations_json 字段+注入+编辑面板+动态更新；记忆植入已做 2026-08-14：面板复用 post_core_memories 通路） |
| 房间感知（NPC 知道所在房间/物品/角色） | RoomManager+RooomArea | 大（需地图预处理+场景描述 prompt） |
| 物品交互语义（椅子/桌子/咖啡机等） | AIAgent.get_object_info | 大（需 interactable 组+碰撞重建） |
| 点击交互（选人/移步/坐椅子） | CharacterManager+Chair | 小（✅ 已做 2026-08-15：上帝 `_unhandled_input` 点 NPC=选中（可选别人角色看面板）、点空地=own 角色走过去（坐着先站起）；B 控制补 owner 守卫。坐椅子此前已做） |
| T-L 邻近对话（非 Enter 自由文本） | DialogManager | 小（✅ 已做 2026-08-15、**双窗 e2e 验证通过 2026-08-16**：上帝按住 T 点对方 NPC = 选中角色与其强制开聊。`OnlineWorld._unhandled_input` T+左键 → `NetworkNPC.try_start_chat_with` → `brain.force_chat`（把关 own/未被控/in_chat/冷却/_waiting_response 持锁防并发踩 _wait_http，锁在 `_end_chat` 释放幂等；**返回 String 拒绝原因**——「正在思考/行动中」「正在聊天」「冷却中」替换原含糊「聊不了」；距离 >20px 走 `_walk_over_and_chat` 自动走过去，`force_chat_walk` meta 防点空地打断）→ 复用 `_start_chat` 完整闭环（多轮 LLM/[离开]/摘要/好感/回血/跨 owner 各写各的）。**验证**：双窗近距离开聊多轮 + 气泡 + 记忆落库 + 好感演化全闭环。**遗留**：auto-walk 远距离分支未单独 e2e；忙时 T-L 直接拒、未排队） |
| 相机跟随/拖拽/缩放 | CameraController | 小（✅ 拖拽/缩放/Space 归位已做 2026-08-13；**2026-08-16 定调：上帝相机纯 WASD 全时可控、不跟随选中 NPC**，跟随不做） |
| 背景故事/社交规则注入 | BackgroundStoryManager | 小（sysconfig 配置+prompt 注入） |
| 每角色 AI 设置（非全局 BYOK） | SettingsManager | ✅ 已做（2026-08-15：characters 三列 byok + GET/PUT /characters/{id}/byok + 客户端复用原版 SettingsManager.character_ai_settings 通路 + brain 6 处按角色名分流；角色设定面板可配/清除；API 全流程验证，GUI 待进镇回归。**2026-08-16 修**：AI 类型下拉从硬编码 3 项改遍历 `SettingsManager.api_types`（=APIConfig 注册表全量，Lobby/OnlineWorld 两处下拉同步），注册表补 **DashScope** provider（修 DB 预选回落 Ollama），provider 全表 = Ollama/OpenAI/DeepSeek/Doubao/Gemini/Claude/KIMI/SiliconFlow/DashScope/OpenAICompatible；OpenAICompatible 选型显示「请求地址」LineEdit 存 `custom_api_url`，`APIConfig.get_url` 非空直用。遗留：响应解析侧 api_type 仍读全局，混合 provider 时要改） |
| 言出法随（NPC AI 改地图,§3.4） | 设计已有 | ✅ 已做（2026-08-15：LLM 自主放/删家具——`map_data` + `POST /maps/town/{id}/actions` + WS `map_update` 广播 + 进镇恢复。**2026-08-16 sprite 扩充**：`office_objects/` 339 个 Kenney Modern Office 单体 → 精选 20 家具（座椅/桌柜/电器/绿植）映射 `OnlineWorld.PREFAB_SPRITES`，prompt 词表 3 处同步（config.py seed / brain FALLBACK / DB sysconfig）；映射表只放精选件、未全放 339（全放零 token 但未映射名是死代码），`<<prefabs>>` 注入就近家具名供 LLM 引用 |
| 混合权威（服务器裁决） | — | 大（架构级；**前置 owner 守卫已补齐 2026-08-15**：PATCH /characters/{id}/status、POST /tasks、PATCH /tasks/{id}、POST /maps/town/{id}/actions 四写接口校验角色归属，越权 403，双账号脚本验证） |
| UI 优化（面板打磨） | — | 小（纯客户端）✅ 持续迭代中（2026-08-15：滚轮缩放/气泡截断/天气中文化/按钮高度/AI 优化按钮/删除角色/ConfirmBox 通用确认框；**UI Phase B 全部完成 2026-08-15**：②③ HUD/角色设定/改状态/任务 + 收尾 10 低频面板（AI设置/切换/玩家列表/对话记录/NPC日志/关系编辑/记忆植入/交易/导演/UI设置）全迁 OnlineWorld.tscn，删 4 孤儿 helper；**sqladmin 后台中文化**（babel + zh 翻译 + I18nConfig）。详见 CLAUDE.md。**2026-08-16**：对话记录面板「看不到刷新」根因修（5s 刷新重建列表后 ScrollContainer 回顶 + 后端升序最新在最底 → 新条目永远在视野外；修为刷新后等一帧滚到 max_value）；植入记忆保存改 `await post_core_memories` 后再 `_refresh_implant_memory`（修异步 fire-and-forget 读旧缓存）；对话记录/NPC 日志 limit=50 维持） |

### 阶段四：玩法完善与优化（第 13–16 周）
- **目标**：实现进阶玩法，打磨体验。
- **任务**：流言系统与情绪传播机制。
- **任务**：经济系统（信息差赚钱、NPC 雇佣）。
- **任务**：剧本杀与观察模式。
- **任务**：UI / UX 打磨与性能优化（20 人同服帧率优化）。
- **验收**：涌现行为可观察，20 人同服稳定 60FPS，核心玩法闭环。

### 阶段五：测试与上线（第 17–20 周）
- **目标**：修复 Bug，准备上线。
- **任务**：压力测试（20 人并发 AI 请求）与安全审计。
- **任务**：Steam 商店页素材完善与审核提交（商店页已于阶段一创建）。
- **任务**：集成 GodotSteam 插件（成就、云存档）。
- **任务**：公开 Beta 测试，收集反馈。
- **任务**：正式发布。
- **验收**：服务器稳定运行 72 小时无崩溃，商店页审核通过，Beta 用户反馈积极。

## 九、Steam 接入策略

### 9.1 分层接入方案
- **第一层（开发初期）**：创建 Steamworks 开发者账号，搭建商店页面（胶囊图、描述、标签），尽早积累愿望单。
- **第二层（核心完成后）**：集成 GodotSteam 插件，实现成就、云存档、排行榜。
- **第三层（1.0 正式版后）**：评估 Steam Networking Sockets，若自建服务器体验不佳再考虑迁移。

### 9.2 注意事项
GodotSteam 插件版本需与 Godot 引擎版本严格对应；云存档需设计好 JSON 序列化与冲突解决机制。

## 十、风险与应对策略

### 10.1 技术风险
- **LLM 响应延迟**：影响游戏体验。应对：采用流式输出（SSE），客户端做打字机效果；非关键 AI 行为异步执行。
- **Token 费用失控**：应对：网关层硬限流；提供 Token 消耗可视化面板。

### 10.2 产品风险
- **AI 行为不可控**：出现违规或破坏体验。应对：强化 System Prompt 约束；增加人工审核与举报机制；设计"记忆重置"按钮。

### 10.3 运营风险
- **内容审核**：应对：接入阿里云内容安全 API 进行文本过滤；BYOK 模式下明确用户协议，平台仅做合规中转。

## 十一、附录

### 11.1 关键术语表
- **BYOK**：Bring Your Own Key，用户自带 API 密钥。
- **RAG**：Retrieval-Augmented Generation，检索增强生成。
- **ENet**：可靠的 UDP 网络协议。

### 11.2 参考项目链接
- Microverse：https://github.com/KsanaDock/Microverse （Godot 4，MIT；Steam App 3902630「Microverse In Box」）
- Godot-MCP：[待补充 GitHub 链接]
- AI Town（a16z）：[待补充 GitHub 链接]

### 11.3 推荐工具清单
- **API 测试**：Postman / Apifox
- **向量可视化**：pgAdmin / DBeaver
- **版本控制**：Git + GitHub / Gitee
- **项目管理**：Trello / Notion
