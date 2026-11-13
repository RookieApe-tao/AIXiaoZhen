extends CharacterBody2D
# 联机 NPC：server 权威位置 + show_speech 广播；大脑（决策 LLM）在 owner 客户端（NetworkNPCBrain）。
# 2026-08-12：卡住检测 + state 字段对齐大脑升级。

# 8 张角色表布局一致（32×64 帧，同 DIR_X 映射），运行时随机挑一张区分外观
const SPRITE_SHEETS := [
	"res://asset/characters/body/Alicex32.png",
	"res://asset/characters/body/Gracex32.png",
	"res://asset/characters/body/Jackx32.png",
	"res://asset/characters/body/Joex32.png",
	"res://asset/characters/body/Leax32.png",
	"res://asset/characters/body/Monicax32.png",
	"res://asset/characters/body/Stephenx32.png",
	"res://asset/characters/body/Tomx32.png",
]
# 按性别选精灵子集（Alice/Grace/Lea/Monica 女；Jack/Joe/Stephen/Tom 男）
const SPRITE_MALE := ["res://asset/characters/body/Jackx32.png", "res://asset/characters/body/Joex32.png", "res://asset/characters/body/Stephenx32.png", "res://asset/characters/body/Tomx32.png"]
const SPRITE_FEMALE := ["res://asset/characters/body/Alicex32.png", "res://asset/characters/body/Gracex32.png", "res://asset/characters/body/Leax32.png", "res://asset/characters/body/Monicax32.png"]
const FRAME_W := 32
const FRAME_H := 64
const FRAME_COUNT := 6
const DIR_X := {"down": 576, "left": 384, "right": 0, "up": 192}
const DIALOG_BUBBLE := preload("res://scene/ui/DialogBubble.tscn")
const SPEED := 100.0

signal gave_up_stuck   # 卡死放弃：owner 端 brain 收到后立即重新决策，不再原地冻到下轮 tick
var navigation_path: PackedVector2Array = PackedVector2Array()
var path_index := 0
var _prev_pos := Vector2.ZERO
var facing := "down"
# 卡住检测（从原版 CharacterController 移植）
var _stuck_timer := 0.0
var _last_stuck_pos := Vector2.ZERO
var _recalc_count := 0
const STUCK_THRESHOLD := 0.8
const MAX_RECALC := 4

var npc_name := "":
	set(v):
		npc_name = v
		if _label:
			_label.text = v
var personality_text := ""   # 可能为 JSON 编码的五字段结构，或旧版纯文本
var persona: Dictionary = {}  # 解析后缓存：position/personality/speaking_style/work_duties/work_habits/notes
var owner_id := 1   # 拥有者 peer id（大脑在 owner 端跑；host 自带时 owner=1）
var character_id := 0   # 后端角色 id（POST /chat_logs 用 speaker_id；0=未关联，不落库）
var controlled_by_player := false
# 角色状态数值（AI 任务/决策驱动，后端 /characters/{id}/status 持久化）
var mood := 0.6       # 0-1 心情
var money := 100       # 金币
var health := 1.0      # 0-1 健康
var items_json: Array = []   # [{name, qty}, ...] 物品栏
var sitting := false        # 是否坐在椅子上（owner 端权威，位置靠 _sync_positions 广播）
var current_chair = null    # 当前坐的椅子节点
var is_player := false              # 标记为玩家角色（vs AI NPC），跨端一致  # 本地：本客户端是否正在手动控制此角色（不复制，不 Synchronizer）
var core_memories: Array = []      # 从对话总结提炼的稳定核心事实（每次全量注入 prompt，不检索）
var relations: Dictionary = {}     # {"他人名":{"affinity":0~1,"tags":[],"note":""}} 对他人动态关系（注入 prompt）
var recent_memories: Array = []    # 最近 N 条 memory_vectors 记录（决策循环上下文，启动加载）
var current_tasks: Array = []      # 未完成任务队列 [{id,title,description,priority,reward_money}]（优先级降序，brain 每日刷新）
var _sprite: AnimatedSprite2D
var _label: Label
var _intent_label: Label   # 头顶意图标签（当前目标：→广场 / 找老张）
var _brain: Node = null    # owner 端的大脑实例（_ready 建；T-L 对话入口用）


