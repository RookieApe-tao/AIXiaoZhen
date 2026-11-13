extends Node2D
# 联机游戏世界：Office 地图作静态背景 + 统一角色系统。
# 所有角色都是 NetworkNPC。玩家控制 = controlled_by_player 标记 + 权威转移（非 host）。
# 玩家切走 → AI 脑接管；切回 → WASD + 手动说话。

const npc_scene := preload("res://scene/characters/NetworkNPC.tscn")
const office_scene := preload("res://scene/maps/Office.tscn")
const outdoor_scene := preload("res://scene/maps/OutdoorTown.tscn")
const BrainClass := preload("res://script/net/NetworkNPCBrain.gd")
const ConfirmBox := preload("res://script/ui/ConfirmBox.gd")
const Tutorial := preload("res://script/ui/Tutorial.gd")
const GOD_CAM_SPEED := 400.0
# 言出法随：可坐的椅子走场景（带碰撞+坐下逻辑）；其余家具走纯 sprite（装饰，无碰撞=无空气墙）
const PREFAB_SCENES := {
	"chair": "res://scene/prefab/Chair.tscn",
	"back_chair": "res://scene/prefab/BackChair.tscn",
	"front_chair": "res://scene/prefab/FrontChair.tscn",
}
# 纯装饰家具 → {Modern_Office_Singles 编号, sprite 偏移}。偏移让物体底边对齐 pos（脚部，消除浮空）。
# ponytail: ox/oy 按 alpha bbox 算（纹理 64×96，中心 32,48；脚=bbox底-8px地面阴影）；新增家具补一条即可。
const PREFAB_SPRITES := {
	# 座椅
	"office_chair": {"num": 213, "ox": 14, "oy": -40},    # 灰转椅
	"wooden_chair": {"num": 220, "ox": 16, "oy": -40},    # 木转椅
	"armchair": {"num": 225, "ox": 6, "oy": -30},         # 单人扶手椅（bbox 12-64/34-82）
	"sofa": {"num": 190, "ox": 10, "oy": -36},            # 双人沙发（bbox 20-64/64-86）
	# 桌柜
	"desk": {"num": 223, "ox": 16, "oy": -32},
	"large_desk": {"num": 249, "ox": 0, "oy": -40},       # 64x64 木 L 桌
	"table": {"num": 248, "ox": 0, "oy": -14},            # 64x38 矮木桌
	"white_desk": {"num": 264, "ox": 0, "oy": -40},       # 64x64 白
	"metal_desk": {"num": 269, "ox": 0, "oy": -40},       # 64x64 灰
	"white_table": {"num": 263, "ox": 0, "oy": -14},      # 64x38 白
	"metal_table": {"num": 268, "ox": 0, "oy": -14},      # 64x38 灰
	"cabinet": {"num": 209, "ox": 16, "oy": -40},         # 高柜
	"bookshelf": {"num": 195, "ox": -10, "oy": -30},      # 书架
	"filing_cabinet": {"num": 206, "ox": 16, "oy": -32},  # 文件柜
	"counter": {"num": 205, "ox": 1, "oy": -32},          # 台面
	# 电器
	"coffee_machine": {"num": 320, "ox": 0, "oy": -14},
	"printer": {"num": 317, "ox": -4, "oy": -38},         # 打印机
	"computer": {"num": 323, "ox": 0, "oy": -22},         # 电脑
	"server": {"num": 328, "ox": 0, "oy": -22},           # 服务器
	# 绿植
	"plant": {"num": 339, "ox": 0, "oy": -25},            # 62x50 大盆栽（底边对齐 pos）
	"small_plant": {"num": 337, "ox": 14, "oy": -28},     # 小盆栽
	"tall_plant": {"num": 338, "ox": 16, "oy": -40},      # 高盆栽
}
const PREFAB_FALLBACK := {"num": 223, "ox": 16, "oy": -32}  # desk：未知家具名兜底

# Phase B②：左侧 HUD（top/bottom bar、side_panel、chat_input）+ 状态 HUD 静态壳已迁 OnlineWorld.tscn
@onready var status_label: Label = $UICanvas/top_bar/status_label
@onready var game_clock_label: Label = $UICanvas/top_bar/game_clock_label
var _last_clock_min: int = -999 # 上次显示的时钟分钟（变化才刷新 label）
@onready var _side_panel: Panel = $UICanvas/side_panel
@onready var _side_handle: Control = $UICanvas/side_panel/side_handle
var _side_dragging: bool = false
@onready var chat_input: LineEdit = $UICanvas/chat_input
var ai_panel: Panel
var byok_http: HTTPRequest
var char_panel: Panel
var char_name_edit: LineEdit
var char_position_edit: LineEdit
var char_personality_edit: TextEdit
var char_speaking_style_edit: TextEdit
var char_work_duties_edit: TextEdit
var char_work_habits_edit: TextEdit
var char_notes_edit: TextEdit
var char_gender_edit: OptionButton
var _ui_canvas: CanvasLayer:
	get: return $UICanvas
var char_http: HTTPRequest
var _char_ai_http: HTTPRequest
var heartbeat_http: HTTPRequest
var heartbeat_timer: Timer
var room_check_http: HTTPRequest
var chat_log_http: HTTPRequest
var chat_log_panel: Panel
var chat_log_vbox: VBoxContainer
var chat_log_timer: Timer
var npc_log_http: HTTPRequest
var npc_log_panel: Panel
var npc_log_vbox: VBoxContainer
var npc_log_title: Label
var ui_prefs_http: HTTPRequest
var ui_prefs_put_http: HTTPRequest
var ui_settings_panel: Panel
var ui_font_slider: HSlider
var ui_bubble_font_slider: HSlider
var ui_bubble_dur_slider: HSlider
var ui_intent_check: CheckBox
var ui_bgm_mute_check: CheckBox
var ui_sfx_mute_check: CheckBox
var token_panel: Panel              # Token 消耗面板（本地累计，按角色/provider 分桶）
var token_label: Label
var about_panel: Panel              # 关于/素材署名面板
var about_label: Label
var npc_log_timer: Timer
var _char_names: Dictionary = {}   # character_id -> name（对话记录展示用）
var switch_panel: Panel
var switch_itemlist: ItemList
var player_list_panel: Panel
@onready var status_hud: Panel = $UICanvas/status_hud   # 状态 HUD（心情条/金币/健康条）
var status_hud_bars: Dictionary = {}  # {"mood":ProgressBar, "money":Label, "health":ProgressBar}
var task_panel: Panel                # 任务列表面板
var task_timer: Timer                # 面板打开期间 5s 自动刷新
var task_list: VBoxContainer
var task_publish_form: VBoxContainer  # 发布表单
var task_title_edit: LineEdit
var task_reward_edit: LineEdit
var task_pri_opt: OptionButton
# 导演控制台（房主叙事：天气/时间流速/世界观/新闻+规则发布/事件流）
var director_panel: Panel
var weather_opt: OptionButton
var time_scale_slider: HSlider
var world_bg_edit: TextEdit
var company_edit: TextEdit
var social_rules_edit: TextEdit
var news_title_edit: LineEdit
var news_content_edit: TextEdit
var rule_title_edit: LineEdit
var rule_content_edit: TextEdit
var event_flow_box: VBoxContainer
var game_clock_timer: Timer         # 房主端虚拟时钟推进（5s tick）
var clock_label: Label              # 常驻时间显示（导演时钟，总可见）
var trade_panel: Panel              # NPC 交易面板
var trade_target_opt: OptionButton
var trade_offer_item: LineEdit
var trade_offer_money: LineEdit
var trade_req_item: LineEdit
var trade_req_money: LineEdit
var trade_items_label: Label        # 自己的物品列表
var trade_gold_label: Label
var player_list_label: Label

# 统一角色追踪
var selected_npc_name := ""      # 当前"选中"的 own NPC 节点名：所有面板(角色设定/任务/物品/对话/NPC日志)都看它；B 退上帝=控制它
var ws_relay: Node    # WSRelay 实例（_start_network 中创建）
var god_mode := false
var god_camera: Camera2D
var god_zoom := Vector2.ONE          # 上帝相机缩放（滚轮，clamp 0.5~2.0）
var _god_dragging := false           # 右键拖拽中
var _hud_refresh_acc := 0.0          # 状态 HUD 刷新节流
var status_edit_panel: Panel         # 上帝改状态面板
var status_edit_mood: HSlider
var status_edit_health: HSlider
var status_edit_money: SpinBox
var status_edit_sel_label: Label
var relations_edit_panel: Panel       # 关系编辑面板（仅自己选中的 NPC）
var relations_edit_vbox: VBoxContainer
var relations_edit_sel_label: Label
var _rel_rows: Array = []             # [{name_edit,silder,note_edit}, ...] 当前编辑行
var implant_memory_panel: Panel       # 记忆植入面板
var implant_memory_input: TextEdit
var implant_memory_list: VBoxContainer   # 记忆列表（每条一行：文本 + 改/删按钮）
var implant_memory_sel_label: Label
var implant_memory_save_btn: Button
var _editing_memory_idx := -1            # 正在编辑的记忆下标（-1=新增）
var _map_node: Node2D = null
var _loaded_scene: String = ""


func _ready() -> void:
	_load_map_background()
	_build_spawner()
	var _dyn := Node2D.new()
	_dyn.name = "DynamicProps"   # 言出法随：动态物品层（NPC 放置的 prefab 渲染到此）
	add_child(_dyn)
	_build_ui()
	_start_network()
	_connect_signals()
	_start_heartbeat()
	# 位置同步：每 50ms 广播本端所有 NPC 的位置
	var sync_timer := Timer.new()
	sync_timer.wait_time = 0.05
	sync_timer.one_shot = false
	sync_timer.timeout.connect(_sync_positions)
	add_child(sync_timer)
	sync_timer.start()
	# 上帝模式相机
	god_camera = Camera2D.new()
	god_camera.enabled = false
	god_camera.position = Vector2(500, 350)   # 开局看向地图主体（960,540 会看到地图外导致黑屏）
	add_child(god_camera)
	AudioManager.play_bgm()


func _process(_delta: float) -> void:
	# Tab 按住显示玩家列表，松开即关
	if Input.is_key_pressed(KEY_TAB):
		if not player_list_panel.visible:
			_open_player_list()
	else:
		if player_list_panel.visible:
			player_list_panel.visible = false
	# 上帝模式：WASD 移动镜头（空格键吸附到选中 NPC）
	if god_mode:
		var v := Vector2.ZERO
		if Input.is_key_pressed(KEY_W): v.y -= 1
		if Input.is_key_pressed(KEY_S): v.y += 1
		if Input.is_key_pressed(KEY_A): v.x -= 1
		if Input.is_key_pressed(KEY_D): v.x += 1
		god_camera.position += v.normalized() * GOD_CAM_SPEED * _delta / god_zoom.x
	# 状态 HUD 可见时每 0.5s 实时刷新（否则只在切换时刷一次）
	if status_hud != null and status_hud.visible:
		_hud_refresh_acc += _delta
		if _hud_refresh_acc >= 0.5:
			_hud_refresh_acc = 0.0
			_refresh_status_hud()
	# 右上角游戏时钟：虚拟时钟变化时刷新（town_time WS 推进 game_clock_min）
	if game_clock_label != null and GameSession.game_clock_min != _last_clock_min:
		_last_clock_min = GameSession.game_clock_min
		_refresh_game_clock_label()


