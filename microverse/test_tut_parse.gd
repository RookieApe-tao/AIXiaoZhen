extends SceneTree
func _init() -> void:
	var T := ResourceLoader.load("res://script/ui/Tutorial.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	print("[probe] compile: ", T != null and T.can_instantiate() if T is GDScript else T)
	quit()