func _ready() -> void:
	_sprite = $AnimatedSprite2D
	_label = $NameLabel
	_intent_label = Label.new()
	_intent_label.offset_left = -80.0
	_intent_label.offset_top = 60.0
	_intent_label.offset_right = 80.0
	_intent_label.offset_bottom = 76.0
	_intent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intent_label.add_theme_font_size_override("font_size", maxi(9, GameSession.int_or(GameSession.ui_config.get("ui_font_size", null), GameSession.FALLBACK_UI_FONT_SIZE) - 12))
	_intent_label.add_theme_color_override("font_color", Color.WHITE)
	_intent_label.visible = false
	add_child(_intent_label)
	_build_frames()
	_prev_pos = position
	if npc_name:
		_label.text = npc_name
	_sprite.play("idle_down")
	if controlled_by_player and has_node("Camera2D"):
		$Camera2D.enabled = true
	# 大脑只在 owner 端实例化（owner 跑决策 LLM，用 owner 本地 BYOK）
	if GameSession.pid == owner_id:
		var brain = preload("res://script/net/NetworkNPCBrain.gd").new()
		brain.npc = self
		add_child(brain)
		_brain = brain


# 上帝 T-L 邻近对话：玩家强制本 NPC 与 other 开聊（复用 brain 完整对话闭环）。
# 仅 owner 端有效（brain 在 owner 端跑）；busy/in_chat/冷却由 brain 侧把关。
func try_start_chat_with(other: CharacterBody2D) -> String:
	if _brain == null or not is_instance_valid(_brain) or not is_instance_valid(other):
		return "未连接 NPC 大脑"
	return _brain.force_chat(other)


func setup_npc(p_name: String, p_bg: String, p_owner: int, p_char_id: int = 0, p_persona: Dictionary = {}) -> void:
	npc_name = p_name
	personality_text = p_bg
	owner_id = p_owner
	character_id = p_char_id
	_parse_persona(p_persona)
	_build_frames()   # persona 解析后按性别重建精灵（_ready 时 persona 还没设）


func _parse_persona(p_dict: Dictionary = {}) -> void:
	persona = {}
	# 优先用服务端 personality_json（JSONB），其次解析 background 里的 JSON 字符串（旧方案）
	if not p_dict.is_empty() and p_dict.has("position"):
		persona = p_dict.duplicate()
		return
	if personality_text.begins_with("{") and personality_text.ends_with("}"):
		var parsed = JSON.parse_string(personality_text)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("position"):
			persona = parsed
			return
	# 旧版纯文本：用整个文本当"补充设定"
	if not personality_text.is_empty():
		persona["notes"] = personality_text


func get_personality_prompt() -> String:
	# 返回格式化成 prompt 可用的人设文本（含核心记忆注入）
	var base := ""
	if persona.has("position"):
		var parts := PackedStringArray()
		parts.append("职位：" + persona.get("position", ""))
		if persona.get("gender", "") != "":
			parts.append("性别：" + persona["gender"])
		parts.append("性格：" + persona.get("personality", ""))
		parts.append("说话风格：" + persona.get("speaking_style", ""))
		parts.append("工作职责：" + persona.get("work_duties", ""))
		parts.append("工作习惯：" + persona.get("work_habits", ""))
		if persona.get("notes", "") != "":
			parts.append("补充设定：" + persona["notes"])
		base = "\n".join(parts)
	elif persona.has("notes"):
		base = persona["notes"]
	if not core_memories.is_empty():
		base += "\n你的核心记忆（经常回想这些事）：\n- " + "\n- ".join(core_memories)
	return base


func _build_frames() -> void:
	if _sprite == null:
		return   # 未入树（setup_npc 在 add_child 前被调），_ready 会再调一次补建
	# 按性别挑子集（persona.gender），子集内按名字哈希（跨端一致 + 外观区分）
	var pool: Array = SPRITE_SHEETS
	var g := GameSession.str_or(persona.get("gender")).to_lower()
	if g == "男" or g == "male" or g == "m":
		pool = SPRITE_MALE
	elif g == "女" or g == "female" or g == "f":
		pool = SPRITE_FEMALE
	var sheet: String = pool[npc_name.hash() % pool.size()] if not npc_name.is_empty() else pool[0]
	var tex := load(sheet)
	var frames := SpriteFrames.new()
	for dir in DIR_X:
		var x0: int = DIR_X[dir]
		for kind in ["idle", "run"]:
			var y := 64 if kind == "idle" else 128
			var aname := "%s_%s" % [kind, dir]
			frames.add_animation(aname)
			frames.set_animation_speed(aname, 5.0 if kind == "idle" else 10.0)
			frames.set_animation_loop(aname, true)
			for i in FRAME_COUNT:
				var at := AtlasTexture.new()
				at.atlas = tex
				at.region = Rect2(x0 + i * FRAME_W, y, FRAME_W, FRAME_H)
				frames.add_frame(aname, at)
	_sprite.sprite_frames = frames