func _input(event: InputEvent) -> void:
	# 滚轮：悬浮在面板/侧边栏上→放行给 GUI 滚动；否则缩放相机（上帝=god_camera，NPC 控制=跟随相机）
	var wheel := event as InputEventMouseButton
	if wheel and wheel.pressed and (wheel.button_index == MOUSE_BUTTON_WHEEL_UP or wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if not _hovering_blocking_gui():
			var cam: Camera2D = god_camera if god_mode else _controlled_camera()
			if cam:
				var z: float = clampf(cam.zoom.x + (0.1 if wheel.button_index == MOUSE_BUTTON_WHEEL_UP else -0.1), 0.5, 2.0)
				cam.zoom = Vector2(z, z)
				if god_mode:
					god_zoom = Vector2(z, z)
				get_viewport().set_input_as_handled()
		return
	# 上帝相机：右键拖拽平移（仅 god_mode；滚轮已在上面统一处理）
	if god_mode:
		var mb := event as InputEventMouseButton
		if mb:
			if mb.button_index == MOUSE_BUTTON_RIGHT:
				_god_dragging = mb.pressed
			# 左键放行 GUI（左侧按钮才能点击弹面板），其余鼠标键（右键）仍吞掉
			if mb.button_index != MOUSE_BUTTON_LEFT:
				get_viewport().set_input_as_handled()
			return
		var mm := event as InputEventMouseMotion
		if mm and _god_dragging:
			god_camera.position -= mm.relative / god_zoom.x
			get_viewport().set_input_as_handled()
			return
	var key_ev := event as InputEventKey
	if key_ev == null or not key_ev.pressed:
		return
	# 焦点在文本输入（侧栏 TextEdit/LineEdit）时击键属于打字，不触发快捷键。
	# 不能看 unicode：B/C 等字母键 unicode 也非 0，会误吞快捷键 → 只看焦点是否落在文本输入控件
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner != null and (focus_owner is TextEdit or focus_owner is LineEdit):
		return
	if event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		if chat_input and chat_input.visible:
			return
		var ctrl = _get_controlled_npc()
		if ctrl == null:
			_set_status("没有可控角色（等待生成…）")
		else:
			_position_chat_input()
			chat_input.show()
			chat_input.grab_focus()
			get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and chat_input and chat_input.visible:
		chat_input.hide()
		chat_input.clear()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_C:
		_switch_next()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_B:
		if god_mode:
			if selected_npc_name.is_empty():
				_set_status("请先在「切换角色」面板选中一个角色")
			else:
				var sel = _find_selected_npc()
				if sel and sel.owner_id != GameSession.pid:
					_set_status("%s 是其他玩家的角色，不能控制" % sel.npc_name)
				else:
					_switch_to(selected_npc_name)   # 退上帝，控制选中的角色
		else:
			_enter_god_mode()   # 进上帝（保留选中，面板仍看选中角色）
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_SPACE and god_mode:
		var sel = _find_selected_npc()
		god_camera.position = sel.position if sel != null else Vector2(500, 350)
		get_viewport().set_input_as_handled()


# 上帝模式点击交互：左键点 NPC=选中（面板跟着切，可选别人角色），点空地=让选中角色走过去（仅自己角色听指挥）。
# 按住 T 点 NPC = T-L 邻近对话：选中角色与点击对象开聊（复用 brain 对话闭环，双方需已走近 ≤20px）。
# 走 _unhandled_input：GUI 先分（面板/按钮点不到这），左键在 god _input 里本就放行。
func _unhandled_input(event: InputEvent) -> void:
	if not god_mode:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if _hovering_blocking_gui():
		return
	var world_pos := get_global_mouse_position()
	var npcs = get_node_or_null("NPCs")
	var clicked = null
	if npcs:
		for n in npcs.get_children():
			if not (n is CharacterBody2D):
				continue
			if world_pos.distance_to(n.position) <= 30.0:
				clicked = n
				break
	# T+点击 NPC：选中角色与点击对象对话（T-L 邻近对话）
	if clicked != null and Input.is_key_pressed(KEY_T):
		var sel = _find_selected_npc()
		if sel == null:
			_set_status("先点选要发起对话的角色，再按住 T 点对象")
		elif sel == clicked:
			_set_status("不能和自己聊")
		elif sel.owner_id != GameSession.pid:
			_set_status("%s 是其他玩家的角色，不能指挥" % sel.npc_name)
		else:
			var reason: String = sel.try_start_chat_with(clicked)
			if reason == "":
				_set_status("%s ←→ %s 开始对话" % [sel.npc_name, clicked.npc_name])
			else:
				_set_status(reason)
		return
	if clicked != null:
		selected_npc_name = clicked.name
		_set_status("选中：%s（按 B 控制它；按住 T 点别人开聊）" % clicked.npc_name)
		return
	var sel = _find_selected_npc()
	if sel == null:
		_set_status("点空地 = 让选中角色走过去；先点一个角色")
		return
	if sel.owner_id != GameSession.pid:
		_set_status("%s 是其他玩家的角色，不能指挥" % sel.npc_name)
		return
	if sel.get("force_chat_walk"):
		_set_status("%s 正走过去开聊，别打断" % sel.npc_name)
		return
	if sel.sitting:
		sel.stand_up()
	sel.request_move(world_pos)
	_set_status("%s → 前往点击处" % sel.npc_name)


# ============================ WS 消息处理 ============================

func _broadcast(msg: Dictionary) -> void:
	if ws_relay: ws_relay.send(msg)


func _sync_positions() -> void:
	var npcs = get_node_or_null("NPCs")
	if not npcs: return
	for n in npcs.get_children():
		if not (n is CharacterBody2D): continue
		if n.get("owner_id") != GameSession.pid: continue
		var anim := "idle_down"
		if n.get("_sprite") and n._sprite.sprite_frames:
			anim = n._sprite.animation
		_broadcast({"t": "pos", "pid": GameSession.pid, "npc": n.name,
			"x": n.position.x, "y": n.position.y,
			"d": n.facing, "a": anim})


func _on_ws_message(msg: Dictionary) -> void:
	var t: String = msg.get("t", "")
	match t:
		"peer_join":
			var pid: int = msg.get("pid", 0)
			if pid != GameSession.pid:
				if GameSession.is_host:
					print("[ws] host 收到 peer_join pid=%d → 发送全场状态给新玩家" % pid)
					# 多端各人 own NPC：各客户端各自 _spawn_my_npcs 广播自己带入的 NPC，host 只需把已有
					# 全场角色发给新玩家 + 同步房间参数。不再为 join 玩家 spawn「玩家角色」avatar（god 模式无自身角色）。
					_send_full_state_to(pid)
					# 立即补发当前时钟快照，消 join 玩家 ≤5s 的 town_time tick 等待（时钟纯 host 端、不在 HTTP catch-up 里）
					if GameSession.game_clock_min >= 0:
						ws_relay.send_to(pid, {"t": "town_time", "minutes": GameSession.game_clock_min, "time_scale": GameSession.time_scale})
					ws_relay.send_to(pid, {"t": "room_params", "town_id": GameSession.town_id, "chat_rounds": GameSession.room_chat_max_rounds, "max_npcs": GameSession.room_max_npcs})
				else:
					print("[ws] 非 host 收到 peer_join pid=%d，忽略" % pid)
				_set_status("玩家加入: %d" % pid)
		"peer_leave":
			_handle_peer_leave(msg)
		"pos":
			_handle_pos(msg)
		"speech":
			_handle_speech(msg)
		"status":
			_handle_status(msg)
		"intent":
			var ipid: int = msg.get("pid", 0)
			if ipid != GameSession.pid:
				var iname: String = msg.get("npc", "")
				var inode = get_node_or_null("NPCs/" + iname) if not iname.is_empty() else null
				if inode:
					inode.set_intent(GameSession.str_or(msg.get("text")), true)
		"control":
			_handle_control(msg)
		"room_params":
			if msg.get("to_pid", 0) == GameSession.pid:
				_apply_room_params(msg.get("town_id", 0), msg.get("chat_rounds", 8), msg.get("max_npcs", 20))
		"kick_all":
			_do_kick(msg.get("reason", "房间已关闭"))
		"spawn":
			_handle_spawn(msg)
		"despawn":
			var dpid: int = msg.get("pid", 0)
			if dpid != GameSession.pid:
				_cleanup_npc(dpid)
		"map_update":
			_handle_map_update(msg)
		"town_weather":
			GameSession.weather = GameSession.str_or(msg.get("weather"), "clear")
		"town_time":
			GameSession.game_clock_min = int(msg.get("minutes", -1))
			GameSession.time_scale = float(msg.get("time_scale", 1.0))
			_refresh_clock_label()
		"town_world":
			GameSession.world_background = GameSession.str_or(msg.get("world_background"))
			GameSession.company_info = GameSession.str_or(msg.get("company_info"))
			GameSession.social_rules = GameSession.str_or(msg.get("social_rules"))
		"town_event":
			_on_town_event(msg)
		"task_update":
			_handle_task_update(msg)
		_:
			print("[ws] 未知消息: ", msg)


# 导演事件流增量：op=add 追加 active_events，op=deactivate 按 id 移除。
func _on_town_event(msg: Dictionary) -> void:
	var op: String = GameSession.str_or(msg.get("op"))
	var eid: int = int(msg.get("id", 0))
	if op == "add" and eid > 0:
		var kind: String = GameSession.str_or(msg.get("kind"))
		var text := _event_text(GameSession.str_or(msg.get("title")), GameSession.str_or(msg.get("content")))
		GameSession.active_events[eid] = {"kind": kind, "text": text}
		if event_flow_box: _add_event_flow_row(eid, kind, text)
		print("[narrative] +%d [%s] %s" % [eid, kind, text])
	elif op == "deactivate" and eid > 0:
		GameSession.active_events.erase(eid)
		_refresh_event_flow()
		print("[narrative] -%d" % eid)


func _handle_pos(msg: Dictionary) -> void:
	var pid: int = msg.get("pid", 0)
	if pid == GameSession.pid:
		return
	var npc_name: String = msg.get("npc", "")
	var npc = get_node_or_null("NPCs/" + npc_name) if not npc_name.is_empty() else null
	if not npc:
		npc = _find_npc_by_owner(pid)
	if npc:
		npc.apply_remote_state(msg)


func _handle_speech(msg: Dictionary) -> void:
	var pid: int = msg.get("pid", 0)
	if pid == GameSession.pid:
		return
	var text: String = msg.get("text", "")
	# 优先按节点名定位（跨 owner 对话时发起端替对方 NPC 说话，只有名能定位），
	# 旧消息无 npc 字段时回退按 owner 找（兼容）
	var npc_name: String = msg.get("npc", "")
	var npc = get_node_or_null("NPCs/" + npc_name) if not npc_name.is_empty() else null
	if not npc:
		npc = _find_npc_by_owner(pid)
	if npc and not text.is_empty():
		npc.show_bubble(text)


func _handle_status(msg: Dictionary) -> void:
	# 跨端状态同步：owner brain 改 mood/health/money 后广播（patch_character_status），非 owner 端据此刷新本地节点；
	# HUD 读本地节点 → 选中别人的 NPC 也能看到真实状态。push 模式（每决策轮~25s 一次），与 pos/speech 同通路。
	var pid: int = msg.get("pid", 0)
	if pid == GameSession.pid:
		return   # 自己的不回声（本地已是最新）
	var npc_name: String = msg.get("npc", "")
	var npc = get_node_or_null("NPCs/" + npc_name) if not npc_name.is_empty() else null
	if npc:
		npc.mood = float(msg.get("mood", npc.mood))
		npc.health = float(msg.get("health", npc.health))
		npc.money = int(msg.get("money", npc.money))


func _handle_spawn(msg: Dictionary) -> void:
	var pid: int = msg.get("pid", 0)
	if pid == GameSession.pid:
		return
	print("[ws] _handle_spawn: 添加角色 name=%s owner=%d is_player=%s" % [msg.get("name","?"), msg.get("owner_id",0), msg.get("is_player",false)])
	_add_npc(msg)


func _send_full_state_to(pid: int) -> void:
	# host 把全场所有角色 spawn 发给新 peer（to_pid 单播）
	var npcs = get_node_or_null("NPCs")
	if not npcs:
		print("[ws] _send_full_state_to: NPCs 节点不存在")
		return
	var count := 0
	for n in npcs.get_children():
		if not (n is CharacterBody2D): continue
		ws_relay.send_to(pid, _npc_to_spawn(n))
		count += 1
	print("[ws] _send_full_state_to → pid=%d 发送 %d 个角色" % [pid, count])


func _npc_to_spawn(n: CharacterBody2D) -> Dictionary:
	var is_player: bool = n.get("is_player") if "is_player" in n else false
	return {
		"t": "spawn",
		"name": n.npc_name if "npc_name" in n else n.name,
		"background": n.personality_text if "personality_text" in n else "",
		"personality_json": n.persona if "persona" in n else {},
		"owner_id": n.owner_id if "owner_id" in n else 1,
		"character_id": n.character_id if "character_id" in n else 0,
		"is_player": is_player,
		"mood": n.mood if "mood" in n else 0.6,
		"health": n.health if "health" in n else 1.0,
		"money": n.money if "money" in n else 100,
		"pos": {"x": n.position.x, "y": n.position.y},
	}


func _find_npc_by_owner(owner_id: int):
	var npcs = get_node_or_null("NPCs")
	if not npcs:
		return null
	for n in npcs.get_children():
		if n is CharacterBody2D and n.get("owner_id") == owner_id:
			return n
	return null


func _cleanup_npc(owner_id: int) -> void:
	var npcs = get_node_or_null("NPCs")
	if npcs:
		for n in npcs.get_children():
			if n is CharacterBody2D and n.get("owner_id") == owner_id:
				n.queue_free()


# ============================ map_update ============================
# ponytail: 仅更新静态房间索引（NPC 大脑共享），不做 TileMapLayer 逐格视觉更新。
# 视觉重建从 GET /maps/town/{id} 拉完整数据重建，作为后续切片。
func _handle_map_update(msg: Dictionary) -> void:
	var actions = msg.get("actions", [])
	var chunk = msg.get("chunk_json", {})
	print("[ws] map_update: %d actions, sender=%d" % [actions.size(), msg.get("sender_id", 0)])
	# 更新全局房间索引（NPC 大脑共享）
	var rooms = chunk.get("rooms", [])
	if typeof(rooms) == TYPE_ARRAY:
		BrainClass._room_index.clear()
		for r in rooms:
			if r is Dictionary:
				var rn = GameSession.str_or(r.get("name"))
				if not rn.is_empty():
					BrainClass._room_index[rn] = {
						"cx": float(r.get("cx", 0)), "cy": float(r.get("cy", 0)),
						"w": float(r.get("w", 100)), "h": float(r.get("h", 100)), "indoor": bool(r.get("indoor", true))
					}
	# 言出法随：把 place_prefab/remove_prefab 渲染到动态物品层，place_tile/remove_tile 渲染到地图层
	for act in actions:
		if typeof(act) != TYPE_DICTIONARY:
			continue
		match act.get("action", ""):
			"place_prefab": _spawn_prefab(act)
			"remove_prefab": _remove_prefab(act)
			"place_tile": _place_tile(act)
			"remove_tile": _remove_tile(act)
			_: pass


# AI 建造地图 tile：place_tile（wall/floor/road/grass/tree）→ OutdoorTown.set_tile。pos 是像素坐标 → tile 网格。
func _place_tile(act: Dictionary) -> void:
	var tile_type: String = GameSession.str_or(act.get("tile_type"), "")
	if tile_type.is_empty():
		return
	var pos := _act_pos(act)
	if _map_node != null and _map_node.has_method("set_tile"):
		_map_node.set_tile(tile_type, Vector2i(int(pos.x / 32), int(pos.y / 32)))
		print("[map] 建造 tile %s @ (%.0f,%.0f)" % [tile_type, pos.x, pos.y])


func _remove_tile(act: Dictionary) -> void:
	var pos := _act_pos(act)
	if _map_node != null and _map_node.has_method("remove_tile"):
		_map_node.remove_tile(Vector2i(int(pos.x / 32), int(pos.y / 32)))
		print("[map] 移除 tile @ (%.0f,%.0f)" % [pos.x, pos.y])


# 从 map action 里解析 pos（兼容 [x,y] 数组 / {x,y} 字典）
func _act_pos(act: Dictionary) -> Vector2:
	var pos_data = act.get("pos", [0, 0])
	if typeof(pos_data) == TYPE_ARRAY and pos_data.size() >= 2:
		return Vector2(float(pos_data[0]), float(pos_data[1]))
	elif typeof(pos_data) == TYPE_DICTIONARY:
		return Vector2(float(pos_data.get("x", 0)), float(pos_data.get("y", 0)))
	return Vector2.ZERO


# 言出法随：实例化 prefab 到动态层。有场景的用场景（chair 等），其余用占位色块+标签。
func _spawn_prefab(act: Dictionary) -> void:
	var prefab_name: String = GameSession.str_or(act.get("prefab_name"), "object")
	var pos_data = act.get("pos", [0, 0])
	var pos := Vector2()
	if typeof(pos_data) == TYPE_ARRAY and pos_data.size() >= 2:
		pos = Vector2(float(pos_data[0]), float(pos_data[1]))
	elif typeof(pos_data) == TYPE_DICTIONARY:
		pos = Vector2(float(pos_data.get("x", 0)), float(pos_data.get("y", 0)))
	var dyn = get_node_or_null("DynamicProps")
	if dyn == null:
		return
	var node: Node2D = null
	var key := prefab_name.to_lower()
	if PREFAB_SCENES.has(key):
		var scene = load(PREFAB_SCENES[key])
		if scene:
			node = scene.instantiate()
	if node == null:
		node = _make_prefab_sprite(prefab_name)
	node.position = pos
	node.z_index = int(pos.y)   # y 排序：与 NPC 同基准，前后遮挡
	node.name = "prefab_%s_%d" % [prefab_name, randi() % 100000]
	node.set_meta("prefab_name", prefab_name.to_lower())
	dyn.add_child(node)
	print("[map] 放置 %s @ (%.0f,%.0f)" % [prefab_name, pos.x, pos.y])


func _make_prefab_sprite(prefab_name: String) -> Node2D:
	# 纯装饰家具用真 sprite（无碰撞=无空气墙）。偏移见 PREFAB_SPRITES，物体底边对齐 pos。
	var info: Dictionary = PREFAB_SPRITES.get(prefab_name.to_lower(), PREFAB_FALLBACK)
	var num := int(info.get("num", 223))
	var ox := float(info.get("ox", 0))
	var oy := float(info.get("oy", -32))
	var tex_path := "res://asset/singleObjects/office_objects/Modern_Office_Singles_32x32_%d.png" % num
	var n := Node2D.new()
	var s := Sprite2D.new()
	s.texture = load(tex_path)
	s.position = Vector2(ox, oy)
	n.add_child(s)
	return n


func _remove_prefab(act: Dictionary) -> void:
	var dyn = get_node_or_null("DynamicProps")
	if dyn == null:
		return
	var prefab_name: String = GameSession.str_or(act.get("prefab_name")).to_lower()
	for c in dyn.get_children():
		if String(c.get_meta("prefab_name", "")) == prefab_name:
			c.queue_free()
			print("[map] 移除 %s" % prefab_name)
			return


func _add_npc(data: Dictionary) -> void:
	var npcs = get_node_or_null("NPCs")
	if not npcs:
		print("[ws] _add_npc: NPCs 节点不存在")
		return
	var p_name := GameSession.str_or(data.get("name"), "Role")
	# ponytail: 按名去重——host 的 _send_full_state_to 和 _broadcast spawn 可能重复到达
	if npcs.has_node(p_name):
		print("[ws] _add_npc: %s 已存在，跳过" % p_name)
		return
	# 位置：本地传 Vector2，网络传 {x,y} dict，统一处理
	var pos_data = data.get("pos", Vector2(400, 300))
	var pos: Vector2
	if typeof(pos_data) == TYPE_DICTIONARY:
		pos = Vector2(float(pos_data.get("x", 400)), float(pos_data.get("y", 300)))
	else:
		pos = pos_data as Vector2
	print("[ws] _add_npc: 创建 %s at (%.0f,%.0f) owner=%d" % [p_name, pos.x, pos.y, data.get("owner_id",0)])
	var p: CharacterBody2D = npc_scene.instantiate()
	p.name = p_name
	p.position = pos
	var pj = data.get("personality_json")
	var persona_dict: Dictionary = pj if typeof(pj) == TYPE_DICTIONARY else {}
	p.setup_npc(
		GameSession.str_or(data.get("name")),
		GameSession.str_or(data.get("background")),
		int(data.get("owner_id", 1)),
		int(data.get("character_id", 0)),
		persona_dict)
	p.is_player = bool(data.get("is_player", false))
	if p.is_player and GameSession.pid == int(data.get("owner_id", 1)):
		p.controlled_by_player = true
	# 跨端状态同步：spawn 即带 mood/health/money（晚加入者拿到 owner 当前状态，不必等首条 status 广播）
	if data.has("mood"):
		p.mood = float(data["mood"])
	if data.has("health"):
		p.health = float(data["health"])
	if data.has("money"):
		p.money = int(data["money"])
	npcs.add_child(p)
	if p.character_id != 0:
		_char_names[p.character_id] = p.npc_name
	if p.controlled_by_player:
		if p.has_node("Camera2D"):
			p.get_node("Camera2D").enabled = true

func _load_map_background(scene_name: String = "office") -> void:
	if _loaded_scene == scene_name:
		return
	if _map_node:
		remove_child(_map_node)
		_map_node.queue_free()
		_map_node = null
	var scene: PackedScene
	# outdoor_town / blank_town 都用数据驱动地图（草地底 + chunk_json.tiles 重放），区别在 DB 预设的 tiles 数据
	match scene_name:
		"outdoor_town", "blank_town": scene = outdoor_scene
		_: scene = office_scene
	var map = scene.instantiate()
	for pname in ["Characters", "MainCamera", "CanvasLayer", "SettingsLayer"]:
		var n = map.get_node_or_null(pname)
		if n:
			map.remove_child(n)
			n.queue_free()
	add_child(map)
	move_child(map, 0)   # 地图垫底（office 是 _ready 首个子节点=最底），换场景若 add_child 会叠到 NPC/UI 之上盖住它们
	_map_node = map
	_loaded_scene = scene_name


# ============================ NPC 管理（手动 spawn，替代 MultiplayerSpawner） ============================

func _build_spawner() -> void:
	var npcs = Node2D.new()
	npcs.name = "NPCs"
	add_child(npcs)


func _spawn_npc(data) -> Node:
	var d: Dictionary = data if data is Dictionary else {}
	var p: CharacterBody2D = npc_scene.instantiate()
	p.name = GameSession.str_or(d.get("name"), "Role")
	# 位置：本地传 Vector2，网络传 {x,y} dict，统一处理
	var pos_data = d.get("pos", Vector2(400, 300))
	if typeof(pos_data) == TYPE_DICTIONARY:
		p.position = Vector2(float(pos_data.get("x", 400)), float(pos_data.get("y", 300)))
	else:
		p.position = pos_data as Vector2
	var pj = d.get("personality_json")
	var persona_dict: Dictionary = pj if typeof(pj) == TYPE_DICTIONARY else {}
	p.setup_npc(
		GameSession.str_or(d.get("name")),
		GameSession.str_or(d.get("background")),
		int(d.get("owner_id", 1)),
		int(d.get("character_id", 0)),
		persona_dict)
	# 状态同步：从后端数据恢复物品/金币/心情/健康
	p.money = int(d.get("money", 100))
	p.mood = float(d.get("mood", 0.6))
	p.health = float(d.get("health", 1.0))
	var items = d.get("items_json")
	if typeof(items) == TYPE_ARRAY: p.items_json = items
	# 玩家角色标记：自己的角色 spawn 后本端接管
	if bool(d.get("is_player", false)) and GameSession.pid == int(d.get("owner_id", 1)):
		p.controlled_by_player = true
		if p.has_node("Camera2D"):
			p.get_node("Camera2D").enabled = true
	return p


func _spawn_my_npcs() -> void:
	var count := 0
	for c in GameSession.npc_list:
		var max_npc := GameSession.room_max_npcs if GameSession.room_max_npcs > 0 else 20
		if count >= max_npc:
			print("[online] NPC 达房间上限 %d，忽略" % max_npc)
			break
		# 跳过和玩家角色同名的（避免重复 spawn）
		if c.get("name", "") == GameSession.character_name:
			continue
		var pos := Vector2(300 + (count % 5) * 80, 250 + (count / 5) * 80)
		_add_npc({
			"name": c.get("name", "NPC"),
			"background": c.get("background", ""),
			"personality_json": c.get("personality_json", {}),
			"character_id": int(c.get("id", 0)),
			"owner_id": GameSession.pid,
			"authority": 1,
			"is_player": false,
			"pos": pos,
		})
		var npc_node = get_node_or_null("NPCs/" + c.get("name", "NPC"))
		if npc_node:
			_broadcast(_npc_to_spawn(npc_node))
		count += 1
	print("[online] 自带 NPC ", count, " 个")


func _get_controlled_npc():
	# 返回本端正控制的 NPC（controlled_by_player == true 且是本端 own）。
	# 远端副本也被 _handle_control 置了此标记（仅用于玩家列表显示「谁在控制谁」），
	# 不过滤 owner 会在多玩家各自控制时误返回别人角色 → 切换/相机/释放全乱。
	var npcs = get_node_or_null("NPCs")
	if not npcs:
		return null
	for n in npcs.get_children():
		if n is CharacterBody2D and n.get("controlled_by_player") and n.get("owner_id") == GameSession.pid:
			return n
	return null


func _get_my_npcs() -> Array:
	# 所有 owner_id == 本端 peer 的 NPC（含玩家角色 + 额外 NPC）
	var result := []
	var npcs = get_node_or_null("NPCs")
	if not npcs:
		return result
	for n in npcs.get_children():
		if n is CharacterBody2D and "owner_id" in n and n.owner_id == GameSession.pid:
			result.append(n)
	return result


# ============================ 网络启动 ============================

func _start_network() -> void:
	ws_relay = WSRelay.new()
	ws_relay.name = "WSRelay"
	add_child(ws_relay)
	ws_relay.connect_to_town(GameSession.town_id, GameSession.jwt)
	_set_status("连接小镇 #%d ..." % GameSession.town_id)

func _exit_tree() -> void:
	# 关闭 WS 连接（返回大厅已先 close_town，此处的请求已被 _on_back 覆盖）
	if ws_relay: ws_relay.close()


func _connect_signals() -> void:
	ws_relay.connected.connect(_on_ws_connected)
	ws_relay.disconnected.connect(_on_ws_disconnected)
	ws_relay.message_received.connect(_on_ws_message)

func _on_ws_connected(p_pid: int) -> void:
	_set_status("已连接 #%d %s" % [p_pid, "（房主）" if GameSession.is_host else ""])
	# 多端各人 own NPC：每个客户端各自 spawn 自己带入的 NPC（owner=本端 pid）并广播给全镇；
	# brain 门控(GameSession.pid == npc.owner_id) 自动让大脑只在 owner 端跑、用 owner 本地 BYOK。
	# join 玩家的 npc_list 不再被丢弃——谁带的角色谁跑 brain，房主不再为全镇付 token/单点。
	_spawn_my_npcs()
	if GameSession.is_host:
		_start_game_clock()        # 房主启动虚拟时钟（权威推进 + 广播 town_time）
	# 玩家=纯上帝（无自身 avatar）：默认进上帝模式，选中第一个自己的 NPC（面板看它；B 退上帝控制它）
	var _my := _get_my_npcs()
	if not _my.is_empty():
		selected_npc_name = _my[0].name
	_enter_god_mode()
	# 从后端加载地图数据（言出法随持久化：重进小镇时恢复已放置的家具/房间）
	_load_map_from_backend()
	# 导演模式：拉取小镇天气/世界观 + 事件流（注入 NPC prompt）
	_load_town_narrative()
	_load_ui_prefs()  # 玩家 UI 偏好（覆盖管理员默认；进镇拉取合并）
	if not SettingsManager.get_settings().get("tutorial_town_done", false):
		Tutorial.show(self, "town")


# 从后端拉取 map_data，恢复 rooms 索引 + 重放 prefabs 到动态层（言出法随持久化）
func _load_map_from_backend() -> void:
	if GameSession.town_id == 0 or GameSession.jwt.is_empty():
		return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/maps/town/%d" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return
	var resp: Array = await http.request_completed
	http.queue_free()
	if resp[1] != 200:
		return
	var data = JSON.parse_string(resp[3].get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return
	# 场景选择：室外小镇走 OutdoorTown，老镇无 scene 字段回退 office（零回归）
	var chunk = data.get("chunk_json", {})
	var scene_name = GameSession.str_or(chunk.get("scene", "office"))
	if scene_name != "office":
		_load_map_background(scene_name)
	# 更新房间索引
	var rooms = chunk.get("rooms", [])
	if typeof(rooms) == TYPE_ARRAY and not rooms.is_empty():
		BrainClass._room_index.clear()
		for r in rooms:
			if r is Dictionary:
				var rn = GameSession.str_or(r.get("name"))
				if not rn.is_empty():
					BrainClass._room_index[rn] = {
						"cx": float(r.get("cx", 0)), "cy": float(r.get("cy", 0)),
						"w": float(r.get("w", 100)), "h": float(r.get("h", 100)), "indoor": bool(r.get("indoor", true))
					}
	# 重放已有的 prefabs 到动态层（言出法随已放置的家具，重进小镇可见）
	var prefabs = data.get("prefabs_json", [])
	if typeof(prefabs) == TYPE_ARRAY:
		for p in prefabs:
			if typeof(p) == TYPE_DICTIONARY:
				_spawn_prefab({
					"action": "place_prefab",
					"pos": p.get("pos", [0, 0]),
					"prefab_name": GameSession.str_or(p.get("name"), "object"),
				})
	# 重放 AI 建造的 tiles（墙/地板/路，重进小镇可见）
	var tiles = chunk.get("tiles", [])
	if typeof(tiles) == TYPE_ARRAY:
		for t in tiles:
			if typeof(t) == TYPE_DICTIONARY:
				_place_tile({
					"action": "place_tile",
					"pos": t.get("pos", [0, 0]),
					"tile_type": GameSession.str_or(t.get("type"), ""),
				})
	print("[map] 地图数据加载：%d 个房间，%d 个家具，%d 个 tile" % [rooms.size(), prefabs.size(), tiles.size()])
	_center_camera_on_content()   # 地图内容加载完，开局看向内容主体（替代 _ready 里 (500,350) 硬编码）


# 开局相机居中：prefabs（DynamicProps）+ 建造 tiles 的 bounding box 并集中心；空地图回退地图中心。
# NPC 不算——进镇时 NPC 还没 spawn 完，且家具/建筑才是「地图主体」。
func _center_camera_on_content() -> void:
	var rect := Rect2()
	var dyn = get_node_or_null("DynamicProps")
	if dyn != null:
		for c in dyn.get_children():
			if c is Node2D:
				rect = rect.expand(c.position)
	if _map_node != null and _map_node.has_method("get_built_rect"):
		rect = rect.merge(_map_node.get_built_rect())
	if rect == Rect2():   # 空地图：地图 (1152x704) 几何中心
		god_camera.position = Vector2(576, 352)
		return
	god_camera.position = rect.get_center()


func _apply_room_params(p_town_id: int, chat_rounds: int, max_npcs: int) -> void:
	GameSession.town_id = p_town_id
	GameSession.room_chat_max_rounds = chat_rounds
	GameSession.room_max_npcs = max_npcs
	print("[online] 收到房间参数 town=%d chat_rounds=%d max_npcs=%d" % [p_town_id, chat_rounds, max_npcs])


func _handle_peer_leave(msg: Dictionary) -> void:
	var id: int = msg.get("pid", 0)
	if id == 0:
		return
	print("[ws] peer_leave pid=%d cleaning NPCs..." % id)
	_set_status("玩家离开: %d" % id)
	var npcs = get_node_or_null("NPCs")
	if npcs:
		for n in npcs.get_children():
			if n is CharacterBody2D and "owner_id" in n and n.owner_id == id:
				print("[ws] remove NPC %s (owner_id=%d)" % [n.npc_name if "npc_name" in n else n.name, id])
				n.queue_free()


func _on_connected_ok() -> void:
	pass  # WebSocket 模式下由 _on_ws_connected 处理


func _on_connected_fail() -> void:
	GameSession.lobby_message = "无法连接到该小镇"
	_return_to_lobby()


func _on_ws_disconnected() -> void:
	# WebSocket 断开（后台挂了/房主关了/网络断）
	GameSession.lobby_message = "与小镇的连接已断开"
	_return_to_lobby()


# ============================ 单端登录心跳 ============================

func _start_heartbeat() -> void:
	heartbeat_timer = Timer.new()
	heartbeat_timer.wait_time = 10.0
	heartbeat_timer.one_shot = false
	heartbeat_timer.timeout.connect(_heartbeat)
	add_child(heartbeat_timer)
	heartbeat_timer.start()


func _heartbeat() -> void:
	if GameSession.jwt.is_empty():
		return
	heartbeat_http.request(
		GameSession.api_base + "/auth/me",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	# 房主额外查小镇状态（检测管理员封禁）
	if GameSession.is_host and GameSession.town_id != 0 and not room_check_http.get_meta("busy", false):
		room_check_http.set_meta("busy", true)
		room_check_http.request(
			GameSession.api_base + "/towns/%d" % GameSession.town_id,
			["Authorization: Bearer " + GameSession.jwt],
			HTTPClient.METHOD_GET)


func _on_heartbeat(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if code == 401:
		_on_kicked()


func _on_kicked() -> void:
	print("[online] 被挤掉（账号在别处登录），回大厅")
	GameSession.kicked_reason = "账号在别处登录，请重新登录"
	if ws_relay: ws_relay.close()
	get_tree().change_scene_to_file("res://scene/maps/Lobby.tscn")


func _on_room_check(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	room_check_http.set_meta("busy", false)
	if code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY and data.get("status") == "banned":
		var reason := GameSession.str_or(data.get("ban_reason"), "房间已被管理员封禁")
		print("[online] 房间被管理员封禁，全员踢回大厅：", reason)
		_broadcast({"t": "kick_all", "reason": "房间被封禁：" + reason})


func _do_kick(reason: String) -> void:
	GameSession.kicked_reason = reason
	if ws_relay: ws_relay.close()
	get_tree().change_scene_to_file("res://scene/maps/Lobby.tscn")


# ============================ 切换控制 ============================

func _switch_to(target_npc_name: String) -> void:
	# 统一：把控制权切到指定 NPC。空字符串 = 上帝模式（不控制任何人）。
	if target_npc_name.is_empty():
		_enter_god_mode()
		return
	_exit_god_mode()
	var old_ctrl = _get_controlled_npc()

	# 释放旧控制
	if old_ctrl:
		old_ctrl.controlled_by_player = false
		if old_ctrl.has_node("Camera2D"):
			old_ctrl.get_node("Camera2D").enabled = false
		if not bool(old_ctrl.get("is_player")):
			_broadcast({"t": "control", "npc": old_ctrl.name, "on": false})

	# 接管新 NPC
	var new_npc = get_node_or_null("NPCs/" + target_npc_name)
	if not new_npc:
		_set_status("NPC '%s' 未找到" % target_npc_name)
		return
	new_npc.controlled_by_player = true
	if new_npc.has_node("Camera2D"):
		new_npc.get_node("Camera2D").enabled = true
		if not bool(new_npc.get("is_player")):
			_broadcast({"t": "control", "npc": target_npc_name, "on": true})

	GameSession.controlled_npc_name = target_npc_name
	_set_status("控制 %s（WASD；B 回上帝，C 切角色）" % target_npc_name)


func _hovering_blocking_gui() -> bool:
	# 鼠标下方是否真正压着拦截鼠标的 GUI（STOP 级：面板/滚动区）。PASS 容器（top/bottom bar 空白区）不算。
	var h: Control = get_viewport().gui_get_hovered_control()   # 4.7 方法名是 hovered（4.3 文档写 hovering）
	while h:
		if h.mouse_filter == Control.MOUSE_FILTER_STOP:
			return true
		h = h.get_parent_control()
	return false


func _controlled_camera() -> Camera2D:
	# 当前控制 NPC 的跟随相机（无控制/无相机返回 null）
	var ctrl = _get_controlled_npc()
	if ctrl and ctrl.has_node("Camera2D"):
		return ctrl.get_node("Camera2D") as Camera2D
	return null


func _enter_god_mode() -> void:
	if god_mode:
		return
	# 释放当前控制的 NPC
	var ctrl = _get_controlled_npc()
	if ctrl:
		ctrl.controlled_by_player = false
		if ctrl.has_node("Camera2D"):
			ctrl.get_node("Camera2D").enabled = false
		_broadcast({"t": "control", "npc": ctrl.name, "on": false})
		# 上帝相机放到最后一个控制的位置
		god_camera.position = ctrl.position
	god_mode = true
	god_camera.enabled = true
	GameSession.controlled_npc_name = ""
	_set_status("上帝模式：WASD 移动镜头，C 或切换面板选角色控制")


func _exit_god_mode() -> void:
	if not god_mode:
		return
	god_mode = false
	god_camera.enabled = false


func _switch_next() -> void:
	# C 键：在我拥有的所有 NPC 间循环（不含上帝模式）
	if god_mode:
		return  # 上帝模式中 C 不生效，按 B 切回
	var my_npcs := _get_my_npcs()
	if my_npcs.is_empty():
		_set_status("你没有可控制的角色")
		return
	var ctrl = _get_controlled_npc()
	var cur_idx := -1
	if ctrl:
		for i in range(my_npcs.size()):
			if my_npcs[i].name == ctrl.name:
				cur_idx = i
				break
	var next_idx := (cur_idx + 1) % my_npcs.size()
	selected_npc_name = my_npcs[next_idx].name   # C 切换控制时同步选中（面板跟着切）
	_switch_to(my_npcs[next_idx].name)


func _handle_control(msg: Dictionary) -> void:
	var npc_name: String = msg.get("npc", "")
	var on: bool = msg.get("on", false)
	var npc = get_node_or_null("NPCs/" + npc_name)
	if not npc:
		return
	npc.controlled_by_player = on


# ============================ UI ============================

# UI 字号 = 配置 ui_font_size + delta（让动态字号同时驱动标题/小字层级；缺配置走 FALLBACK）
func _ui_fs(delta: int = 0) -> int:
	return maxi(9, GameSession.int_or(GameSession.ui_config.get("ui_font_size", null), GameSession.FALLBACK_UI_FONT_SIZE) + delta)


# ---- 面板开/关动效（Phase C：统一所有面板淡入淡出；替换裸 visible=/.show/.hide）----
var _panel_tweens: Dictionary = {}

# 侧边栏右边缘拖拽调宽
func _on_side_handle_gui(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		_side_dragging = mb.pressed
		_side_handle.accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm and _side_dragging:
		_side_panel.offset_right = clampf(_side_panel.offset_right + mm.relative.x, 240.0, 600.0)
		_side_handle.accept_event()


# 隐藏侧边栏内除 keep 外的面板（互斥：一次只显示一个）
func _hide_other_side_panels(keep: Control) -> void:
	if not is_instance_valid(_side_panel):
		return
	for c in _side_panel.get_children():
		if c == _side_handle or c == keep:
			continue
		if c is CanvasItem:
			c.visible = false


func _panel_open(p: Control) -> void:
	if p == null:
		return
	# 侧边栏：互斥 + reparent 进侧边栏并填满（各 _build_xxx_panel 仍建在 canvas，打开时移入）
	_hide_other_side_panels(p)
	if is_instance_valid(_side_panel):
		if p.get_parent() != _side_panel:
			p.reparent(_side_panel)
		p.set_anchors_preset(Control.PRESET_FULL_RECT)
		p.offset_left = 0; p.offset_top = 0; p.offset_right = 0; p.offset_bottom = 0
		_side_panel.visible = true
		# 侧边栏宽度 ≥ 内容 min 宽（字号放大不横向溢出）
		var need_w := p.get_combined_minimum_size().x + 12
		_side_panel.offset_right = maxf(_side_panel.offset_right, need_w)
	_kill_panel_tween(p)
	p.modulate.a = 0.0
	p.visible = true
	AudioManager.play_open()
	var tw: Tween = p.create_tween()
	_panel_tweens[p] = tw
	tw.tween_property(p, "modulate:a", 1.0, 0.15)


func _panel_close(p: Control) -> void:
	if p == null or not p.visible:
		return
	_kill_panel_tween(p)
	AudioManager.play_close()
	var tw: Tween = p.create_tween()
	_panel_tweens[p] = tw
	tw.tween_property(p, "modulate:a", 0.0, 0.12)
	tw.finished.connect(_hide_panel.bind(p))


func _hide_panel(p: Control) -> void:
	if is_instance_valid(p):
		p.visible = false
	_panel_tweens.erase(p)
	# 侧边栏：若无面板可见则收起
	if is_instance_valid(_side_panel):
		var any_vis := false
		for c in _side_panel.get_children():
			if c != _side_handle and c is CanvasItem and c.visible:
				any_vis = true
				break
		if not any_vis:
			_side_panel.visible = false


func _kill_panel_tween(p: Control) -> void:
	var tw: Tween = _panel_tweens.get(p)
	if tw:
		tw.kill()
	_panel_tweens.erase(p)


# ---- 玩家 UI 设置（覆盖管理员默认，按账号存 settings_json["ui"]）----

func _load_ui_prefs() -> void:
	if GameSession.jwt.is_empty():
		return
	var err := ui_prefs_http.request(
		GameSession.api_base + "/auth/me/ui_prefs",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		print("[ui] 拉 ui_prefs 失败 %d" % err)


func _on_ui_prefs_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return  # 静默：未设置过则沿用默认值
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) == TYPE_DICTIONARY:
		GameSession.ui_prefs = json
		GameSession.rebuild_ui_config()
		call_deferred("_relayout_bottom")


func _mk_ui_slider(parent: Control, label_text: String, minv: float, maxv: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(110, 0)
	row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = minv
	sl.max_value = maxv
	sl.step = 1.0
	sl.custom_minimum_size = Vector2(150, 0)
	row.add_child(sl)
	var val := Label.new()
	val.custom_minimum_size = Vector2(34, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sl.value_changed.connect(func(v: float) -> void: val.text = str(int(v)))
	row.add_child(val)
	parent.add_child(row)
	return sl


func _build_ui_settings_panel(canvas: CanvasLayer) -> void:
	# 壳已在 .tscn（Phase B 收尾）：标题/保存/关闭；slider 行带值联动 label 留代码（_mk_ui_slider 闭包）
	ui_settings_panel = $UICanvas/ui_settings_panel
	var vb: VBoxContainer = $UICanvas/ui_settings_panel/VBox
	var anchor := vb.get_index() + 1   # slider 行插在 HSeparator 之后
	ui_font_slider = _mk_ui_slider(vb, "界面字号", 10, 30)
	vb.move_child(ui_font_slider.get_parent(), anchor)
	ui_bubble_font_slider = _mk_ui_slider(vb, "气泡字号", 8, 24)
	vb.move_child(ui_bubble_font_slider.get_parent(), anchor + 1)
	ui_bubble_dur_slider = _mk_ui_slider(vb, "气泡停留(秒)", 1, 12)
	vb.move_child(ui_bubble_dur_slider.get_parent(), anchor + 2)
	ui_intent_check = CheckBox.new()
	ui_intent_check.text = "显示头顶意图标签"
	vb.add_child(ui_intent_check)
	vb.move_child(ui_intent_check, anchor + 3)
	ui_bgm_mute_check = CheckBox.new()
	ui_bgm_mute_check.text = "背景音乐静音"
	ui_bgm_mute_check.toggled.connect(_on_bgm_mute_toggled)
	vb.add_child(ui_bgm_mute_check)
	vb.move_child(ui_bgm_mute_check, anchor + 4)
	ui_sfx_mute_check = CheckBox.new()
	ui_sfx_mute_check.text = "界面音效静音"
	ui_sfx_mute_check.toggled.connect(_on_sfx_mute_toggled)
	vb.add_child(ui_sfx_mute_check)
	vb.move_child(ui_sfx_mute_check, anchor + 5)
	vb.move_child($UICanvas/ui_settings_panel/VBox/btn_row, anchor + 6)
	$UICanvas/ui_settings_panel/VBox/btn_row/save_btn.pressed.connect(_on_save_ui_prefs)
	$UICanvas/ui_settings_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(ui_settings_panel))


func _on_open_ui_settings() -> void:
	# 用当前生效值（默认+玩家覆盖合并）回填控件
	ui_font_slider.value = float(GameSession.int_or(GameSession.ui_config.get("ui_font_size", null), GameSession.FALLBACK_UI_FONT_SIZE))
	ui_bubble_font_slider.value = float(GameSession.int_or(GameSession.ui_config.get("bubble_font_size", null), GameSession.FALLBACK_BUBBLE_FONT_SIZE))
	ui_bubble_dur_slider.value = GameSession.float_or(GameSession.ui_config.get("bubble_duration_sec", null), GameSession.FALLBACK_BUBBLE_DURATION_SEC)
	ui_intent_check.button_pressed = GameSession.bool_or(GameSession.ui_config.get("show_npc_intent_label", null), GameSession.FALLBACK_SHOW_INTENT_LABEL)
	ui_bgm_mute_check.set_pressed_no_signal(AudioManager.bgm_muted)
	ui_sfx_mute_check.set_pressed_no_signal(AudioManager.sfx_muted)
	_panel_open(ui_settings_panel)


func _build_token_panel(canvas: CanvasLayer) -> void:
	token_panel = $UICanvas/token_panel
	token_label = $UICanvas/token_panel/VBox/Scroll/token_label
	$UICanvas/token_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(token_panel))


func _on_open_token_panel() -> void:
	var lines := PackedStringArray()
	lines.append("累计：输入 %d / 输出 %d / 合计 %d" % [
		GameSession.total_prompt_tokens, GameSession.total_completion_tokens,
		GameSession.total_prompt_tokens + GameSession.total_completion_tokens])
	if GameSession.token_usage.is_empty():
		lines.append("")
		lines.append("暂无消耗。进镇跑一会儿，NPC 决策/对话会产生 token。")
	else:
		lines.append("")
		lines.append("— 按角色 —")
		for n in GameSession.token_usage:
			var e: Dictionary = GameSession.token_usage[n]
			lines.append("  %s（%s）：入 %d / 出 %d" % [
				n, GameSession.str_or(e.get("provider"), "?"),
				int(e.get("prompt_tokens", 0)), int(e.get("completion_tokens", 0))])
		var by_provider := {}
		for n in GameSession.token_usage:
			var e: Dictionary = GameSession.token_usage[n]
			var p := GameSession.str_or(e.get("provider"), "?")
			var acc: Dictionary = by_provider.get(p, {"in": 0, "out": 0})
			acc["in"] = int(acc["in"]) + int(e.get("prompt_tokens", 0))
			acc["out"] = int(acc["out"]) + int(e.get("completion_tokens", 0))
			by_provider[p] = acc
		lines.append("")
		lines.append("— 按 provider —")
		for p in by_provider:
			var acc: Dictionary = by_provider[p]
			lines.append("  %s：入 %d / 出 %d" % [p, int(acc["in"]), int(acc["out"])])
	token_label.text = "\n".join(lines)
	_panel_open(token_panel)


func _build_about_panel(canvas: CanvasLayer) -> void:
	about_panel = $UICanvas/about_panel
	about_label = $UICanvas/about_panel/VBox/about_label
	about_label.text = "音频素材：\n  BGM「Indie Meditations - lvl_2_the_village」by Yann Ziangos（CC BY 4.0）\n  SFX「Kenney Interface Sounds」by Kenney（CC0）"
	$UICanvas/about_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(about_panel))


func _on_open_about() -> void:
	_panel_open(about_panel)


func _on_open_tutorial() -> void:
	Tutorial.show(self, "town")


func _on_save_ui_prefs() -> void:
	var prefs := {
		"ui_font_size": int(ui_font_slider.value),
		"bubble_font_size": int(ui_bubble_font_slider.value),
		"bubble_duration_sec": float(ui_bubble_dur_slider.value),
		"show_npc_intent_label": ui_intent_check.button_pressed,
	}
	GameSession.ui_prefs = prefs
	GameSession.rebuild_ui_config()  # 立即生效（字号/意图标签/气泡）
	call_deferred("_relayout_bottom")
	if GameSession.jwt.is_empty():
		_panel_close(ui_settings_panel)
		return
	if is_instance_valid(ui_prefs_put_http):
		ui_prefs_put_http.queue_free()
	ui_prefs_put_http = HTTPRequest.new()
	add_child(ui_prefs_put_http)
	ui_prefs_put_http.request_completed.connect(_on_ui_prefs_saved)
	var err := ui_prefs_put_http.request(
		GameSession.api_base + "/auth/me/ui_prefs",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PUT, JSON.stringify(prefs))
	if err != OK:
		_set_status("UI 设置保存失败 %d" % err)
	_panel_close(ui_settings_panel)


func _on_ui_prefs_saved(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_set_status("UI 设置已保存" if code == 200 else "保存失败 HTTP %d" % code)


func _on_bgm_mute_toggled(_on: bool) -> void:
	AudioManager.toggle_bgm_muted()


func _on_sfx_mute_toggled(_on: bool) -> void:
	AudioManager.toggle_sfx_muted()


func _build_ui() -> void:
	byok_http = HTTPRequest.new()
	char_http = HTTPRequest.new()
	_char_ai_http = HTTPRequest.new()
	heartbeat_http = HTTPRequest.new()
	room_check_http = HTTPRequest.new()
	chat_log_http = HTTPRequest.new()
	npc_log_http = HTTPRequest.new()
	ui_prefs_http = HTTPRequest.new()
	add_child(byok_http)
	add_child(char_http)
	add_child(_char_ai_http)
	add_child(heartbeat_http)
	add_child(room_check_http)
	add_child(chat_log_http)
	add_child(npc_log_http)
	add_child(ui_prefs_http)
	byok_http.request_completed.connect(_on_byok_saved)
	char_http.request_completed.connect(_on_char_saved)
	_char_ai_http.request_completed.connect(_on_char_ai_saved)
	heartbeat_http.request_completed.connect(_on_heartbeat)
	room_check_http.request_completed.connect(_on_room_check)
	chat_log_http.request_completed.connect(_on_chat_log_response)
	npc_log_http.request_completed.connect(_on_npc_log_response)
	ui_prefs_http.request_completed.connect(_on_ui_prefs_response)
	# 角色 id→name 映射（对话记录展示用）
	if GameSession.character_id != 0:
		_char_names[GameSession.character_id] = GameSession.character_name
	for c in GameSession.npc_list:
		var cid := int(c.get("id", 0))
		if cid != 0:
			_char_names[cid] = GameSession.str_or(c.get("name"), "#%d" % cid)
	var canvas = _ui_canvas
	# 左侧 HUD 壳（top/bottom bar、side_panel、chat_input、status_hud）已迁 OnlineWorld.tscn（Phase B②）
	_side_handle.gui_input.connect(_on_side_handle_gui)
	var bottom_bar := $UICanvas/bottom_bar
	var bottom_content := $UICanvas/bottom_content
	_add_tab(bottom_bar, bottom_content, "设置", [["AI 设置", _on_open_ai_settings], ["UI 设置", _on_open_ui_settings], ["Token 消耗", _on_open_token_panel]])
	_add_tab(bottom_bar, bottom_content, "角色", [["角色设定", _on_open_char_panel], ["对话记录", _on_open_chat_log], ["NPC 日志", _on_open_npc_log], ["植入记忆", _on_open_implant_memory]])
	_add_tab(bottom_bar, bottom_content, "状态", [["状态 HUD", _toggle_status_hud], ["改状态", _on_open_status_edit], ["改关系", _on_open_relations_edit]])
	_add_tab(bottom_bar, bottom_content, "玩法", [["任务", _on_open_task_panel], ["交易", _on_open_trade_panel]])
	if GameSession.is_host:
		_add_tab(bottom_bar, bottom_content, "导演", [["导演控制台", _on_open_director_panel]])
	_add_tab(bottom_bar, bottom_content, "系统", [["切换角色（C 键）", _open_switch_panel], ["新手教程", _on_open_tutorial], ["关于", _on_open_about], ["返回大厅", _on_back]])
	call_deferred("_relayout_bottom")

	# 底部对话输入框（.tscn 已建，默认隐藏，回车唤起）
	chat_input.text_submitted.connect(_on_chat_submitted)

	_build_ai_settings_panel(canvas)
	_build_char_panel(canvas)
	_build_switch_panel(canvas)
	_build_player_list_panel(canvas)
	_build_status_hud(canvas)
	_build_status_edit_panel(canvas)
	_build_relations_edit_panel(canvas)
	_build_implant_memory_panel(canvas)
	_build_trade_panel(canvas)
	_build_director_panel(canvas)
	_build_ui_settings_panel(canvas)
	_build_token_panel(canvas)
	_build_about_panel(canvas)


# 底部横排 tab：组标题横排，点击在上方一行展开该组按钮（互斥，再点收起）
func _add_tab(bar: HBoxContainer, content: Control, title: String, btns: Array) -> void:
	var head := Button.new()
	head.text = title
	head.custom_minimum_size = Vector2(120, 0)
	head.toggle_mode = true
	bar.add_child(head)
	head.toggled.connect(func(on: bool) -> void:
		for c in bar.get_children():
			if c is Button and c != head:
				c.set_pressed_no_signal(false)
		for c in content.get_children():
			c.queue_free()
		if on:
			for b in btns:
				_add_btn(content, b[0], b[1])
			content.visible = true
		else:
			content.visible = false
		call_deferred("_relayout_bottom"))


func _add_btn(parent: Control, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)


# 底部一级/二级菜单高度跟随内容 min 高（字号放大按钮变高不重叠）：贴底向上长
func _relayout_bottom() -> void:
	var bb := $UICanvas/bottom_bar
	var bc := $UICanvas/bottom_content
	bb.offset_top = bb.offset_bottom - bb.get_combined_minimum_size().y
	if bc.visible and bc.get_child_count() > 0:
		bc.offset_bottom = bb.offset_top - 8
		bc.offset_top = bc.offset_bottom - bc.get_combined_minimum_size().y


# 右上角游戏时钟文本：game_clock_min(分钟) → HH:MM · 时段(·天气)
func _refresh_game_clock_label() -> void:
	if not is_instance_valid(game_clock_label):
		return
	var m := GameSession.game_clock_min
	if m < 0:
		game_clock_label.text = "🕐 --:--"
		return
	var h: int = m / 60
	var mi: int = m % 60
	var period := "白天" if (h >= 6 and h < 18) else "黑夜"
	var wstr := ""
	match GameSession.weather:
		"rain": wstr = " · 雨"
		"storm": wstr = " · 暴风"
		"snow": wstr = " · 雪"
		"cloudy": wstr = " · 阴"
	game_clock_label.text = "🕐 %02d:%02d · %s%s" % [h, mi, period, wstr]


func _build_ai_settings_panel(canvas: CanvasLayer) -> void:
	var panel = $UICanvas/ai_settings_panel
	ai_panel = panel
	var type_opt: OptionButton = $UICanvas/ai_settings_panel/VBox/type_row/ai_type_opt
	var model_edit: LineEdit = $UICanvas/ai_settings_panel/VBox/model_row/ai_model_edit
	var key_edit: LineEdit = $UICanvas/ai_settings_panel/VBox/key_row/ai_key_edit
	for t in SettingsManager.api_types:
		type_opt.add_item(t)
	$UICanvas/ai_settings_panel/VBox/btn_row/save_btn.pressed.connect(
		_on_save_ai_settings.bind(type_opt, model_edit, key_edit))
	$UICanvas/ai_settings_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(ai_panel))


func _on_open_ai_settings() -> void:
	var s = SettingsManager.get_settings()
	var type_opt: OptionButton = ai_panel.get_node("VBox/type_row/ai_type_opt")
	var model_edit: LineEdit = ai_panel.get_node("VBox/model_row/ai_model_edit")
	var key_edit: LineEdit = ai_panel.get_node("VBox/key_row/ai_key_edit")
	var cur_type = GameSession.str_or(s.get("api_type"), "Ollama")
	var found := false
	for i in type_opt.item_count:
		if type_opt.get_item_text(i) == cur_type:
			type_opt.selected = i
			found = true
			break
	if not found:
		type_opt.selected = 0
	model_edit.text = GameSession.str_or(s.get("model"))
	key_edit.text = GameSession.str_or(s.get("api_key"))
	_panel_open(ai_panel)


func _on_save_ai_settings(type_opt: OptionButton, model_edit: LineEdit, key_edit: LineEdit) -> void:
	var s = SettingsManager.get_settings()
	s["api_type"] = type_opt.get_item_text(type_opt.selected)
	s["model"] = model_edit.text.strip_edges()
	s["api_key"] = key_edit.text.strip_edges()
	SettingsManager.update_settings(s)
	_panel_close(ai_panel)
	_set_status("AI 设置已保存：%s / %s" % [s["api_type"], s["model"]])
	if GameSession.jwt:
		var body := JSON.stringify({"api_type": s["api_type"], "model": s["model"], "api_key": s["api_key"]})
		byok_http.request(
			GameSession.api_base + "/auth/me/byok",
			["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
			HTTPClient.METHOD_PUT, body)


func _on_byok_saved(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	print("[online] BYOK 同步后台 HTTP ", code)


func _position_chat_input() -> void:
	var vp := get_viewport_rect().size
	chat_input.size = Vector2(600, 40)
	chat_input.position = Vector2(int((vp.x - 600) / 2), int(vp.y - 60))


# ============================ 角色设定面板 ============================

func _build_char_panel(canvas: CanvasLayer) -> void:
	# 壳已在 .tscn（Phase B③）：表单控件 + AI 优化/保存/关闭按钮；这里只接信号 + 填性别选项
	char_panel = $UICanvas/char_panel
	char_name_edit = $UICanvas/char_panel/Scroll/VBox/char_name_edit
	char_position_edit = $UICanvas/char_panel/Scroll/VBox/char_position_edit
	char_gender_edit = $UICanvas/char_panel/Scroll/VBox/char_gender_edit
	char_personality_edit = $UICanvas/char_panel/Scroll/VBox/char_personality_edit
	char_speaking_style_edit = $UICanvas/char_panel/Scroll/VBox/char_speaking_style_edit
	char_work_duties_edit = $UICanvas/char_panel/Scroll/VBox/char_work_duties_edit
	char_work_habits_edit = $UICanvas/char_panel/Scroll/VBox/char_work_habits_edit
	char_notes_edit = $UICanvas/char_panel/Scroll/VBox/char_notes_edit
	for g in ["未设定", "男", "女"]:
		char_gender_edit.add_item(g)
	# 每角色 AI：provider 下拉用 APIConfig 真 key（未知名会回退 Ollama，勿用别名）
	for t in SettingsManager.api_types:
		$UICanvas/char_panel/Scroll/VBox/char_ai_type_opt.add_item(t)
	$UICanvas/char_panel/Scroll/VBox/char_ai_row/char_ai_clear_btn.pressed.connect(_on_clear_char_ai)
	$UICanvas/char_panel/Scroll/VBox/char_ai_row/char_ai_save_btn.pressed.connect(_on_save_char_ai)
	$UICanvas/char_panel/Scroll/VBox/btn_row/ai_btn.pressed.connect(_on_ai_optimize_char)
	$UICanvas/char_panel/Scroll/VBox/btn_row/save_btn.pressed.connect(_on_save_char)
	$UICanvas/char_panel/Scroll/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(char_panel))


func _mk_text(placeholder: String) -> TextEdit:
	var t = TextEdit.new()
	t.placeholder_text = placeholder
	t.custom_minimum_size = Vector2(0, 100)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	return t


# 填入编辑框：优先 personality_json dict，其次 background JSON 字符串
func _populate_char_fields(bg: String, p_dict: Dictionary = {}) -> void:
	char_position_edit.text = ""
	char_personality_edit.text = ""
	char_speaking_style_edit.text = ""
	char_work_duties_edit.text = ""
	char_work_habits_edit.text = ""
	char_notes_edit.text = ""
	char_gender_edit.select(0)
	if not p_dict.is_empty() and p_dict.has("position"):
		char_position_edit.text = GameSession.str_or(p_dict.get("position"))
		char_personality_edit.text = GameSession.str_or(p_dict.get("personality"))
		char_speaking_style_edit.text = GameSession.str_or(p_dict.get("speaking_style"))
		char_work_duties_edit.text = GameSession.str_or(p_dict.get("work_duties"))
		char_work_habits_edit.text = GameSession.str_or(p_dict.get("work_habits"))
		char_notes_edit.text = GameSession.str_or(p_dict.get("notes"))
		char_gender_edit.select(_gender_index(GameSession.str_or(p_dict.get("gender"))))
		return
	if bg.is_empty():
		return
	if bg.begins_with("{") and bg.ends_with("}"):
		var parsed = JSON.parse_string(bg)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("position"):
			char_position_edit.text = GameSession.str_or(parsed.get("position"))
			char_personality_edit.text = GameSession.str_or(parsed.get("personality"))
			char_speaking_style_edit.text = GameSession.str_or(parsed.get("speaking_style"))
			char_work_duties_edit.text = GameSession.str_or(parsed.get("work_duties"))
			char_work_habits_edit.text = GameSession.str_or(parsed.get("work_habits"))
			char_notes_edit.text = GameSession.str_or(parsed.get("notes"))
			char_gender_edit.select(_gender_index(GameSession.str_or(parsed.get("gender"))))
			return
	char_notes_edit.text = bg  # 旧版纯文本 → 补充设定


# 性别文本 → OptionButton 索引（0 未设定 / 1 男 / 2 女；识别英文别名）
func _gender_index(g: String) -> int:
	var t := g.to_lower()
	if t in ["男", "male", "m"]:
		return 1
	if t in ["女", "female", "f"]:
		return 2
	return 0


func _on_open_char_panel() -> void:
	var sel = _find_selected_npc()
	if sel == null:
		_set_status("请先选中一个角色")
		return
	char_name_edit.text = sel.npc_name
	_populate_char_fields(sel.get("personality_text"), sel.get("persona"))
	_load_char_ai(sel)
	_panel_open(char_panel)
	char_name_edit.grab_focus()


# ---------- 每角色 AI（BYOK）：回填 / 保存 / 清除 ----------
func _char_ai_nodes() -> Dictionary:
	return {
		"type_opt": char_panel.get_node("Scroll/VBox/char_ai_type_opt"),
		"model_edit": char_panel.get_node("Scroll/VBox/char_ai_model_edit"),
		"key_edit": char_panel.get_node("Scroll/VBox/char_ai_key_edit"),
	}


func _load_char_ai(sel) -> void:
	# 未配置角色显示账号全局值作参考（key 打码不回显）；配置过则显示角色值
	var ui := _char_ai_nodes()
	var s := SettingsManager.get_settings()
	var char_s := SettingsManager.get_character_ai_settings(sel.npc_name)
	var has_own := SettingsManager.has_character_ai_settings(sel.npc_name)
	var cur_type := GameSession.str_or(char_s.get("api_type") if has_own else s.get("api_type"), "Ollama")
	var opt: OptionButton = ui["type_opt"]
	for i in opt.item_count:
		if opt.get_item_text(i) == cur_type:
			opt.selected = i
			break
	(ui["model_edit"] as LineEdit).text = GameSession.str_or(char_s.get("model") if has_own else s.get("model"))
	(ui["key_edit"] as LineEdit).text = ""   # key 不回显（留空不改）


func _on_save_char_ai() -> void:
	var sel = _find_selected_npc()
	if sel == null or sel.character_id <= 0 or GameSession.jwt.is_empty():
		_set_status("未选中角色或未登录")
		return
	var ui := _char_ai_nodes()
	var opt: OptionButton = ui["type_opt"]
	var body := JSON.stringify({
		"api_type": opt.get_item_text(opt.selected),
		"model": (ui["model_edit"] as LineEdit).text.strip_edges(),
		"api_key": (ui["key_edit"] as LineEdit).text.strip_edges(),
	})
	_char_ai_http.request(
		GameSession.api_base + "/characters/%d/byok" % sel.character_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PUT, body)
	_set_status("角色 AI 设置保存中...")


func _on_char_ai_saved(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		_set_status("角色 AI 设置保存失败 (HTTP %d)" % code)
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY:
		return
	var sel = _find_selected_npc()
	if sel and not GameSession.str_or(json.get("api_type")).is_empty():
		SettingsManager.set_character_ai_settings(sel.npc_name, {
			"api_type": GameSession.str_or(json.get("api_type")),
			"model": GameSession.str_or(json.get("model")),
			"api_key": GameSession.str_or(json.get("api_key")),
		})
		_set_status("角色 AI 已生效：%s / %s" % [json.get("api_type"), json.get("model")])
		_load_char_ai(sel)
	elif sel:
		_set_status("角色 AI 已保存")


func _on_clear_char_ai() -> void:
	var sel = _find_selected_npc()
	if sel == null or sel.character_id <= 0 or GameSession.jwt.is_empty():
		_set_status("未选中角色或未登录")
		return
	# 全字段置空 = 后端存 NULL = 客户端回退账号级全局
	var body := JSON.stringify({"api_type": "", "model": "", "api_key": ""})
	_char_ai_http.request(
		GameSession.api_base + "/characters/%d/byok" % sel.character_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PUT, body)
	SettingsManager.remove_character_ai_settings(sel.npc_name)
	_set_status("已清除，本角色回退账号全局 AI")
	_load_char_ai(sel)


# AI 优化：把已填的 6 字段发给玩家 BYOK 的 LLM 润色，结果回填表单（不自动保存）
func _on_ai_optimize_char() -> void:
	var edits := {
		"position": char_position_edit,
		"personality": char_personality_edit,
		"speaking_style": char_speaking_style_edit,
		"work_duties": char_work_duties_edit,
		"work_habits": char_work_habits_edit,
		"notes": char_notes_edit,
	}
	var all_empty := true
	for k in edits:
		if not String((edits[k] as Control).get("text")).strip_edges().is_empty():
			all_empty = false
			break
	if all_empty:
		_set_status("先填写一些内容再优化")
		return
	var prompt := """你是角色设定优化助手。根据用户填写的角色信息，把每个字段润色得更加生动、具体、有画面感，并保持原意不变。只回 JSON，不要任何解释或围栏：
{"position":"职位","personality":"性格","speaking_style":"说话风格","work_duties":"工作职责","work_habits":"工作习惯","notes":"补充设定"}

用户填写的原始信息：
职位：<<position>>
性格：<<personality>>
说话风格：<<speaking_style>>
工作职责：<<work_duties>>
工作习惯：<<work_habits>>
补充设定：<<notes>>

要求：空字段可以留空，也可以根据其他字段合理补全一个简短合理的值；每个字段控制在 60 字内；语气、人设一致。"""
	for k in edits:
		prompt = prompt.replace("<<" + k + ">>", String((edits[k] as Control).get("text")).strip_edges())
	_set_status("AI 优化中...")
	var req = await APIManager.generate_dialog(prompt, "")
	if req == null:
		_set_status("AI 未配置（先到大厅「AI 设置」填 API）")
		return
	var result = await req.request_completed
	if typeof(result) != TYPE_ARRAY or result.size() < 4 or int(result[1]) != 200:
		_set_status("AI 优化失败")
		return
	var api_type := GameSession.str_or(APIManager.current_settings.get("api_type"), "Ollama")
	var text := APIConfig.parse_response(api_type, JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8()))
	var body_str := text.strip_edges()
	var lb := body_str.find("{")
	var rb := body_str.rfind("}")
	if lb == -1 or rb == -1 or rb <= lb:
		_set_status("AI 返回异常")
		return
	var parsed = JSON.parse_string(body_str.substr(lb, rb - lb + 1))
	if typeof(parsed) != TYPE_DICTIONARY:
		_set_status("AI 返回异常")
		return
	for k in edits:
		var v := str(parsed.get(k, ""))
		if not v.is_empty():
			(edits[k] as Control).set("text", v.strip_edges())
	_set_status("已优化，检查后点「保存」")


func _on_save_char() -> void:
	var nm = char_name_edit.text.strip_edges()
	if nm.is_empty():
		_set_status("角色名不能为空")
		return
	var sel = _find_selected_npc()
	if sel == null or sel.character_id <= 0 or GameSession.jwt.is_empty():
		_set_status("未选中角色或未登录")
		return
	var persona_dict := {
		position = char_position_edit.text.strip_edges(),
		personality = char_personality_edit.text.strip_edges(),
		speaking_style = char_speaking_style_edit.text.strip_edges(),
		work_duties = char_work_duties_edit.text.strip_edges(),
		work_habits = char_work_habits_edit.text.strip_edges(),
		notes = char_notes_edit.text.strip_edges(),
		gender = char_gender_edit.get_item_text(char_gender_edit.selected),
	}
	if persona_dict["gender"] == "未设定":
		persona_dict["gender"] = ""
	var body := JSON.stringify({"name": nm, "personality_json": persona_dict})
	var err = char_http.request(
		GameSession.api_base + "/characters/%d" % sel.character_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH, body)
	_set_status("角色设定保存中..." if err == OK else "请求失败 %d" % err)


func _on_char_saved(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		_set_status("角色设定保存失败 (HTTP %d)" % code)
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	var new_name := ""
	var new_bg := ""
	var new_persona: Dictionary = {}
	if typeof(json) == TYPE_DICTIONARY:
		new_name = GameSession.str_or(json.get("name"))
		new_bg = GameSession.str_or(json.get("background"))
		var rp = json.get("personality_json")
		new_persona = rp if typeof(rp) == TYPE_DICTIONARY else {}
	# 刷新当前选中 NPC 的本地显示
	var p = _find_selected_npc()
	if p:
		p.setup_npc(new_name if not new_name.is_empty() else p.npc_name, new_bg, p.owner_id, p.character_id, new_persona)
	_panel_close(char_panel)
	_set_status("角色设定已更新：%s" % (new_name if not new_name.is_empty() else (p.npc_name if p else "?")))


# ============================ 切换角色面板 ============================

func _build_switch_panel(canvas: CanvasLayer) -> void:
	var panel = $UICanvas/switch_panel
	switch_panel = panel
	switch_itemlist = $UICanvas/switch_panel/VBox/switch_itemlist
	switch_itemlist.item_selected.connect(_on_switch_pick)
	$UICanvas/switch_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(switch_panel))


func _open_switch_panel() -> void:
	switch_itemlist.clear()
	for n in _get_my_npcs():
		switch_itemlist.add_item(n.npc_name)
	_panel_open(switch_panel)


func _on_switch_pick(idx: int) -> void:
	if idx < 0:
		return
	var my_npcs := _get_my_npcs()
	if idx < my_npcs.size():
		selected_npc_name = my_npcs[idx].name   # 始终更新选中（所有面板看它）
		if god_mode:
			_set_status("选中：%s（按 B 控制它）" % my_npcs[idx].npc_name)
		else:
			_switch_to(selected_npc_name)   # 非上帝：同步切换控制


func _on_chat_submitted(text: String) -> void:
	var ctrl = _get_controlled_npc()
	chat_input.hide()
	chat_input.clear()
	if ctrl:
		ctrl.player_speak(text)


func _return_to_lobby() -> void:
	# 非主动离开（断线/被踢/挤掉），fire-and-forget 关小镇
	if GameSession.is_host and GameSession.town_id != 0 and not GameSession.jwt.is_empty():
		var http := HTTPRequest.new()
		get_tree().root.add_child(http)
		http.request_completed.connect(func(_r, _c, _h, _b): http.queue_free())
		http.request(
			GameSession.api_base + "/towns/%d?status=closed" % GameSession.town_id,
			["Authorization: Bearer " + GameSession.jwt],
			HTTPClient.METHOD_PATCH)
	if ws_relay: ws_relay.close()
	GameSession.pid = 0
	GameSession.is_host = false
	get_tree().change_scene_to_file("res://scene/maps/Lobby.tscn")


func _on_back() -> void:
	# 二次确认，避免误点（会关小镇状态 + 断连接 + 切场景）；主题化确认框（ConfirmBox）
	ConfirmBox.show_confirm(self, "返回大厅", "确定返回大厅吗？", "返回大厅", "留在小镇", _do_back)


func _do_back() -> void:
	# 主动返回大厅：先关小镇状态再切场景
	if GameSession.is_host and GameSession.town_id != 0 and not GameSession.jwt.is_empty():
		await _close_town()
	if ws_relay: ws_relay.close()
	GameSession.pid = 0
	GameSession.is_host = false
	get_tree().change_scene_to_file("res://scene/maps/Lobby.tscn")


func _close_town() -> void:
	var http := HTTPRequest.new()
	get_tree().root.add_child(http)
	http.request(
		GameSession.api_base + "/towns/%d?status=closed" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH)
	var resp = await http.request_completed
	print("[online] town #%d → closed (HTTP %d)" % [GameSession.town_id, resp[1]])
	http.queue_free()


# ============================ 玩家列表面板（Tab） ============================

func _build_player_list_panel(canvas: CanvasLayer) -> void:
	player_list_panel = $UICanvas/player_list_panel
	player_list_label = $UICanvas/player_list_panel/VBox/player_list_label


func _open_player_list() -> void:
	# 动态扫描 NPCs 节点统计
	var lines: Array[String] = []
	var npcs = get_node_or_null("NPCs")
	if npcs:
		var stats := {}
		for n in npcs.get_children():
			if not (n is CharacterBody2D) or not "owner_id" in n:
				continue
			var pid: int = n.owner_id
			if not stats.has(pid):
				stats[pid] = {"player_name": "", "total": 0, "controlled": ""}
			stats[pid]["total"] += 1
			if n.get("controlled_by_player"):
				stats[pid]["controlled"] = n.npc_name
			if stats[pid]["player_name"].is_empty():
				stats[pid]["player_name"] = n.npc_name
		var my_id = GameSession.pid
		for pid in stats:
			var s: Dictionary = stats[pid]
			var marker := "  ← 你" if pid == my_id else ""
			var ctrl := ""
			if pid == my_id and god_mode:
				ctrl = " [上帝模式]"
			elif not s["controlled"].is_empty():
				ctrl = " [控: %s]" % s["controlled"]
			lines.append("peer %d  %s  NPC×%d%s%s" % [pid, s["player_name"], s["total"], ctrl, marker])
	else:
		lines.append("（暂无角色）")
	player_list_label.text = "\n".join(lines)
	# PRESET_CENTER 只对齐左上角，面板撑开后偏右下——显式按视口居中
	var vp := get_viewport_rect().size
	player_list_panel.position = (vp - player_list_panel.size) / 2.0
	player_list_panel.visible = true   # Tab 临时显示，不走侧边栏


func _set_status(t: String) -> void:
	if status_label:
		status_label.text = t
	print("[online] ", t)


# ============================ 对话记录面板 ============================

func _on_open_chat_log() -> void:
	if chat_log_panel == null:
		_build_chat_log_panel()
	_panel_open(chat_log_panel)
	_refresh_chat_logs()
	if not is_instance_valid(chat_log_timer):
		chat_log_timer = Timer.new()
		chat_log_timer.wait_time = 5.0
		chat_log_timer.one_shot = false
		chat_log_timer.timeout.connect(_refresh_chat_logs)
		add_child(chat_log_timer)
	chat_log_timer.start()


func _build_chat_log_panel() -> void:
	chat_log_panel = $UICanvas/chat_log_panel
	chat_log_vbox = $UICanvas/chat_log_panel/VBox/Scroll/chat_log_vbox
	$UICanvas/chat_log_panel/VBox/btn_row/refresh_btn.pressed.connect(_refresh_chat_logs)
	$UICanvas/chat_log_panel/VBox/btn_row/close_btn.pressed.connect(_close_chat_log)


func _close_chat_log() -> void:
	_panel_close(chat_log_panel)
	if is_instance_valid(chat_log_timer):
		chat_log_timer.stop()


# ============================ NPC 日志面板（看选中角色的行为记录）============================

func _on_open_npc_log() -> void:
	if npc_log_panel == null:
		_build_npc_log_panel()
	_panel_open(npc_log_panel)
	_refresh_npc_logs()
	if not is_instance_valid(npc_log_timer):
		npc_log_timer = Timer.new()
		npc_log_timer.wait_time = 5.0
		npc_log_timer.one_shot = false
		npc_log_timer.timeout.connect(_refresh_npc_logs)
		add_child(npc_log_timer)
	npc_log_timer.start()


func _build_npc_log_panel() -> void:
	npc_log_panel = $UICanvas/npc_log_panel
	npc_log_title = $UICanvas/npc_log_panel/VBox/title   # 标题动态显选中名
	npc_log_vbox = $UICanvas/npc_log_panel/VBox/Scroll/npc_log_vbox
	$UICanvas/npc_log_panel/VBox/btn_row/refresh_btn.pressed.connect(_refresh_npc_logs)
	$UICanvas/npc_log_panel/VBox/btn_row/close_btn.pressed.connect(_close_npc_log)


func _close_npc_log() -> void:
	_panel_close(npc_log_panel)
	if is_instance_valid(npc_log_timer):
		npc_log_timer.stop()


func _refresh_npc_logs() -> void:
	if GameSession.jwt.is_empty():
		return
	# 上帝视角：拉全镇 NPC 日志（不按选中角色隔离），每条带 character_name 标是谁
	var url := GameSession.api_base + "/npc_logs?limit=50"
	npc_log_http.request(url, ["Authorization: Bearer " + GameSession.jwt], HTTPClient.METHOD_GET)


func _on_npc_log_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		_set_status("NPC 日志加载失败 HTTP %d" % code)
		return
	var arr = JSON.parse_string(body.get_string_from_utf8())
	if typeof(arr) != TYPE_ARRAY or npc_log_vbox == null:
		return
	if is_instance_valid(npc_log_title):
		npc_log_title.text = "NPC 日志（%s）" % (selected_npc_name if not selected_npc_name.is_empty() else "全镇")
	for c in npc_log_vbox.get_children():
		c.queue_free()
	var shown := 0
	for log in arr:
		if typeof(log) != TYPE_DICTIONARY:
			continue
		var cn: String = GameSession.str_or(log.get("character_name"), "?")
		# 选中角色隔离：有选中只看它的行为流，否则全镇（上帝视角）
		if not selected_npc_name.is_empty() and cn != selected_npc_name:
			continue
		var content: String = GameSession.str_or(log.get("content"))
		var lbl := Label.new()
		# 每行带角色名；内容自带中文类型前缀（决策意图/内心独白/移动/…），不显示英文 log_type
		lbl.text = "[%s] %s" % [cn, content]
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		npc_log_vbox.add_child(lbl)
		shown += 1
	if shown == 0:
		var empty := Label.new()
		empty.text = "暂无日志" if selected_npc_name.is_empty() else "%s 暂无日志" % selected_npc_name
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		npc_log_vbox.add_child(empty)


func _refresh_chat_logs() -> void:
	if GameSession.jwt.is_empty():
		return
	var sel = _find_selected_npc()
	var url := GameSession.api_base + "/chat_logs?limit=50&town_id=%d" % GameSession.town_id
	if sel and sel.character_id != 0:
		url += "&character_id=%d" % sel.character_id   # 只看选中 NPC 参与的对话
	chat_log_http.request(url, ["Authorization: Bearer " + GameSession.jwt], HTTPClient.METHOD_GET)


func _on_chat_log_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		_set_status("对话记录加载失败 HTTP %d" % code)
		return
	var arr = JSON.parse_string(body.get_string_from_utf8())
	if typeof(arr) != TYPE_ARRAY or chat_log_vbox == null:
		return
	# 清空旧条目
	for c in chat_log_vbox.get_children():
		c.queue_free()
	if arr.is_empty():
		var empty := Label.new()
		empty.text = "暂无对话记录"
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chat_log_vbox.add_child(empty)
		return
	for log in arr:
		if typeof(log) != TYPE_DICTIONARY:
			continue
		var sid: int = GameSession.int_or(log.get("speaker_id"))
		var speaker: String = GameSession.str_or(_char_names.get(sid), "#%d" % sid) if sid != 0 else "（独白）"
		var lid: int = GameSession.int_or(log.get("listener_id"))
		var line := speaker
		if lid != 0:
			line += " → " + GameSession.str_or(_char_names.get(lid), "#%d" % lid)
		line += "：" + GameSession.str_or(log.get("content"))
		var lbl := Label.new()
		lbl.text = line
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if bool(log.get("is_flagged", false)):
			lbl.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		chat_log_vbox.add_child(lbl)
	# 列表时间升序，最新在最底部；刷新后滚到底，否则 5s 定时刷新看不到新条目
	await get_tree().process_frame
	var _scroll := $UICanvas/chat_log_panel/VBox/Scroll as ScrollContainer
	if _scroll:
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


# ============================ 状态 HUD ============================

func _build_status_hud(canvas: CanvasLayer) -> void:
	# 壳已在 .tscn（status_hud + VBox + mood/money/health），这里只收 bars 引用
	status_hud_bars["mood"] = $UICanvas/status_hud/VBox/mood_bar
	status_hud_bars["money"] = $UICanvas/status_hud/VBox/money_label
	status_hud_bars["health"] = $UICanvas/status_hud/VBox/health_bar


func _toggle_status_hud() -> void:
	if status_hud == null: return
	status_hud.visible = not status_hud.visible
	if status_hud.visible:
		_refresh_status_hud()


func _refresh_status_hud() -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null: return
	var mb = status_hud_bars.get("mood")
	if mb is ProgressBar: mb.value = ctrl.mood
	var ml = status_hud_bars.get("money")
	if ml is Label: ml.text = "金币: %d" % ctrl.money
	var hb = status_hud_bars.get("health")
	if hb is ProgressBar: hb.value = ctrl.health


# ============================ 上帝改状态面板 ============================

func _build_status_edit_panel(canvas: CanvasLayer) -> void:
	# 壳已在 .tscn（Phase B③）：滑条/SpinBox/按钮；这里只接信号
	status_edit_panel = $UICanvas/status_edit_panel
	status_edit_sel_label = $UICanvas/status_edit_panel/VBox/status_edit_sel_label
	status_edit_mood = $UICanvas/status_edit_panel/VBox/mood_row/status_edit_mood
	status_edit_health = $UICanvas/status_edit_panel/VBox/health_row/status_edit_health
	status_edit_money = $UICanvas/status_edit_panel/VBox/money_row/status_edit_money
	$UICanvas/status_edit_panel/VBox/btn_row/apply_btn.pressed.connect(_apply_status_edit)
	$UICanvas/status_edit_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(status_edit_panel))


func _on_open_status_edit() -> void:
	if status_edit_panel == null: return
	_panel_open(status_edit_panel)
	_refresh_status_edit()


func _refresh_status_edit() -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null:
		status_edit_sel_label.text = "选中：无（请先选角色）"
		return
	status_edit_sel_label.text = "选中：" + ctrl.npc_name
	status_edit_mood.value = ctrl.mood
	status_edit_health.value = ctrl.health
	status_edit_money.value = ctrl.money


func _apply_status_edit() -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null:
		_set_status("没有选中角色")
		return
	ctrl.patch_character_status({"mood": status_edit_mood.value, "money": int(status_edit_money.value), "health": status_edit_health.value})
	_set_status("已应用状态到 %s" % ctrl.npc_name)
	_refresh_status_hud()


# ============================ 关系编辑面板（仅自己选中的 NPC；后端 owner 校验兜底） ============================

func _build_relations_edit_panel(canvas: CanvasLayer) -> void:
	relations_edit_panel = $UICanvas/relations_edit_panel
	relations_edit_sel_label = $UICanvas/relations_edit_panel/Scroll/VBox/relations_edit_sel_label
	relations_edit_vbox = $UICanvas/relations_edit_panel/Scroll/VBox/relations_edit_vbox
	var ar: HBoxContainer = $UICanvas/relations_edit_panel/Scroll/VBox/add_row
	ar.get_child(0).pressed.connect(func(): _add_relation_row("(选对方)", 0.0, ""))
	ar.get_child(1).pressed.connect(_apply_relations_edit)
	ar.get_child(2).pressed.connect(_panel_close.bind(relations_edit_panel))


func _on_open_relations_edit() -> void:
	if relations_edit_panel == null: return
	_panel_open(relations_edit_panel)
	_refresh_relations_edit()


func _refresh_relations_edit() -> void:
	_rel_rows.clear()
	for c in relations_edit_vbox.get_children():
		c.queue_free()
	var ctrl = _find_selected_npc()
	if ctrl == null:
		relations_edit_sel_label.text = "选中：无（请先选自己的角色）"
		return
	relations_edit_sel_label.text = "选中：" + ctrl.npc_name + "（只能改自己拥有的角色）"
	for other in ctrl.relations.keys():
		var info = ctrl.relations[other]
		if typeof(info) != TYPE_DICTIONARY: continue
		_add_relation_row(str(other), float(info.get("affinity", 0.0)), str(info.get("note", "")))


func _affinity_cn(v: float) -> String:
	if v >= 0.6: return "很要好"
	if v >= 0.3: return "友好"
	if v <= -0.4: return "反感"
	if v <= -0.15: return "不太亲近"
	return "一般"


# 加一条关系（四行布局）：
# ① 对方（下拉框，选当前小镇 NPC） ② 好感滑块+档位 ③ 备注 ④ 对方名字（只读） ⑤ 添加/删除按钮行
func _add_relation_row(other_name: String, affinity: float, note: String) -> void:
	if other_name.is_empty(): return
	var wrap = VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)

	# 行1：对方下拉框（当前小镇 NPC，排除自己）
	var name_row1 = HBoxContainer.new()
	name_row1.add_theme_constant_override("separation", 8)
	var l1 := Label.new(); l1.text = "对方"; l1.custom_minimum_size = Vector2(50, 0)
	name_row1.add_child(l1)
	var name_edit = OptionButton.new()
	name_edit.custom_minimum_size = Vector2(160, 0)
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sel := -1
	var npcs = get_node_or_null("NPCs")
	if npcs:
		for n in npcs.get_children():
			var nm: String = str(n.get("npc_name"))
			if nm.is_empty(): continue
			name_edit.add_item(nm)
			if nm == other_name: sel = name_edit.item_count - 1
	# 已存对方不在当前镇：末尾补一项保证不丢数据
	if sel == -1:
		name_edit.add_item(other_name)
		sel = name_edit.item_count - 1
	name_edit.select(sel)
	name_row1.add_child(name_edit)
	wrap.add_child(name_row1)

	# 行2：好感滑块 + 档位文本
	var bar_row = HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 8)
	var l2 := Label.new(); l2.text = "好感"; l2.custom_minimum_size = Vector2(50, 0)
	bar_row.add_child(l2)
	var slider = HSlider.new()
	slider.min_value = -1; slider.max_value = 1; slider.step = 0.05; slider.value = affinity
	slider.custom_minimum_size = Vector2(160, 28)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar_row.add_child(slider)
	var val_lbl = Label.new(); val_lbl.custom_minimum_size = Vector2(96, 0)
	val_lbl.text = "%+.2f %s" % [affinity, _affinity_cn(affinity)]
	slider.value_changed.connect(func(v: float): val_lbl.text = "%+.2f %s" % [v, _affinity_cn(v)])
	bar_row.add_child(val_lbl)
	wrap.add_child(bar_row)

	# 行3：备注（多行文本）
	var note_row = HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 8)
	var l3 := Label.new(); l3.text = "备注"; l3.custom_minimum_size = Vector2(50, 0)
	note_row.add_child(l3)
	var note_edit = TextEdit.new(); note_edit.text = note; note_edit.placeholder_text = "这段关系怎么来的"
	note_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY   # 长行自动换行（默认 none 一行到底）
	note_edit.custom_minimum_size = Vector2(0, 100)
	note_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_row.add_child(note_edit)
	wrap.add_child(note_row)

	# 行4：对方名字（只读展示，保存即以此为准）
	var name_row4 = HBoxContainer.new()
	name_row4.add_theme_constant_override("separation", 8)
	var l4 := Label.new(); l4.text = "对方名"; l4.custom_minimum_size = Vector2(50, 0)
	name_row4.add_child(l4)
	var ro_name = Label.new(); ro_name.text = other_name
	ro_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row4.add_child(ro_name)
	wrap.add_child(name_row4)

	var entry = {"name_edit": name_edit, "slider": slider, "note_edit": note_edit}
	var del = Button.new(); del.text = "删除这条关系"
	del.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del.pressed.connect(func():
		wrap.queue_free()
		_rel_rows.erase(entry))
	# 距上一行 5px：单独 margin 容器
	var btn_margin = MarginContainer.new()
	btn_margin.add_theme_constant_override("margin_top", 5)
	btn_margin.add_child(del)
	wrap.add_child(btn_margin)
	name_edit.item_selected.connect(func(idx: int):
		ro_name.text = name_edit.get_item_text(idx))
	relations_edit_vbox.add_child(wrap)
	_rel_rows.append(entry)


func _apply_relations_edit() -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null:
		_set_status("没有选中角色")
		return
	var out: Dictionary = {}
	for e in _rel_rows:
		var nm: String = str(e["name_edit"].get_item_text(e["name_edit"].selected)).strip_edges()
		if nm.is_empty(): continue
		out[nm] = {"affinity": clampf(float(e["slider"].value), -1.0, 1.0), "note": str(e["note_edit"].text)}
	ctrl.relations = out   # 立即更新本地缓存（下次决策注入即生效）
	ctrl.patch_relations(out.duplicate(true))
	_set_status("已保存 %s 的关系（%d 条）" % [ctrl.npc_name, out.size()])


# 导演时钟显示：游戏分钟 → "HH:MM (白天/黑夜)"

# 记忆植入面板
func _build_implant_memory_panel(canvas: CanvasLayer) -> void:
	implant_memory_panel = $UICanvas/implant_memory_panel
	implant_memory_sel_label = $UICanvas/implant_memory_panel/VBox/implant_memory_sel_label
	implant_memory_list = $UICanvas/implant_memory_panel/VBox/Scroll/implant_memory_list
	implant_memory_input = $UICanvas/implant_memory_panel/VBox/implant_memory_input
	implant_memory_save_btn = $UICanvas/implant_memory_panel/VBox/btn_row/save_btn
	implant_memory_save_btn.pressed.connect(_apply_implant_memory)
	$UICanvas/implant_memory_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(implant_memory_panel))


func _on_open_implant_memory() -> void:
	if implant_memory_panel == null: return
	_editing_memory_idx = -1
	_reset_implant_input()
	_panel_open(implant_memory_panel)
	_refresh_implant_memory()


func _reset_implant_input() -> void:
	implant_memory_input.text = ""
	_editing_memory_idx = -1
	implant_memory_save_btn.text = "植入"


func _refresh_implant_memory() -> void:
	for c in implant_memory_list.get_children():
		c.queue_free()
	var ctrl = _find_selected_npc()
	if ctrl == null:
		implant_memory_sel_label.text = "选中：无（请先选自己的角色）"
		return
	implant_memory_sel_label.text = "选中：" + ctrl.npc_name + "（%d 条）" % ctrl.core_memories.size()
	if ctrl.core_memories.is_empty():
		var empty = Label.new()
		empty.text = "暂无核心记忆"
		empty.modulate = Color(0.7, 0.7, 0.7)
		implant_memory_list.add_child(empty)
		return
	for i in range(ctrl.core_memories.size()):
		implant_memory_list.add_child(_make_memory_row(i, str(ctrl.core_memories[i])))


# 单条记忆行：文本（可换行）+ 改 / 删 按钮
func _make_memory_row(idx: int, text: String) -> Control:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl = Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 28)
	row.add_child(lbl)
	var edit_btn = Button.new(); edit_btn.text = "改"
	edit_btn.pressed.connect(func(): _edit_implant_memory(idx))
	row.add_child(edit_btn)
	var del_btn = Button.new(); del_btn.text = "删"
	del_btn.pressed.connect(func(): _delete_implant_memory(idx))
	row.add_child(del_btn)
	return row


