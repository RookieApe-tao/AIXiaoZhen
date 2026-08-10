# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目状态

当前仓库处于**设计阶段**：尚无实际代码（Godot 客户端 / Python 后端均未落地），内容物仅为设计文档 `AI小镇游戏开发流程文档.md` 与 Claude Code 启动脚本 `start-claude.bat`。**该 .md 文档是项目事实来源（source of truth）**——任何架构或模块决策先回查文档，变更须同步更新文档。

## 项目概述

AI小镇：基于"斯坦福小镇"理念的 2D AI 社交模拟游戏。核心理念"人人皆可创造 AI 角色"，AI 角色具备记忆/情感/自主行为，AI 与 AI、AI 与人类之间产生涌现式社交。采用 **BYOK（Bring Your Own Key）** 模式——玩家自带大模型 API Token，服务器只做状态同步与数据路由，不承担 GPU 推理成本。

## 目标技术栈（尚未实现，以文档为准）

- **客户端**：Godot 4.x（2D），GDScript。
- **后端**：Python FastAPI（异步）。
- **网络（双通道）**：
  - 实时状态同步：UDP / ENet（20 人同服，约 100ms 同步一次关键状态）。
  - AI 网关通信：HTTP（REST / SSE 流式）。
- **数据库**：PostgreSQL + pgvector（关系数据与记忆向量一体化）。
- **部署**：Docker Compose（FastAPI + PostgreSQL + Redis + Nginx），目标阿里云 ECS。

## 关键架构决策：混合权威（Hybrid Authority）

- **游戏状态层 = 服务器权威**：玩家位置、动作、地图状态、小镇配置等由 FastAPI 后端裁决，客户端仅做预测/插值，最终以服务器为准，防止作弊与状态分叉。
- **AI 推理层 = 客户端执行（BYOK）**：AI 的"思考"在客户端用玩家 Token 调用大模型；服务器只接收、校验并广播 AI 产出的**行为结果**，不承载也不转发推理过程。
- **升级路径**：若未来需强反作弊，可将 AI 推理迁至服务器端——仍用玩家 BYOK Token 计费（成本归玩家），不破坏 BYOK 模式。

## 核心模块（规划）

角色编辑器、AI 对话与记忆系统（RAG + pgvector，短期 N 轮 Context + 长期向量检索）、AI 地图生成（受约束 JSON 指令 → TileMapLayer / PackedScene）、小镇生命周期管理（Redis 房间状态 + RBAC：造物主/居民/观察者）、AI 网关（OpenAI 兼容 `POST /v1/chat/completions`，经 LiteLLM 适配通义千问/智谱/Kimi/DeepSeek/Ollama）、用户与权限系统。

## 二开基线

以开源项目 **Microverse**（MIT 许可，Steam App ID 3902630）为 AI 社交模块基线 Fork，采用**插件化拆分策略**：不改动其核心 AI 代码，封装为独立插件；自建 Godot 内置 ENet 联机底座；AI 网关独立部署。其他参考：Godot-MCP、AI Town(a16z)。详见文档 §4。

## 核心数据表（规划）

`users`、`characters`、`towns`、`map_data`、`chat_logs`、`memory_vectors`（含 Embedding 与情绪权重）。详见文档 §6.3。

## 开发约定

- **语言**：项目文档与提交信息使用中文。
- **Token 安全**：用户 API Token 必须 AES-256 加密存储，仅在发起 AI 请求时解密；AI 网关层做敏感词/合规校验与限流（防刷）。
- **AI 输出校验**：服务器虽不校验 AI 思考过程，但必须对 AI 行为结果做合法性/Schema/合规校验后再广播。

## 常用命令

- **启动 Claude Code（本机）**：双击 `start-claude.bat`（在新的 PowerShell 窗口运行 `claude --dangerously-skip-permissions`）。
- **构建 / 测试 / lint**：待 Godot 项目与 FastAPI 服务落地后补充（当前无代码）。
