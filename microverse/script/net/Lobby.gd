extends Control
# 联机大厅：两页结构 —— 登录页(LoginPanel) + 大厅页(LobbyPanel)。
# 登录页：账号/密码 + 记住密码 + 自动登录 + 登录按钮。
# 大厅页：左上 角色管理/AI设置；左 3/4 小镇列表 + 右 1/4 预览；底部进入小镇。
# UI 结构在 Lobby.tscn（@onready 引用 + _ready 接信号）；本脚本管数据流 + 动态填充。

const ConfirmBox := preload("res://script/ui/ConfirmBox.gd")
const Tutorial := preload("res://script/ui/Tutorial.gd")

# ============================ HTTP ============================
var auth_http: HTTPRequest
var chars_http: HTTPRequest
var town_http: HTTPRequest
var mutate_http: HTTPRequest
var byok_http: HTTPRequest
var _preset_http: HTTPRequest
var config_http: HTTPRequest
var ui_prefs_http: HTTPRequest

# ============================ 登录页 ============================
@onready var login_panel: Control = $LoginPanel
@onready var username_edit: LineEdit = $LoginPanel/Center/VBox/username_edit
@onready var password_edit: LineEdit = $LoginPanel/Center/VBox/password_edit
@onready var remember_chk: CheckBox = $LoginPanel/Center/VBox/opt_row/remember_chk
@onready var auto_chk: CheckBox = $LoginPanel/Center/VBox/opt_row/auto_chk
@onready var login_btn: Button = $LoginPanel/Center/VBox/login_btn
@onready var auth_status: Label = $LoginPanel/Center/VBox/auth_status

# ============================ 大厅页 ============================
@onready var lobby_panel: Control = $LobbyPanel
@onready var welcome_lbl: Label = $LobbyPanel/Margin/VBox/top_bar/welcome_lbl
@onready var char_mgmt_btn: Button = $LobbyPanel/Margin/VBox/top_bar/char_mgmt_btn
@onready var ai_btn: Button = $LobbyPanel/Margin/VBox/top_bar/ai_btn
@onready var help_btn: Button = $LobbyPanel/Margin/VBox/top_bar/help_btn
@onready var logout_btn: Button = $LobbyPanel/Margin/VBox/top_bar/logout_btn
@onready var town_list: ItemList = $LobbyPanel/Margin/VBox/body/left/town_list
@onready var town_refresh_btn: Button = $LobbyPanel/Margin/VBox/body/left/town_btn_row/town_refresh_btn
@onready var create_town_btn: Button = $LobbyPanel/Margin/VBox/body/left/town_btn_row/create_town_btn
@onready var town_preview: RichTextLabel = $LobbyPanel/Margin/VBox/body/right/Margin/VBox/town_preview
@onready var town_status: Label = $LobbyPanel/Margin/VBox/bottom/town_status
@onready var enter_town_btn: Button = $LobbyPanel/Margin/VBox/bottom/enter_town_btn

# ============================ 角色管理面板 ============================
@onready var char_mgmt_panel: Panel = $char_mgmt_panel
@onready var npc_itemlist: ItemList = $LobbyPanel/Margin/VBox/body/right/Margin/VBox/npc_itemlist
@onready var mgmt_list: ItemList = $char_mgmt_panel/Margin/VBox/mgmt_list
@onready var refresh_btn: Button = $char_mgmt_panel/Margin/VBox/btn_row/refresh_btn
@onready var create_btn: Button = $char_mgmt_panel/Margin/VBox/btn_row/create_btn
@onready var edit_btn: Button = $char_mgmt_panel/Margin/VBox/btn_row/edit_btn
@onready var preset_btn: Button = $char_mgmt_panel/Margin/VBox/btn_row/preset_btn
@onready var delete_btn: Button = $char_mgmt_panel/Margin/VBox/btn_row/delete_btn

# ============================ 角色表单（新建/编辑）============================
@onready var char_panel: Panel = $char_panel
@onready var panel_title: Label = $char_panel/Scroll/VBox/panel_title
@onready var name_edit: LineEdit = $char_panel/Scroll/VBox/name_edit
@onready var position_edit: LineEdit = $char_panel/Scroll/VBox/position_edit
@onready var personality_edit: TextEdit = $char_panel/Scroll/VBox/personality_edit
@onready var speaking_style_edit: TextEdit = $char_panel/Scroll/VBox/speaking_style_edit
@onready var work_duties_edit: TextEdit = $char_panel/Scroll/VBox/work_duties_edit
@onready var work_habits_edit: TextEdit = $char_panel/Scroll/VBox/work_habits_edit
@onready var notes_edit: TextEdit = $char_panel/Scroll/VBox/notes_edit
@onready var gender_opt: OptionButton = $char_panel/Scroll/VBox/gender_opt
@onready var panel_save_btn: Button = $char_panel/Scroll/VBox/btn_row/panel_save_btn
@onready var ai_optimize_btn: Button = $char_panel/Scroll/VBox/btn_row/ai_optimize_btn
var panel_mode: String = ""   # "create" | "edit"
var editing_id: int = 0

