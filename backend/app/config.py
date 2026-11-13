"""系统配置默认值。建表/启动时自动 seed 缺失项；运行时改配置走后台 sysconfig 表。
   改这里=改默认值；已有运行值的项不会被覆盖。"""

SYS_CONFIG_DEFAULTS = [
    # 记忆 / embedding（管理员统一配，§5.7.4）
    {"key": "embedding_provider", "value": "dashscope", "value_type": "string", "category": "memory",
     "description": "embedding 提供商：dashscope/zhipu/ollama"},
    {"key": "embedding_model", "value": "text-embedding-v3", "value_type": "string", "category": "memory",
     "description": "全局 embedding 模型名"},
    {"key": "embedding_api_key", "value": "", "value_type": "string", "category": "memory",
     "description": "embedding API Key", "encrypted": True},
    {"key": "embedding_dim", "value": "1024", "value_type": "int", "category": "memory",
     "description": "embedding 向量维度（须与模型一致，改维度需重建 memory_vectors）"},
    {"key": "memory_decay_days", "value": "30", "value_type": "int", "category": "memory",
     "description": "记忆时间衰减天数（越大遗忘越慢；30 = 约 20 天半衰期）"},
    {"key": "memory_top_k", "value": "5", "value_type": "int", "category": "memory",
     "description": "记忆检索默认返回条数"},
    # 提示词审查（§5.8.2）
    {"key": "review_provider", "value": "dashscope", "value_type": "string", "category": "review",
     "description": "AI 审查 LLM 提供商"},
    {"key": "review_model", "value": "qwen-plus", "value_type": "string", "category": "review",
     "description": "AI 审查模型"},
    {"key": "review_api_key", "value": "", "value_type": "string", "category": "review",
     "description": "AI 审查 API Key", "encrypted": True},
    {"key": "review_threshold", "value": "0.7", "value_type": "float", "category": "review",
     "description": "AI 审查可疑度阈值（>=此值进人工队列）"},
    {"key": "review_enabled", "value": "true", "value_type": "bool", "category": "review",
     "description": "是否开启 AI 审查"},
    # 服务器
    {"key": "max_town_players", "value": "20", "value_type": "int", "category": "server",
     "description": "单小镇最大同服人数"},
    {"key": "sync_interval_ms", "value": "100", "value_type": "int", "category": "server",
     "description": "ENet 状态同步间隔（毫秒）"},
    # 游戏玩法调参（客户端 /config/public 拉取，非敏感，可后台改）
    {"key": "chat_max_rounds", "value": "8", "value_type": "int", "category": "gameplay",
     "description": "NPC 互聊最大轮数（安全上限；实际何时结束由大模型 [离开] 决定）"},
    # 导演模式：房主叙事控制（世界观默认值 + 虚拟时钟起点）
    {"key": "default_world_background", "value": "一座沿海的现代小镇，经济以科技和旅游为支柱，居民友善而忙碌。",
     "value_type": "string", "category": "gameplay",
     "description": "建镇默认世界观背景（房主可在导演控制台改）"},
    {"key": "default_company_info", "value": "星辰科技公司，主营 AI 产品，氛围务实，同事关系融洽。",
     "value_type": "string", "category": "gameplay",
     "description": "默认公司信息"},
    {"key": "default_social_rules", "value": "同事间保持基本礼貌；午休时间避免大声喧哗；遇事互相帮忙。",
     "value_type": "string", "category": "gameplay",
     "description": "默认社交规则"},
    {"key": "game_clock_start_minute", "value": "480", "value_type": "int", "category": "gameplay",
     "description": "游戏时钟起点（分钟，480=08:00；房主端按 time_scale 推进）"},
    # 数据留存（定时清理：startup 起 asyncio 循环，按天删过期 chat_logs）
    {"key": "chat_log_retention_days", "value": "30", "value_type": "int", "category": "retention",
     "description": "对话日志保留天数（0=不自动清理；startup 后台循环每小时扫一次，删早于此天数的 chat_logs）"},
    # NPC 提示词模板（后台可改，重进镇生效；<<占位符>> 由 brain _fill_template 填充）
    {
        "key": "prompt_decision",
        "value": """你是<<name>>。
<<personality>>
<<town_context>>
<<recent_memories>><<core_memories>>你的状态：心情<<mood>>% 金币<<money>> 健康<<health>>%。
<<status_guide>><<nearby_items>><<relations>><<actions_block>>
用 JSON 回复，只输出 JSON：
{"action":"chat/speak/move/think/map_edit/create_task/complete_task/use_item/trade/sit/stand","text":"意图(≤20字)","target_room":"","target_person":"","status_change":{}}

target（仅 chat/move 用）："target_room":"广场" 或 "target_room":"会议室" 或 "target_person":"老张"
status_change（可选，任何动作可带）：{"mood_delta":0.05,"money_delta":0,"health_delta":-0.02}
注意：只选一个 action 和意图。map_actions/task/trade/use_item 的详细格式不要写——选中后会单独给你。""",
        "value_type": "string", "category": "prompt",
        "description": "NPC 决策 prompt（stage 1，25s 决策循环）。环境全量 + 能力菜单(actions_block 按需)。占位符 name/personality/town_context/recent_memories/core_memories/mood/money/health/status_guide/nearby_items/actions_block"
    },
    {
        "key": "prompt_detail_map_edit",
        "value": """你（<<name>>）决定建造/改造小镇（<<intent>>）。
所在房间：<<room>>。附近已有家具：<<prefabs>>（共 <<prefab_count>> 件）。
你周围已建造的地图：<<tiles>>。
用 JSON 回复，只输出 JSON，map_actions 里放 1-3 个动作：
- 铺地面/建墙/造路：{"action":"place_tile","pos":[x,y],"tile_type":"wall|floor|road|grass|tree"}
  wall=墙(灰) floor=地板(红棕) road=路(灰) grass=草地(绿) tree=树
- 放家具：{"action":"place_prefab","pos":[x,y],"prefab_name":"chair|office_chair|wooden_chair|armchair|sofa|desk|large_desk|table|white_desk|metal_desk|white_table|metal_table|cabinet|bookshelf|filing_cabinet|counter|coffee_machine|printer|computer|server|plant|small_plant|tall_plant"}
  座椅:chair|office_chair|wooden_chair|armchair|sofa  桌柜:desk|large_desk|table|white_desk|metal_desk|white_table|metal_table|cabinet|bookshelf|filing_cabinet|counter  电器:coffee_machine|printer|computer|server  绿植:plant|small_plant|tall_plant
- 删地面：{"action":"remove_tile","pos":[x,y]}
- 删家具：{"action":"remove_prefab","prefab_name":"desk"}
pos 是像素坐标（=网格坐标×32），地图范围 x 0~1152、y 0~704。建房子先铺 floor 再围 wall；造路用 road 连起来。
重要：选新位置建造，不要在已建造的坐标重复铺；每次用不同的坐标，从已有建筑边缘向外扩展。""",
        "value_type": "string", "category": "prompt",
        "description": "map_edit 第二轮详细格式教学（stage 2，决策选 map_edit 后注入）。占位符 name/intent/room/prefabs/prefab_count"
    },
    {
        "key": "prompt_detail_task",
        "value": """你（<<name>>）决定创建/完成任务（<<intent>>）。
用 JSON 回复，只输出 JSON：
创建：{"task":{"action":"create","title":"任务名","description":"...","priority":3,"reward":10}}
完成：{"task":{"action":"complete","task_title":"要完成的任务名"}}
priority 1-5，reward 是赏金金币数。""",
        "value_type": "string", "category": "prompt",
        "description": "task 第二轮详细格式教学（stage 2）。占位符 name/intent"
    },
    {
        "key": "prompt_detail_use_item",
        "value": """你（<<name>>）决定使用物品（<<intent>>）。
附近物品：<<prefabs>>。用 JSON 回复，只输出 JSON：
{"use_item":{"prefab_name":"coffee_machine","room_name":"茶水间"}}""",
        "value_type": "string", "category": "prompt",
        "description": "use_item 第二轮详细格式教学（stage 2）。占位符 name/intent/prefabs"
    },
    {
        "key": "prompt_detail_trade",
        "value": """你（<<name>>）决定交易（<<intent>>）。
你的金币：<<money>>。用 JSON 回复，只输出 JSON：
{"trade":{"target_name":"同事名","offer_items":["物品"],"offer_money":0,"request_items":["想要的"],"request_money":0}}""",
        "value_type": "string", "category": "prompt",
        "description": "trade 第二轮详细格式教学（stage 2）。占位符 name/intent/money"
    },
    {"key": "prompt_think", "value": "你是<<name>>。\n<<personality>>\n<<town_context>>\n<<memories>>你现在在内心思考/反省。写一段80-150字的内心独白（第一人称），只是内心的想法，不对外说话。只输出独白内容本身，不要引号。",
     "value_type": "string", "category": "prompt", "description": "NPC 内心独白 prompt。占位符 name/personality/town_context/memories"},
    {"key": "prompt_speak", "value": "你的名字是 <<name>>。\n<<personality>>\n<<town_context>>\n<<memories>>\n你正在 AI 小镇里。以这个角色的身份自然地说一句话（不超过30字，只输出台词本身，不要引号和解释）。可以提及或招呼身边的同事，也可以呼应你的记忆。",
     "value_type": "string", "category": "prompt", "description": "NPC 自言自语 prompt。占位符 name/personality/town_context/memories"},
    {"key": "prompt_chat_opening", "value": "你是<<sn>>。\n<<sb>>\n<<mem_block>>\n<<world_block>>\n<<topic_block>>你主动找<<ln>>（\n<<lb>>）搭话。先开口说一句话开场（不超过30字，只输出一句台词本身，不要引号、不要括号动作描述）。",
     "value_type": "string", "category": "prompt", "description": "NPC 对话开场 prompt。占位符 sn/sb/mem_block/world_block/topic_block/ln/lb"},
    {"key": "prompt_chat_reply", "value": "你是<<sn>>。\n<<sb>>\n<<mem_block>>\n<<world_block>>\n<<hist_block>>\n现在轮到你（<<sn>>）回应。\n<<opt>>",
     "value_type": "string", "category": "prompt", "description": "NPC 对话接话 prompt。占位符 sn/sb/mem_block/world_block/hist_block/opt"},
    {
        "key": "prompt_summarize",
        "value": """以下是 <<sn>> 和 <<ln>> 的一段对话：
<<history>>

请用 JSON 总结。只输出 JSON，不要其他文字。
格式：{"summary":"一段话总结对话内容（≤60字）","core_facts":["可长期记住的事实",...],"a_to_b":0.0,"b_to_a":0.0}。
summary 写一段中文总结。core_facts 提炼值得长期记住的事实，没有则空数组 []。
a 指 <<sn>>，b 指 <<ln>>。a_to_b 是这段对话后 a 对 b 好感的变化（-0.3~0.3：正=更亲近，负=更疏远，0=无变化）；b_to_a 同理是 b 对 a 的变化。""",
        "value_type": "string", "category": "prompt",
        "description": "对话摘要 prompt（写 memory_vectors + 双向好感演化）。占位符 sn/ln/history"
    },
    {
        "key": "prompt_generate_tasks",
        "value": """你是<<name>>。
<<personality>>
你正在为自己安排今天的任务。请生成 <<count>> 个符合你职位、性格和当前处境的任务。
用 JSON 回复，只输出 JSON：
{"tasks":[{"title":"任务名","description":"简述","priority":3,"reward":0}, ...]}
priority 1-5（越高越重要），reward 是完成后可得的金币赏金（0-20）。""",
        "value_type": "string", "category": "prompt",
        "description": "NPC 每日任务批量生成 prompt（每日刷新补足用）。占位符 name/personality/count"
    },
    {"key": "prompt_night_outdoor", "value": "现在是黑夜，室外不安全，尽量待在室内、别出门。",
     "value_type": "string", "category": "prompt",
     "description": "黑夜+室外时注入世界上下文（NPC 大脑 _world_context 使用）"},
    {"key": "prompt_day_outdoor", "value": "白天有空可以去室外的广场或花园走走、透透气。",
     "value_type": "string", "category": "prompt",
     "description": "白天+室外时注入世界上下文"},
    # UI 主题调参（/config/public 下发，客户端 GameSession.ui_config 缓存；管理员 sqladmin 改、重进镇生效）
    {"key": "ui_font_size", "value": "24", "value_type": "int", "category": "ui",
     "description": "UI 基础字号（应用到项目默认主题 default_font_size；调可读性免重编）"},
    {"key": "bubble_duration_sec", "value": "5", "value_type": "float", "category": "ui",
     "description": "NPC 气泡停留秒数（说话/思考气泡自动消失）"},
    {"key": "bubble_font_size", "value": "12", "value_type": "int", "category": "ui",
     "description": "气泡文字字号"},
    {"key": "show_npc_intent_label", "value": "true", "value_type": "bool", "category": "ui",
     "description": "是否显示 NPC 头顶意图标签（演示可关去杂）"},
]
