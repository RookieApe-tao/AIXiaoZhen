extends Node
class_name NetworkNPCBrain
# NPC 大脑升级（2026-08-12）：统一决策循环 + 内心独白 + 状态机。
# 替换 3 个独立 Timer（speak 30s / move 8s / chat 5s）为 1 个决策 Timer（60s，首次 5-15s 错峰）。
# 决策 prompt：persona + town_context + core_memories → LLM 选 speak/move/chat/think → 执行原语。
# 内心独白 think 只写记忆不显示气泡。互聊+记忆+落库代码不动。

enum State { IDLE, MOVING, SPEAKING, CHATTING, THINKING }

const DECISION_INTERVAL := 25.0            # 统一决策间隔（缩短以加快节奏）
const CHAT_RANGE := 20.0   # 面对面聊天距离（很近）；想聊远处的人要先走过去
const CHAT_COOLDOWN := 40.0
# 互聊最大轮数走 GameSession.chat_max_rounds（/config/public 拉取，后台可改，默认 8）
const WANDER_BOUNDS := Rect2(360, 290, 380, 220)
const PEER_GRAVITATE_PROB := 0.6
const LEAVE_TOKEN := "[离开]"
# 状态涌现：每决策轮被动衰减（确定性骨架），逼 NPC 社交/休息/用物品恢复。money 不衰减。
# ponytail: 幅度可调——mood 0.6 起，约 30 轮(12min)触底，中途聊天/用物品应能恢复。
const STATUS_DECAY_MOOD := -0.01     # 心情：久不社交缓降
const STATUS_DECAY_HEALTH := -0.005  # 健康：久不休息缓降
const CHAT_MOOD_GAIN := 0.05         # 对话结束双方心情恢复（社交=回血，与衰减对称；否则 mood 单向螺旋触底）
const SIT_HEALTH_GAIN := 0.03        # 坐下休息回血（health 衰减 -0.005/轮的对应恢复通路；此前 sit 零恢复 → health 必然归零）
const ITEM_HEALTH_GAIN := 0.02       # 用物品顺带小幅回血（喝咖啡也算歇口气）
const THINK_MOOD_GAIN := 0.02        # 内心独白自我调节回血（think 是低 mood 的恢复通路；否则引导说「想想开心的事」但代码零恢复 → 单向触底）
# prompt 模板 FALLBACK（sysconfig 拉取失败/未进镇时兜底；与 config.py 默认值一致，<<占位符>> 风格）
const FALLBACK_DECISION := """你是<<name>>。
<<personality>>
<<town_context>>
<<recent_memories>><<core_memories>>你的状态：心情<<mood>>% 金币<<money>> 健康<<health>>%。
<<status_guide>><<nearby_items>><<relations>><<actions_block>>
用 JSON 回复，只输出 JSON：
{"action":"chat/speak/move/think/map_edit/create_task/complete_task/use_item/trade/sit/stand","text":"意图(≤20字)","target_room":"","target_person":"","status_change":{}}

target（仅 chat/move 用）："target_room":"广场" 或 "target_room":"会议室" 或 "target_person":"老张"
status_change（可选，任何动作可带）：{"mood_delta":0.05,"money_delta":0,"health_delta":-0.02}
注意：只选一个 action 和意图。map_actions/task/trade/use_item 的详细格式不要写——选中后会单独给你。"""
# 第二轮：map_edit 选中后注入的详细格式教学（两阶段决策的 stage 2）
const FALLBACK_DETAIL_MAP_EDIT := """你（<<name>>）决定建造/改造小镇（<<intent>>）。
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
重要：选新位置建造，不要在已建造的坐标重复铺；每次用不同的坐标，从已有建筑边缘向外扩展。"""
const FALLBACK_DETAIL_TASK := """你（<<name>>）决定创建/完成任务（<<intent>>）。
用 JSON 回复，只输出 JSON：
创建：{"task":{"action":"create","title":"任务名","description":"...","priority":3,"reward":10}}
完成：{"task":{"action":"complete","task_title":"要完成的任务名"}}
priority 1-5，reward 是赏金金币数。"""
const FALLBACK_DETAIL_USE_ITEM := """你（<<name>>）决定使用物品（<<intent>>）。
附近物品：<<prefabs>>。用 JSON 回复，只输出 JSON：
{"use_item":{"prefab_name":"coffee_machine","room_name":"茶水间"}}"""
const FALLBACK_DETAIL_TRADE := """你（<<name>>）决定交易（<<intent>>）。
你的金币：<<money>>。用 JSON 回复，只输出 JSON：
{"trade":{"target_name":"同事名","offer_items":["物品"],"offer_money":0,"request_items":["想要的"],"request_money":0}}"""
const FALLBACK_THINK := "你是<<name>>。\n<<personality>>\n<<town_context>>\n<<memories>>你现在在内心思考/反省。写一句不超过20字的内心独白（第一人称），只是内心的想法，不对外说话。只输出独白内容本身，不要引号。"
const FALLBACK_SPEAK := "你的名字是 <<name>>。\n<<personality>>\n<<town_context>>\n<<memories>>\n你正在 AI 小镇里。以这个角色的身份自然地说一句话（不超过20字，只输出台词本身，不要引号和解释）。可以提及或招呼身边的同事，也可以呼应你的记忆。"
const FALLBACK_CHAT_OPENING := "你是<<sn>>。\n<<sb>>\n<<mem_block>>\n<<world_block>>\n<<topic_block>>你主动找<<ln>>（\n<<lb>>）搭话。先开口说一句话开场（不超过20字，只输出一句台词本身，不要引号、不要括号动作描述）。"
const FALLBACK_CHAT_REPLY := "你是<<sn>>。\n<<sb>>\n<<mem_block>>\n<<world_block>>\n<<hist_block>>\n现在轮到你（<<sn>>）回应。\n<<opt>>"
const FALLBACK_SUMMARIZE := """以下是 <<sn>> 和 <<ln>> 的一段对话：
<<history>>

请用 JSON 总结。只输出 JSON，不要其他文字。
格式：{"summary":"一段话总结对话内容（≤60字）","core_facts":["可长期记住的事实",...],"a_to_b":0.0,"b_to_a":0.0}。
summary 写一段中文总结。core_facts 提炼值得长期记住的事实，没有则空数组 []。
a 指 <<sn>>，b 指 <<ln>>。a_to_b 是这段对话后 a 对 b 好感的变化（-0.3~0.3：正=更亲近，负=更疏远，0=无变化）；b_to_a 同理是 b 对 a 的变化。"""
const FALLBACK_GENERATE_TASKS := """你是<<name>>。
<<personality>>
你正在为自己安排今天的任务。请生成 <<count>> 个符合你职位、性格和当前处境的任务。
用 JSON 回复，只输出 JSON：
{"tasks":[{"title":"任务名","description":"简述","priority":3,"reward":0}, ...]}
priority 1-5（越高越重要），reward 是完成后可得的金币赏金（0-20）。"""
# 世界上下文外部化文案（sysconfig prompt_night_outdoor / prompt_day_outdoor 兜底，与 config.py 默认值一致）
const FALLBACK_NIGHT_OUTDOOR := "现在是黑夜，室外不安全，尽量待在室内、别出门。"
const FALLBACK_DAY_OUTDOOR := "白天有空可以去室外的广场或花园走走、透透气。"


# 占位符填充：遍历 vars 把 <<key>> 替换为值（prompt 正文不含 <<>>，无冲突）
# 响应解析用的 api_type 按请求时的同名设置取（角色级 BYOK 可能与全局 provider 不同，
# 全局 openai 格式解不开 Ollama 响应→空→误判"LLM 不可用"）。
func _parse_api_type(character_name: String = "") -> String:
	var s: Dictionary = SettingsManager.get_character_ai_settings(character_name) if character_name != "" else APIManager.current_settings
	return GameSession.str_or(s.get("api_type"), "Ollama")


func fill_template(tpl: String, vars: Dictionary) -> String:
	var result := tpl
	for key in vars:
		result = result.replace("<<" + key + ">>", str(vars[key]))
	return result

var npc: CharacterBody2D
var _decision_timer: Timer
var _waiting_response := false            # 并发 guard：防重复 LLM 调用
var _state := State.IDLE                 # 当前状态（替代 in_chat 字符串 meta 的部分用途）
var _idle_rounds := 0                    # 连续未移动轮数：累计≥2 强制 move，防止 NPC 原地反复 think/speak
var _last_task_day := -1                 # 上次每日任务刷新的游戏日（游戏时钟驱动；跨天刷新）
var _recent_topics: Array = []     # 最近几次对话开场话题（跨对话，防回音室反复聊同一主题）
static var chat_cooldowns: Dictionary = {}
static var chatting_pairs: Dictionary = {}
var _hr_done := false
var _hr_result: Variant = null
var _hr_key := ""   # 本次 HTTP 请求归属的角色名（token 分桶 key；空=非 BYOK 请求）
# 房间索引（静态，所有大脑共享，从后端 /towns/{id}/rooms 拉取）
static var _room_index: Dictionary = {}   # {room_name: {"cx": float, "cy": float, "w": float, "h": float}}
static var _room_index_built := false


