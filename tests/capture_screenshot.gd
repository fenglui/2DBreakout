extends SceneTree
## 开发辅助脚本（不属于游戏流程）：启动 Main.tscn，先截玩法菜单，再选定经典模式、
## 自动发射并操控挡板，依次截取"蓄力瞄准 / 游戏进行中 / 特殊砖与多球 / 已暂停 /
## 游戏结束 / 关卡通过 / 第 2 关耐久砖 / 通关"，最后另开一局无尽挑战截"三选一抽卡"，
## 全部保存到 screenshots/，便于人工确认视觉效果。
## 必须带窗口运行（不要加 --headless），否则不渲染、截不到图：
##   godot --path . --script res://tests/capture_screenshot.gd

const OUT_DIR := "res://screenshots"
const PANEL_VBOX := "GameOverPanel/Panel/Margin/VBox"
## "蓄力瞄准"截图的蓄力门槛：攒到 0.3 再截，预测线偏角够明显。
## 攒到 1.0 会触发自动发射，所以再用帧数上限兜底，防止低帧率下等不到门槛就先满了。
const CHARGE_SHOT_AT := 0.3
const CHARGE_SHOT_MAX_FRAMES := 20


func _initialize() -> void:
	_run()


## GameMode.Mode.CLASSIC 的值。从脚本常量反查而不是写 0：
## 玩法枚举一旦重排，写死的 0 就指到别的模式上，截出来的图也会跟着对不上。
func _classic_mode() -> int:
	var script := load("res://scripts/game_mode.gd") as GDScript
	if script == null:
		return 0
	return int((script.get_script_constant_map().get("Mode", {}) as Dictionary).get("CLASSIC", 0))


## GameMode.Mode.RUN 的值。
func _run_mode() -> int:
	var script := load("res://scripts/game_mode.gd") as GDScript
	if script == null:
		return 1
	return int((script.get_script_constant_map().get("Mode", {}) as Dictionary).get("RUN", 1))


## 以指定模式开一局（同步调用，等同于在菜单上点了对应按钮）。
## P3 之后 Main 启动即停在玩法菜单上，不选模式就一直是 MENU 态：
## 球不飞、挡板不响应，下面所有靠发射与撞砖推进的截图都会截到一块静止的画面。
func _begin(scene: Node, mode: int, run_seed: int = -1) -> void:
	scene.call("_begin_run", mode, run_seed)
	await _wait(3)


func _run() -> void:
	await process_frame

	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var scene: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	# 玩法菜单：复玩性三件套的门面，也是唯一一张"还没开局"的截图
	await _shot("menu.png")
	print("[capture] 菜单 ", scene.get_node("MenuPanel/Panel/Margin/VBox/DailyInfoLabel").text)
	await _begin(scene, _classic_mode())

	var paddle: CharacterBody2D = scene.get_node("Paddle")
	var balls: BallManager = scene.get_node("Balls")
	var ball: Ball = balls.primary()

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

	# 特殊砖与多球：这张图是六种特殊砖与「球 ×N」的唯一视觉存档。
	# 手动测试要能一眼核对形状标记（护角 / 十字 / 菱形 / 炸弹 / 双点 / 双层倒 V）
	# 与 HUD 上的球数，所以这里刻意让 5 颗球同时在场、球速冻结。
	await _capture_specials(scene, paddle, balls, ball)

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
	# 整场景重载出来的新实例同样停在玩法菜单上，得再选一次经典模式
	await _begin(level_clear, _classic_mode())

	var clear_bricks: Node2D = level_clear.get_node("Bricks")
	var clear_ball: Ball = (level_clear.get_node("Balls") as BallManager).primary()
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
	var level2_ball: Ball = (level2.get_node("Balls") as BallManager).primary()
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
	await _capture_card_draft()
	quit(0)


## 「三选一抽卡」截图。
##
## 另开一局无尽挑战而不是接着经典局截：卡牌只存在于无尽模式，
## 而经典局此刻正停在通关面板上，两条流程的界面会互相盖住。
## 固定种子是为了让每次重截得到同一手牌 —— 换卡之后没法拿新旧两图做对比。
func _capture_card_draft() -> void:
	var run_seed := 20261005
	var run_scene: Node = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	root.add_child(run_scene)
	await _wait(3)
	await _begin(run_scene, _run_mode(), run_seed)

	var bricks: Node2D = run_scene.get_node("Bricks")
	var run_ball: Ball = (run_scene.get_node("Balls") as BallManager).primary()
	var snapshot: Array = bricks.get_children()
	# 关卡判定看 Main 的击破计数，先把计数推到"只剩两块"，再释放其余
	run_scene.set("_bricks_cleared", snapshot.size() - 1)
	for i in snapshot.size() - 1:
		snapshot[i].queue_free()
	await _wait(3)
	var last: Node = bricks.get_child(0)
	last.set("hits_left", 1)
	run_ball.brick_hit.emit(last)
	await _wait(3)

	_send(&"restart")
	await _wait(5)
	var draft := run_scene.get_node("CardDraftPanel") as CardDraftPanel
	await _shot("card_draft.png")
	print("[capture] 抽卡 ", draft.offered.size(), " 张：",
		_hand_summary(draft), " 副标题=", draft.get_node("Panel/Margin/VBox/SubLabel").text)
	run_scene.queue_free()
	await _wait(2)


## 手牌摘要「宽板 / 疾风 / 贪婪」，打日志用。
func _hand_summary(draft: CardDraftPanel) -> String:
	var names: Array[String] = []
	for card: Dictionary in draft.offered:
		names.append(String(card["name"]))
	return " / ".join(names)


## 「特殊砖与多球」截图。
##
## 这张图存在的理由是六种特殊砖的形状标记与 HUD 的「球 ×N」目前没有别的视觉存档，
## 而它们恰好是最容易在换肤或改分辨率时被悄悄改坏的两样东西。
## 球刻意冻结在画面里而不是任其飞：飞行中的球会拖出一条随机的轨迹，
## 每次重截的图都不一样，就没法拿两张图对比确认「形状标记没变」。
func _capture_specials(scene: Node, paddle: CharacterBody2D, balls: BallManager, ball: Ball) -> void:
	# 主球拉回挡板上方，让画面下半部分留给副球
	ball.set("attached_to_paddle", false)
	ball.global_position = Vector2(240.0, 430.0)
	for i in 4:
		balls.spawn_extra(Vector2(120.0 + i * 80.0, 500.0 + (i % 2) * 46.0),
			Vector2(0.0, -1.0))
	for b in balls.all_balls():
		b.set_physics_process(false)
	# 减速状态也留在图里：霜圈是「球怎么慢了」唯一的常驻提示
	balls.apply_speed_scale(0.62)
	# HUD 球数由 count_changed 驱动，spawn_extra 已经发过信号，这里再确认一次
	(scene.get_node("HUD") as GameHUD).set_balls(balls.count())
	await _wait(3)
	await _shot("specials.png")
	print("[capture] 特殊砖图：场上 ", balls.count(), " 颗球，图例=",
		String(scene.call("_level_legend")), " 球数标签=",
		scene.get_node("HUD/BallsLabel").text)
	# 恢复成单球满速，后面的截图不能带着减速与 5 颗球继续跑
	for b in balls.all_balls():
		if b != ball:
			b.emit_signal("fell_out_of_playfield")
	await _wait(2)
	balls.apply_speed_scale(1.0)
	ball.set("attached_to_paddle", true)
	ball.call("stick_to", paddle)


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
