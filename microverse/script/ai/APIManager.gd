extends Node

# 单例实例
static var instance = null

# API URLs现在通过APIConfig统一管理

# 当前设置（从SettingsManager获取）
var current_settings = {}

# 获取单例实例
static func get_instance() -> APIManager:
	if instance == null:
		instance = Engine.get_singleton("APIManager")
		if instance == null:
			instance = APIManager.new()
	return instance

func _enter_tree():
	# 设置单例实例
	if instance == null:
		instance = self

	add_to_group("api_manager")

func _ready():
	SettingsManager.settings_changed.connect(_on_settings_changed)
	current_settings = SettingsManager.get_settings()

func _on_settings_changed(new_settings: Dictionary):
	current_settings = new_settings.duplicate()

func generate_dialog(prompt: String, character_name: String = "") -> HTTPRequest:
	if not is_inside_tree():
		push_error("APIManager is not properly initialized!")
		return null

	# 等待三帧以确保完全初始化
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var http_request = HTTPRequest.new()
	http_request.name = "HTTPRequest_" + str(Time.get_unix_time_from_system()) + "_" + str(randi())
	add_child(http_request)

	http_request.request_completed.connect(func(result, response_code, headers, body):
		get_tree().create_timer(1.0).timeout.connect(func():
			if http_request and is_instance_valid(http_request):
				remove_child(http_request)
				http_request.queue_free()
		)
	)

	var ai_settings = current_settings
	if character_name != "":
		ai_settings = SettingsManager.get_character_ai_settings(character_name)

	var headers = APIConfig.build_headers(ai_settings.api_type, ai_settings.api_key)
	var data = JSON.stringify(APIConfig.build_request_data(ai_settings.api_type, ai_settings.model, prompt))
	var url = APIConfig.get_url(ai_settings.api_type, ai_settings.model, GameSession.str_or(ai_settings.get("custom_api_url")))

	http_request.request(url, headers, HTTPClient.METHOD_POST, data)
	return http_request

func generate_decision(prompt: String, character_name: String = "") -> HTTPRequest:
	return await generate_dialog(prompt, character_name)