func _ready() -> void:
	_decision_timer = Timer.new()
	_decision_timer.wait_time = randf_range(2.0, 5.0)   # 首次快速（登录后立刻决策），tick 时 _on_decision_tick 恢复 25s 常规
	_decision_timer.one_shot = false
	_decision_timer.timeout.connect(_on_decision_tick)
	add_child(_decision_timer)
	npc.gave_up_stuck.connect(_on_gave_up_stuck)
	await npc.fetch_core_memories()       # 长期核心事实（characters.core_memories_json）
	await npc.fetch_recent_memories(10)   # 近期记忆向量（memory_vectors 最近 10 条，时序）
	await get_tree().create_timer(randf_range(0.5, 2.0)).timeout   # 轻错峰（fetch 耗时已天然错峰），避免登录后久等
	if is_instance_valid(_decision_timer):
		_decision_timer.start()


# ============================ 统一决策循环 ============================

# 快速重评估：取消当前等待，3~8s 后立即决策（用于聊天结束/说完话等事件后）
func _schedule_soon() -> void:
	if not is_instance_valid(_decision_timer): return
	_decision_timer.stop()
	_decision_timer.wait_time = randf_range(3.0, 8.0)
	_decision_timer.start()


# 卡死放弃（NetworkNPC 卡角 4 次重算失败）：清锁 + 立即重决策，不再原地冻到下轮 25s tick
func _on_gave_up_stuck() -> void:
	_waiting_response = false
	_schedule_soon()


func _on_decision_tick() -> void:
	# 恢复正常间隔（_schedule_soon 改了 wait_time，tick 时恢复）
	_decision_timer.wait_time = DECISION_INTERVAL + randf_range(-5.0, 5.0)
	if not is_instance_valid(npc): return
	if npc.controlled_by_player or GameSession.pid != npc.owner_id: return
	if _waiting_response: return
	if npc.has_meta("in_chat") and npc.get_meta("in_chat"): return
	_apply_status_decay()   # 状态被动衰减（确定性骨架），决策前扣
	_make_decision()


# 决策 prompt v2（言出法随）：JSON 输出，支持 speak/move/think/map_edit。
# 包含地图上下文（已有房间+可编辑能力），让 LLM 知道世界是"活的"。
func _build_decision_prompt() -> String:
	var recent := ""
	if not npc.recent_memories.is_empty():
		recent = "你最近的经历：\n- " + "\n- ".join(npc.recent_memories) + "\n"
	var core := ""
	if not npc.core_memories.is_empty():
		core = "你的核心记忆：\n- " + "\n- ".join(npc.core_memories) + "\n"
	var relations := ""
	if not npc.relations.is_empty():
		relations = "你和其他人的关系：\n"
		for other in npc.relations.keys():
			var info = npc.relations[other]
			if typeof(info) != TYPE_DICTIONARY:
				continue
			var aff := float(info.get("affinity", 0.0))
			var desc := "一般"
			if aff >= 0.6: desc = "很要好"
			elif aff >= 0.3: desc = "友好"
			elif aff <= -0.4: desc = "反感"
			elif aff <= -0.15: desc = "不太亲近"
			var note := GameSession.str_or(info.get("note"))
			relations += "- %s：%s%s\n" % [other, desc, ("（" + note + "）") if not note.is_empty() else ""]
	# 状态→行为反馈 + 久坐引导合并为 status_guide（条件逻辑留代码；纯文字模板走 sysconfig）
	var status_guide := ""
	if npc.mood < 0.4:
		# 空场时别引导找人聊——没人可聊会空转，改用物品/独白恢复
		if _find_nearby_npc() != null:
			status_guide += "你心情低落，优先找人聊天(chat)或用物品(use_item)恢复心情。\n"
		else:
			status_guide += "你心情低落，镇上没别人。完成手头任务最能提振心情（complete_task，有成就感+赏金），也可以用物品(use_item)或想想开心的事(think)自我调节。\n"
	if npc.health < 0.4:
		status_guide += "你身体疲惫，减少奔波，去休息区或用咖啡机(use_item)恢复。\n"
	if npc.money < 50:
		status_guide += "你手头紧，可以接任务赚赏金(complete_task)或交易(trade)。\n"
	if _idle_rounds >= 2:
		status_guide += "你在原地待了一会儿，也许该去别的房间转转（move）。"
		if _has_outdoor():
			status_guide += " 室外的广场或花园也是好去处。"
		status_guide += "\n"
	var nearby := ""
	var nearby_items := _nearby_prefabs()
	if not nearby_items.is_empty():
		nearby = "附近可用物品：" + ", ".join(nearby_items) + "。\n"
	var nearby_tiles := _nearby_tiles()
	if not nearby_tiles.is_empty():
		nearby += "附近地形：" + ", ".join(nearby_tiles) + "（小镇已被建造过的地方）。\n"
	status_guide = _task_block() + status_guide   # 任务队列前置（优先级最高的行动依据）
	return fill_template(GameSession.prompt_templates.get("prompt_decision", FALLBACK_DECISION), {
		"name": npc.npc_name, "personality": npc.get_personality_prompt(),
		"town_context": _town_context() + "\n",
		"recent_memories": recent, "core_memories": core,
		"relations": relations,
		"mood": str(int(npc.mood * 100)), "money": str(npc.money), "health": str(int(npc.health * 100)),
		"status_guide": status_guide, "nearby_items": nearby,
		"actions_block": _build_actions_block(),
	})


# 决策轮能力菜单（stage 1）：环境上下文已全量注入上方，这里只列能力选项——
# map_edit 按家具密度决定提不提（空→放、挤→收、适中→不提），sit 按附近有无椅子。
func _build_actions_block() -> String:
	var s := "你现在可以选一个动作：\n"
	s += "- chat 找同事聊天 / speak 自言自语 / move 去别处 / think 思考\n"
	var n := _nearby_prefabs().size()
	if n <= 1:
		s += "- map_edit 建造小镇（这里还是空地，可铺 floor 建房子、road 造路、放 chair/desk/coffee_machine/plant）\n"
	elif n >= 6:
		s += "- map_edit 整理（家具偏多，可移除挡路的）\n"
	s += "- create_task/complete_task 任务 / trade 交易 / use_item 用物品\n"
	if _has_nearby_chair():
		s += "- sit 坐下休息 / stand 起身\n"
	return s


func _has_nearby_chair() -> bool:
	for chair in get_tree().get_nodes_in_group("chairs"):
		if chair is Node2D and npc.position.distance_to(chair.position) < 150:
			return true
	return false


# 共享 stage 2：调 LLM + 剥围栏 + 解析 JSON。各能力的 detail 函数复用。
# 按 NPC 名分流 AI 设置（每角色 BYOK；未配置由 APIManager 回退账号级全局）。
func _llm_json(prompt: String) -> Dictionary:
	var req = await APIManager.generate_dialog(prompt, npc.npc_name)
	if req == null:
		return {}
	var result = await _wait_http(req, npc.npc_name)
	var raw := ""
	if typeof(result) == TYPE_DICTIONARY:
		var api_type := _parse_api_type(npc.npc_name)
		raw = APIConfig.parse_response(api_type, result)
	if raw == null or raw.strip_edges().is_empty():
		return {}
	var data = JSON.parse_string(_strip_code_fence(raw.strip_edges()))
	return data if typeof(data) == TYPE_DICTIONARY else {}


func _generate_map_edit_detail(intent: String) -> Array:
	var prefabs := _nearby_prefabs()
	var tiles := _nearby_tiles()
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_detail_map_edit", FALLBACK_DETAIL_MAP_EDIT), {
		"name": npc.npc_name, "intent": intent,
		"room": _which_room(npc.position),
		"prefabs": ", ".join(prefabs) if not prefabs.is_empty() else "无",
		"prefab_count": str(prefabs.size()),
		"tiles": ", ".join(tiles) if not tiles.is_empty() else "无（全是空草地）",
	})
	var data: Dictionary = await _llm_json(prompt)
	var ma = data.get("map_actions")
	return ma if typeof(ma) == TYPE_ARRAY else []


func _generate_task_detail(intent: String) -> Dictionary:
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_detail_task", FALLBACK_DETAIL_TASK), {
		"name": npc.npc_name, "intent": intent,
	})
	var data: Dictionary = await _llm_json(prompt)
	var t = data.get("task")
	return t if typeof(t) == TYPE_DICTIONARY else {}


func _generate_use_item_detail(intent: String) -> Dictionary:
	var prefabs := _nearby_prefabs()
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_detail_use_item", FALLBACK_DETAIL_USE_ITEM), {
		"name": npc.npc_name, "intent": intent,
		"prefabs": ", ".join(prefabs) if not prefabs.is_empty() else "无",
	})
	var data: Dictionary = await _llm_json(prompt)
	var u = data.get("use_item")
	return u if typeof(u) == TYPE_DICTIONARY else {}


func _generate_trade_detail(intent: String) -> Dictionary:
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_detail_trade", FALLBACK_DETAIL_TRADE), {
		"name": npc.npc_name, "intent": intent,
		"money": str(npc.money),
	})
	var data: Dictionary = await _llm_json(prompt)
	var tr = data.get("trade")
	return tr if typeof(tr) == TYPE_DICTIONARY else {}


# 去掉 LLM 输出可能裹的 ```json ... ``` 代码围栏
func _strip_code_fence(s: String) -> String:
	if s.begins_with("```"):
		var i := s.find("\n")
		s = s.substr(i + 1) if i != -1 else s
		if s.ends_with("```"):
			s = s.substr(0, s.length() - 3)
	return s