func _edit_implant_memory(idx: int) -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null or idx < 0 or idx >= ctrl.core_memories.size():
		return
	_editing_memory_idx = idx
	implant_memory_input.text = str(ctrl.core_memories[idx])
	implant_memory_save_btn.text = "保存修改"
	implant_memory_input.grab_focus()


func _delete_implant_memory(idx: int) -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null or idx < 0 or idx >= ctrl.core_memories.size():
		return
	ctrl.core_memories.remove_at(idx)
	ctrl.put_core_memories(ctrl.core_memories)
	if _editing_memory_idx == idx:
		_reset_implant_input()
	elif _editing_memory_idx > idx:
		_editing_memory_idx -= 1
	_refresh_implant_memory()
	_set_status("已删除记忆")


func _apply_implant_memory() -> void:
	var ctrl = _find_selected_npc()
	if ctrl == null:
		_set_status("没有选中角色")
		return
	var text := implant_memory_input.text.strip_edges()
	if text.is_empty():
		_set_status("请输入要植入的记忆")
		return
	if _editing_memory_idx >= 0:
		# 修改：本地替换 + 整体 PUT
		ctrl.core_memories[_editing_memory_idx] = text
		ctrl.put_core_memories(ctrl.core_memories)
		_reset_implant_input()
		_refresh_implant_memory()
		_set_status("已修改 %s 的记忆，下个决策生效" % ctrl.npc_name)
	else:
		# 新增：走后端 append（服务端去重 + FIFO）；等响应回来 core_memories 已更新，再刷新列表
		await ctrl.post_core_memories([text])
		implant_memory_input.text = ""
		_refresh_implant_memory()
		_set_status("已为 %s 植入记忆，下个决策生效" % ctrl.npc_name)