# ============================ 创建小镇面板 ============================
@onready var town_panel: Panel = $town_panel
@onready var town_name_edit: LineEdit = $town_panel/Scroll/VBox/town_name_edit
@onready var town_desc_edit: TextEdit = $town_panel/Scroll/VBox/town_desc_edit
@onready var town_preset_option: OptionButton = $town_panel/Scroll/VBox/town_preset_option
@onready var chat_rounds_edit: LineEdit = $town_panel/Scroll/VBox/param_row/chat_rounds_edit
@onready var max_npcs_edit: LineEdit = $town_panel/Scroll/VBox/param_row/max_npcs_edit
@onready var world_bg_edit: TextEdit = $town_panel/Scroll/VBox/world_bg_edit
@onready var company_edit: TextEdit = $town_panel/Scroll/VBox/company_edit
@onready var social_edit: TextEdit = $town_panel/Scroll/VBox/social_edit
@onready var items_edit: TextEdit = $town_panel/Scroll/VBox/items_edit
@onready var town_save_btn: Button = $town_panel/Scroll/VBox/btn_row/town_save_btn
var _preset_ids: Array = []   # 与 town_preset_option 选项并行的预设 id（0=无预设）

# ============================ AI 设置面板 ============================
@onready var ai_panel: Panel = $ai_panel
@onready var ai_type_opt: OptionButton = $ai_panel/Margin/VBox/ai_type_opt
@onready var ai_model_edit: LineEdit = $ai_panel/Margin/VBox/ai_model_edit
@onready var ai_key_edit: LineEdit = $ai_panel/Margin/VBox/ai_key_edit
@onready var ai_url_label: Label = $ai_panel/Margin/VBox/UrlLabel
@onready var ai_url_edit: LineEdit = $ai_panel/Margin/VBox/ai_url_edit
@onready var ai_save_btn: Button = $ai_panel/Margin/VBox/btn_row/ai_save_btn

var characters: Array = []  # 后端 /characters 返回的原始数组
var towns: Array = []       # GET /towns 返回的原始数组
var selected_town_idx: int = -1

# 预设 NPC：丰富人设（编码进 personality_json，LLM prompt 直接受益）
const PRESET_NPCS: Array = [
	{
		name = "小林",
		background = '{"notes":"22岁，公司最年轻的成员，大家都把她当妹妹看","position":"前端开发实习生","personality":"元气满满但毛手毛脚，刚从大学毕业，崇拜 Alice 的设计能力但总被怼，每天用 Excel 记「Alice金句」学习职场怼人术","speaking_style":"语速超快，爱用网络热梗和表情包，开口就是「救命」「绝绝子」，被批评时会小声嘟囔「好的好的我这就改」","work_duties":"切图、修 CSS bug、给 Alice 买咖啡","work_habits":"工位贴满动漫便利贴，耳机里放着 vlog 当背景音，每天午休拉着 Joe 讲 bug 冷笑话"}'
	},
	{
		name = "王姐",
		background = '{"notes":"35岁，公司元老之一，办公室实际上的知心大姐","position":"设计组长 / 资深 UI 设计师","personality":"刀子嘴豆腐心，嘴上说「这届实习生带不动」但加班帮改稿，有选择困难症但绝不承认，对渐变参数有宗教信仰般的执着","speaking_style":"语气像班主任，爱用「我跟你说」「听我的没错」，吐槽需求时引经据典从包豪斯讲到 Material Design，经典语录：「甲方要五彩斑斓的黑？你让他先定义什么叫五彩斑斓」","work_duties":"主视觉定调、设计评审、带新人、跟产品经理 battle 需求","work_habits":"桌面永远摊着三杯不同温度的咖啡，对着屏幕皱眉时表示正在「找感觉」勿扰，收藏了 2000+ Dribbble 参考图但从来不看"}'
	},
	{
		name = "老张",
		background = '{"notes":"38岁，技术定海神针，老板也要让他三分","position":"技术架构师 / 全栈工程师","personality":"平时闷葫芦一坐一整天，但聊到技术就变身话痨，口头禅「这玩意我十年前就写过了」，对服务器 uptime 有强迫症，内心深处是个段子手但笑点清奇只有 Joe 能 get","speaking_style":"惜字如金，敲代码时别人说话只回「嗯」，Code Review 却突然活跃起来每条 comment 都带技术原理引用，偶尔冒出的冷笑话冷到让会议室降温","work_duties":"系统架构、代码审查、帮 Jack 排查诡异 bug、阻止产品经理的技术幻想","work_habits":"永远用 vim 快捷键（连浏览器都装 vim 插件），显示器竖屏写代码自称「效率提升 37%」，抽屉里藏了 5 年陈的速溶咖啡号称「越陈越香」"}'
	},
	{
		name = "建造者阿强",
		background = '{"notes":"小镇建造工，职责是用 place_tile 和 place_prefab 从零建小镇","position":"小镇建造工","personality":"勤劳能干的建筑工，看到空地就手痒想盖房子","speaking_style":"话不多，干活利索，爱说「这地儿我来盖」","work_duties":"铺地板建墙造路，把这片空草坪建成功能齐全的小镇","work_habits":"一有空就 map_edit 建造：先铺 floor 地板，再围 wall 墙，用 road 连路，摆 desk/chair/coffee_machine 家具"}'
	},
	{
		name = "建造者小美",
		background = '{"notes":"小镇规划师，职责是用 place_tile 和 place_prefab 把小镇建得漂亮实用","position":"小镇规划师","personality":"细心的规划师，讲究布局美观和绿化","speaking_style":"温柔耐心，爱说「这里放个盆栽更好看」","work_duties":"规划小镇布局，造路、绿化、摆放家具","work_habits":"先规划再建造：用 road 规划道路，用 tree 绿化，用 plant/coffee_machine 点缀，铺 floor 建房间"}'
	}
]