# 解析 LLM 输出：优先 JSON，失败回退到旧关键词匹配
func _parse_decision_v2(raw: String) -> Dictionary:
	raw = raw.strip_edges()
	var json_str := raw
	if raw.begins_with("```"):
		var i := raw.find("\n")
		json_str = raw.substr(i + 1) if i != -1 else raw
		if json_str.ends_with("```"):
			json_str = json_str.substr(0, json_str.length() - 3)
		json_str = json_str.strip_edges()
	if not json_str.begins_with("{"):
		return {"json": false, "action": _parse_decision_legacy(raw), "text": raw, "map_actions": []}
	# JSON.new().parse 静默解析：LLM 返回损坏 JSON 时不刷 ERROR（parse_string 会刷屏），降级走 legacy。
	var jp := JSON.new()
	var data = jp.data if jp.parse(json_str) == OK else null
	if typeof(data) == TYPE_DICTIONARY and data.has("action"):
		var map_actions = data.get("map_actions")
		if typeof(map_actions) != TYPE_ARRAY:
			map_actions = []
		return {"json": true, "action": str(data.get("action", "")).to_lower(),
				"text": GameSession.str_or(data.get("text")), "map_actions": map_actions,
				"target_room": GameSession.str_or(data.get("target_room")),
				"target_person": GameSession.str_or(data.get("target_person"))}
	return {"json": false, "action": _parse_decision_legacy(raw), "text": raw, "map_actions": []}


# 旧关键词解析器（保留兼容，v2 回退时用）
func _parse_decision_legacy(text: String) -> String:
	text = text.strip_edges().to_lower()
	# 取第一行（防多行输出）
	var line := text.split("\n")[0]
	# 社交意图：主动找人说话 → chat
	if _find_nearby_npc() != null:
		for kw in ["聊", "找", "问", "搭话", "对话", "聊聊", "问问", "招呼", "告诉"]:
			if kw in line: return "chat"
	# 走/移动 → move
	for kw in ["走", "逛", "散步", "移动", "转转", "溜达", "过去"]:
		if kw in line: return "move"
	# 思考/反省 → think
	for kw in ["想", "思考", "反省", "反思", "回忆", "琢磨"]:
		if kw in line: return "think"
	# 说/表达 → speak（社交感知会转 chat）
	for kw in ["说", "感慨", "吐槽", "碎碎念", "念叨", "感叹"]:
		if kw in line: return "speak"
	# 模糊回退：有附近人 → chat，否则随机 speak/move
	if _find_nearby_npc() != null:
		return "chat"
	return "speak" if randf() < 0.6 else "move"


func _make_decision() -> void:
	# busy guard：决策→执行整周期持锁（防 tick 重入 → _wait_http 实例变量竞态/LLM 堆积）。
	# chat/speak/think 用 await 等子动作完整跑完，末尾统一释放。
	_waiting_response = true
	await _maybe_daily_refresh()   # 每日任务刷新（跨天拉取+补足；持锁防与决策 LLM 竞态）
	var req = await APIManager.generate_dialog(_build_decision_prompt(), npc.npc_name)
	if req == null:
		_waiting_response = false
		_fallback_decision()
		return
	var result = await _wait_http(req, npc.npc_name)
	var raw_choice := ""
	if typeof(result) == TYPE_DICTIONARY:
		var api_type := _parse_api_type(npc.npc_name)
		raw_choice = APIConfig.parse_response(api_type, result)
	if raw_choice == null or raw_choice.strip_edges().is_empty():
		_waiting_response = false
		_fallback_decision()
		return
	raw_choice = raw_choice.strip_edges()
	var parsed: Dictionary = _parse_decision_v2(raw_choice)
	var action: String = str(parsed.get("action", ""))
	var decision_text := GameSession.str_or(parsed.get("text"))
	# 连续未移动累计：≥2 轮时注入 prompt 软引导（不强制改 action，保留 LLM 决策权）
	if action == "move":
		_idle_rounds = 0
	else:
		_idle_rounds += 1
	print("[npc-brain] %s 意图「%s」→ 动作 %s" % [npc.npc_name, decision_text.left(40), action])
	# 决策落 npc_logs（含完整意图文本，后台可回溯 NPC 当时在想什么）
	npc.post_npc_log("决策意图：%s → 动作：%s（情境：%s）" % [decision_text, action, _town_context().left(30)], "decision")
	npc.set_intent(_intent_tag(action, parsed))   # 头顶意图标签（持续到下轮决策）
	# 先应用状态变化（任何动作都可能带 status_change）
	_apply_status_change(parsed.get("status_change", {}))
	match action:
		"chat":
			# 全图感知：20 内直接聊；远处先走到目标身边（下次 tick 再聊）
			var _ct := _find_nearby_in_range()
			if _ct != null:
				await _start_chat(_ct)
			else:
				var _peer := _find_nearby_npc()
				if _peer == null:
					# 全图没人可聊，随机找个同事走去（下次 tick 可能触发 speak→chat）
					_peer = _pick_peer()
				if _peer != null:
					_auto_move("", _peer.npc_name)
					print("[npc-chat] %s 想聊，走向 %s" % [npc.npc_name, _peer.npc_name])
				_schedule_soon()
		"speak": await _auto_speak()
		"move":
			if npc.sitting:
				npc.stand_up()
			_auto_move(GameSession.str_or(parsed.get("target_room")),
					GameSession.str_or(parsed.get("target_person")))
		"think": await _think()
		"map_edit":
			var map_actions = await _generate_map_edit_detail(decision_text)
			if typeof(map_actions) == TYPE_ARRAY and not map_actions.is_empty():
				npc.post_map_actions(map_actions)
				_apply_map_actions_locally(map_actions)
			_schedule_soon()
		"create_task":
			_handle_create_task(await _generate_task_detail(decision_text))
			_schedule_soon()
		"complete_task":
			_handle_complete_task(await _generate_task_detail(decision_text))
			_schedule_soon()
		"use_item":
			_handle_use_item(await _generate_use_item_detail(decision_text))
			_schedule_soon()
		"trade":
			_handle_trade(await _generate_trade_detail(decision_text))
			_schedule_soon()
		"sit":
			_sit_down()
			_schedule_soon()
		"stand":
			if npc.sitting:
				npc.stand_up()
				npc.post_npc_log("起身", "move")
			_schedule_soon()
		_: _fallback_decision()
	_waiting_response = false   # 决策-执行链完成，允许下次 tick 决策


func _fallback_decision() -> void:
	# LLM 挂时只移动保底：不再 _auto_speak（LLM 不可用时再调 LLM 注定失败；且 fallback 在
	# _make_decision 释放 busy 后跑，异步 speak 会与下个 tick 决策并发踩 _wait_http 实例变量）。
	# LLM 不可用：不移动（移动应由 LLM 拿地图/人物位置后决定），原地待命
	print("[npc-brain] %s 决策回退（LLM 不可用）→ 原地待命" % npc.npc_name)
	npc.post_npc_log("决策（回退）：LLM 不可用，原地待命", "decision")


# ============================ 地图编辑（map_edit） ============================

# ponytail: 仅更新房间索引（NPC 空间感知），不做 TileMapLayer 逐格视觉更新。
# 视觉重建从 GET /maps/town/{id} 拉完整 chunk_json 重建，作为后续切片。
func _apply_map_actions_locally(actions: Array) -> void:
	for act in actions:
		if not act is Dictionary: continue
		match act.get("action", ""):
			"add_room":
				var room = act.get("room", {})
				if room is Dictionary and room.get("name"):
					if not _room_index.has(room["name"]):
						_room_index[room["name"]] = {
						"cx": float(room.get("cx", 0)), "cy": float(room.get("cy", 0)),
						"w": float(room.get("w", 100)), "h": float(room.get("h", 100))
					}
					print("[npc-brain] 加房间: %s" % room["name"])
					npc.post_npc_log("加房间：%s" % room["name"], "map_edit")
			"remove_room":
				var rn = act.get("room_name", "")
				if _room_index.erase(rn):
					print("[npc-brain] 删房间: %s" % rn)
					npc.post_npc_log("删房间：%s" % rn, "map_edit")
			_: pass  # tile/prefab 暂不本地更新


# ============================ 状态变化 ============================

# 确定性状态衰减：每决策轮心情/健康缓降，逼 NPC 主动恢复（社交/休息/用物品）。
# 复用 _apply_status_change（本地扣 + PATCH 落库），money 不衰减（只任务/交易变）。
func _apply_status_decay() -> void:
	_apply_status_change({
		"mood_delta": STATUS_DECAY_MOOD,
		"health_delta": STATUS_DECAY_HEALTH,
	})

func _apply_status_change(sc: Dictionary) -> void:
	if sc.is_empty(): return
	npc.apply_status_change(sc)


# ============================ 任务系统（队列 + 每日刷新 + LLM 生成） ============================

func _handle_create_task(task_data: Dictionary) -> void:
	var title: String = GameSession.str_or(task_data.get("title"))
	if title.is_empty(): return
	var priority: int = max(1, min(5, int(task_data.get("priority", 3))))
	var reward := int(task_data.get("reward", 0))
	npc.post_task_create(title,
		GameSession.str_or(task_data.get("description")),
		priority, reward)
	# 本地队列即时追加（id=0 表示尚未落库回读，下次刷新校准）
	npc.current_tasks.append({"id": 0, "title": title, "description": GameSession.str_or(task_data.get("description")), "priority": priority, "reward_money": reward})
	npc.current_tasks.sort_custom(func(a, b): return a["priority"] > b["priority"])


