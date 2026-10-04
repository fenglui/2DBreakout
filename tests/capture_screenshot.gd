extends SceneTree
## 开发辅助脚本（不属于游戏流程）：启动 Main.tscn，自动发射并操控挡板，
## 依次截取“游戏进行中 / 已暂停 / 游戏结束 / 通关”四张画面保存到 screenshots/，便于人工确认视觉效果。
## 运行方式：
##   godot --path . --script res://tests/capture_screenshot.gd

const OUT_DIR := "res://screenshots"


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	var scene: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	var paddle: CharacterBody2D = scene.get_node("Paddle")
	var ball: CharacterBody2D = scene.get_node("Ball")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	_send(&"launch")
	for i in 150:
		paddle.position.x = clampf(ball.position.x, paddle.get("left_bound"), paddle.get("right_bound"))
		await physics_frame
	await _shot("breakout.png")

	# 暂停画面
	_send(&"pause")
	await physics_frame
	await physics_frame
	await _shot("paused.png")
	_send(&"pause")
	await physics_frame

	# 连续掉球直到游戏结束
	var guard := 0
	while int(scene.get("_lives")) > 0 and guard < 10:
		guard += 1
		ball.set("attached_to_paddle", false)
		ball.position = Vector2(paddle.position.x, float(ball.get("death_y")) + 50.0)
		await physics_frame
		await physics_frame
	await physics_frame
	await _shot("game_over.png")

	# 重开一局，击破最后一块砖 -> 通关画面
	_send(&"launch")
	await _wait(20)
	var won: Node = current_scene
	if won == null or won == scene:
		print("[capture] 重开失败，跳过通关截图")
		quit(0)
		return

	var bricks: Node2D = won.get_node("Bricks")
	var won_ball: CharacterBody2D = won.get_node("Ball")
	# queue_free 帧末才生效，先取快照再逐个移除；
	# 通关判定依赖 Main 的击破计数，这里同步把计数推到“只剩两块”的位置。
	var snapshot: Array = bricks.get_children()
	won.set("_bricks_cleared", snapshot.size() - 2)
	for i in snapshot.size() - 2:
		snapshot[i].queue_free()
	await _wait(3)
	won_ball.brick_hit.emit(bricks.get_child(0))
	won_ball.brick_hit.emit(bricks.get_child(1))
	await _wait(3)
	await _shot("victory.png")

	print("[capture] done. score=", won.get("_score"), " best=", won.get("_best"), " state=", won.get("_state"))
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _send(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var err := image.save_png(OUT_DIR + "/" + file_name)
	print("[capture] ", file_name, " err=", err, " size=", image.get_size())
