extends SceneTree
## 开发辅助脚本（不属于游戏流程）：启动 Main.tscn，自动发射并操控挡板，
## 依次截取“蓄力瞄准 / 游戏进行中 / 已暂停 / 游戏结束 / 关卡通过 / 第 2 关耐久砖 / 通关”画面
## 保存到 screenshots/，便于人工确认视觉效果。
## 必须带窗口运行（不要加 --headless），否则不渲染、截不到图：
##   godot --path . --script res://tests/capture_screenshot.gd

const OUT_DIR := "res://screenshots"
const PANEL_VBOX := "GameOverPanel/Panel/Margin/VBox"
## “蓄力瞄准”截图的蓄力门槛：攒到 0.3 再截，预测线偏角够明显。
## 攒到 1.0 会触发自动发射，所以再用帧数上限兜底，防止低帧率下等不到门槛就先满了。
const CHARGE_SHOT_AT := 0.3
const CHARGE_SHOT_MAX_FRAMES := 20


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

	# 蓄力瞄准：按住 ← 让预测线斜着画出来，同时挡板蓄力条可见
	_hold(&"move_left")
	_hold(&"launch")
	var charged := 0
	while float(scene.get("_charge")) < CHARGE_SHOT_AT and charged < CHARGE_SHOT_MAX_FRAMES:
		await physics_frame
		charged += 1
	await _shot("charging.png")
	print("[capture] 蓄力 progress=", scene.get("_charge"), " 预测线点数=",
		scene.get_node("AimLine").call("get_point_count"))
	_release(&"launch")
	_release(&"move_left")
	for i in 150:
		paddle.position.x = clampf(ball.position.x, paddle.get("left_bound"), paddle.get("right_bound"))
		await physics_frame

	# 击破一块砖，趁碎屑还在空中截一张，确认粒子生效
	# 震动在 0.2 秒内就衰减完，这里不读 offset，避免把「恰好衰减完」当成失败
	var bricks: Node2D = scene.get_node("Bricks")
	if bricks.get_child_count() > 0:
		ball.brick_hit.emit(bricks.get_child(0))
	var shake: Node = root.get_node("/root/Shake")
	# 震动必须在击碎后立刻采样：trauma 每秒衰减 1.9，约 0.2 秒就归零了
	print("[capture] 击碎瞬间 创伤值=", shake.call("get_trauma"),
		" 相机偏移=", str(scene.get_node("Camera2D").offset))
	await _wait(8)
	await _shot("breakout.png")

	# 暂停画面
	_send(&"pause")
	await _wait(2)
	await _shot("paused.png")
	_send(&"pause")
	await _wait(1)

	# 连续掉球直到游戏结束
	var guard := 0
	while int(scene.get("_lives")) > 0 and guard < 10:
		guard += 1
		ball.set("attached_to_paddle", false)
		ball.position = Vector2(paddle.position.x, float(ball.get("death_y")) + 50.0)
		await _wait(2)
	await _wait(1)
	await _shot("game_over.png")

	# 重开一局，清空砖墙 -> 关卡通过面板
	_send(&"launch")
	await _wait(20)
	var level_clear: Node = current_scene
	if level_clear == null or level_clear == scene:
		print("[capture] 重开失败，跳过后续截图")
		quit(0)
		return

	var clear_bricks: Node2D = level_clear.get_node("Bricks")
	var clear_ball: CharacterBody2D = level_clear.get_node("Ball")
	# queue_free 帧末才生效，先取快照再逐个移除；
	# 关卡判定依赖 Main 的击破计数，这里同步把计数推到“只剩两块”的位置。
	var snapshot: Array = clear_bricks.get_children()
	level_clear.set("_bricks_cleared", snapshot.size() - 2)
	for i in snapshot.size() - 2:
		snapshot[i].queue_free()
	await _wait(3)
	for node in clear_bricks.get_children():
		node.set("hits_left", 1)
	clear_ball.brick_hit.emit(clear_bricks.get_child(0))
	clear_ball.brick_hit.emit(clear_bricks.get_child(1))
	await _wait(3)
	await _shot("level_clear.png")
	print("[capture] 关卡通过标题=", level_clear.get_node(PANEL_VBOX + "/TitleLabel").text)

	# 进入下一关：截一张带裂纹的多耐久砖块
	_send(&"restart")
	await _wait(6)
	var level2: Node = current_scene
	var level2_ball: CharacterBody2D = level2.get_node("Ball")
	var level2_bricks: Node2D = level2.get_node("Bricks")
	if level2_bricks.get_child_count() > 0:
		level2_ball.brick_hit.emit(level2_bricks.get_child(0))
		level2_ball.brick_hit.emit(level2_bricks.get_child(1))
		level2_ball.brick_hit.emit(level2_bricks.get_child(1))
	await _wait(6)
	await _shot("level2.png")
	print("[capture] 第 2 关=", level2.get_node("HUD/LevelLabel").text,
		" 砖块耐久=", level2_bricks.get_child(0).get("max_hits"),
		" 剩余耐久=", level2_bricks.get_child(0).get("hits_left"))

	# 推到最后一关并清空 -> 通关画面
	level2.set("_level", int(level2.get_script().get_script_constant_map().get("MAX_LEVEL", 1)))
	var last_bricks: Node2D = level2.get_node("Bricks")
	var last_snapshot: Array = last_bricks.get_children()
	level2.set("_bricks_cleared", int(level2.get_script().get_script_constant_map().get("BRICK_TOTAL", 48)) - 2)
	for i in last_snapshot.size() - 2:
		last_snapshot[i].queue_free()
	await _wait(3)
	for node in last_bricks.get_children():
		node.set("hits_left", 1)
	level2_ball.brick_hit.emit(last_bricks.get_child(0))
	level2_ball.brick_hit.emit(last_bricks.get_child(1))
	await _wait(3)
	await _shot("victory.png")

	print("[capture] done. score=", level2.get("_score"), " best=", level2.get("_best"),
		" state=", level2.get("_state"), " 标题=", level2.get_node(PANEL_VBOX + "/TitleLabel").text)
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await physics_frame


## 只送「按下」事件（游戏内的继续 / 重开按钮只看按下沿）。
func _send(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)


## 按住：两条路径都得走，缺一不可（详见 headless_smoke_test.gd 里同名辅助函数处的注释）。
## - Input.action_press 更新动作状态，Input.get_axis 才读得到
## - Input.parse_input_event 把事件派发进 _unhandled_input
## 少了后者蓄力不会开始，少了前者发射方向永远算成“垂直向上”。
func _hold(action: StringName) -> void:
	Input.action_press(action, 1.0)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	event.strength = 1.0
	Input.parse_input_event(event)


func _release(action: StringName) -> void:
	Input.action_release(action)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = false
	event.strength = 0.0
	Input.parse_input_event(event)


func _shot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var err := image.save_png(OUT_DIR + "/" + file_name)
	print("[capture] ", file_name, " err=", err, " size=", image.get_size())