func _handle_complete_task(task_data: Dictionary) -> void:
	var task_title: String = GameSession.str_or(task_data.get("task_title"))
	var idx := -1
	if task_title.is_empty():
		idx = 0   # 没指定 → 完成最高优先级任务
	else:
		for i in range(npc.current_tasks.size()):
			if task_title.to_lower() in GameSession.str_or(npc.current_tasks[i].get("title")).to_lower():
				idx = i
				break
	if idx < 0 or idx >= npc.current_tasks.size():
		if not task_title.is_empty():
			npc.post_task_complete(task_title, "complete")   # 兜底：本地队列未命中，走旧标题匹配
		return
	var t: Dictionary = npc.current_tasks[idx]
	var tid := int(t.get("id", 0))
	if tid > 0:
		npc.post_task_complete_by_id(tid)
	else:
		npc.post_task_complete(GameSession.str_or(t.get("title")), "complete")
	npc.current_tasks.remove_at(idx)
	npc.post_npc_log("完成任务：%s" % GameSession.str_or(t.get("title")), "task")


# 任务队列 → 决策 prompt 文本（前 3 条按优先级，作为最高行动依据）
func _task_block() -> String:
	if npc.current_tasks.is_empty():
		return ""
	var s := "你当前的任务（按重要性排序，优先完成排在前面的）：\n"
	for i in range(min(3, npc.current_tasks.size())):
		var t: Dictionary = npc.current_tasks[i]
		var r := int(t.get("reward_money", 0))
		s += "- %s（重要度 %d%s）\n" % [GameSession.str_or(t.get("title")), int(t.get("priority", 3)), ("，赏金 %d 金币" % r) if r > 0 else ""]
	if npc.current_tasks.size() > 3:
		s += "（还有 %d 个任务未列出）\n" % (npc.current_tasks.size() - 3)
	return s


# 每日任务刷新：游戏时钟跨天时重拉队列；未完成 < 3 则 LLM 批量补足。持锁调用（_make_decision 内）。
func _maybe_daily_refresh() -> void:
	if GameSession.game_clock_min < 0:
		return
	var day := int(GameSession.game_clock_min / 1440)
	if _last_task_day == day:
		return
	await npc.fetch_tasks()
	if npc.current_tasks.size() < 3:
		await _generate_task_batch(3 - npc.current_tasks.size())
	if npc.current_tasks.size() >= 3:
		_last_task_day = day   # 补足成功才记日；失败下次决策重试（防 LLM 瞬时挂掉整日无任务）


# LLM 批量生成任务（每日刷新补足用）：JSON 数组 → 落库 + 本地队列。id 记 0，下次刷新校准。
func _generate_task_batch(n: int) -> void:
	if n <= 0: return
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_generate_tasks", FALLBACK_GENERATE_TASKS), {
		"name": npc.npc_name, "personality": npc.get_personality_prompt(), "count": str(n),
	})
	var data: Dictionary = await _llm_json(prompt)
	var arr = data.get("tasks")
	if typeof(arr) != TYPE_ARRAY:
		print("[task] %s 任务生成失败（LLM 无 tasks 数组，下轮决策重试）" % npc.npc_name)
		return
	for t in arr:
		if typeof(t) != TYPE_DICTIONARY: continue
		var title: String = GameSession.str_or(t.get("title"))
		if title.is_empty(): continue
		var priority: int = max(1, min(5, int(t.get("priority", 3))))
		var reward := int(t.get("reward", 0))
		npc.post_task_create(title, GameSession.str_or(t.get("description")), priority, reward)
		npc.current_tasks.append({"id": 0, "title": title, "description": GameSession.str_or(t.get("description")), "priority": priority, "reward_money": reward})
	npc.current_tasks.sort_custom(func(a, b): return a["priority"] > b["priority"])
	print("[task] %s 每日刷新：补充 %d 个任务" % [npc.npc_name, n])


# ============================ 物品使用 ============================

func _nearby_prefabs() -> Array:
	# 扫描 DynamicProps 里真实存在的物品（言出法随热更新后可感知）
	var all_prefabs: Array = []
	var dyn := _get_dynamic_props()
	if dyn:
		for c in dyn.get_children():
			var pn: String = String(c.get_meta("prefab_name", ""))
			if pn.is_empty(): continue
			if npc.position.distance_to(c.position) < 150:
				all_prefabs.append(pn)
	return all_prefabs


# 感知附近已建造的地图 tile（AI 造镇后，NPC 知道周围哪里建了墙/地板/路/树，避免重复铺同一块）
# 返回 "类型@(gridx,gridy)" 列表（最多 12 个），注入 map_edit prompt 让 LLM 知道地图现状。
func _nearby_tiles() -> Array:
	var out: Array = []
	var layer := _get_tiles_layer()
	if layer == null:
		return out
	var center := Vector2i(int(npc.position.x / 32), int(npc.position.y / 32))
	for dx in range(-3, 4):
		for dy in range(-3, 4):
			if out.size() >= 12:
				return out
			var cell := center + Vector2i(dx, dy)
			var atlas: Vector2i = layer.get_cell_atlas_coords(cell)
			if atlas == Vector2i(-1, -1) or atlas == Vector2i(0, 0):
				continue   # 空/草地不算"已建造"
			var name := _tile_atlas_name(atlas)
			if not name.is_empty():
				out.append("%s@(%d,%d)" % [name, cell.x, cell.y])
	return out


# 沿 parent 链找 OutdoorTown 的 Tiles 层（TileMapLayer）
func _get_tiles_layer() -> Node:
	var p := npc.get_parent()
	while p:
		var m = p.get("_map_node")
		if m != null and m is Node:
			var t = m.get_node_or_null("Tiles")
			if t: return t
		p = p.get_parent()
	return null


# atlas 坐标 → tile 语义名（供感知注入；road 含墙、roof 含地板，语义近似即可）
func _tile_atlas_name(atlas: Vector2i) -> String:
	match atlas:
		Vector2i(1, 0): return "tree"
		Vector2i(2, 0): return "road"
		Vector2i(3, 0): return "roof"
	return ""


# 定位 DynamicProps 节点（NPC 的 OnlineWorld 根下）
func _get_dynamic_props() -> Node:
	var p = npc.get_parent()
	while p:
		var d = p.get_node_or_null("DynamicProps")
		if d: return d
		p = p.get_parent()
	return null


func _handle_use_item(data: Dictionary) -> void:
	var prefab_name: String = GameSession.str_or(data.get("prefab_name"))
	var room_name: String = GameSession.str_or(data.get("room_name"))
	if prefab_name.is_empty(): return
	print("[npc-brain] %s 使用 %s（%s）" % [npc.npc_name, prefab_name, room_name])
	npc.post_npc_log("使用物品：%s / %s" % [prefab_name, room_name], "item_use")
	# 物品效果：咖啡机 → mood +0.08，打印机 → mood -0.03；顺带小幅回血（歇口气）
	match prefab_name.to_lower():
		"coffee_machine", "咖啡机", "饮水机": _apply_status_change({"mood_delta": 0.08, "health_delta": ITEM_HEALTH_GAIN})
		"printer", "打印机": _apply_status_change({"mood_delta": -0.03})
		_: _apply_status_change({"mood_delta": 0.03, "health_delta": ITEM_HEALTH_GAIN})


# ============================ 坐下休息（sit） ============================

# ponytail: 直接 teleport 到椅子（原版 sit_character 本就设 global_position，无寻路）。
# 占用 occupied 仅 owner 端权威，位置靠 _sync_positions 广播；要"走过去再坐"再补 move→sit 两段。
func _sit_down() -> void:
	if npc.sitting: return
	var best = null
	var best_d := 150.0
	for chair in get_tree().get_nodes_in_group("chairs"):
		if not is_instance_valid(chair): continue
		if bool(chair.get("occupied")): continue
		var d: float = npc.position.distance_to(chair.global_position)
		if d < best_d:
			best_d = d
			best = chair
	if best == null:
		print("[npc-sit] %s 想坐但附近没空椅子" % npc.npc_name)
		return
	if npc.sit_on(best):
		print("[npc-sit] %s 坐下" % npc.npc_name)
		npc.post_npc_log("坐下休息", "move")
		npc.apply_status_change({"health_delta": SIT_HEALTH_GAIN})


# ============================ 交易（trade） ============================

func _handle_trade(data: Dictionary) -> void:
	var target_name: String = GameSession.str_or(data.get("target_name"))
	if target_name.is_empty(): return
	var target_npc = _find_npc_by_name(target_name)
	if target_npc == null or target_npc.character_id == 0: return
	var offer_items: Array = data.get("offer_items", [])
	var request_items: Array = data.get("request_items", [])
	if not offer_items is Array: offer_items = []
	if not request_items is Array: request_items = []
	var offer_money := int(data.get("offer_money", 0))
	var request_money := int(data.get("request_money", 0))
	if offer_items.is_empty() and request_items.is_empty() and offer_money == 0 and request_money == 0:
		return
	print("[npc-trade] %s 发起交易" % npc.npc_name)
	npc.post_npc_log("发起交易，对象：%s" % target_name, "trade")
	npc.post_trade(target_npc.character_id, offer_items, offer_money, request_items, request_money)