func _ready() -> void:
	AudioManager.stop_bgm()   # 回大厅停掉小镇 BGM
	auth_http = HTTPRequest.new()
	chars_http = HTTPRequest.new()
	town_http = HTTPRequest.new()
	mutate_http = HTTPRequest.new()
	byok_http = HTTPRequest.new()
	_preset_http = HTTPRequest.new()
	config_http = HTTPRequest.new()
	ui_prefs_http = HTTPRequest.new()
	for h in [auth_http, chars_http, town_http, mutate_http, byok_http, _preset_http, config_http, ui_prefs_http]:
		add_child(h)
	auth_http.request_completed.connect(_on_auth_response)
	chars_http.request_completed.connect(_on_chars_response)
	town_http.request_completed.connect(_on_town_response)
	mutate_http.request_completed.connect(_on_mutate_response)
	byok_http.request_completed.connect(_on_byok_response)
	_preset_http.request_completed.connect(_on_preset_response)
	config_http.request_completed.connect(_on_config_response)
	ui_prefs_http.request_completed.connect(_on_ui_prefs_response)

	# UI 信号接线（结构在 .tscn）
	login_btn.pressed.connect(_on_login)
	auto_chk.toggled.connect(_on_auto_toggled)
	logout_btn.pressed.connect(_on_logout)
	char_mgmt_btn.pressed.connect(_on_open_char_mgmt)
	ai_btn.pressed.connect(_on_open_ai)
	help_btn.pressed.connect(func(): Tutorial.show(self, "lobby"))
	refresh_btn.pressed.connect(_load_characters)
	create_btn.pressed.connect(_on_create_char)
	edit_btn.pressed.connect(_on_edit_char)
	preset_btn.pressed.connect(_on_create_presets)
	delete_btn.pressed.connect(_on_delete_char)
	get_node("char_mgmt_panel/Margin/VBox/btn_row/close_btn").pressed.connect(func(): char_mgmt_panel.visible = false)
	town_list.item_selected.connect(_on_town_selected)
	town_refresh_btn.pressed.connect(_load_towns)
	create_town_btn.pressed.connect(_on_create_town)
	enter_town_btn.pressed.connect(_on_enter_town)
	town_save_btn.pressed.connect(_on_town_save)
	panel_save_btn.pressed.connect(_on_panel_save)
	ai_optimize_btn.pressed.connect(_on_ai_optimize)
	ai_save_btn.pressed.connect(_on_save_ai)
	get_node("char_panel/Scroll/VBox/btn_row/cancel_btn").pressed.connect(func(): char_panel.visible = false)
	get_node("town_panel/Scroll/VBox/btn_row/cancel_btn").pressed.connect(func(): town_panel.visible = false)
	get_node("ai_panel/Margin/VBox/btn_row/cancel_btn").pressed.connect(func(): ai_panel.visible = false)

	town_preset_option.add_item("无（默认办公室）")
	_preset_ids.append(0)
	for t in SettingsManager.api_types:
		ai_type_opt.add_item(t)
	ai_type_opt.item_selected.connect(_on_ai_type_selected)
	gender_opt.add_item("未设定")
	gender_opt.add_item("男")
	gender_opt.add_item("女")

	if GameSession.kicked_reason != "":
		_show_kicked_dialog(GameSession.kicked_reason)
		GameSession.kicked_reason = ""
	if GameSession.lobby_message != "":
		_show_kicked_dialog(GameSession.lobby_message)
		GameSession.lobby_message = ""

	# 从镇返回大厅（jwt 还在、已登录）→ 直接进大厅页，不重走登录
	if not GameSession.jwt.is_empty():
		_show_lobby(GameSession.my_username if not GameSession.my_username.is_empty() else "玩家")
		_load_characters()
		_load_towns()
		_load_byok()
		_load_config()
		_load_ui_prefs()
		return
	# 记住密码 / 自动登录（本地明文存 SettingsManager；单机 BYOK 场景可接受）
	_load_remembered()