func _refresh_clock_label() -> void:
	var m := GameSession.game_clock_min
	var txt := "时刻 --:--"
	if m >= 0:
		var hh := int(m / 60) % 24
		var mm := m % 60
		var period := "黑夜" if (hh < 6 or hh >= 18) else "白天"
		txt = "时刻 %02d:%02d %s" % [hh, mm, period]
	var clk = status_hud_bars.get("clock")
	if clk is Label: clk.text = txt
	if clock_label: clock_label.text = txt


# ============================ 导演控制台（房主叙事）============================

# 打开面板：回填当前值（GameSession 是房主权威最新态）+ 刷新事件流
func _on_open_director_panel() -> void:
	if not GameSession.is_host:
		_set_status("仅房主可导演")
		return
	if director_panel == null:
		return
	_panel_open(director_panel)
	weather_opt.select(_weather_idx(GameSession.weather))
	time_scale_slider.value = GameSession.time_scale
	world_bg_edit.text = GameSession.world_background
	company_edit.text = GameSession.company_info
	social_rules_edit.text = GameSession.social_rules
	_refresh_event_flow()


func _weather_idx(w: String) -> int:
	# 按 metadata（英文 key）匹配，显示文本是中文
	for i in range(weather_opt.item_count):
		if String(weather_opt.get_item_metadata(i)) == w:
			return i
	return 0