# owner 客户端调（any_peer）：请求说话。server 收到校验非空后广播 show_speech。
func request_speak(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	show_bubble(text)
	_broadcast_speech(text)


var _active_bubble: Node = null   # 当前气泡：新泡出现前先释放旧的（决策最短 3s 一轮 < 5s 气泡时长，不换会两泡叠显）

func _show_bubble_common() -> Node:
	# 每 NPC 同时只留一个泡
	if is_instance_valid(_active_bubble):
		_active_bubble.queue_free()
	var bubble = DIALOG_BUBBLE.instantiate()
	get_tree().root.add_child(bubble)
	bubble.target_node = self
	_active_bubble = bubble
	return bubble

# server 广播：各端在该 NPC 副本上显示气泡（duration 后自释放）。
# 气泡只显前 20 字（本地/远端统一截断），广播与落库仍是全文。
func show_bubble(text: String) -> void:
	if text.length() > 20:
		text = text.substr(0, 20) + "…"
	_show_bubble_common().show_dialog(text)  # duration 走配置 bubble_duration_sec


# 内心独白气泡（仅 owner 端本地显示，不广播）：贴底染色淡紫，字深灰斜体——与说话白泡同版式。
func show_thought(text: String) -> void:
	if text.length() > 20:
		text = text.substr(0, 20) + "…"   # 气泡只显前 20 字，npc_logs 落库全文
	var bubble := _show_bubble_common()
	bubble.tint(Color(0.90, 0.84, 0.99))
	bubble.show_dialog(text)  # duration 走配置 bubble_duration_sec


# 头顶意图标签：决策轮设置当前目标（→广场 / 找老张），空串隐藏。
# owner 端脑调时顺带广播（跨端可见别人 NPC 在干嘛）；远端收到 "intent" 消息也走这里（_from_remote 防回声再广播）。
func set_intent(text: String, _from_remote := false) -> void:
	if not is_instance_valid(_intent_label):
		return
	_intent_label.text = text
	# 受配置 show_npc_intent_label 控制（演示可关去杂）；非空文本才显示
	var show_label := GameSession.bool_or(GameSession.ui_config.get("show_npc_intent_label", null), GameSession.FALLBACK_SHOW_INTENT_LABEL)
	_intent_label.visible = show_label and text != ""
	if not _from_remote and owner_id == GameSession.pid:
		var world = get_tree().current_scene
		if world and world.has_method("_broadcast"):
			world._broadcast({"t": "intent", "pid": GameSession.pid, "npc": name, "text": text})


# ============================ 移动（server 权威，navmesh 防穿墙） ============================

# owner 客户端调（any_peer）：请求移动到 target。server 收到后 move_to（NavigationServer 算 navmesh 路径）
func request_move(target: Vector2) -> void:
	move_to(target)


func move_to(target: Vector2) -> void:
	# 搬 CharacterController.move_to 核心：NavigationServer2D 算 navmesh 路径（绕墙），空路径回退直线
	var path_params := NavigationPathQueryParameters2D.new()
	path_params.map = get_world_2d().navigation_map
	path_params.start_position = global_position
	path_params.target_position = target
	path_params.path_postprocessing = NavigationPathQueryParameters2D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	var path_result := NavigationPathQueryResult2D.new()
	NavigationServer2D.query_path(path_params, path_result)
	navigation_path = path_result.path
	if navigation_path.is_empty():
		navigation_path = PackedVector2Array([global_position, target])   # navmesh 不可达时回退直线
	path_index = 0


func _physics_process(delta: float) -> void:
	# 统一控制：controlled_by_player（本地标记）优先；否则 server 权威走 AI 寻路。
	# 仅 owner 端才跑 WASD——远端 copy 也被 _handle_control 置了 controlled_by_player，但它只用于
	# 玩家列表显示「谁在控制谁」，不能在这里读本地键盘（否则原地踏步、靠 REMOTE_SNAP_DIST 瞬移才追上）。
	if controlled_by_player and GameSession.pid == owner_id:
		_player_wasd()
		move_and_slide()
	elif GameSession.pid == owner_id:
		# 聊天中冻结：清掉残留路径 + 速度归零，不走动；_end_chat 清掉 in_chat 后才恢复
		if has_meta("in_chat") and get_meta("in_chat"):
			navigation_path = PackedVector2Array()
			velocity = Vector2.ZERO
		else:
			_follow_path(delta)
		move_and_slide()
	elif _has_remote_target:
		# 远端 NPC：lerp 追 owner 广播的目标点（消 WS 抖动抽搐）
		position = position.lerp(_remote_target, clampf(REMOTE_LERP_RATE * delta, 0.0, 1.0))

	if delta > 0.0 and not _has_remote_target:
		_update_anim((position - _prev_pos) / delta)   # 远端动画由 apply_remote_state 驱动，本地速度算会跟它打架（抽搐）
	_prev_pos = position
	z_index = int(position.y)   # y 排序：与动态家具同基准，前后遮挡


func _player_wasd() -> void:
	var v := Vector2.ZERO
	var focused = get_viewport().gui_get_focus_owner()
	if not (focused is LineEdit or focused is TextEdit):
		if Input.is_key_pressed(KEY_W): v.y -= 1
		if Input.is_key_pressed(KEY_S): v.y += 1
		if Input.is_key_pressed(KEY_A): v.x -= 1
		if Input.is_key_pressed(KEY_D): v.x += 1
	velocity = v.normalized() * SPEED


func _follow_path(delta: float) -> void:
	if navigation_path.is_empty():
		velocity = Vector2.ZERO
		return
	if path_index >= navigation_path.size():
		navigation_path = PackedVector2Array()
		velocity = Vector2.ZERO
		_recalc_count = 0
		_stuck_timer = 0.0
		return
	var next_point: Vector2 = navigation_path[path_index]
	velocity = (next_point - global_position).normalized() * SPEED
	if global_position.distance_to(next_point) < 12.0:
		path_index += 1
		_recalc_count = 0
		_stuck_timer = 0.0
		return
	# 卡住检测：从原版 CharacterController._check_if_stuck 移植。
	# 0.8s 内位移 <5px → 加偏移重算路径，4 次仍不动 → 放弃并让 brain 立即重新决策（不再原地冻 25s）。
	if global_position.distance_to(_last_stuck_pos) < 5.0:
		_stuck_timer += delta
		if _stuck_timer >= STUCK_THRESHOLD:
			_recalc_count += 1
			if _recalc_count <= MAX_RECALC:
				_recalculate_path()
				_stuck_timer = 0.0
			else:
				navigation_path = PackedVector2Array()
				velocity = Vector2.ZERO
				gave_up_stuck.emit()
	else:
		_stuck_timer = 0.0
		_last_stuck_pos = global_position


func _recalculate_path() -> void:
	if navigation_path.is_empty(): return
	var target := navigation_path[navigation_path.size() - 1]
	var offset := Vector2(randf_range(-60, 60), randf_range(-60, 60)) * (1 + _recalc_count)
	var path_params := NavigationPathQueryParameters2D.new()
	path_params.map = get_world_2d().navigation_map
	path_params.start_position = global_position
	path_params.target_position = target + offset
	path_params.path_postprocessing = NavigationPathQueryParameters2D.PATH_POSTPROCESSING_CORRIDORFUNNEL
	var path_result := NavigationPathQueryResult2D.new()
	NavigationServer2D.query_path(path_params, path_result)
	navigation_path = path_result.path
	if navigation_path.is_empty():
		navigation_path = PackedVector2Array([global_position, target])   # 最后手段：直线
	path_index = 0


func _update_anim(v: Vector2) -> void:
	var moving := v.length() > 5.0
	if abs(v.x) > abs(v.y):
		facing = "right" if v.x > 0 else "left"
	elif abs(v.y) > 0.1:
		facing = "down" if v.y > 0 else "up"
	var aname := ("run_" if moving else "idle_") + facing
	if _sprite and _sprite.sprite_frames and _sprite.sprite_frames.has_animation(aname) and _sprite.animation != aname:
		_sprite.play(aname)


# ============================ WS 广播辅助 ============================

func _broadcast_speech(text: String) -> void:
	var world = get_tree().current_scene
	if world and world.has_method("_broadcast"):
		# 带说话者节点名：跨 owner 对话时发起端 brain 会替对方 NPC 生成台词，
		# 只带 pid 会让对端把气泡挂到 pid 拥有的第一个 NPC 上（挂错人/本人看不到）
		world._broadcast({"t": "speech", "pid": GameSession.pid, "npc": name, "text": text})


# 远端 NPC 插值：owner 50ms 广播 + WS 延迟抖动 → 硬 set position 会突跳（抽搐）。
# 收包只记目标点，_physics_process 里 lerp 平滑追；距离过大（spawn/传送）直接吸附。
var _remote_target: Vector2 = Vector2.ZERO
var _has_remote_target := false
const REMOTE_SNAP_DIST := 300.0   # 超此距离视为传送/spawn，直接吸附不做插值
const REMOTE_LERP_RATE := 12.0    # 追点速率（越大越跟手，越小越平滑）

func apply_remote_state(msg: Dictionary) -> void:
	_remote_target = Vector2(msg.get("x", position.x), msg.get("y", position.y))
	_has_remote_target = true
	if position.distance_to(_remote_target) > REMOTE_SNAP_DIST:
		position = _remote_target
	var d: String = msg.get("d", facing)
	facing = d
	var a: String = msg.get("a", "idle_down")
	if _sprite and _sprite.sprite_frames and _sprite.sprite_frames.has_animation(a) and _sprite.animation != a:
		_sprite.play(a)   # 同动画不重播，避免每 50ms 收包把 run 动画从第 0 帧重启（抽搐）


# ============================ 手动说话（统一入口） ============================

func player_speak(text: String) -> void:
	if text.strip_edges() == "":
		return
	text = text.strip_edges()
	show_bubble(text)
	_broadcast_speech(text)
	# 谁在说话：被控 NPC 自身后端 id 优先（控老张→记老张），否则记玩家角色
	var sid := character_id if character_id != 0 else GameSession.character_id
	post_chat_log(text, sid)


# 把一句台词落库 /chat_logs（双通道：RPC 广播气泡 + HTTP 持久化）。
# speaker_id=说话角色的后端 id；玩家用 GameSession.character_id，NPC 用自身 character_id。
# id=0（未关联后端）或无 JWT → 静默跳过，不影响气泡。
func post_chat_log(text: String, speaker_id: int, listener_id: int = 0) -> void:
	if speaker_id == 0 or GameSession.jwt.is_empty():
		return
	# 跨 owner 对话：发起端 brain 替对方 NPC 生成台词时，chat_logs 落库走 speaker 自己的
	# owner 端——这里替非己方节点写也会 403，跳过（对方端 _say_and_remember 会落自己的）
	if owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var payload := {"speaker_id": speaker_id, "content": text}
	if listener_id != 0:
		payload["listener_id"] = listener_id
	if GameSession.room_id != 0:
		payload["room_id"] = GameSession.room_id
	if GameSession.town_id != 0:
		payload["town_id"] = GameSession.town_id
	var body := JSON.stringify(payload)
	var err := http.request(
		GameSession.api_base + "/chat_logs",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[chat] POST chat_logs 失败 ", err)
	http.request_completed.connect(func(_r, _c, _h, _b):
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http):
				http.queue_free()))