func _show_kicked_dialog(reason: String) -> void:
	var d := AcceptDialog.new()
	d.title = "提示"
	d.dialog_text = reason
	d.confirmed.connect(func(): d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	d.popup_centered(Vector2i(400, 160))


# ============================ 登录 + 记住密码 + 自动登录 ============================

# ponytail: 密码明文存本地配置文件。单机/个人 BYOK 场景用户主动要求；多用户/共享设备不安全。
func _load_remembered() -> void:
	var s = SettingsManager.get_settings()
	remember_chk.button_pressed = bool(s.get("remember_login", false))
	auto_chk.button_pressed = bool(s.get("auto_login", false))
	if remember_chk.button_pressed:
		username_edit.text = String(s.get("saved_username", ""))
		password_edit.text = String(s.get("saved_password", ""))
	if auto_chk.button_pressed and not username_edit.text.is_empty() and not password_edit.text.is_empty():
		_on_login()


func _on_auto_toggled(on: bool) -> void:
	# 自动登录前提 = 记住密码
	if on:
		remember_chk.button_pressed = true


func _save_remembered() -> void:
	var s = SettingsManager.get_settings()
	s["remember_login"] = remember_chk.button_pressed
	s["auto_login"] = auto_chk.button_pressed
	if remember_chk.button_pressed:
		s["saved_username"] = username_edit.text.strip_edges()
		s["saved_password"] = password_edit.text
	else:
		s.erase("saved_username")
		s.erase("saved_password")
	SettingsManager.update_settings(s)


func _on_login() -> void:
	var u = username_edit.text.strip_edges()
	var p = password_edit.text
	if u.is_empty() or p.is_empty():
		auth_status.text = "用户名/密码不能为空"
		return
	var body = JSON.stringify({"username": u, "password": p})
	var err = auth_http.request(
		GameSession.api_base + "/auth/login",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)
	auth_status.text = "登录中..." if err == OK else "请求失败 %d" % err


func _on_auth_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		match code:
			400, 401, 403:
				auth_status.text = "账号或密码有误"
			500, 502, 503, 504:
				auth_status.text = "服务器繁忙，请稍后重试"
			0:
				auth_status.text = "网络连接失败，请检查网络"
			_:
				auth_status.text = "登录失败，请稍后重试"
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY or not json.has("access_token"):
		auth_status.text = "登录返回异常"
		return
	GameSession.jwt = json["access_token"]
	GameSession.my_user_id = json.get("user", {}).get("id", 0)
	GameSession.my_username = String(json.get("user", {}).get("username", ""))
	_save_remembered()
	_show_lobby(json.get("user", {}).get("username", "?"))
	_load_characters()
	_load_towns()
	_load_byok()   # 换设备恢复：从后台拉 BYOK 回填本地
	_load_config() # 拉 gameplay 调参（chat_max_rounds 等）
	_load_ui_prefs() # 拉玩家 UI 覆盖（字号优先于 sysconfig 默认）


func _show_lobby(username: String) -> void:
	login_panel.visible = false
	lobby_panel.visible = true
	welcome_lbl.text = "欢迎，%s" % username
	if not SettingsManager.get_settings().get("tutorial_lobby_done", false):
		Tutorial.show(self, "lobby")


func _on_logout() -> void:
	GameSession.jwt = ""
	GameSession.my_user_id = 0
	characters.clear()
	towns.clear()
	npc_itemlist.clear()
	town_list.clear()
	town_preview.text = "选择左侧小镇查看详情"
	enter_town_btn.disabled = true
	lobby_panel.visible = false
	login_panel.visible = true
	auth_status.text = "已退出登录"


# ============================ 角色管理 ============================

# 模态面板尺寸跟随内容 min_size（字号放大不溢出背景），居中定位
func _fit_modal(panel: Control, content: Control, base: Vector2) -> void:
	var need := content.get_combined_minimum_size() + Vector2(32, 24)
	var sz := Vector2(maxf(base.x, need.x), maxf(base.y, need.y))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -sz.x / 2.0
	panel.offset_right = sz.x / 2.0
	panel.offset_top = -sz.y / 2.0
	panel.offset_bottom = sz.y / 2.0


func _on_open_char_mgmt() -> void:
	if GameSession.jwt.is_empty():
		return
	_fit_modal(char_mgmt_panel, $char_mgmt_panel/Margin/VBox, Vector2(560, 480))
	char_mgmt_panel.visible = true
	_load_characters()


func _load_characters() -> void:
	var err = chars_http.request(
		GameSession.api_base + "/characters",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		print("[lobby] 拉取角色失败 ", err)


func _on_chars_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		print("[lobby] 拉取角色失败 (HTTP %d)" % code)
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_ARRAY:
		print("[lobby] 角色返回异常")
		return
	characters = json
	# 保留带入多选（大厅右侧），只重建列表项；管理列表同步刷新
	var prev_carry := npc_itemlist.get_selected_items()
	npc_itemlist.clear()
	mgmt_list.clear()
	if characters.is_empty():
		npc_itemlist.add_item("（无角色，在「角色管理」新建）")
		mgmt_list.add_item("（无角色）")
		edit_btn.disabled = true
		return
	for i in range(characters.size()):
		var lbl := "%s (id=%d)" % [characters[i].get("name", "?"), characters[i].get("id", 0)]
		npc_itemlist.add_item(lbl)
		mgmt_list.add_item(lbl)
	# 恢复带入多选
	for idx in prev_carry:
		if idx >= 0 and idx < npc_itemlist.item_count:
			npc_itemlist.select(idx, false)
	edit_btn.disabled = false


func _first_selected_npc_idx() -> int:
	var sel := mgmt_list.get_selected_items()
	return int(sel[0]) if not sel.is_empty() else -1


func _on_create_char() -> void:
	if GameSession.jwt.is_empty():
		return
	panel_mode = "create"
	editing_id = 0
	panel_title.text = "新建角色"
	name_edit.text = ""
	position_edit.text = ""
	personality_edit.text = ""
	speaking_style_edit.text = ""
	work_duties_edit.text = ""
	work_habits_edit.text = ""
	notes_edit.text = ""
	gender_opt.select(0)
	char_panel.visible = true
	name_edit.grab_focus()


func _on_edit_char() -> void:
	if characters.is_empty():
		return
	var idx := _first_selected_npc_idx()
	if idx < 0:
		panel_title.text = "先在列表选中一个角色再编辑"
		return
	var c = characters[idx]
	panel_mode = "edit"
	editing_id = int(c.get("id", 0))
	panel_title.text = "编辑角色 #%d" % editing_id
	name_edit.text = GameSession.str_or(c.get("name"))
	var persona = c.get("personality_json")
	if typeof(persona) == TYPE_DICTIONARY and not persona.is_empty():
		_populate_fields_dict(persona)
	else:
		_populate_fields(GameSession.str_or(c.get("background")))
	char_panel.visible = true


func _populate_fields(bg: String) -> void:
	position_edit.text = ""
	personality_edit.text = ""
	speaking_style_edit.text = ""
	work_duties_edit.text = ""
	work_habits_edit.text = ""
	notes_edit.text = ""
	gender_opt.select(0)
	if bg.is_empty():
		return
	if bg.begins_with("{") and bg.ends_with("}"):
		var parsed = JSON.parse_string(bg)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("position"):
			position_edit.text = GameSession.str_or(parsed.get("position"))
			personality_edit.text = GameSession.str_or(parsed.get("personality"))
			speaking_style_edit.text = GameSession.str_or(parsed.get("speaking_style"))
			work_duties_edit.text = GameSession.str_or(parsed.get("work_duties"))
			work_habits_edit.text = GameSession.str_or(parsed.get("work_habits"))
			notes_edit.text = GameSession.str_or(parsed.get("notes"))
			gender_opt.select(_gender_index(GameSession.str_or(parsed.get("gender"))))
			return
	notes_edit.text = bg
	name_edit.grab_focus()


func _populate_fields_dict(d: Dictionary) -> void:
	position_edit.text = GameSession.str_or(d.get("position"))
	personality_edit.text = GameSession.str_or(d.get("personality"))
	speaking_style_edit.text = GameSession.str_or(d.get("speaking_style"))
	work_duties_edit.text = GameSession.str_or(d.get("work_duties"))
	work_habits_edit.text = GameSession.str_or(d.get("work_habits"))
	notes_edit.text = GameSession.str_or(d.get("notes"))
	gender_opt.select(_gender_index(GameSession.str_or(d.get("gender"))))


# 性别文本 → OptionButton 索引（0 未设定 / 1 男 / 2 女；识别英文别名）
func _gender_index(g: String) -> int:
	var t := g.to_lower()
	if t in ["男", "male", "m"]:
		return 1
	if t in ["女", "female", "f"]:
		return 2
	return 0


func _on_panel_save() -> void:
	var nm = name_edit.text.strip_edges()
	if nm.is_empty():
		panel_title.text = "角色 — 名字必填"
		return
	var persona = _pack_persona()
	var body := JSON.stringify({"name": nm, "personality_json": persona})
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt]
	var err := OK
	if panel_mode == "create":
		err = mutate_http.request(GameSession.api_base + "/characters", headers, HTTPClient.METHOD_POST, body)
	else:
		err = mutate_http.request(GameSession.api_base + "/characters/%d" % editing_id, headers, HTTPClient.METHOD_PATCH, body)
	panel_save_btn.text = "保存中..." if err == OK else "请求失败 %d" % err


# AI 优化：把已填的 6 字段发给玩家 BYOK 的 LLM 润色丰富，结果回填表单（不自动保存，玩家看完再点保存）
func _on_ai_optimize() -> void:
	var persona := _pack_persona()
	# 至少填一个字段才有意义
	if persona.position.is_empty() and persona.personality.is_empty() and persona.speaking_style.is_empty() \
			and persona.work_duties.is_empty() and persona.work_habits.is_empty() and persona.notes.is_empty():
		panel_title.text = "先填写一些内容再优化"
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
	for k in persona:
		prompt = prompt.replace("<<" + k + ">>", str(persona[k]))
	ai_optimize_btn.text = "优化中..."
	ai_optimize_btn.disabled = true
	var req = await APIManager.generate_dialog(prompt, "")
	if req == null:
		ai_optimize_btn.text = "AI 优化"
		ai_optimize_btn.disabled = false
		panel_title.text = "AI 未配置（先到「AI 设置」填 API）"
		return
	var result = await req.request_completed
	ai_optimize_btn.text = "AI 优化"
	ai_optimize_btn.disabled = false
	if typeof(result) != TYPE_ARRAY or result.size() < 4 or int(result[1]) != 200:
		panel_title.text = "AI 优化失败"
		return
	var api_type := GameSession.str_or(SettingsManager.get_settings().get("api_type"), "Ollama")
	var text := APIConfig.parse_response(api_type, JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8()))
	# 剥围栏 + 提 JSON 对象
	var body_str := text.strip_edges()
	var lb := body_str.find("{")
	var rb := body_str.rfind("}")
	if lb == -1 or rb == -1 or rb <= lb:
		panel_title.text = "AI 返回异常"
		return
	var parsed = JSON.parse_string(body_str.substr(lb, rb - lb + 1))
	if typeof(parsed) != TYPE_DICTIONARY:
		panel_title.text = "AI 返回异常"
		return
	_set_opt_field(position_edit, parsed, "position")
	_set_opt_field(personality_edit, parsed, "personality")
	_set_opt_field(speaking_style_edit, parsed, "speaking_style")
	_set_opt_field(work_duties_edit, parsed, "work_duties")
	_set_opt_field(work_habits_edit, parsed, "work_habits")
	_set_opt_field(notes_edit, parsed, "notes")
	panel_title.text = "已优化，检查后点「保存」"


