extends SceneTree
## 无头自动冒烟测试（可选验证工具，不参与正式游戏流程）。
## 运行方式：
##   godot --headless --path . --script res://tests/headless_smoke_test.gd
## 它会真实实例化 Main.tscn，模拟输入并校验移动/发射/碰撞/计分/掉命/暂停/结束/通关/重开/最高分。
## 用例开头会清掉 user:// 存档，因此可以任意次连续运行（幂等）。
##
## 测试不写死任何来自游戏脚本的数值：State 枚举、砖块总数、每块砖分数、
## 生命数、碰撞层位值，全部从 main.gd 的脚本常量与 project.godot 的 layer_names 反查得到，
## 游戏侧改名或调数不会让测试静默失效。

const MAIN_SCENE := "res://scenes/Main.tscn"
const MAIN_SCRIPT := "res://scripts/main.gd"
const SAVE_PATH := "user://2d_breakout_save.cfg"

# 运行期从脚本常量与项目设置绑定，见 _bind_constants()
var _state_playing := -1
var _state_paused := -1
var _state_game_over := -1
var _state_won := -1
var _brick_total := 0
var _points_per_brick := 0
var _start_lives := 0
var _layer_wall := 0
var _layer_paddle := 0
var _layer_brick := 0
var _layer_ball := 0

var _checks := 0
var _fails := 0


func _initialize() -> void:
	Engine.time_scale = 4.0  # 加速物理，缩短测试时间
	_reset_save()
	_bind_constants()
	_run()


## 删除历史存档，保证“最高分”断言不受上一次运行影响，测试可重复执行。
func _reset_save() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists("2d_breakout_save.cfg"):
		dir.remove("2d_breakout_save.cfg")


## 从 main.gd 读取 State 枚举与玩法常量，避免测试里维护一份会过期的副本。
func _bind_constants() -> void:
	var script := load(MAIN_SCRIPT) as GDScript
	if script == null:
		return
	var consts: Dictionary = script.get_script_constant_map()
	var states: Dictionary = consts.get("State", {})
	_state_playing = int(states.get("PLAYING", -1))
	_state_paused = int(states.get("PAUSED", -1))
	_state_game_over = int(states.get("GAME_OVER", -1))
	_state_won = int(states.get("WON", -1))
	_brick_total = int(consts.get("BRICK_TOTAL", 0))
	_points_per_brick = int(consts.get("POINTS_PER_BRICK", 0))
	_start_lives = int(consts.get("START_LIVES", 0))


## 依据 project.godot 的 layer_names 反查位值（第 N 层 -> 1 << (N-1)）。
func _layer_value(display_name: String) -> int:
	for i in range(1, 33):
		var name := str(ProjectSettings.get_setting("layer_names/2d_physics/layer_%d" % i, ""))
		if name == display_name:
			return 1 << (i - 1)
	return 0


## Main 的私有字段统一经由这里读取，字符串访问只集中在一处，便于维护。
func _gi(node: Node, key: String) -> int:
	return int(node.get(key))


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] ", label)
	else:
		_fails += 1
		print("  [FAIL] ", label)


func _wait(frames: int) -> void:
	for i in frames:
		await physics_frame