func _find_npc_by_name(nm: String):
	nm = nm.strip_edges()
	if nm.is_empty(): return null
	var parent = npc.get_parent()
	if parent == null: return null
	for child in parent.get_children():
		if child.has_method("show_bubble") and child.npc_name.strip_edges() == nm:
			return child
	for child in parent.get_children():
		if child.has_method("show_bubble") and nm in child.npc_name:
			return child
	return null

# ============================ 内心独白（think） ============================

func _think() -> void:
	if not is_instance_valid(npc): return
	_state = State.THINKING
	var mem_block := ""
	if not npc.recent_memories.is_empty():
		mem_block = "最近的经历：\n- " + "\n- ".join(npc.recent_memories) + "\n"
	if not npc.core_memories.is_empty():
		mem_block += "核心记忆：\n- " + "\n- ".join(npc.core_memories) + "\n"
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_think", FALLBACK_THINK), {
		"name": npc.npc_name, "personality": npc.get_personality_prompt(),
		"town_context": _town_context(), "memories": mem_block,
	})
	var req = await APIManager.generate_dialog(prompt, npc.npc_name)
	if req == null:
		_state = State.IDLE
		return
	var result = await _wait_http(req, npc.npc_name)
	_state = State.IDLE
	if typeof(result) != TYPE_DICTIONARY: return
	var api_type := _parse_api_type(npc.npc_name)
	var text := APIConfig.parse_response(api_type, result)
	if text and text.strip_edges().length() > 0:
		text = text.strip_edges()
		npc.post_npc_log("内心独白：" + text, "inner_thought")
		npc.show_thought(text)
		print("[npc-think] %s 内心: %s" % [npc.npc_name, text.left(60)])
	_apply_status_change({"mood_delta": THINK_MOOD_GAIN})  # 自我调节回血：打破「低 mood→think→更低」单向触底
	_schedule_soon()  # 想完立即评估下一步


# ============================ 自主移动 ============================

func _auto_move(target_room: String = "", target_person: String = "") -> void:
	if not is_instance_valid(npc):
		return
	if npc.controlled_by_player or GameSession.pid != npc.owner_id:
		return
	if npc.has_meta("in_chat") and npc.get_meta("in_chat"):
		return   # 聊天中暂停移动
	_state = State.MOVING
	_ensure_room_index()
	var target := _resolve_move_target(target_room, target_person)
	npc.request_move(target)
	var _mdesc := _move_target_desc(target_room, target_person)
	print("[npc-move] %s → %s" % [npc.npc_name, _mdesc])
	npc.post_npc_log("移动 → %s" % _mdesc, "move")


# 解析移动目标：LLM 指定的人/房间优先（移动有明确目的），否则保底随机房间。
func _resolve_move_target(target_room: String, target_person: String) -> Vector2:
	if not target_person.is_empty():
		var peer = _find_npc_by_name(target_person)
		if peer != null:
			# 走到目标前方 ~15px（CHAT_RANGE=20 内，面对面聊天距离），而非完全重叠
			var d: Vector2 = peer.position - npc.position
			if d.length() < 1.0:
				d = Vector2(1, 0)
			return peer.position - d.normalized() * 15.0
	if not target_room.is_empty() and _room_index.has(target_room):
		var info: Dictionary = _room_index[target_room]
		return Vector2(float(info["cx"]), float(info["cy"]))
	return _pick_move_target()


func _move_target_desc(target_room: String, target_person: String) -> String:
	if not target_person.is_empty():
		return "找%s" % target_person
	if not target_room.is_empty():
		return target_room if _room_index.has(target_room) else (target_room + "(未知)")
	return "随处转转"


# 头顶意图标签文案：动作 → 短目标（→广场 / 找老张 / 思考中 …）。空动作返回 ""。
func _intent_tag(action: String, parsed: Dictionary) -> String:
	match action:
		"move":
			return "→" + _move_target_desc(GameSession.str_or(parsed.get("target_room")), GameSession.str_or(parsed.get("target_person")))
		"chat":
			var peer = _find_nearby_npc()
			return "找%s聊天" % (peer.npc_name if peer != null else "人")
		"think":
			return "思考中"
		"speak":
			return "自言自语"
		"map_edit":
			return "整理布置"
		"create_task":
			return "派任务"
		"complete_task":
			return "完成任务"
		"use_item":
			return "使用物品"
		"trade":
			return "去交易"
		"sit":
			return "找地方坐"
		"stand":
			return "起身"
		_:
			return ""


# 选一个有目的的移动目标：优先去同事所在的房间（自然聚集→可能触发聊天），
# 其次随机房间（探索），最后找具体同伴/漫游。去房间一律用房间中心，避免无目的乱晃。
func _pick_move_target() -> Vector2:
	var peer_rooms := _peer_room_centers()
	if not peer_rooms.is_empty() and randf() < 0.5:
		return peer_rooms[randi() % peer_rooms.size()] + Vector2(randf_range(-40, 40), randf_range(-40, 40))
	if not _room_index.is_empty() and randf() < 0.8:
		var keys := _room_index.keys()
		var rn: String = keys[randi() % keys.size()]
		var info: Dictionary = _room_index[rn]
		return Vector2(info["cx"], info["cy"]) + Vector2(randf_range(-40, 40), randf_range(-40, 40))
	var peer = _pick_peer()
	if peer != null:
		return peer.position + Vector2(randf_range(-60, 60), randf_range(-60, 60))
	return Vector2(
		randf_range(WANDER_BOUNDS.position.x, WANDER_BOUNDS.end.x),
		randf_range(WANDER_BOUNDS.position.y, WANDER_BOUNDS.end.y))


# 同事（兄弟 NPC）当前所在房间的中心列表，去重。让"去找人"的移动有明确终点。
func _peer_room_centers() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var parent = npc.get_parent()
	if parent:
		for other in parent.get_children():
			if other == npc or not (other is CharacterBody2D):
				continue
			if other.get("controlled_by_player"):
				continue
			var rn := _which_room(other.position)
			if rn.is_empty() or seen.has(rn):
				continue
			seen[rn] = true
			var info: Dictionary = _room_index[rn]
			out.append(Vector2(float(info["cx"]), float(info["cy"])))
	return out


# 找一个能聊天的附近 NPC（与 _check_nearby 共享聊天资质判断逻辑）
# 找一个能聊天的 NPC（全图感知，不限距离；返回最近符合条件的）。
# 聊天需要走到 CHAT_RANGE(20) 内——远处的人先走过去再聊。
func _find_nearby_npc() -> CharacterBody2D:
	var parent = npc.get_parent()
	if not parent: return null
	var now := Time.get_ticks_msec()
	var best: CharacterBody2D = null
	var best_dist := INF
	for other in parent.get_children():
		if not (other is CharacterBody2D) or other == npc: continue
		if other.has_meta("in_chat") and other.get_meta("in_chat"): continue
		if other.get("controlled_by_player"): continue
		var pk := _pair_key(npc.npc_name, other.npc_name)
		if chatting_pairs.has(pk): continue
		if chat_cooldowns.get(pk, 0) > now: continue
		var d := npc.position.distance_to(other.position)
		if d < best_dist:
			best_dist = d
			best = other
	return best

# 在 CHAT_RANGE(20) 内找可聊的人——用于"附近就直接聊"的快速路径。
func _find_nearby_in_range() -> CharacterBody2D:
	var p = _find_nearby_npc()
	if p == null: return null
	return p if npc.position.distance_to(p.position) <= CHAT_RANGE else null


func _pick_peer() -> Node2D:
	# 找一个未被玩家控制的兄弟 NPC 作为靠近目标
	var parent = npc.get_parent()
	if not parent:
		return null
	var peers: Array = []
	for other in parent.get_children():
		if other == npc or not (other is CharacterBody2D):
			continue
		if other.get("controlled_by_player"):
			continue
		peers.append(other)
	if peers.is_empty():
		return null
	return peers[randi() % peers.size()]


# ============================ 自主说话（独白） ============================

func _auto_speak() -> void:
	if not is_instance_valid(npc):
		return
	if npc.controlled_by_player or GameSession.pid != npc.owner_id:
		return
	if npc.has_meta("in_chat") and npc.get_meta("in_chat"):
		return   # 聊天中用互聊代替独白

	# 社交感知（全图）：有人可聊 → 20 内直接聊，远处先走过去
	var nearby = _find_nearby_npc()
	if nearby != null:
		if npc.position.distance_to(nearby.position) <= CHAT_RANGE:
			await _start_chat(nearby)
		else:
			_auto_move("", nearby.npc_name)
			print("[npc-chat] %s 想聊，走向 %s" % [npc.npc_name, nearby.npc_name])
		return

	_state = State.SPEAKING
	# RAG：检索与身边同事相关的最近记忆，注入 prompt（让 NPC 引用过往交流）
	var mems := await _search_memories(npc.character_id, _nearby_query(), 3)
	var mem_block := ""
	if not mems.is_empty():
		mem_block = "你最近的记忆：\n- " + "\n- ".join(mems) + "\n"
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_speak", FALLBACK_SPEAK), {
		"name": npc.npc_name, "personality": npc.get_personality_prompt(),
		"town_context": _town_context(), "memories": mem_block,
	})
	var req = await APIManager.generate_dialog(prompt, npc.npc_name)
	if req == null:
		_state = State.IDLE
		return
	var result = await _wait_http(req, npc.npc_name)
	_state = State.IDLE
	if typeof(result) != TYPE_DICTIONARY:
		_schedule_soon()
		return
	var api_type := _parse_api_type(npc.npc_name)
	var text := APIConfig.parse_response(api_type, result)
	if text and is_instance_valid(npc):
		text = text.strip_edges().replace('"', "")
		if text.length() > 0:
			npc.request_speak(text)
			npc.post_chat_log(text, npc.character_id)   # 落库 /chat_logs
			npc.post_npc_log("说：" + text, "speak")
			print("[npc-brain] ", npc.npc_name, " 说：", text)
	_schedule_soon()  # 说完话立即评估下一步