func _build_director_panel(canvas: CanvasLayer) -> void:
	director_panel = $UICanvas/director_panel
	var vbox: VBoxContainer = $UICanvas/director_panel/Scroll/VBox
	event_flow_box = vbox.get_node("event_flow_box")
	weather_opt = vbox.get_node("weather_opt")
	# 显示中文、metadata 存英文 key（towns.weather 存英文，NPC/时钟解析靠 key）
	var weather_cn := {"clear": "晴", "rain": "雨", "storm": "暴风雨", "fog": "雾", "snow": "雪", "hot": "酷热"}
	for w in ["clear", "rain", "storm", "fog", "snow", "hot"]:
		weather_opt.add_item(weather_cn[w])
		weather_opt.set_item_metadata(weather_opt.item_count - 1, w)
	weather_opt.item_selected.connect(func(_i): _on_change_weather())
	time_scale_slider = vbox.get_node("time_scale_slider")
	time_scale_slider.value_changed.connect(func(_v): _on_change_time_scale())
	world_bg_edit = vbox.get_node("world_bg_edit")
	company_edit = vbox.get_node("company_edit")
	social_rules_edit = vbox.get_node("social_rules_edit")
	news_title_edit = vbox.get_node("news_title_edit")
	news_content_edit = vbox.get_node("news_content_edit")
	rule_title_edit = vbox.get_node("rule_title_edit")
	rule_content_edit = vbox.get_node("rule_content_edit")
	vbox.get_node("world_btn_row/save_world_btn").pressed.connect(_on_save_world)
	vbox.get_node("news_btn_row/pub_news_btn").pressed.connect(_on_publish_news)
	vbox.get_node("rule_btn_row/pub_rule_btn").pressed.connect(_on_publish_rule)
	vbox.get_node("close_btn_row/close_btn").pressed.connect(_panel_close.bind(director_panel))