# 写一条记忆到 /memories（embedding→pgvector，供后续 RAG 检索）。
# 同样 owner 校验：char_id 必须归当前玩家所有（host 自带的 NPC 满足）。
# embedding 未配置/失败 → 后端 503，这里静默跳过（不影响说话）。
func post_memory(content: String, char_id: int, mtype: String = "social", importance: int = 3) -> void:
	if char_id == 0 or GameSession.jwt.is_empty() or content.strip_edges().is_empty():
		return
	# 跨 owner 对话：替对方 NPC 写记忆会被后端 403（守卫正确），直接跳过——
	# 对方视角的摘要由对方 owner 的 brain 自己的对话总结负责
	if owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({
		"character_id": char_id,
		"content": content.strip_edges(),
		"memory_type": mtype,
		"importance": importance,
	})
	var err := http.request(
		GameSession.api_base + "/memories",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[memory] POST /memories 请求失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code != 201:
			print("[memory] 写入失败 HTTP %d（embedding 未配？）" % code)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http):
				http.queue_free()))


# ============================ NPC 日志 ============================

# 写入决策/内心独白到 /npc_logs（不入 embedding，轻量持久化）
func post_npc_log(content: String, log_type: String = "other") -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or content.strip_edges().is_empty():
		return
	# 同 post_memory：非本端拥有的角色写入会被 403（跨 owner 对话发起端替对方 NPC 记日志）
	if owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"character_id": character_id, "log_type": log_type, "content": content.strip_edges()})
	var err := http.request(
		GameSession.api_base + "/npc_logs",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[npc_log] POST /npc_logs 请求失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code != 201:
			print("[npc_log] 写入失败 HTTP %d" % code)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http):
				http.queue_free()))