# 回填单个优化字段（AI 留空则跳过，不覆盖玩家原输入）。position_edit 是 LineEdit、其余 TextEdit，统一走 Control.set("text")
func _set_opt_field(edit: Control, parsed: Dictionary, key: String) -> void:
	var v := str(parsed.get(key, ""))
	if not v.is_empty():
		edit.set("text", v.strip_edges())


func _pack_persona() -> Dictionary:
	var g := gender_opt.get_item_text(gender_opt.selected)
	return {
		position = position_edit.text.strip_edges(),
		personality = personality_edit.text.strip_edges(),
		speaking_style = speaking_style_edit.text.strip_edges(),
		work_duties = work_duties_edit.text.strip_edges(),
		work_habits = work_habits_edit.text.strip_edges(),
		notes = notes_edit.text.strip_edges(),
		gender = "" if g == "未设定" else g,
	}


func _on_mutate_response(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	panel_save_btn.text = "保存"
	if code in [200, 201]:
		char_panel.visible = false
		print("[lobby] 角色已保存（HTTP %d），刷新列表" % code)
		_load_characters()
	else:
		panel_title.text = "保存失败 (HTTP %d)" % code


# 删除选中角色（DELETE /characters/{id}）；独立一次性 HTTPRequest，不与 mutate_http 抢回调
func _on_delete_char() -> void:
	if GameSession.jwt.is_empty() or characters.is_empty():
		return
	var idx := _first_selected_npc_idx()
	if idx < 0:
		edit_btn.text = "先选中角色"
		return
	var c = characters[idx]
	ConfirmBox.show_confirm(self, "删除角色",
		"确定删除角色「%s」吗？相关数据一并删除，不可恢复。" % String(c.get("name", "?")),
		"删除", "取消", _do_delete_char.bind(c))


func _do_delete_char(c: Dictionary) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r: int, code: int, _h: PackedStringArray, _b: PackedByteArray):
		http.queue_free()
		if code == 204:
			print("[lobby] 已删除角色 %s (id=%d)" % [c.get("name", "?"), c.get("id", 0)])
			_load_characters()
		else:
			edit_btn.text = "删除失败 (HTTP %d)" % code
	, CONNECT_ONE_SHOT)
	http.request(
		GameSession.api_base + "/characters/%d" % int(c.get("id", 0)),
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_DELETE)