# 提交：天气 → PATCH /towns + 本地 + 广播（broadcast 不回声，房主先本地写）
func _on_change_weather() -> void:
	if GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var w := String(weather_opt.get_item_metadata(weather_opt.selected))   # 英文 key（存库/广播），非显示文本
	_patch_town(JSON.stringify({"weather": w}), "天气：" + w)
	GameSession.weather = w
	_broadcast({"t": "town_weather", "weather": w})


func _on_change_time_scale() -> void:
	if GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var ts := float(time_scale_slider.value)
	_patch_town(JSON.stringify({"time_scale": ts}), "时间流速：%d" % int(ts))
	GameSession.time_scale = ts


func _on_save_world() -> void:
	if GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var cfg := {
		"world_background": world_bg_edit.text, "company_info": company_edit.text,
		"social_rules": social_rules_edit.text,
	}
	_patch_town(JSON.stringify({"config_json": cfg}), "世界观已保存")
	GameSession.world_background = cfg["world_background"]
	GameSession.company_info = cfg["company_info"]
	GameSession.social_rules = cfg["social_rules"]
	_broadcast({"t": "town_world", "world_background": cfg["world_background"],
		"company_info": cfg["company_info"], "social_rules": cfg["social_rules"]})


# 通用 PATCH /towns/{id}（inline HTTPRequest + 闭包）
func _patch_town(body: String, status_msg: String) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	var err = http.request(
		GameSession.api_base + "/towns/%d" % GameSession.town_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH, body)
	if err != OK:
		http.queue_free()
		_set_status("导演请求失败 %d" % err)
		return
	http.request_completed.connect(func(_r, code, _h, _b):
		_set_status(status_msg if code == 200 else "导演操作失败 (HTTP %d)" % code)
		http.queue_free())