# ============================ 核心记忆 ============================

# 加载最近 N 条 memory_vectors（时序，不检索）——决策循环上下文
func fetch_recent_memories(limit: int = 10) -> void:
	if character_id == 0 or GameSession.jwt.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/memories?character_id=%d&limit=%d" % [character_id, limit],
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] != 200:
		return
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) == TYPE_ARRAY:
		recent_memories.clear()
		for m in data:
			if typeof(m) == TYPE_DICTIONARY:
				var c: String = GameSession.str_or(m.get("content"))
				if not c.is_empty():
					recent_memories.append(c)
		print("[npc] %s 近期记忆加载 %d 条" % [npc_name, recent_memories.size()])


func fetch_core_memories() -> void:
	if character_id == 0 or GameSession.jwt.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/characters/" + str(character_id),
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed  # Array: [result, code, headers, body]
	http.queue_free()
	if resp[1] != 200:
		return
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY and data.has("core_memories_json"):
		var arr = data["core_memories_json"]
		if typeof(arr) == TYPE_ARRAY:
			core_memories = arr
			print("[npc] %s core_memories 加载 %d 条" % [npc_name, core_memories.size()])
	if typeof(data) == TYPE_DICTIONARY and data.has("relations_json"):
		var rj = data["relations_json"]
		if typeof(rj) == TYPE_DICTIONARY:
			relations = rj
			print("[npc] %s relations 加载 %d 条" % [npc_name, relations.size()])
	# 物品栏：拉后端真实值；空且本端 owner 拥有 → 本地补给小镇默认初始物品
	#（ponytail: 仅本地补给不 PATCH，重进镇重补即可；持久化 PATCH 留待后续）
	if typeof(data) == TYPE_DICTIONARY:
		var db_items = data.get("items_json", [])
		if typeof(db_items) == TYPE_ARRAY and not db_items.is_empty():
			items_json = db_items
		elif owner_id == GameSession.pid and not GameSession.npc_initial_items.is_empty():
			items_json = GameSession.npc_initial_items.duplicate()
			print("[npc] %s 补给初始物品 %d 件" % [npc_name, items_json.size()])
	_fetch_byok()