# ============================ 预设 NPC 一键生成 ============================

func _on_create_presets() -> void:
	if GameSession.jwt.is_empty():
		return
	_preset_queue.clear()
	for p in PRESET_NPCS:
		var dup := false
		for c in characters:
			if c.get("name") == p.name:
				dup = true
				break
		if not dup:
			_preset_queue.append(p)
	if _preset_queue.is_empty():
		print("[lobby] 预设 NPC 都已存在，跳过")
		return
	preset_btn.disabled = true
	preset_btn.text = "创建中 1/%d..." % _preset_queue.size()
	_create_next_preset()


var _preset_queue: Array = []

func _create_next_preset() -> void:
	if _preset_queue.is_empty():
		preset_btn.text = "生成预设 NPC"
		preset_btn.disabled = false
		_load_characters()
		return
	var p = _preset_queue.pop_front()
	var persona = JSON.parse_string(p.background) if typeof(p.background) == TYPE_STRING else {}
	var body := JSON.stringify({"name": p.name, "personality_json": persona})
	preset_btn.text = "创建中 %d/%d..." % [PRESET_NPCS.size() - _preset_queue.size(), PRESET_NPCS.size()]
	_preset_http.request(
		GameSession.api_base + "/characters",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)


func _on_preset_response(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if code not in [200, 201]:
		print("[lobby] 预设 NPC 创建失败 HTTP %d" % code)
	_create_next_preset()


# ============================ AI 设置（BYOK）============================

func _on_open_ai() -> void:
	if GameSession.jwt.is_empty():
		return
	var s = SettingsManager.get_settings()
	var cur_type = GameSession.str_or(s.get("api_type"), "Ollama")
	var found := false
	for i in ai_type_opt.item_count:
		if ai_type_opt.get_item_text(i) == cur_type:
			ai_type_opt.selected = i
			found = true
			break
	if not found:
		ai_type_opt.selected = 0
	ai_model_edit.text = GameSession.str_or(s.get("model"))
	ai_key_edit.text = GameSession.str_or(s.get("api_key"))
	ai_url_edit.text = GameSession.str_or(s.get("custom_api_url"))
	_update_ai_url_visibility()
	_fit_modal(ai_panel, $ai_panel/Margin/VBox, Vector2(620, 480))
	ai_panel.visible = true


func _on_ai_type_selected(_index: int) -> void:
	_update_ai_url_visibility()


func _update_ai_url_visibility() -> void:
	var compat := ai_type_opt.get_item_text(ai_type_opt.selected) == "OpenAICompatible"
	ai_url_label.visible = compat
	ai_url_edit.visible = compat


func _on_save_ai() -> void:
	var s = SettingsManager.get_settings()
	s["api_type"] = ai_type_opt.get_item_text(ai_type_opt.selected)
	s["model"] = ai_model_edit.text.strip_edges()
	s["api_key"] = ai_key_edit.text.strip_edges()
	s["custom_api_url"] = ai_url_edit.text.strip_edges()
	SettingsManager.update_settings(s)
	ai_panel.visible = false
	print("[lobby] AI 设置已保存本地：%s / %s" % [s["api_type"], s["model"]])
	if GameSession.jwt:
		var body := JSON.stringify({"api_type": s["api_type"], "model": s["model"], "api_key": s["api_key"]})
		byok_http.request(
			GameSession.api_base + "/auth/me/byok",
			["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
			HTTPClient.METHOD_PUT, body)


# ============================ 多小镇 ============================

func _load_towns() -> void:
	if GameSession.jwt.is_empty():
		return
	town_status.text = "加载小镇列表..."
	var err = town_http.request(
		GameSession.api_base + "/towns",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		town_status.text = "请求失败 %d" % err


func _on_town_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		town_status.text = "加载小镇失败 (HTTP %d)" % code
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_ARRAY:
		town_status.text = "小镇返回异常"
		return
	towns = json
	town_list.clear()
	selected_town_idx = -1
	enter_town_btn.disabled = true
	if towns.is_empty():
		town_list.add_item("（暂无小镇，点【创建小镇】新建）")
		town_status.text = "暂无小镇"
		return
	for i in range(towns.size()):
		var t = towns[i]
		town_list.add_item("%s (id=%d)" % [t.get("name", "?"), t.get("id", 0)])
	town_status.text = "共 %d 个小镇" % towns.size()


func _on_town_selected(idx: int) -> void:
	if idx < 0 or idx >= towns.size():
		selected_town_idx = -1
		enter_town_btn.disabled = true
		return
	selected_town_idx = idx
	enter_town_btn.disabled = false
	_render_town_preview(towns[idx])
	var t = towns[idx]
	var st = t.get("status", "?")
	var host_id = t.get("host_id", 0)
	var my_id = GameSession.my_user_id
	if st == "playing" and my_id != 0 and host_id != null and host_id != my_id:
		town_status.text = "%s — 游戏中 → 点「进入小镇」加入" % t.get("name", "?")
	else:
		town_status.text = "%s → 点「进入小镇」开房" % t.get("name", "?")


func _render_town_preview(t: Dictionary) -> void:
	var cfg = t.get("config_json", {})
	if typeof(cfg) != TYPE_DICTIONARY:
		cfg = {}
	var status_map := {"waiting": "等待中", "playing": "游戏中", "closed": "已关闭", "banned": "已封禁"}
	var st = String(status_map.get(String(t.get("status", "?")), String(t.get("status", "?"))))
	var rooms = t.get("rooms_json", [])
	var rooms_n = rooms.size() if typeof(rooms) == TYPE_ARRAY else 0
	var rounds = cfg.get("chat_rounds", "—")
	var maxn = cfg.get("max_npcs", "—")
	var desc = String(cfg.get("description", ""))
	var wb = String(cfg.get("world_background", ""))
	var bb := "[font_size=26][b]🏘 %s[/b][/font_size]\n\n" % String(t.get("name", "?"))
	bb += "[color=#9aa0b8]状态[/color]    %s\n" % st
	bb += "[color=#9aa0b8]创建者[/color]  #%d\n" % int(t.get("creator_id", 0))
	bb += "[color=#9aa0b8]天气[/color]    %s\n" % String(t.get("weather", "?"))
	bb += "[color=#9aa0b8]房间数[/color]  %d\n" % rooms_n
	if not desc.is_empty():
		bb += "\n[b]描述[/b]\n%s\n" % desc
	if not wb.is_empty():
		bb += "\n[b]世界观[/b]\n%s\n" % wb.left(120)
	bb += "\n──────────────\n互聊 [b]%s[/b] 轮 · 上限 [b]%s[/b] NPC" % [str(rounds), str(maxn)]
	town_preview.clear()
	town_preview.append_text(bb)


func _on_create_town() -> void:
	if GameSession.jwt.is_empty():
		return
	town_name_edit.text = ""
	town_desc_edit.text = ""
	world_bg_edit.text = ""
	company_edit.text = ""
	social_edit.text = ""
	items_edit.text = ""
	chat_rounds_edit.text = "8"
	max_npcs_edit.text = "20"
	town_panel.visible = true
	town_name_edit.grab_focus()
	_refresh_map_presets()


func _refresh_map_presets() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, code, _h, b):
		if code != 200:
			http.queue_free()
			return
		var data = JSON.parse_string(b.get_string_from_utf8())
		if typeof(data) != TYPE_ARRAY:
			http.queue_free()
			return
		town_preset_option.clear()
		_preset_ids.clear()
		town_preset_option.add_item("无（默认办公室）")
		_preset_ids.append(0)
		for p in data:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			town_preset_option.add_item(GameSession.str_or(p.get("name"), "?"))
			_preset_ids.append(int(p.get("id", 0)))
		http.queue_free())
	http.request(
		GameSession.api_base + "/maps/presets",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)


# 解析「NPC 初始物品」多行文本 → [{name, qty}, ...]（格式：物品名 或 物品名 x数量）
func _parse_items(text: String) -> Array:
	var items := []
	for raw in text.split("\n"):
		var line = raw.strip_edges()
		if line.is_empty():
			continue
		var name = line
		var qty = 1
		var at = line.rfind(" x")
		if at > 0:
			var tail = line.substr(at + 2).strip_edges()
			if tail.is_valid_int():
				qty = int(tail)
				name = line.substr(0, at).strip_edges()
		items.append({"name": name, "qty": qty})
	return items


func _on_town_save() -> void:
	var nm = town_name_edit.text.strip_edges()
	if nm.is_empty():
		return
	var cfg := {}
	var desc = town_desc_edit.text.strip_edges()
	if not desc.is_empty():
		cfg["description"] = desc
	cfg["chat_rounds"] = int(chat_rounds_edit.text) if chat_rounds_edit.text.is_valid_int() else 8
	cfg["max_npcs"] = int(max_npcs_edit.text) if max_npcs_edit.text.is_valid_int() else 20
	var wb = world_bg_edit.text.strip_edges()
	if not wb.is_empty():
		cfg["world_background"] = wb
	var cp = company_edit.text.strip_edges()
	if not cp.is_empty():
		cfg["company_info"] = cp
	var sr = social_edit.text.strip_edges()
	if not sr.is_empty():
		cfg["social_rules"] = sr
	var its = _parse_items(items_edit.text)
	if not its.is_empty():
		cfg["npc_initial_items"] = its

	var body_dict := {"name": nm, "config_json": cfg}
	if town_preset_option.selected < _preset_ids.size():
		var pid := int(_preset_ids[town_preset_option.selected])
		if pid > 0:
			body_dict["map_preset_id"] = pid
	var body := JSON.stringify(body_dict)
	town_save_btn.text = "创建中..."
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_r, code, _h, _b):
		town_save_btn.text = "创建"
		if code in [200, 201]:
			town_panel.visible = false
			town_status.text = "小镇已创建"
			_load_towns()
		else:
			town_status.text = "创建小镇失败 (HTTP %d)" % code
		http.queue_free())
	http.request(
		GameSession.api_base + "/towns",
		["Content-Type: application/json", "Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_POST, body)


func _on_enter_town() -> void:
	if selected_town_idx < 0 or selected_town_idx >= towns.size():
		return
	var t = towns[selected_town_idx]
	GameSession.town_id = t.get("id", 0) as int
	# 进镇参数从镇配置读（创建时写入 config_json），缺省回退默认
	var cfg = t.get("config_json", {})
	if typeof(cfg) != TYPE_DICTIONARY:
		cfg = {}
	GameSession.room_chat_max_rounds = int(cfg.get("chat_rounds", 8))
	GameSession.room_max_npcs = int(cfg.get("max_npcs", 20))
	var items = cfg.get("npc_initial_items", [])
	GameSession.npc_initial_items = items if typeof(items) == TYPE_ARRAY else []
	_collect_npcs()

	var my_id = GameSession.my_user_id
	var host_id = t.get("host_id", 0)
	if host_id == null:
		host_id = 0
	var creator_id = t.get("creator_id", 0)

	if t.get("status") == "playing" and my_id != 0 and host_id != my_id:
		# 别人开的小镇 → 加入
		GameSession.is_host = false
		print("[lobby] 加入小镇 #%d (host_id=%d)" % [GameSession.town_id, host_id])
	elif host_id == my_id or creator_id == my_id:
		# 自己是房主或创建者 → 开房
		GameSession.is_host = true
		print("[lobby] 启动小镇 #%d (creator=%d)" % [GameSession.town_id, creator_id])
		await _patch_town_playing()
	else:
		GameSession.is_host = false
		print("[lobby] 等待小镇 #%d 房主上线" % GameSession.town_id)
	_start_game()


func _patch_town_playing() -> void:
	"""通知后端小镇已启动（PATCH /towns/{id}?status=playing）。挂 root 保证场景切换不丢。"""
	if GameSession.town_id == 0 or GameSession.jwt.is_empty():
		return
	var http := HTTPRequest.new()
	get_tree().root.add_child(http)
	var err := http.request(
		GameSession.api_base + "/towns/%d?status=playing" % GameSession.town_id,
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_PATCH)
	if err != OK:
		print("[lobby] patch town playing 失败 %d" % err)
		http.queue_free()
		return
	var resp = await http.request_completed
	print("[lobby] town #%d → playing (HTTP %d)" % [GameSession.town_id, resp[1]])
	http.queue_free()


func _collect_npcs() -> void:
	# 把勾选的角色收进 GameSession.npc_list。host 与 join 客户端各自带入：进镇时各自 _spawn_my_npcs()。
	GameSession.npc_list = []
	for idx in npc_itemlist.get_selected_items():
		if idx >= 0 and idx < characters.size():
			GameSession.npc_list.append(characters[idx])
	print("[lobby] 勾选带入 NPC ", GameSession.npc_list.size(), " 个")


func _start_game() -> void:
	get_tree().change_scene_to_file("res://scene/maps/OnlineWorld.tscn")


# ============================ BYOK / 配置（换设备恢复 / 玩法调参）============================

func _load_byok() -> void:
	var err = byok_http.request(
		GameSession.api_base + "/auth/me/byok",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		print("[lobby] 拉 BYOK 失败 ", err)


func _on_byok_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# GET 回填本地（换设备恢复）；PUT 同步只打印结果（_on_byok_response 复用，二者皆静默）
	if code != 200:
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY:
		return
	if not json.get("api_type"):
		return
	var s := SettingsManager.get_settings()
	s["api_type"] = GameSession.str_or(json.get("api_type"), "Ollama")
	s["model"] = GameSession.str_or(json.get("model"))
	s["api_key"] = GameSession.str_or(json.get("api_key"))
	SettingsManager.update_settings(s)
	print("[lobby] 从后台回填 BYOK: %s / %s" % [s["api_type"], s["model"]])


func _load_ui_prefs() -> void:
	if GameSession.jwt.is_empty():
		return
	var err = ui_prefs_http.request(
		GameSession.api_base + "/auth/me/ui_prefs",
		["Authorization: Bearer " + GameSession.jwt],
		HTTPClient.METHOD_GET)
	if err != OK:
		print("[lobby] 拉 ui_prefs 失败 ", err)


func _on_ui_prefs_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return  # 静默：未设置过则沿用 sysconfig 默认值
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) == TYPE_DICTIONARY:
		GameSession.ui_prefs = json
		GameSession.rebuild_ui_config()


func _load_config() -> void:
	var err = config_http.request(GameSession.api_base + "/config/public")
	if err != OK:
		print("[lobby] 拉 /config/public 失败 ", err)


func _on_config_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return
	var json = JSON.parse_string(body.get_string_from_utf8())
	if typeof(json) != TYPE_DICTIONARY:
		return
	if json.has("chat_max_rounds") and int(json["chat_max_rounds"]) > 0:
		GameSession.chat_max_rounds = int(json["chat_max_rounds"])
	for key in json:
		if key.begins_with("prompt_"):
			GameSession.prompt_templates[key] = String(json[key])
	var ui_keys := ["ui_font_size", "bubble_duration_sec", "bubble_font_size", "show_npc_intent_label"]
	for key in ui_keys:
		if json.has(key):
			GameSession.ui_defaults[key] = json[key]
	GameSession.rebuild_ui_config()
	print("[lobby] 配置: chat_max_rounds=", GameSession.chat_max_rounds, " prompt 模板数=", GameSession.prompt_templates.size())