func _on_publish_news() -> void:
	_publish_event("news", news_title_edit, news_content_edit)


func _on_publish_rule() -> void:
	_publish_event("rule", rule_title_edit, rule_content_edit)


# 发布事件 → POST /narrative/events（后端 send_all 广播 town_event，房主收回声刷新）
func _publish_event(kind: String, title_edit: LineEdit, content_edit: TextEdit) -> void:
	if GameSession.jwt.is_empty() or GameSession.town_id == 0: return
	var content := content_edit.text.strip_edges()
	if content.is_empty():
		_set_status("内容不能为空")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 201:
			title_edit.text = ""; content_edit.text = ""
			_set_status("%s已发布" % ("新闻" if kind == "news" else "规则"))
		else:
			_set_status("发布失败 (HTTP %d)" % code)
		http.queue_free())
	http.request(
		GameSession.api_base + "/narrative/events?town_id=%d" % GameSession.town_id,
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST,
		JSON.stringify({"kind": kind, "title": title_edit.text.strip_edges(), "content": content}))


# 刷新事件流（GET active 事件 → 填 GameSession.active_events + 事件流 UI）
func _refresh_event_flow() -> void:
	if event_flow_box == null or GameSession.town_id == 0 or GameSession.jwt.is_empty(): return
	for c in event_flow_box.get_children():
		c.queue_free()
	var http := HTTPRequest.new()
	add_child(http)
	http.request(
		GameSession.api_base + "/narrative/events?town_id=%d&active_only=true" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt], HTTPClient.METHOD_GET)
	http.request_completed.connect(func(_r, code, _h, body):
		http.queue_free()
		print("[director] 事件流 HTTP %d" % code)
		if code != 200: return
		var arr = JSON.parse_string(body.get_string_from_utf8())
		if typeof(arr) != TYPE_ARRAY:
			print("[director] 事件流返回非数组")
			return
		print("[director] 事件流拉到 %d 条" % arr.size())
		GameSession.active_events.clear()
		for ev in arr:
			if typeof(ev) == TYPE_DICTIONARY:
				var eid := int(ev.get("id", 0))
				var kind := GameSession.str_or(ev.get("kind"))
				var text := _event_text(GameSession.str_or(ev.get("title")), GameSession.str_or(ev.get("content")))
				GameSession.active_events[eid] = {"kind": kind, "text": text}
				_add_event_flow_row(eid, kind, text))