# 每角色 AI 设置（BYOK）：own 角色才拉（非 own 端不跑 brain，用不到）。有配置 → 注入
# SettingsManager.character_ai_settings（APIManager.generate_dialog 按名分流，原版本地通路）；
# 未配置 → 不注入 = 自动回退账号级全局设置。发一次独立请求，避免撑大 GET /characters/{id}。
func _fetch_byok() -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/characters/" + str(character_id) + "/byok",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] != 200:
		return   # 未配置/失败：静默，走账号级全局
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return
	var api_type := GameSession.str_or(data.get("api_type"))
	if api_type.is_empty() or GameSession.str_or(data.get("model")).is_empty():
		return   # 空配置视为"未配置"，回退全局
	SettingsManager.set_character_ai_settings(npc_name, {
		"api_type": api_type,
		"model": GameSession.str_or(data.get("model")),
		"api_key": GameSession.str_or(data.get("api_key")),
	})
	print("[npc] %s 使用角色级 AI：%s / %s" % [npc_name, api_type, data.get("model")])


func post_core_memories(facts: Array) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or facts.is_empty():
		return
	# 同 post_memory：跨 owner 对话时对方角色由其 owner 端写入
	if owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"facts": facts})
	var err := http.request(
		GameSession.api_base + "/characters/" + str(character_id) + "/core_memories",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] == 200:
		var data = JSON.parse_string(resp[3].get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY and data.has("core_memories_json"):
			var arr = data["core_memories_json"]
			if typeof(arr) == TYPE_ARRAY:
				core_memories = arr   # 同步本地缓存（服务端已去重+截断）


# 整体替换 core_memories（删除/编辑用）：客户端传完整新列表，服务端 trim + FIFO，不去重。
func put_core_memories(facts: Array) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or owner_id != GameSession.pid:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"facts": facts})
	var err := http.request(
		GameSession.api_base + "/characters/" + str(character_id) + "/core_memories",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PUT, body)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] == 200:
		var data = JSON.parse_string(resp[3].get_string_from_utf8())
		if typeof(data) == TYPE_DICTIONARY and data.has("core_memories_json"):
			var arr = data["core_memories_json"]
			if typeof(arr) == TYPE_ARRAY:
				core_memories = arr   # 同步本地缓存（服务端已 trim + 截断）