## 模拟一次“按下并松开”的动作事件，走完整的输入管线（_unhandled_input）。
func _send_action(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	event.strength = 1.0
	Input.parse_input_event(event)


func _read_best_from_disk() -> int:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return -1
	return int(config.get_value("progress", "best_score", -1))


func _run() -> void:
	await process_frame

	_check(_brick_total > 0 and _state_won >= 0, "从 main.gd 绑定到 State 枚举与玩法常量")
	_layer_wall = _layer_value("Wall")
	_layer_paddle = _layer_value("Paddle")
	_layer_brick = _layer_value("Brick")
	_layer_ball = _layer_value("Ball")
	_check(_layer_wall > 0 and _layer_paddle > 0 and _layer_brick > 0 and _layer_ball > 0,
		"从 project.godot 反查到 Wall/Paddle/Brick/Ball 层位值（%d/%d/%d/%d）" % [_layer_wall, _layer_paddle, _layer_brick, _layer_ball])

	# ---------- 1. 场景结构 ----------
	var scene: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	current_scene = scene
	await physics_frame

	var paddle: CharacterBody2D = scene.get_node("Paddle")
	var ball: CharacterBody2D = scene.get_node("Ball")
	var bricks: Node2D = scene.get_node("Bricks")
	var pause_label: Label = scene.get_node("PausePanel/Panel/Margin/PausedLabel")

	_check(scene.get_script() != null, "Main 节点挂载了 main.gd")
	_check(scene.get_node("Walls/LeftWall") is StaticBody2D, "左墙为 StaticBody2D")
	_check(paddle.get_node_or_null("Sensor") is Area2D, "挡板带有 Area2D(Sensor)")
	_check(ball.get_node_or_null("CollisionShape2D") is CollisionShape2D, "球带有 CollisionShape2D")
	_check(bricks.get_child_count() == _brick_total,
		"运行时生成 %d 块砖（实际 %d）" % [_brick_total, bricks.get_child_count()])
	_check(bool(ball.get("attached_to_paddle")), "球初始停在挡板上")
	_check(scene.get_node("HUD/ScoreLabel").text == "分数 0", "HUD 初始分数为 0")
	_check(_gi(scene, "_lives") == _start_lives, "初始生命为 %d" % _start_lives)
	_check(pause_label.text == "已暂停", "暂停面板文本为“已暂停”")

	# ---------- 2. 碰撞层与 layer_names 命名一致 ----------
	var brick: Node = bricks.get_child(0)
	var sensor: Area2D = paddle.get_node("Sensor")
	_check(int(brick.get("collision_layer")) == _layer_brick,
		"砖块位于 Brick 层（值 %d，实际 %d）" % [_layer_brick, int(brick.get("collision_layer"))])
	_check(int(ball.get("collision_layer")) == _layer_ball,
		"球位于 Ball 层（值 %d，实际 %d）" % [_layer_ball, int(ball.get("collision_layer"))])
	var ball_mask: int = int(ball.get("collision_mask"))
	_check((ball_mask & _layer_wall) != 0 and (ball_mask & _layer_paddle) != 0 and (ball_mask & _layer_brick) != 0,
		"球掩码同时包含 Wall/Paddle/Brick 三层（掩码=%d）" % ball_mask)
	_check((int(sensor.get("collision_mask")) & _layer_ball) != 0, "挡板传感器掩码指向 Ball 层")
	_check((int(brick.get("collision_layer")) & int(sensor.get("collision_mask"))) == 0, "挡板传感器不会误检砖块")

	# ---------- 3. 挡板移动与边界限制 ----------
	var left_bound: float = paddle.get("left_bound")
	var right_bound: float = paddle.get("right_bound")
	Input.action_press("move_left")
	await _wait(45)
	Input.action_release("move_left")
	_check(paddle.position.x <= left_bound + 0.5,
		"向左移动被夹在左边界内（x=%.1f <= %.1f）" % [paddle.position.x, left_bound])
	Input.action_press("move_right")
	await _wait(90)
	Input.action_release("move_right")
	_check(paddle.position.x >= right_bound - 0.5,
		"向右移动被夹在右边界内（x=%.1f >= %.1f）" % [paddle.position.x, right_bound])

	# ---------- 4. 发射 ----------
	paddle.position.x = 240.0
	var rest_y: float = ball.position.y
	_send_action(&"launch")
	await _wait(3)
	_check(not bool(ball.get("attached_to_paddle")), "按 空格(launch) 后球进入飞行状态")
	_check(ball.position.y < rest_y, "球离开发射点向上运动（y %.1f -> %.1f）" % [rest_y, ball.position.y])

	# ---------- 5. 砖块碰撞与加分（挡板自动跟随，模拟一个“会玩”的玩家） ----------
	var score_before: int = _gi(scene, "_score")
	for i in 420:
		paddle.position.x = clampf(ball.position.x, left_bound, right_bound)
		await physics_frame
	var score_after: int = _gi(scene, "_score")
	_check(score_after > score_before, "球击中砖块后分数增加（%d -> %d）" % [score_before, score_after])
	_check(score_after % _points_per_brick == 0,
		"分数始终是每块砖分值（%d）的整数倍" % _points_per_brick)
	_check(bricks.get_child_count() < _brick_total,
		"被击中的砖块已消失（剩余 %d 块）" % bricks.get_child_count())
	_check(ball.position.x > 0.0 and ball.position.x < 480.0 and ball.position.y > 0.0,
		"球始终被限制在左右/顶部墙体之内（x=%.1f, y=%.1f）" % [ball.position.x, ball.position.y])

	# ---------- 6. 球掉出底部：生命 -1 ----------
	var lives_before: int = _gi(scene, "_lives")
	ball.position.y = float(ball.get("death_y")) + 50.0
	await _wait(4)
	_check(_gi(scene, "_lives") == lives_before - 1,
		"球掉出底部生命 -1（%d -> %d）" % [lives_before, _gi(scene, "_lives")])
	_check(bool(ball.get("attached_to_paddle")), "掉球后球重新吸附到挡板等待发射")

	# ---------- 7. 暂停 / 继续 ----------
	_send_action(&"pause")
	await _wait(2)
	_check(paused, "按 P 键后 get_tree().paused == true")
	_check(_gi(scene, "_state") == _state_paused, "暂停后进入 Paused 状态")
	_check(scene.get_node("PausePanel/Panel").visible, "暂停时显示“已暂停”面板")
	var frozen_position: Vector2 = ball.position
	var frozen_paddle_x: float = paddle.position.x
	Input.action_press("move_right")
	await _wait(12)
	Input.action_release("move_right")
	_check(ball.position.is_equal_approx(frozen_position), "暂停期间球完全静止")
	_check(paddle.position.x == frozen_paddle_x, "暂停期间挡板不响应输入（x 保持 %.1f）" % paddle.position.x)
	_send_action(&"pause")
	await _wait(2)
	_check(not paused, "再次按 P 键恢复游戏")
	_check(_gi(scene, "_state") == _state_playing, "恢复后回到 Playing 状态")

	# ---------- 8. 生命耗尽 -> 游戏结束 + 最高分存档 ----------
	var guard := 0
	while _gi(scene, "_lives") > 0 and guard < 10:
		guard += 1
		# 先解除吸附，否则球会被 _physics_process 拉回挡板上，永远掉不下去
		ball.set("attached_to_paddle", false)
		ball.position = Vector2(paddle.position.x, float(ball.get("death_y")) + 50.0)
		await _wait(4)
	await _wait(2)

	var final_score: int = _gi(scene, "_score")
	_check(_gi(scene, "_state") == _state_game_over, "生命归零后进入 Game Over 状态")
	_check(scene.get_node("GameOverPanel/Panel").visible, "显示 Game Over 面板")
	_check(scene.get_node("GameOverPanel/Panel/Margin/VBox/TitleLabel").text == "游戏结束",
		"结算面板标题为“游戏结束”")
	_check(scene.get_node("GameOverPanel/Panel/Margin/VBox/FinalScoreLabel").text.contains(str(final_score)),
		"面板显示最终分数 %d" % final_score)
	_check(scene.get_node("HUD/HintLabel").text.contains("重开"),
		"结束后 HUD 底部提示改为重开提示（%s）" % scene.get_node("HUD/HintLabel").text)
	_check(not bool(ball.get("visible")), "结束后球隐藏并停止运动")

	# 结算后挡板应冻结
	var paddle_x_at_over: float = paddle.position.x
	Input.action_press("move_right")
	await _wait(30)
	Input.action_release("move_right")
	_check(paddle.position.x == paddle_x_at_over,
		"结算后挡板不再响应输入（x 保持 %.1f）" % paddle.position.x)

	var best_on_disk := _read_best_from_disk()
	_check(best_on_disk >= final_score, "最高分写入 user:// ConfigFile（%d >= %d）" % [best_on_disk, final_score])

	# ---------- 9. 重开 ----------
	_send_action(&"launch")
	await _wait(20)
	var restarted: Node = current_scene
	_check(restarted != null and restarted != scene, "按 空格/launch 触发重开，场景重新加载")
	if restarted != null:
		_check(_gi(restarted, "_score") == 0, "重开后分数归零")
		_check(_gi(restarted, "_best") == best_on_disk, "重开后最高分从存档恢复（%d）" % _gi(restarted, "_best"))
		_check(_gi(restarted, "_lives") == _start_lives, "重开后生命恢复为 %d" % _start_lives)
		_check(bool(restarted.get_node("Paddle").get("input_enabled")), "重开后挡板恢复可操控")
		_check(restarted.get_node("Bricks").get_child_count() == _brick_total,
			"重开后砖墙重新生成（%d 块）" % restarted.get_node("Bricks").get_child_count())

	# ---------- 10. 通关：最后一帧同时击破两块砖 ----------
	if restarted != null:
		var bricks2: Node2D = restarted.get_node("Bricks")
		var ball2: CharacterBody2D = restarted.get_node("Ball")
		# queue_free 是帧末才生效，必须先取快照再逐个移除，否则 get_child(0) 会反复拿到同一块砖。
		# 通关判定依赖 Main 的击破计数，这里同步把计数推到“只剩两块”的位置。
		var snapshot: Array = bricks2.get_children()
		restarted.set("_bricks_cleared", _brick_total - 2)
		for i in _brick_total - 2:
			snapshot[i].queue_free()
		await _wait(3)
		_check(bricks2.get_child_count() == 2, "场上只剩最后两块砖（剩余 %d 块）" % bricks2.get_child_count())
		_check(_gi(restarted, "_state") == _state_playing, "砖块未清空时不判定通关")

		# 走真实的击破路径：同一帧连续击破两块砖 -> Main 加分并判定通关
		var score_before_win: int = _gi(restarted, "_score")
		ball2.brick_hit.emit(bricks2.get_child(0))
		ball2.brick_hit.emit(bricks2.get_child(1))
		await _wait(3)
		_check(_gi(restarted, "_state") == _state_won, "同一帧击破最后两块砖也进入通关状态")
		_check(_gi(restarted, "_score") == score_before_win + 2 * _points_per_brick,
			"通关时两块砖都计分（%d -> %d）" % [score_before_win, _gi(restarted, "_score")])
		_check(restarted.get_node("GameOverPanel/Panel").visible, "显示通关结算面板")
		_check(restarted.get_node("GameOverPanel/Panel/Margin/VBox/TitleLabel").text == "通关！",
			"结算面板标题切换为“通关！”")
		_check(restarted.get_node("HUD/HintLabel").text.contains("通关"),
			"通关后 HUD 底部提示同步更新（%s）" % restarted.get_node("HUD/HintLabel").text)
		_check(not bool(restarted.get_node("Ball").get("visible")), "通关后球停止运动并隐藏")

		# 结算状态下不应再扣命：直接触发掉球信号，生命必须保持不变
		var lives_at_win: int = _gi(restarted, "_lives")
		ball2.fell_out_of_playfield.emit()
		await _wait(2)
		_check(_gi(restarted, "_lives") == lives_at_win,
			"通关状态下掉球不再扣命（生命保持 %d）" % _gi(restarted, "_lives"))
		_check(restarted.get_node("GameOverPanel/Panel").visible, "结算面板不会被掉球盖掉")

		# 通关状态下也应能重开
		current_scene = restarted
		_send_action(&"restart")
		await _wait(20)
		var restarted2: Node = current_scene
		_check(restarted2 != null and restarted2 != restarted, "通关后按 R 触发重开")

	# ---------- 11. 存档健壮性 ----------
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("progress", "best_score", "not-a-number")
	cfg.save(SAVE_PATH)
	_check(HighScore.load_best() == 0, "存档字段被改坏时 load_best() 安全返回 0")
	_reset_save()
	_check(HighScore.load_best() == 0, "存档清空后 load_best() 返回 0")

	print("\n===== 冒烟测试结果：%d 项检查，%d 项失败 =====" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
