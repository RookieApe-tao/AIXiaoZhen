extends CharacterBody2D
# 玩家：authority 端读 WASD 输入移动，MultiplayerSynchronizer 自动把 position 广播给其他端。

const SPEED := 300.0


func _ready() -> void:
	# 可视化：本地玩家绿色，远程镜像红色（Polygon2D 是 Node2D 原生，无需纹理）
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([Vector2(-20, -20), Vector2(20, -20), Vector2(20, 20), Vector2(-20, 20)])
	poly.color = Color.GREEN if is_multiplayer_authority() else Color.RED
	add_child(poly)
	# replication_config 已在 main.gd 的 _spawn_player 中（进树前）配好
	# 本地玩家挂相机
	if is_multiplayer_authority():
		add_child(Camera2D.new())


func _physics_process(_delta: float) -> void:
	# 仅权威端移动；其他端靠 Synchronizer 接收 position 被动更新
	if not is_multiplayer_authority():
		return
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		v.y -= 1
	if Input.is_key_pressed(KEY_S):
		v.y += 1
	if Input.is_key_pressed(KEY_A):
		v.x -= 1
	if Input.is_key_pressed(KEY_D):
		v.x += 1
	velocity = v.normalized() * SPEED
	move_and_slide()