# ============================ 地图修改（言出法随 §3.4） ============================

# 提交地图修改到后端（持久化 + WS 广播给同镇所有在线玩家）
func post_map_actions(actions: Array) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or actions.is_empty():
		return
	if GameSession.town_id == 0:
		print("[map] 未加入小镇，跳过地图修改")
		return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"actions": actions, "character_id": character_id})
	var err := http.request(
		GameSession.api_base + "/maps/town/%d/actions" % GameSession.town_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[map] POST /maps/town/actions 请求失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code != 200:
			print("[map] 上传地图修改失败 HTTP %d" % code)
		else:
			print("[map] 地图修改已持久化 + 广播")
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


# ---- 角色状态同步（心情/金钱/健康） ----

# 应用状态变化（本地 + PATCH 落库 + 广播）。brain 衰减/物品效果/对话回血共用；跨 NPC 调用时带 owner 守卫。
func apply_status_change(sc: Dictionary) -> void:
	if sc.is_empty(): return
	# 多 owner 边界：非本端拥有的角色由其 owner 的 brain 更新（后端 PATCH 也会 403）
	if owner_id != GameSession.pid: return
	if sc.has("mood_delta"): mood = clampf(mood + float(sc["mood_delta"]), 0.0, 1.0)
	if sc.has("money_delta"): money += int(sc["money_delta"])
	if sc.has("health_delta"): health = clampf(health + float(sc["health_delta"]), 0.0, 1.0)
	patch_character_status(sc)


func patch_character_status(sc: Dictionary) -> void:
	if character_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify(sc)
	var err := http.request(
		GameSession.api_base + "/characters/%d/status" % character_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH, body)
	if err != OK:
		print("[status] PATCH 失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 200:
			var data = JSON.parse_string(_b.get_string_from_utf8())
			if data is Dictionary:
				mood = float(data.get("mood", mood))
				money = int(data.get("money", money))
				health = float(data.get("health", health))
				# 跨端状态同步：广播 mood/health/money（push，复用 pos/speech 通路），非 owner 端据此刷新本地节点→HUD
				var _w = get_tree().current_scene
				if _w and _w.has_method("_broadcast"):
					_w._broadcast({"t": "status", "pid": GameSession.pid, "npc": name, "mood": mood, "health": health, "money": money})
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


# ---- relations_json 写回（对话后双向好感演化，复用 PATCH /characters/{id}） ----
func patch_relations(relations_dict: Dictionary) -> void:
	if character_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"relations_json": relations_dict})
	var err := http.request(
		GameSession.api_base + "/characters/%d" % character_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH, body)
	if err != OK:
		print("[relations] PATCH 失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 200:
			var data = JSON.parse_string(_b.get_string_from_utf8())
			if data is Dictionary and data.has("relations_json"):
				var rj = data["relations_json"]
				if typeof(rj) == TYPE_DICTIONARY:
					relations = rj   # 同步本地缓存（服务端即写入值）
		else:
			print("[relations] 写入失败 HTTP %d" % code)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


# ---- 椅子坐/起（复用原版 Chair.gd sit_character/stand_up，net 无 sit 帧用 idle 代替） ----

func sit_on(chair: Node) -> bool:
	if sitting: return false
	if chair.has_method("sit_character") and chair.sit_character(self):
		sitting = true
		current_chair = chair
		if _sprite: _sprite.play("idle_down")
		return true
	return false


func stand_up() -> void:
	if not sitting: return
	if current_chair != null and is_instance_valid(current_chair) and current_chair.has_method("stand_up"):
		current_chair.stand_up()
	sitting = false
	current_chair = null


# ---- 任务系统 HTTP ----

func post_task_create(title: String, description: String, priority: int, reward: int) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"title": title, "description": description, "priority": priority, "reward_money": reward, "assignee_id": character_id})
	var err := http.request(
		GameSession.api_base + "/tasks?town_id=%d&creator_id=%d" % [GameSession.town_id, character_id],
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[task] 创建失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 201:
			print("[task] 创建成功: %s" % title)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


func post_task_complete(task_title: String, action_type: String) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/tasks?town_id=%d" % GameSession.town_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK: return
	var _char_id := character_id
	http.request_completed.connect(func(_r, code, _h, _b):
		if code != 200: return
		var tasks = JSON.parse_string(_b.get_string_from_utf8())
		if typeof(tasks) != TYPE_ARRAY: return
		var target_id := 0
		for t in tasks:
			if t is Dictionary and GameSession.str_or(t.get("title")).to_lower() == task_title.to_lower():
				target_id = int(t.get("id", 0))
				break
		if target_id == 0:
			print("[task] 未找到任务: %s" % task_title)
			return
		var http2 := HTTPRequest.new()
		add_child(http2)
		var status_val := "done" if action_type == "complete" else "cancelled"
		var body2 := JSON.stringify({"status": status_val, "assignee_id": _char_id})
		http2.request(
			GameSession.api_base + "/tasks/%d" % target_id,
			["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
			HTTPClient.METHOD_PATCH, body2)
		http2.request_completed.connect(func(_r2, code2, _h2, _b2):
			if code2 == 200: print("[task] %s → %s" % [task_title, action_type])
			get_tree().create_timer(1.0).timeout.connect(func():
				if is_instance_valid(http2): http2.queue_free()))
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


# 直接按 id 完成任务（brain 本地队列命中时用，比标题匹配更稳）
func post_task_complete_by_id(task_id: int) -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or task_id == 0: return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({"status": "done", "assignee_id": character_id})
	http.request(
		GameSession.api_base + "/tasks/%d" % task_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH, body)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 200: print("[task] 完成任务 #%d" % task_id)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


# 拉取自己的未完成任务队列（GET /tasks?town_id&assignee_id=self），brain 每日刷新/启动加载用。
func fetch_tasks() -> void:
	if character_id == 0 or GameSession.jwt.is_empty() or GameSession.town_id == 0:
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/tasks?town_id=%d&assignee_id=%d" % [GameSession.town_id, character_id],
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var resp = await http.request_completed
	http.queue_free()
	if resp[1] != 200:
		return
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) != TYPE_ARRAY:
		return
	current_tasks.clear()
	for t in data:
		if typeof(t) != TYPE_DICTIONARY: continue
		var st: String = GameSession.str_or(t.get("status"))
		if st == "done" or st == "cancelled": continue
		current_tasks.append({
			"id": int(t.get("id", 0)),
			"title": GameSession.str_or(t.get("title")),
			"description": GameSession.str_or(t.get("description")),
			"priority": int(t.get("priority", 3)),
			"reward_money": int(t.get("reward_money", 0)),
		})
	current_tasks.sort_custom(func(a, b): return a["priority"] > b["priority"])
	print("[task] %s 任务队列加载 %d 条" % [npc_name, current_tasks.size()])


# ---- 交易系统 HTTP ----

func post_trade(target_id: int, offer_items: Array, offer_money: int, request_items: Array, request_money: int) -> void:
	if character_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	var body := JSON.stringify({
		"proposer_id": character_id,
		"target_id": target_id,
		"offer_items": offer_items,
		"offer_money": offer_money,
		"request_items": request_items,
		"request_money": request_money
	})
	var err := http.request(
		GameSession.api_base + "/trades",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		print("[trade] POST 失败 ", err)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 200:
			print("[trade] %s trade ok" % npc_name)
			var data = JSON.parse_string(_b.get_string_from_utf8())
			if data is Dictionary:
				var p = data.get("proposer", {})
				if p is Dictionary:
					money = int(p.get("money", money))
					items_json = p.get("items_json", items_json)
		http.queue_free())
