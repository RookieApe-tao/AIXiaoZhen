# 内测玩家指南：配置你的 AI Key（BYOK）

AI 小镇的 NPC 对话/决策由大模型驱动，**每个玩家自带自己的 API Key（BYOK）**，谁的角色谁付费。不配也能进镇，但 NPC 不会说话/思考/做任务。

## 一、领一个 Key（推荐 DeepSeek，便宜）

1. 打开 https://platform.deepseek.com ，手机号注册
2. 左侧「充值」——**充 10 元够内测玩很久**（deepseek-chat 约百万字几块钱）
3. 左侧「API Keys」→「创建 API key」→ 复制保存（`sk-` 开头，**只显示一次**）

其他可选（都行，任选一家）：

| 平台 | 网址 | 说明 |
|------|------|------|
| DeepSeek | platform.deepseek.com | 便宜，推荐 |
| KIMI（月之暗面） | platform.moonshot.cn | |
| 硅基流动 | siliconflow.cn | 有免费额度 |
| 豆包 | volcengine.com | 火山方舟 |
| 通义 DashScope | bailian.aliyun.com | |
| OpenAI / Claude / Gemini | | 需外网 |

## 二、填到游戏里（两层，按需配）

### 1. 账号级（必配）—— Lobby 左上角「AI 设置」

进游戏登录后，大厅左上角点 **「AI 设置」**：

- **API 类型**：选 DeepSeek
- **模型**：deepseek-chat
- **API Key**：粘贴你的 `sk-...`
- 点保存。这层管：你的账号全局默认 AI（生成角色、AI 优化等）

### 2. 角色级（可选）—— 进镇后给单个角色单独配

想让某个角色用不同的 Key/模型（比如角色 A 用 DeepSeek、角色 B 用 KIMI）：

进镇 → 点选该角色 → 右侧面板「角色设定」→ **AI 设置区**：API 类型/模型/API Key，保存即可。不配的角色自动用你账号级的那套。

## 三、验证配好了

进镇后选一个自己带入的角色，等 25 秒左右看 NPC：

- 头顶出现**思想气泡**或在**行为日志侧栏**滚动 = AI 已在工作
- 点开「Token 消耗」面板（底部「设置」tab）有数字增长 = 请求真实发出

NPC 一直站着不动、日志无更新 → 回 Lobby 检查 AI 设置的 Key 是否复制完整。

## 常见问题

- **Key 泄露了吗？** Key 用 AES-256 加密存服务器数据库，仅发起 AI 请求时解密使用，管理员看不到明文。
- **会花多少钱？** 只有你带入的角色决策走你的 Key（谁带的谁付）。Token 消耗面板可实时看用量。
- **填错想换？** 直接在 AI 设置里覆盖保存即可；角色级配错了用「清除」回到账号级。