# 扫描同场 NPC，告诉模型小镇里有谁、谁在附近（让台词能呼应真实在场的人）
func _town_context() -> String:
	# 世界级上下文（时间/天气/世界观/新闻/规则）独立于同事存在：无同事时也注入。
	var world := _world_context()
	var parent = npc.get_parent()
	if not parent:
		return world
	var all_names := PackedStringArray()
	var near_names := PackedStringArray()
	for other in parent.get_children():
		if other == npc or not (other is CharacterBody2D):
			continue
		var nm: String = other.npc_name if "npc_name" in other else other.name
		if nm.is_empty():
			continue
		all_names.append(nm)
		if npc.position.distance_to(other.position) <= CHAT_RANGE:
			near_names.append(nm)
	var s := ""
	if all_names.is_empty():
		# 明说没人在场——persona 里提到的名字（暗恋对象/同事）不是在场角色，别对空气喊话/找人聊
		s = "小镇里现在只有你一个人，没有其他同事在场（设定里提到的人也不在）。"
	else:
		s = "小镇里的同事：" + ", ".join(all_names) + "。"
		if not near_names.is_empty():
			s += "此刻在你身边（可对话）：" + ", ".join(near_names) + "。"
		else:
			s += "此刻身边没人。"
		s += " " + _rooms_description()
	return world + s


# 世界级上下文：时间/天气/世界观/新闻/规则（房主权威，WS 写 GameSession，纯本地零 HTTP）。
# news=氛围性"最近发生的事"，rule=约束性"必须遵守的规则"（规则怪谈式，两类独立、不关联）。
func _world_context() -> String:
	var s := ""
	if GameSession.game_clock_min >= 0:
		var hh := int(GameSession.game_clock_min / 60) % 24
		var mm := GameSession.game_clock_min % 60
		var period := "黑夜" if (hh < 6 or hh >= 18) else "白天"
		s += "现在是%s，时刻 %02d:%02d。" % [period, hh, mm]
		if period == "黑夜" and _has_outdoor():
			s += " " + GameSession.prompt_templates.get("prompt_night_outdoor", FALLBACK_NIGHT_OUTDOOR)
		elif period == "白天" and _has_outdoor():
			s += " " + GameSession.prompt_templates.get("prompt_day_outdoor", FALLBACK_DAY_OUTDOOR)
	var w := GameSession.weather
	if not w.is_empty() and w != "clear":
		s += " 天气：" + _weather_cn(w) + "。"
	if not GameSession.world_background.is_empty():
		s += " 小镇背景：" + GameSession.world_background
	if not GameSession.company_info.is_empty():
		s += " 公司：" + GameSession.company_info
	if not GameSession.social_rules.is_empty():
		s += " 社交规则：" + GameSession.social_rules
	var news_arr := PackedStringArray()
	var rule_arr := PackedStringArray()
	for eid in GameSession.active_events:
		var ev = GameSession.active_events[eid]
		if ev is Dictionary:
			if ev.get("kind") == "news":
				news_arr.append(GameSession.str_or(ev.get("text")))
			elif ev.get("kind") == "rule":
				rule_arr.append(GameSession.str_or(ev.get("text")))
	if news_arr.size() > 0:
		s += " 最近发生的事：" + "; ".join(news_arr)
	if rule_arr.size() > 0:
		s += " 必须遵守的规则：" + "; ".join(rule_arr)
	return s.strip_edges()


func _weather_cn(w: String) -> String:
	match w.to_lower():
		"clear": return "晴"
		"rain": return "雨"
		"storm": return "暴风雨"
		"fog": return "雾"
		"snow": return "雪"
		"hot": return "酷热"
		_: return w


# ============================ 房间空间感知 ============================

# 构建房间索引（静态，所有大脑共享，首次调用异步拉取后端 /towns/{id}/rooms）
# 数据格式：[{name, cx, cy, w, h}, ...] — 每个小镇可不同，言出法随改地图后更新
static func _ensure_room_index() -> void:
	if _room_index_built: return
	_room_index_built = true
	if GameSession.town_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	var err := http.request(
		GameSession.api_base + "/towns/%d/rooms" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK: http.queue_free(); return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] != 200: return
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) != TYPE_ARRAY: return
	for r in data:
		if typeof(r) != TYPE_DICTIONARY: continue
		var rn: String = GameSession.str_or(r.get("name"))
		if rn.is_empty(): continue
		_room_index[rn] = {"cx": float(r.get("cx", 0)), "cy": float(r.get("cy", 0)),
						   "w": float(r.get("w", 100)), "h": float(r.get("h", 100)), "indoor": bool(r.get("indoor", true))}


func _which_room(pos: Vector2) -> String:
	_ensure_room_index()
	for rn in _room_index:
		var info: Dictionary = _room_index[rn]
		var c := Vector2(info["cx"], info["cy"]); var s := Vector2(info["w"], info["h"])
		if pos.x >= c.x - s.x / 2 and pos.x <= c.x + s.x / 2 and pos.y >= c.y - s.y / 2 and pos.y <= c.y + s.y / 2:
			return rn
	return ""


# 是否在同一房间。都在走廊/公共区（或房间索引未加载）时不限制，回退纯距离判定；
# 能识别房间时才禁止跨房聊天——避免隔着墙搭话。
func _same_room(a: Node2D, b: Node2D) -> bool:
	var ra := _which_room(a.position)
	if ra.is_empty():
		return true
	return ra == _which_room(b.position)


func _all_room_names() -> PackedStringArray:
	_ensure_room_index(); var out := PackedStringArray()
	for rn in _room_index: out.append(rn)
	return out


# 是否有室外房间（室内外分区）。房间无 indoor 字段或全 indoor → false（Office 老镇）。
func _has_outdoor() -> bool:
	_ensure_room_index()
	for rn in _room_index:
		if not bool(_room_index[rn].get("indoor", true)):
			return true
	return false


func _rooms_description() -> String:
	_ensure_room_index()
	if _room_index.is_empty(): return ""
	var my_room := _which_room(npc.position)
	var s := "小镇共有%d个房间：%s。" % [_room_index.size(), ", ".join(_all_room_names())]
	var indoor := PackedStringArray()
	var outdoor := PackedStringArray()
	for rn in _room_index:
		if bool(_room_index[rn].get("indoor", true)): indoor.append(rn)
		else: outdoor.append(rn)
	if not indoor.is_empty(): s += " 室内：" + ", ".join(indoor) + "。"
	if not outdoor.is_empty(): s += " 室外：" + ", ".join(outdoor) + "。"
	s += "你现在在%s。" % (my_room if not my_room.is_empty() else "走廊/公共区域")
	var parent = npc.get_parent()
	if parent:
		for other in parent.get_children():
			if other == npc or not (other is CharacterBody2D): continue
			var nm: String = other.npc_name if "npc_name" in other else other.name
			if nm.is_empty(): continue
			var oroom := _which_room(other.position)
			if not oroom.is_empty() and oroom != my_room:
				s += " %s在%s。" % [nm, oroom]
			elif oroom == my_room and oroom != "":
				s += " %s也在这里。" % nm
	return s