func _add_event_flow_row(eid: int, kind: String, text: String) -> void:
	var row := HBoxContainer.new()
	var lbl := Label.new(); lbl.text = "[%s] %s" % [kind, text]
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(360, 0)
	row.add_child(lbl)
	var btn := Button.new(); btn.text = "停用"
	btn.pressed.connect(func(): _deactivate_event(eid))
	row.add_child(btn)
	event_flow_box.add_child(row)


func _deactivate_event(eid: int) -> void:
	if GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	http.request(
		GameSession.api_base + "/narrative/events/%d/deactivate" % eid,
		["Authorization: Bearer " + GameSession.jwt], HTTPClient.METHOD_PATCH, "")
	http.request_completed.connect(func(_r, _code, _h, _b): http.queue_free())


# 事件文本：title+content 拼接（title 是简短标签时也保留 content 细节，规则怪谈不丢细节）
func _event_text(title: String, content: String) -> String:
	if not title.is_empty() and not content.is_empty():
		return title + "：" + content
	return title if not title.is_empty() else content


# ============================ 房主虚拟时钟 ============================

# 房主进镇启动时钟（_on_ws_connected host 分支调用）
func _start_game_clock() -> void:
	if game_clock_timer != null: return
	if GameSession.game_clock_min < 0:
		GameSession.game_clock_min = 480   # 默认 08:00（sysconfig game_clock_start_minute=480）
	game_clock_timer = Timer.new()
	game_clock_timer.wait_time = 5.0
	game_clock_timer.timeout.connect(_on_clock_tick)
	add_child(game_clock_timer)
	game_clock_timer.start()
	_refresh_clock_label()


# 5s 推进 + 广播（房主权威，所有端经 town_time 同步，避免 NPC 各推各的打架）
func _on_clock_tick() -> void:
	GameSession.game_clock_min = int(GameSession.game_clock_min + GameSession.time_scale * 5.0) % 1440
	_refresh_clock_label()
	_broadcast({"t": "town_time", "minutes": GameSession.game_clock_min, "time_scale": GameSession.time_scale})


# 进镇拉取小镇天气/世界观 + 事件流（注入 NPC prompt；房主/非房主都拉）
func _load_town_narrative() -> void:
	if GameSession.town_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request(
		GameSession.api_base + "/towns/%d" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt], HTTPClient.METHOD_GET)
	if err == OK:
		var resp: Array = await http.request_completed
		var body = resp[3]
		var j = JSON.parse_string(body.get_string_from_utf8())
		if typeof(j) == TYPE_DICTIONARY:
			GameSession.weather = GameSession.str_or(j.get("weather"), "clear")
			GameSession.time_scale = float(j.get("time_scale", 1.0))
			var cfg = j.get("config_json")
			if typeof(cfg) == TYPE_DICTIONARY:
				GameSession.world_background = GameSession.str_or(cfg.get("world_background"))
				GameSession.company_info = GameSession.str_or(cfg.get("company_info"))
				GameSession.social_rules = GameSession.str_or(cfg.get("social_rules"))
	http.queue_free()
	_refresh_event_flow()
	_refresh_clock_label()


func _find_controlled_npc():
	var npcs = get_node_or_null("NPCs")
	if not npcs: return null
	for n in npcs.get_children():
		if n is CharacterBody2D and n.get("controlled_by_player"):
			return n
	return null


# 当前"选中"的 NPC（面板数据源）。上帝模式下=只看不控；退上帝=控制它。
func _find_selected_npc():
	if selected_npc_name.is_empty():
		return null
	return get_node_or_null("NPCs/" + selected_npc_name)


# ============================ 任务面板 ============================

func _build_task_panel(canvas: CanvasLayer) -> void:
	# 壳已在 .tscn（Phase B③）：按钮行/发布表单/滚动列表；这里只接信号 + 填优先级选项
	task_panel = $UICanvas/task_panel
	task_publish_form = $UICanvas/task_panel/VBox/task_publish_form
	task_title_edit = $UICanvas/task_panel/VBox/task_publish_form/task_title_edit
	task_reward_edit = $UICanvas/task_panel/VBox/task_publish_form/task_reward_edit
	task_pri_opt = $UICanvas/task_panel/VBox/task_publish_form/task_pri_opt
	task_list = $UICanvas/task_panel/VBox/Scroll/task_list
	for i in range(1, 6):
		task_pri_opt.add_item("P%d" % i)
	task_pri_opt.select(2)  # default P3
	$UICanvas/task_panel/VBox/btn_row/pub_btn.pressed.connect(_show_task_publish_form)
	$UICanvas/task_panel/VBox/btn_row/refresh_btn.pressed.connect(_refresh_task_list)
	$UICanvas/task_panel/VBox/btn_row/close_btn.pressed.connect(_close_task_panel)
	$UICanvas/task_panel/VBox/task_publish_form/submit_row/submit_btn.pressed.connect(_do_publish_task)


func _on_open_task_panel() -> void:
	if task_panel == null:
		_build_task_panel(_ui_canvas)
	_panel_open(task_panel)
	_refresh_task_list()
	if not is_instance_valid(task_timer):
		task_timer = Timer.new()
		task_timer.wait_time = 5.0
		task_timer.one_shot = false
		task_timer.timeout.connect(_refresh_task_list)
		add_child(task_timer)
	task_timer.start()


# 任务变更 WS 广播：own NPC 重拉队列（新任务即时进 brain 队列，不等跨天刷新）+ 面板开着就刷
func _handle_task_update(_msg: Dictionary) -> void:
	var npcs = get_node_or_null("NPCs")
	if npcs:
		for n in npcs.get_children():
			if not (n is CharacterBody2D): continue
			if n.get("owner_id") != GameSession.pid: continue
			if n.has_method("fetch_tasks"):
				n.fetch_tasks()
	if task_panel and task_panel.visible:
		_refresh_task_list()


func _close_task_panel() -> void:
	_panel_close(task_panel)
	if is_instance_valid(task_timer):
		task_timer.stop()


func _refresh_task_list() -> void:
	if task_list == null: return
	for c in task_list.get_children(): c.queue_free()
	if GameSession.town_id == 0 or GameSession.jwt.is_empty(): return
	var http := HTTPRequest.new()
	add_child(http)
	http.request(
		GameSession.api_base + "/tasks?town_id=%d" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code != 200: return
		var tasks = JSON.parse_string(_b.get_string_from_utf8())
		if typeof(tasks) != TYPE_ARRAY: return
		if tasks.is_empty():
			var empty := Label.new(); empty.text = "暂无任务"
			empty.modulate = Color(0.6, 0.6, 0.6)
			task_list.add_child(empty)
		for t in tasks:
			var st: String = str(t.get("status", ""))
			var icon := "○" if st == "pending" else ("◉" if st == "in_progress" else "✓")
			var block := VBoxContainer.new()
			block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			block.add_theme_constant_override("separation", 2)
			# 标题行
			var title_lbl := Label.new()
			title_lbl.text = "%s [P%d] %s" % [icon, int(t.get("priority", 3)), GameSession.str_or(t.get("title", "?"))]
			title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			block.add_child(title_lbl)
			# 元信息行：负责人 / 发布者 / 赏金 / 状态
			var meta := ""
			var assignee := GameSession.str_or(t.get("assignee_name"))
			var creator := GameSession.str_or(t.get("creator_name"))
			if not assignee.is_empty(): meta += "负责人: %s" % assignee
			if not creator.is_empty(): meta += "  发布: %s" % creator
			var reward := int(t.get("reward_money", 0))
			if reward > 0: meta += "  赏金: %d金币" % reward
			if st == "done": meta += "  (已完成)"
			if not meta.is_empty():
				var meta_lbl := Label.new()
				meta_lbl.text = meta
				meta_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				meta_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				meta_lbl.modulate = Color(0.7, 0.7, 0.7)
				block.add_child(meta_lbl)
			# 描述行（若有）
			var desc := GameSession.str_or(t.get("description"))
			if not desc.is_empty():
				var desc_lbl := Label.new()
				desc_lbl.text = "    " + desc
				desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				block.add_child(desc_lbl)
			block.add_child(HSeparator.new())
			task_list.add_child(block)
		get_tree().create_timer(1.0).timeout.connect(func():
			if is_instance_valid(http): http.queue_free()))


func _show_task_publish_form() -> void:
	if task_publish_form == null: return
	task_publish_form.visible = not task_publish_form.visible


func _do_publish_task() -> void:
	if GameSession.jwt.is_empty(): return
	var title := task_title_edit.text.strip_edges()
	if title.is_empty(): return
	var reward := int(task_reward_edit.text) if task_reward_edit.text.is_valid_int() else 0
	var priority := task_pri_opt.selected + 1
	var sel = _find_selected_npc()
	if sel == null:
		_set_status("请先选中一个角色再发布任务")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, code, _h, _b):
		if code == 201:
			task_title_edit.text = ""
			task_reward_edit.text = "0"
			task_publish_form.visible = false
			_refresh_task_list()
		http.queue_free())
	var body := JSON.stringify({
		"title": title, "priority": priority, "reward_money": max(0, reward)
	})
	http.request(
		GameSession.api_base + "/tasks?town_id=%d&creator_id=%d" % [GameSession.town_id, sel.character_id],
		["Authorization: Bearer " + GameSession.jwt, "Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)


# ---- 交易面板 ----

func _on_open_trade_panel() -> void:
	if trade_panel == null: return
	_panel_close(trade_panel) if trade_panel.visible else _panel_open(trade_panel)
	if trade_panel.visible:
		_refresh_trade_items()


func _build_trade_panel(canvas: CanvasLayer) -> void:
	trade_panel = $UICanvas/trade_panel
	trade_items_label = $UICanvas/trade_panel/VBox/trade_items_label
	trade_gold_label = $UICanvas/trade_panel/VBox/trade_gold_label
	trade_target_opt = $UICanvas/trade_panel/VBox/trade_target_opt
	trade_offer_item = $UICanvas/trade_panel/VBox/offer_row/trade_offer_item
	trade_offer_money = $UICanvas/trade_panel/VBox/offer_row/trade_offer_money
	trade_req_item = $UICanvas/trade_panel/VBox/req_row/trade_req_item
	trade_req_money = $UICanvas/trade_panel/VBox/req_row/trade_req_money
	trade_target_opt.item_selected.connect(func(_i): _on_trade_target_changed())
	$UICanvas/trade_panel/VBox/btn_row/submit_btn.pressed.connect(_do_trade)
	$UICanvas/trade_panel/VBox/btn_row/close_btn.pressed.connect(_panel_close.bind(trade_panel))


func _refresh_trade_items() -> void:
	# 刷新自己的物品列表和目标列表
	var my_npc = _find_selected_npc()
	if my_npc == null: return
	trade_items_label.text = "你的物品：" + (_items_to_str(my_npc.items_json) if not my_npc.items_json.is_empty() else "无")
	trade_gold_label.text = "金币：%d" % my_npc.money
	# 填充 Nearby NPC 列表
	trade_target_opt.clear()
	for child in get_children():
		if not child.has_method("show_bubble") or child == my_npc: continue
		trade_target_opt.add_item(child.npc_name + (" ⭐" if child.is_player else ""))
		trade_target_opt.set_metadata(trade_target_opt.item_count - 1, child)


func _on_trade_target_changed() -> void:
	var i := trade_target_opt.selected
	if i < 0: return
	var tgt = trade_target_opt.get_item_metadata(i)
	if tgt == null: return
	# 显示目标物品和金币
	trade_items_label.text += "\n对方物品：" + (_items_to_str(tgt.items_json) if not tgt.items_json.is_empty() else "无")
	trade_gold_label.text += " | 对方金币：%d" % tgt.money


func _items_to_str(items: Array) -> String:
	if items.is_empty(): return "无"
	var parts: Array = []
	for it in items:
		if it is Dictionary:
			parts.append("%s×%d" % [GameSession.str_or(it.get("name")), it.get("qty", 1)])
	return ", ".join(parts)


func _do_trade() -> void:
	var my_npc = _find_selected_npc()
	if my_npc == null or my_npc.character_id == 0: return
	var i := trade_target_opt.selected
	if i < 0: return
	var tgt = trade_target_opt.get_item_metadata(i)
	if tgt == null or tgt.character_id == 0: return
	_panel_close(trade_panel)
	var offer_items: Array = []
	var oi_name := trade_offer_item.text.strip_edges()
	if not oi_name.is_empty():
		offer_items = [{"name": oi_name, "qty": 1}]
	var req_items: Array = []
	var ri_name := trade_req_item.text.strip_edges()
	if not ri_name.is_empty():
		req_items = [{"name": ri_name, "qty": 1}]
	var offer_money := int(trade_offer_money.text) if trade_offer_money.text.is_valid_int() else 0
	var req_money := int(trade_req_money.text) if trade_req_money.text.is_valid_int() else 0
	my_npc.post_trade(tgt.character_id, offer_items, offer_money, req_items, req_money)
