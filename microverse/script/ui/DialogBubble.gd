extends Node2D

var target_node: Node2D = null
var text_box: VBoxContainer
var text_label: Label
var background: NinePatchRect
var tween: Tween
var is_target_on_right: bool = false

func _ready():
	# 高于 NPC z_index=int(pos.y)（≤1080），气泡始终在最上不被名字/意图盖住
	z_index = 1000
	background = NinePatchRect.new()
	background.texture = preload("res://asset/ui/dialog_bubble_bg.png")
	background.patch_margin_left = 8
	background.patch_margin_top = 8
	background.patch_margin_right = 8
	background.patch_margin_bottom = 8
	add_child(background)
	# 固定宽容器包文本：VBox 约束 text_label 宽度，autowrap 才可靠换行 + 高度由文本撑开
	# （Label 不在容器时 custom_minimum_size 只是下限，size 不会缩，autowrap 不生效→一行宽矮）
	text_box = VBoxContainer.new()
	background.add_child(text_box)
	text_label = Label.new()
	text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_label.add_theme_font_size_override("font_size", GameSession.int_or(GameSession.ui_config.get("bubble_font_size", null), GameSession.FALLBACK_BUBBLE_FONT_SIZE))
	text_label.add_theme_color_override("font_color", Color(0, 0, 0, 1)) # 气泡浅底 → 黑字
	text_label.add_theme_stylebox_override("normal", StyleBoxEmpty.new()) # 去掉继承自主题的 Label 蓝底
	text_box.add_child(text_label)
	hide()

# 显示对话内容
# 思想气泡用：贴底染淡紫（self_modulate 只染纹理，不染黑字——Label 主题 override 不受影响）
func tint(c: Color) -> void:
	background.self_modulate = c


func show_dialog(text: String, duration: float = -1.0, target_on_right: bool = false):
	text_label.text = text
	is_target_on_right = target_on_right
	# duration<=0 → 走配置 bubble_duration_sec（联机由 NetworkNPC.show_bubble 不传 duration 触发）
	if duration < 0.0:
		duration = GameSession.float_or(GameSession.ui_config.get("bubble_duration_sec", null), GameSession.FALLBACK_BUBBLE_DURATION_SEC)

	# 宽高：短句文本撑开、长句≤240 换行。同步用 TextServer 量（get_multiline_string_size
	# 直接按 240 宽算换行结果，不依赖容器两帧布局——同帧多气泡也不互相踩）
	var font := text_label.get_theme_default_font()
	var fs := text_label.get_theme_default_font_size()
	var natural := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var sz: Vector2 = natural
	if natural.x > 240.0:
		sz = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, 240.0, fs)
	text_box.custom_minimum_size = sz
	text_box.size = sz
	background.size = sz + Vector2(20, 20)
	text_box.position = Vector2(10, 10)

	# 显示气泡
	show()

	# 创建消失动画
	if tween:
		tween.kill()
	tween = create_tween()
	tween.tween_interval(duration)
	tween.tween_callback(hide)
	# ponytail: 原 show_dialog 只 hide 不 free，每句话留一个 orphan 节点（内存泄漏）。
	# 联机高频说话下尤其严重，hide 后释放。原单机调用方不持有引用，安全。
	tween.tween_callback(queue_free)

# 更新位置
func _process(_delta):
	if target_node and visible:
		# 水平居中：气泡中心对齐角色中心
		var horizontal_offset = -background.size.x / 2
		# 气泡高度 + 额外间距(20像素)确保不遮挡角色
		var vertical_offset = -(background.size.y + 20)
		global_position = target_node.global_position + Vector2(horizontal_offset, vertical_offset)