# RAG 检索：用 query（身边同事名 / 话题）查 NPC 的记忆，返回最近相关的 top_k 条内容。
# 失败/无记忆/未配置 embedding → 返回空数组，调用方照常生成。
func _search_memories(char_id: int, query: String, top_k: int = 3) -> Array:
	if char_id == 0 or GameSession.jwt.is_empty() or query.strip_edges().is_empty():
		return []
	# 跨 owner 对话：替对方 NPC 生成台词时查对方记忆会被 403（owner 守卫），提前跳过——
	# 对方记忆本就不该我方看到，静默无记忆注入即可
	if npc != null and is_instance_valid(npc) and npc.owner_id != GameSession.pid:
		return []
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"character_id": char_id, "query_text": query, "top_k": top_k})
	var err := http.request(
		GameSession.api_base + "/memories/search",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		_free_http(http)
		return []
	var resp = await _wait_http(http)
	_free_http(http)
	if typeof(resp) != TYPE_ARRAY:
		return []
	var out: Array = []
	for m in resp:
		if typeof(m) == TYPE_DICTIONARY:
			var c: String = GameSession.str_or(m.get("content"))
			if not c.is_empty():
				out.append(c)
	return out


func _free_http(http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()


# 作为记忆检索 query：身边同事名（有），否则自己的名字
func _nearby_query() -> String:
	var parent = npc.get_parent()
	if parent:
		var names := PackedStringArray()
		for other in parent.get_children():
			if other == npc or not (other is CharacterBody2D):
				continue
			if npc.position.distance_to(other.position) <= CHAT_RANGE:
				names.append(other.npc_name if "npc_name" in other else String(other.name))
		if not names.is_empty():
			return ", ".join(names)
	return npc.npc_name


# ============================ Phase 5：NPC 互聊 ============================

func _check_nearby() -> void:
	if not is_instance_valid(npc):
		return
	if npc.controlled_by_player or GameSession.pid != npc.owner_id:
		return
	if npc.has_meta("in_chat") and npc.get_meta("in_chat"):
		return
	var parent = npc.get_parent()
	if not parent:
		return
	var now := Time.get_ticks_msec()
	for other in parent.get_children():
		if not (other is CharacterBody2D) or other == npc:
			continue
		if other.has_meta("in_chat") and other.get_meta("in_chat"):
			continue
		if other.get("controlled_by_player"):
			continue
		# 全图感知：20 内直接聊；太远则走过去
		if npc.position.distance_to(other.position) > CHAT_RANGE:
			_auto_move("", other.npc_name)
			print("[npc-chat] %s 想聊，走向 %s" % [npc.npc_name, other.npc_name])
			return
		# 冷却检查
		var pair_key := _pair_key(npc.npc_name, other.npc_name)
		if chatting_pairs.has(pair_key):
			continue
		if chat_cooldowns.get(pair_key, 0) > now:
			continue
		# 触发对话
		await _start_chat(other)
		return   # 一次只聊一对


func _pair_key(a: String, b: String) -> String:
	# 保证同对无序一致
	return a + "|" + b if a < b else b + "|" + a


# 玩家（上帝）强制发起对话：T-L 邻近对话入口。把关：own 角色 + 未在聊 + 无冷却 + 距离 ≤ CHAT_RANGE。
# 距离要求玩家先把人挪到一起（点空地指挥走过去），与 NPC 自主聊天同标准。
# 返回空串 = 成功（已派发走过去/开聊）；非空 = 拒绝原因（给玩家看，别再用含糊的「聊不了」）。
func force_chat(other: CharacterBody2D) -> String:
	if not is_instance_valid(npc) or not is_instance_valid(other) or other == npc:
		return "目标无效"
	if npc.controlled_by_player:
		return "%s 正被你手动控制（按 B 退出控制再试）" % npc.npc_name
	if GameSession.pid != npc.owner_id:
		return "%s 不是你的角色" % npc.npc_name
	if _waiting_response:
		return "%s 正在思考/行动中，稍等再试" % npc.npc_name   # 决策-执行链进行中，避免并发踩 _wait_http 实例变量
	if npc.has_meta("in_chat") and npc.get_meta("in_chat"):
		return "%s 正在聊天" % npc.npc_name
	if other.has_meta("in_chat") and other.get_meta("in_chat"):
		return "%s 正在聊天" % other.npc_name
	var pair_key := _pair_key(npc.npc_name, other.npc_name)
	if chatting_pairs.has(pair_key) or chat_cooldowns.get(pair_key, 0) > Time.get_ticks_msec():
		return "%s 和 %s 刚聊过，冷却中" % [npc.npc_name, other.npc_name]
	_waiting_response = true   # 整周期持锁；_start_chat 所有退出路径都走 _end_chat → 锁在那释放
	if npc.position.distance_to(other.position) > CHAT_RANGE:
		_walk_over_and_chat(other)   # 太远：先走过去（到位自动开聊），别再要求玩家像素级凑到 20px 内
	else:
		_start_chat(other)   # 不 await：fire-and-forget（保持 try_start_chat_with 同步返回），对话全程后台跑
	return ""


# T-L 邻近对话太远时：走到目标前方 ~15px（复用 _resolve_move_target 的站位逻辑），到位自动开聊。
# 持锁轮询距离，12s 超时/目标失效则解锁放弃（对方走远/卡住）。锁从 force_chat 一路持到 _end_chat 释放。
func _walk_over_and_chat(other: CharacterBody2D) -> void:
	var d: Vector2 = other.position - npc.position
	if d.length() < 1.0:
		d = Vector2(1, 0)
	npc.set_meta("force_chat_walk", true)   # 玩家点空地的 move 指令不覆盖（走到位自动开聊）
	npc.request_move(other.position - d.normalized() * 15.0)
	npc.post_npc_log("走向 %s 开聊" % other.npc_name, "move")
	var timeout := Time.get_ticks_msec() + 12000
	while is_instance_valid(npc) and is_instance_valid(other):
		if npc.position.distance_to(other.position) <= CHAT_RANGE:
			npc.set_meta("force_chat_walk", false)
			_start_chat(other)
			return
		if Time.get_ticks_msec() > timeout:
			break
		await get_tree().create_timer(0.2).timeout
	npc.set_meta("force_chat_walk", false)
	_waiting_response = false   # 超时/目标失效：放弃，解锁


func _start_chat(other: CharacterBody2D) -> void:
	var pair_key := _pair_key(npc.npc_name, other.npc_name)
	chatting_pairs[pair_key] = true
	npc.set_meta("in_chat", true)
	other.set_meta("in_chat", true)
	_state = State.CHATTING

	print("[npc-chat] %s ←→ %s 开始对话（距离 %.0f）" % [npc.npc_name, other.npc_name, npc.position.distance_to(other.position)])
	npc.post_npc_log("与 %s 开始对话" % other.npc_name, "chat")

	# 随机谁先开口
	var speaker: CharacterBody2D = npc
	var listener: CharacterBody2D = other
	if randf() < 0.5:
		speaker = other
		listener = npc

	# 累积对话历史，每轮回喂 prompt（防逐字重复 + 让模型判断是否聊尽→[离开]）
	var history: Array = []

	# 第 1 轮：发起者开口（必须说话）
	var prev := await _generate_chat_line(speaker, listener, "", true, false, history)
	if prev.is_empty():
		_end_chat(pair_key, npc, other)
		return
	_say_and_remember(speaker, listener, prev)
	history.append("%s：%s" % [speaker.npc_name, prev])
	# 记录本次对话话题（跨对话防回音室，限最近 5 条）
	_recent_topics.append(prev)
	if _recent_topics.size() > 5:
		_recent_topics = _recent_topics.slice(-5)
	await get_tree().create_timer(1.5).timeout   # 留气泡显示时间

	# 后续轮：接话者由大模型决定——正常回应，或返回 [离开] 走开。
	# 上限走 GameSession.chat_max_rounds（/config/public 拉取，可在后台改）；默认 8。
	var max_rounds := GameSession.room_chat_max_rounds if GameSession.room_chat_max_rounds > 0 else (GameSession.chat_max_rounds if GameSession.chat_max_rounds > 0 else 8)
	var rounds := 1
	while rounds < max_rounds:
		var tmp = speaker   # 交换发言权
		speaker = listener
		listener = tmp
		var line := await _generate_chat_line(speaker, listener, prev, false, true, history)
		if line.is_empty():
			break   # 生成失败/空，结束
		if line.begins_with(LEAVE_TOKEN):
			_walk_away(speaker, listener)
			break
		_say_and_remember(speaker, listener, line)
		history.append("%s：%s" % [speaker.npc_name, line])
		prev = line
		rounds += 1
		await get_tree().create_timer(1.5).timeout

	# 对话结束：LLM 写摘要（→memory_vectors）+ 提炼核心事实（→core_memories_json）
	if history.size() >= 2:  # 至少一来一回才值得总结
		await _summarize_chat(npc, other, history)
		# 社交=回血：双方心情恢复（闭环补强——衰减确定、恢复全靠 LLM 自愿，低 mood NPC 偏 think 会单向触底）
		if is_instance_valid(npc):
			npc.apply_status_change({"mood_delta": CHAT_MOOD_GAIN})
		if is_instance_valid(other):
			other.apply_status_change({"mood_delta": CHAT_MOOD_GAIN})

	_end_chat(pair_key, npc, other)


# 说出口（广播气泡）+ 落库 chat_logs。记忆由对话结束时 _summarize_chat 统一写摘要。
func _say_and_remember(speaker: CharacterBody2D, listener: CharacterBody2D, line: String) -> void:
	speaker.request_speak(line)
	speaker.post_chat_log(line, speaker.character_id, listener.character_id)
	speaker.post_npc_log("对 %s 说：%s" % [listener.npc_name, line], "chat")


# 大模型选择不接话/离开：让该 NPC 朝远离对方的方向走开
func _walk_away(leaver: CharacterBody2D, partner: CharacterBody2D) -> void:
	var dir := leaver.position - partner.position
	if dir.length() < 1.0:
		dir = Vector2(randf_range(-1, 1), randf_range(-1, 1))
	dir = dir.normalized()
	leaver.request_move(leaver.position + dir * 280.0)


func _generate_chat_line(speaker: CharacterBody2D, listener: CharacterBody2D, prev_line: String, is_opening: bool, can_leave: bool, history: Array) -> String:
	var sn: String = speaker.npc_name
	var sb: String = speaker.get_personality_prompt()
	var ln: String = listener.npc_name
	var lb: String = listener.get_personality_prompt()
	# RAG：检索与 listener 相关的记忆（接话时带上一句，命中更准）
	var mem_query := ln if prev_line.is_empty() else (ln + " " + prev_line)
	# 跨 owner 替对方生成台词时不查对方记忆（会被 403，且对方记忆本就不该我方检索）
	var mems: Array = []
	if speaker.owner_id == GameSession.pid:
		mems = await _search_memories(speaker.character_id, mem_query, 3)
	var mem_block := ""
	if not mems.is_empty():
		mem_block = "你对%s的相关记忆：\n- " % ln + "\n- ".join(mems) + "\n"
	# 对话历史喂回（防逐字重复；让模型据此判断话题是否聊尽→可 [离开]）
	var hist_block := ""
	if history.size() > 0:
		hist_block = "你们的对话记录（不要重复已说过的话）：\n" + "\n".join(history) + "\n"

	# 当下情境（导演模式：时间/天气/事件/规则/世界观）注入对话，让 NPC 聊起房主导演的内容
	var world := _world_context()
	var world_block := "当下情境：" + world + "\n" if not world.is_empty() else ""
	# 跨对话话题记录：开场提醒最近聊过的，引导换话题（防回音室反复聊同一主题）
	var topic_block := ""
	if is_opening and not _recent_topics.is_empty():
		topic_block = "你最近和同事聊过：%s。这次开场换个新鲜话题（可结合当下情境：天气/最近发生的事/规则/公司背景）。\n" % "；".join(_recent_topics)
	var prompt: String
	if is_opening:
		prompt = fill_template(GameSession.prompt_templates.get("prompt_chat_opening", FALLBACK_CHAT_OPENING), {
			"sn": sn, "sb": sb, "mem_block": mem_block, "world_block": world_block,
			"topic_block": topic_block, "ln": ln, "lb": lb,
		})
	else:
		var opt := ("根据你的性格、对话内容和当下心情，判断要不要继续：想走开或不接话就只回复「%s」；否则回一句新台词（不超过20字，只输出台词本身，不要引号/括号/动作描述，绝不能和对话记录里重复）。话题已聊尽时优先选择离开。" % LEAVE_TOKEN) if can_leave else "回一句新台词（不超过20字，只输出台词本身，不要引号/括号/动作描述，不要重复）。"
		prompt = fill_template(GameSession.prompt_templates.get("prompt_chat_reply", FALLBACK_CHAT_REPLY), {
			"sn": sn, "sb": sb, "mem_block": mem_block, "world_block": world_block,
			"hist_block": hist_block, "opt": opt,
		})

	# 按 speaker 分流 AI 设置：跨 owner 对话替对方生成台词时用对方的模型（谁的人格谁的声音）
	var req = await APIManager.generate_dialog(prompt, sn)
	if req == null:
		return ""
	var result = await _wait_http(req, sn)
	if typeof(result) != TYPE_DICTIONARY:
		return ""
	var api_type := _parse_api_type(sn)   # 台词按 sn 分流生成，解析也用 sn 的 provider
	var text := APIConfig.parse_response(api_type, result)
	if text:
		text = text.strip_edges().replace('"', "")
		if not text.begins_with(LEAVE_TOKEN):
			print("[npc-chat] %s 说：%s" % [sn, text])
	return text


# 用实例变量 + 方法回调等待 HTTP 响应（独白 _on_speak_response 同款可靠写法）。
# lambda 捕获局部变量在跨 await 挂起时不可靠，会导致聊天永远拿不到响应 → 故弃用。
func _wait_http(req: HTTPRequest, key: String = "") -> Variant:
	_hr_done = false
	_hr_result = null
	_hr_key = key
	if not req.request_completed.is_connected(_on_hr_done):
		req.request_completed.connect(_on_hr_done)
	var waited := 0.0
	while not _hr_done and waited < 25.0:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if not _hr_done:
		pass   # 超时静默：_hr_result 为 null，调用方按"无响应"处理
	return _hr_result


func _on_hr_done(_r: int, _c: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	_hr_result = JSON.parse_string(body.get_string_from_utf8())
	if _hr_result is Dictionary:
		var u := APIConfig.extract_usage(_hr_result)
		var pt := int(u["prompt_tokens"])
		var ct := int(u["completion_tokens"])
		if pt > 0 or ct > 0:
			var provider := ""
			if not _hr_key.is_empty():
				provider = _parse_api_type(_hr_key)
			GameSession.add_token_usage(_hr_key, provider, pt, ct)
	_hr_done = true


func _end_chat(pair_key: String, a: CharacterBody2D, b: CharacterBody2D) -> void:
	chatting_pairs.erase(pair_key)
	chat_cooldowns[pair_key] = Time.get_ticks_msec() + int(CHAT_COOLDOWN * 1000)
	if is_instance_valid(a):
		a.remove_meta("in_chat")
	if is_instance_valid(b):
		b.remove_meta("in_chat")
	_state = State.IDLE
	_waiting_response = false   # force_chat 入口持的锁在此释放（_make_decision 路径末尾也重复释放，幂等无害）
	print("[npc-chat] %s ←→ %s 对话结束" % [a.npc_name if is_instance_valid(a) else "?", b.npc_name if is_instance_valid(b) else "?"])
	_schedule_soon()  # 聊完立即重新评估下一步


# 对话结束后一次 LLM 调用：生成摘要（→双方各写 memory_vectors/interaction）+ 提炼核心事实（→双方各 append core_memories_json）。
# ponytail: JSON parse 失败降级用末句当摘要、不追加事实（稳，聊天原文已全量存 chat_logs）。
func _summarize_chat(a: CharacterBody2D, b: CharacterBody2D, history: Array) -> void:
	var sn: String = a.npc_name; var ln: String = b.npc_name
	var prompt := fill_template(GameSession.prompt_templates.get("prompt_summarize", FALLBACK_SUMMARIZE), {
		"sn": sn, "ln": ln, "history": "\n".join(history),
	})
	var req = await APIManager.generate_dialog(prompt, npc.npc_name)
	if req == null:
		return
	var resp = await _wait_http(req, npc.npc_name)
	if typeof(resp) != TYPE_DICTIONARY:
		return
	var api_type := _parse_api_type(npc.npc_name)
	var raw := APIConfig.parse_response(api_type, resp)
	if raw == null or raw.strip_edges().is_empty():
		return
	raw = raw.strip_edges()
	# DeepSeek etc 可能把 JSON 包在 ```json ... ``` 里
	if raw.begins_with("```"):
		var i := raw.find("\n")
		raw = raw.substr(i + 1) if i != -1 else raw
		if raw.ends_with("```"):
			raw = raw.substr(0, raw.length() - 3)
		raw = raw.strip_edges()
	var jp := JSON.new()
	var data = jp.data if jp.parse(raw) == OK else null
	if typeof(data) != TYPE_DICTIONARY:
		return
	var summary: String = GameSession.str_or(data.get("summary"))
	var facts: Array = []
	var raw_facts = data.get("core_facts")
	if typeof(raw_facts) == TYPE_ARRAY:
		for f in raw_facts:
			if typeof(f) in [TYPE_STRING, TYPE_STRING_NAME] and not str(f).strip_edges().is_empty():
				facts.append(str(f).strip_edges())
	# 双方各写 memory_vectors（摘要，interaction 类型）
	if not summary.is_empty():
		a.post_memory("与%s的对话摘要：%s" % [ln, summary], a.character_id, "interaction", 3)
		b.post_memory("与%s的对话摘要：%s" % [sn, summary], b.character_id, "interaction", 3)
	# 双方各追加 core_memories
	if not facts.is_empty():
		a.post_core_memories(facts)
		b.post_core_memories(facts)
	# 关系演化：LLM 给双向好感变化（a_to_b/b_to_a，钳到 -0.3~0.3），叠加双方 relations 并 PATCH
	var d_ab := clampf(_json_float(data, "a_to_b"), -0.3, 0.3)
	var d_ba := clampf(_json_float(data, "b_to_a"), -0.3, 0.3)
	if not summary.is_empty():
		_apply_relation_delta(a, ln, d_ab, summary)
		_apply_relation_delta(b, sn, d_ba, summary)


# 从 LLM JSON 取浮点（缺失/空/非数 → 0.0），容错 LLM 偶发 null/字符串/对象。
func _json_float(data: Dictionary, key: String) -> float:
	var v = data.get(key, null)
	if v == null:
		return 0.0
	if typeof(v) in [TYPE_FLOAT, TYPE_INT]:
		return float(v)
	if typeof(v) == TYPE_STRING:
		var f := float(v)
		return f if not is_nan(f) else 0.0
	return 0.0


# 把好感增量叠加到 char_node 对 other_name 的 relations 条目（affinity 钳 -1~1，note 取对话摘要），再 PATCH 落库。
func _apply_relation_delta(char_node: CharacterBody2D, other_name: String, delta: float, note: String) -> void:
	if not is_instance_valid(char_node) or other_name.is_empty() or delta == 0.0:
		return
	# 多 owner 边界：只写本地玩家拥有的角色。单房主拥有全镇→守卫不触发、现状不变；
	# 多 owner 时对方角色由其 owner 的 brain 更新自己的视角（非己方角色 PATCH 也会被后端 403）
	if char_node.owner_id != GameSession.pid:
		return
	var entry = char_node.relations.get(other_name, {})
	if typeof(entry) != TYPE_DICTIONARY:
		entry = {}
	var new_aff := clampf(float(entry.get("affinity", 0.0)) + delta, -1.0, 1.0)
	entry["affinity"] = new_aff
	entry["note"] = note.left(30)
	char_node.relations[other_name] = entry
	char_node.patch_relations(char_node.relations.duplicate(true))
	print("[relations] %s → %s 好感 %+.2f → %.2f" % [char_node.npc_name, other_name, delta, new_aff])
