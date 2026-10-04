extends SceneTree
## 无头自动冒烟测试（可选验证工具，不参与正式游戏流程）。
## 运行方式：
##   godot --headless --path . --script res://tests/headless_smoke_test.gd
## 它会真实实例化 Main.tscn，模拟输入并校验：
## 移动/发射/碰撞/计分/掉命/暂停/关卡递进/通关/重开/最高分/多耐久砖块/挡板收窄/
## 退出按钮/音效与粒子与震动。
## 用例开头会清掉 user:// 存档，因此可以任意次连续运行（幂等）。
##
## 测试不写死任何来自游戏脚本的数值：State 枚举、砖块总数、每块砖分数、生命数、
## 关卡数、砖块耐久、挡板宽度阶梯、碰撞层位值，全部从 main.gd 的脚本常量与
## project.godot 的 layer_names 反查得到，游戏侧改名或调数不会让测试静默失效。

const MAIN_SCENE := "res://scenes/Main.tscn"
const MAIN_SCRIPT := "res://scripts/main.gd"
const SFX_SCRIPT := "res://scripts/sfx.gd"
const SAVE_PATH := "user://2d_breakout_save.cfg"
const PANEL_VBOX := "GameOverPanel/Panel/Margin/VBox"
const PAUSE_VBOX := "PausePanel/Panel/Margin/VBox"

# 运行期从脚本常量与项目设置绑定，见 _bind_constants()
var _state_playing := -1
var _state_paused := -1
var _state_game_over := -1
var _state_level_clear := -1
var _state_won := -1
var _brick_total := 0
var _points_per_brick := 0
var _start_lives := 0
var _max_level := 0
var _wall_thickness := 0.0
var _view_width := 0.0
var _view_center := Vector2.ZERO
var _layer_wall := 0
var _layer_paddle := 0
var _layer_brick := 0
var _layer_ball := 0
var _level_hits: Array = []
var _paddle_widths: Array = []

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
	_state_level_clear = int(states.get("LEVEL_CLEAR", -1))
	_state_won = int(states.get("WON", -1))
	_brick_total = int(consts.get("BRICK_TOTAL", 0))
	_points_per_brick = int(consts.get("POINTS_PER_BRICK", 0))
	_start_lives = int(consts.get("START_LIVES", 0))
	_max_level = int(consts.get("MAX_LEVEL", 0))
	var view: Vector2 = consts.get("VIEW_SIZE", Vector2.ZERO)
	_view_width = view.x
	_view_center = view * 0.5
	_wall_thickness = float(consts.get("WALL_THICKNESS", 0.0))
	_level_hits = consts.get("LEVEL_BRICK_HITS", [])
	_paddle_widths = consts.get("PADDLE_WIDTH_STEPS", [])


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


func _gf(node: Object, key: String) -> float:
	return float(node.get(key))


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


## 扫描脚本源码里用到的音效名，供“预设齐全”检查使用。
## 必须把整个实参表达式取完再提字面量：`_play_sfx("brick" if destroyed else "crack")`
## 只取第一个引号对会漏掉 "crack"，删掉预设也测不出来。
func _sfx_names_in_use() -> Array:
	var names: Array = []
	var pattern := RegEx.new()
	pattern.compile("\"([a-z_]+)\"")
	for path in ["res://scripts/main.gd", "res://scripts/game_over_panel.gd", "res://scripts/pause_panel.gd"]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var source := file.get_as_text()
		file.close()
		for prefix in ["_play_sfx(", "sfx.play("]:
			var search_from := 0
			while true:
				var at := source.find(prefix, search_from)
				if at < 0:
					break
				var start: int = at + int(prefix.length())
				var stop := _matching_paren(source, start)
				if stop < 0:
					break
				for match_result in pattern.search_all(source.substr(start, stop - start)):
					var found := match_result.get_string(1)
					if not names.has(found):
						names.append(found)
				search_from = stop
	return names


## 从 from（左括号之后）找到配对的右括号下标，找不到返回 -1。
func _matching_paren(source: String, from: int) -> int:
	var depth := 1
	var i := from
	while i < source.length():
		var ch := source[i]
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


func _run() -> void:
	await process_frame

	_check(_brick_total > 0 and _state_won >= 0 and _state_level_clear >= 0 and _max_level > 0,
		"从 main.gd 绑定到 State 枚举与玩法常量（关卡数 %d）" % _max_level)
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
	var pause_label: Label = scene.get_node(PAUSE_VBOX + "/PausedLabel")

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
	_check(scene.get_node("HUD/LevelLabel").text.contains("1"),
		"HUD 显示关卡（%s）" % scene.get_node("HUD/LevelLabel").text)

	# ---------- 2. 手感系统就位 ----------
	var sfx_node: Node = root.get_node_or_null("/root/Sfx")
	var shake_node: Node = root.get_node_or_null("/root/Shake")
	_check(sfx_node is Node, "autoload Sfx 已就位")
	_check(shake_node is Node, "autoload Shake 已就位")
	_check(scene.get_node_or_null("Camera2D") is Camera2D, "场景带有 Camera2D（屏幕震动的载体）")
	_check(scene.get_node("Camera2D").position.distance_to(_view_center) < 0.01,
		"相机位于视口中心 %s，画面布局与无相机时一致" % str(_view_center))
	_check(scene.get_node_or_null("Fx") is Node2D, "场景带有 Fx 根节点（粒子碎屑的容器）")

	# ---------- 3. 碰撞层与 layer_names 命名一致 ----------
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

	# ---------- 4. 挡板移动与边界限制 ----------
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

	# ---------- 5. 发射 ----------
	paddle.position.x = 240.0
	var rest_y: float = ball.position.y
	_send_action(&"launch")
	await _wait(3)
	_check(not bool(ball.get("attached_to_paddle")), "按 空格(launch) 后球进入飞行状态")
	_check(ball.position.y < rest_y, "球离开发射点向上运动（y %.1f -> %.1f）" % [rest_y, ball.position.y])

	# ---------- 6. 砖块碰撞与加分（挡板自动跟随，模拟一个“会玩”的玩家） ----------
	var score_before: int = _gi(scene, "_score")
	var fx_root: Node2D = scene.get_node("Fx")
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

	# ---------- 7. 击破砖块会生成碎屑粒子，且会自行销毁 ----------
	var ball2: CharacterBody2D = ball
	var fx_before: int = fx_root.get_child_count()
	ball2.brick_hit.emit(bricks.get_child(0))
	await _wait(2)
	var fx_after: int = fx_root.get_child_count()
	_check(fx_after > fx_before, "击破砖块时在 Fx 下生成碎屑粒子（%d -> %d）" % [fx_before, fx_after])
	var burst: Node = fx_root.get_child(fx_root.get_child_count() - 1)
	_check(burst is CPUParticles2D and bool(burst.get("one_shot")), "碎屑是一次性(one_shot) CPUParticles2D")
	await _wait(240)
	_check(fx_root.get_child_count() == 0,
		"碎屑粒子播放完毕后自动销毁，不累积泄漏（剩余 %d 个）" % fx_root.get_child_count())

	# ---------- 8. 球掉出底部：生命 -1 且挡板收窄 ----------
	var lives_before: int = _gi(scene, "_lives")
	var width_before: float = _gf(paddle, "paddle_width")
	# 上一节要等 240 帧让粒子自毁，期间球可能已经掉落并被重新吸附。
	# 吸附态下球每帧都会被拉回挡板，直接改 y 不会触发掉落，所以先确保球在飞行中。
	if bool(ball.get("attached_to_paddle")):
		ball.call("launch")
		await _wait(2)
	ball.position.y = float(ball.get("death_y")) + 50.0
	await _wait(4)
	_check(_gi(scene, "_lives") == lives_before - 1,
		"球掉出底部生命 -1（%d -> %d）" % [lives_before, _gi(scene, "_lives")])
	_check(bool(ball.get("attached_to_paddle")), "掉球后球重新吸附到挡板等待发射")
	var width_after_loss: float = _gf(paddle, "paddle_width")
	var expected_width: float = float(_paddle_widths[clampi(_start_lives - _gi(scene, "_lives"), 0, _paddle_widths.size() - 1)])
	_check(width_after_loss < width_before and absf(width_after_loss - expected_width) < 0.01,
		"掉命后挡板收窄（%.1f -> %.1f，阶梯值 %.1f）" % [width_before, width_after_loss, expected_width])
	# 边界必须按新宽度重算：左 = 墙厚 + 半宽，右 = 视口宽 - 墙厚 - 半宽
	var expected_left: float = _wall_thickness + width_after_loss * 0.5
	var expected_right: float = _view_width - _wall_thickness - width_after_loss * 0.5
	_check(absf(_gf(paddle, "left_bound") - expected_left) < 0.01
		and absf(_gf(paddle, "right_bound") - expected_right) < 0.01,
		"挡板收窄后活动边界同步重算（%.1f ~ %.1f，期望 %.1f ~ %.1f）"
		% [_gf(paddle, "left_bound"), _gf(paddle, "right_bound"), expected_left, expected_right])

	# ---------- 9. 暂停 / 继续 ----------
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
	# 暂停面板上的按钮在暂停状态下必须可点
	var resume_button: Button = scene.get_node(PAUSE_VBOX + "/ResumeButton")
	_check(resume_button != null and resume_button.visible, "暂停面板提供“继续”按钮")
	_send_action(&"pause")
	await _wait(2)
	_check(not paused, "再次按 P 键恢复游戏")
	_check(_gi(scene, "_state") == _state_playing, "恢复后回到 Playing 状态")

	# ---------- 10. 生命耗尽 -> 游戏结束 + 最高分存档 ----------
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
	_check(scene.get_node(PANEL_VBOX + "/TitleLabel").text == "游戏结束",
		"结算面板标题为“游戏结束”")
	_check(scene.get_node(PANEL_VBOX + "/ContinueButton").text == "再来一局",
		"游戏结束时按钮文案为“再来一局”")
	_check(scene.get_node(PANEL_VBOX + "/FinalScoreLabel").text.contains(str(final_score)),
		"面板显示最终分数 %d" % final_score)
	_check(scene.get_node("HUD/HintLabel").text.contains("重开"),
		"结束后 HUD 底部提示改为重开提示（%s）" % scene.get_node("HUD/HintLabel").text)
	_check(not bool(ball.get("visible")), "结束后球隐藏并停止运动")
	_check(absf(_gf(paddle, "paddle_width") - float(_paddle_widths[_paddle_widths.size() - 1])) < 0.01,
		"生命耗尽时挡板已收窄到最窄一档（%.1f）" % _gf(paddle, "paddle_width"))

	# 结算后挡板应冻结
	var paddle_x_at_over: float = paddle.position.x
	Input.action_press("move_right")
	await _wait(30)
	Input.action_release("move_right")
	_check(paddle.position.x == paddle_x_at_over,
		"结算后挡板不再响应输入（x 保持 %.1f）" % paddle.position.x)

	var best_on_disk := _read_best_from_disk()
	_check(best_on_disk >= final_score, "最高分写入 user:// ConfigFile（%d >= %d）" % [best_on_disk, final_score])

	# ---------- 11. 退出按钮只发信号，不直接退出进程 ----------
	var over_panel: Node = scene.get_node("GameOverPanel")
	var quit_button: Button = scene.get_node(PANEL_VBOX + "/QuitButton")
	_check(quit_button != null and quit_button.text == "退出游戏", "结算面板提供“退出游戏”按钮")
	_check(over_panel.has_signal("quit_requested"), "结算面板暴露 quit_requested 信号")
	# 断开 Main 的退出处理，避免真的把测试进程关掉
	over_panel.quit_requested.disconnect(scene._on_quit_requested)
	var quit_emitted := [false]
	over_panel.quit_requested.connect(func() -> void: quit_emitted[0] = true)
	quit_button.pressed.emit()
	_check(quit_emitted[0], "点击“退出游戏”发出 quit_requested（由 Main 决定退出）")

	# ---------- 12. 重开 ----------
	_send_action(&"launch")
	await _wait(20)
	var restarted: Node = current_scene
	_check(restarted != null and restarted != scene, "按 空格/launch 触发重开，场景重新加载")
	if restarted == null:
		_finish()
		return

	_check(_gi(restarted, "_score") == 0, "重开后分数归零")
	_check(_gi(restarted, "_best") == best_on_disk, "重开后最高分从存档恢复（%d）" % _gi(restarted, "_best"))
	_check(_gi(restarted, "_lives") == _start_lives, "重开后生命恢复为 %d" % _start_lives)
	_check(_gi(restarted, "_level") == 1, "重开后回到第 1 关")
	_check(bool(restarted.get_node("Paddle").get("input_enabled")), "重开后挡板恢复可操控")
	_check(restarted.get_node("Bricks").get_child_count() == _brick_total,
		"重开后砖墙重新生成（%d 块）" % restarted.get_node("Bricks").get_child_count())
	_check(absf(_gf(restarted.get_node("Paddle"), "paddle_width") - float(_paddle_widths[0])) < 0.01,
		"重开后挡板恢复初始宽度（%.1f）" % _gf(restarted.get_node("Paddle"), "paddle_width"))

	# ---------- 13. 关卡递进：清空砖墙先进入“关卡通过”，不是直接结束 ----------
	var bricks3: Node2D = restarted.get_node("Bricks")
	var ball3: CharacterBody2D = restarted.get_node("Ball")
	var score_before_clear: int = _gi(restarted, "_score")
	var lives_before_clear: int = _gi(restarted, "_lives")
	# queue_free 帧末才生效：先取快照，释放除最后一块以外的全部砖，再真实击破最后一块
	var clear_snapshot: Array = bricks3.get_children()
	restarted.set("_bricks_cleared", _brick_total - 1)
	for i in _brick_total - 1:
		clear_snapshot[i].queue_free()
	await _wait(3)
	_check(bricks3.get_child_count() == 1, "场上只剩最后一块砖（剩余 %d 块）" % bricks3.get_child_count())
	_check(_gi(restarted, "_state") == _state_playing, "砖块未清空时不判定关卡通过")
	ball3.brick_hit.emit(bricks3.get_child(0))
	await _wait(3)
	var score_after_clear: int = _gi(restarted, "_score")
	_check(_gi(restarted, "_state") == _state_level_clear,
		"第 1 关清空砖墙后进入 Level Clear（不是直接结束）")
	_check(restarted.get_node(PANEL_VBOX + "/TitleLabel").text == "第 1 关通过！",
		"结算面板标题为“第 1 关通过！”（实际 %s）" % restarted.get_node(PANEL_VBOX + "/TitleLabel").text)
	_check(restarted.get_node(PANEL_VBOX + "/ContinueButton").text == "下一关",
		"关卡通过时按钮文案为“下一关”")
	_check(restarted.get_node("HUD/HintLabel").text.contains("下一关"),
		"关卡通过后 HUD 底部提示同步更新（%s）" % restarted.get_node("HUD/HintLabel").text)

	# 进入下一关：分数与生命延续，砖墙重建
	_send_action(&"restart")
	await _wait(6)
	_check(_gi(restarted, "_level") == 2, "按 空格/R 进入第 2 关（当前 %d）" % _gi(restarted, "_level"))
	_check(_gi(restarted, "_state") == _state_playing, "进入下一关后回到 Playing 状态")
	_check(_gi(restarted, "_score") == score_after_clear, "关卡之间分数延续（%d）" % _gi(restarted, "_score"))
	_check(_gi(restarted, "_lives") == lives_before_clear, "关卡之间生命延续（%d）" % _gi(restarted, "_lives"))
	_check(_gi(restarted, "_bricks_cleared") == 0, "新一关的击破计数归零")
	_check(restarted.get_node("Bricks").get_child_count() == _brick_total,
		"新一关砖墙重建（%d 块）" % restarted.get_node("Bricks").get_child_count())
	_check(not restarted.get_node("GameOverPanel/Panel").visible, "进入下一关后结算面板收起")
	_check(restarted.get_node("HUD/LevelLabel").text.contains("2"),
		"HUD 关卡显示同步（%s）" % restarted.get_node("HUD/LevelLabel").text)

	# 关卡推进不走场景重载，挡板冻结必须被显式解除，否则第 2 关起玩家只能看着命掉光
	var paddle3: CharacterBody2D = restarted.get_node("Paddle")
	_check(bool(paddle3.get("input_enabled")), "进入下一关后挡板恢复可操控")
	var x_before_move: float = paddle3.position.x
	Input.action_press("move_right")
	await _wait(12)
	Input.action_release("move_right")
	_check(paddle3.position.x > x_before_move,
		"进入下一关后挡板确实能移动（x %.1f -> %.1f）" % [x_before_move, paddle3.position.x])

	# ---------- 14. 多耐久砖块：第 2 关的砖要打两次才碎 ----------
	var tough: Node = restarted.get_node("Bricks").get_child(0)
	var hits_expected: int = int(_level_hits[1 % _level_hits.size()])
	_check(int(tough.get("max_hits")) == hits_expected,
		"第 2 关砖块耐久为 %d（实际 %d）" % [hits_expected, int(tough.get("max_hits"))])
	var score_before_tough: int = _gi(restarted, "_score")
	var count_before_tough: int = restarted.get_node("Bricks").get_child_count()
	ball3.brick_hit.emit(tough)
	await _wait(2)
	_check(_gi(restarted, "_score") == score_before_tough + _points_per_brick,
		"击打多耐久砖块同样计分（%d -> %d）" % [score_before_tough, _gi(restarted, "_score")])
	_check(restarted.get_node("Bricks").get_child_count() == count_before_tough,
		"耐久未耗尽时砖块不消失（剩余 %d 块）" % restarted.get_node("Bricks").get_child_count())
	_check(int(tough.get("hits_left")) == hits_expected - 1,
		"击打一次后剩余耐久 %d（实际 %d）" % [hits_expected - 1, int(tough.get("hits_left"))])
	_check(_gi(restarted, "_bricks_cleared") == 0, "未击碎的砖块不计入“已清除”计数")
	ball3.brick_hit.emit(tough)
	await _wait(3)
	_check(restarted.get_node("Bricks").get_child_count() == count_before_tough - 1,
		"耐久耗尽后砖块消失（剩余 %d 块）" % restarted.get_node("Bricks").get_child_count())
	_check(_gi(restarted, "_bricks_cleared") == 1, "击碎后计入“已清除”计数")

	# ---------- 14b. 碎屑粒子必须在同一个 Main 实例上全部自毁 ----------
	# 注意：必须在同一个实例上测。通关后重载出来的新场景从没生成过粒子，
	# 在它身上断言 Fx 为空是恒真的，抓不到泄漏回归。
	var fx_same: Node2D = restarted.get_node("Fx")
	var bricks_same: Node2D = restarted.get_node("Bricks")
	var fx_peak := 0
	for i in mini(20, bricks_same.get_child_count()):
		var target: Node = bricks_same.get_child(bricks_same.get_child_count() - 1)
		if target == null:
			break
		target.set("hits_left", 1)
		ball3.brick_hit.emit(target)
		await _wait(1)
		fx_peak = maxi(fx_peak, fx_same.get_child_count())
	_check(fx_peak > 0, "连续击破时碎屑持续生成（峰值 %d 个）" % fx_peak)
	await _wait(300)
	_check(fx_same.get_child_count() == 0,
		"同一 Main 实例上的碎屑全部自毁，无泄漏（剩余 %d 个）" % fx_same.get_child_count())

	# ---------- 15. 最后一关清空 -> 通关 ----------
	restarted.set("_level", _max_level)
	var last_bricks: Node2D = restarted.get_node("Bricks")
	var last_snapshot: Array = last_bricks.get_children()
	# 只留最后两块：释放数量按快照实际大小算，前面用例可能已经击碎过砖块
	restarted.set("_bricks_cleared", _brick_total - 2)
	for i in last_snapshot.size() - 2:
		last_snapshot[i].queue_free()
	await _wait(3)
	_check(last_bricks.get_child_count() == 2, "场上只剩最后两块砖（剩余 %d 块）" % last_bricks.get_child_count())
	_check(_gi(restarted, "_state") == _state_playing, "砖块未清空时不判定通关")

	# 把这两块砖调到“再挨一下就碎”的状态，模拟真正的最后一击
	for node in last_bricks.get_children():
		node.set("hits_left", 1)

	# 走真实的击破路径：同一帧连续击破两块砖 -> Main 加分并判定通关
	var score_before_win: int = _gi(restarted, "_score")
	ball3.brick_hit.emit(last_bricks.get_child(0))
	ball3.brick_hit.emit(last_bricks.get_child(1))
	await _wait(3)
	_check(_gi(restarted, "_state") == _state_won, "最后一关同一帧击破最后两块砖也进入通关状态")
	_check(_gi(restarted, "_score") == score_before_win + 2 * _points_per_brick,
		"通关时两块砖都计分（%d -> %d）" % [score_before_win, _gi(restarted, "_score")])
	_check(restarted.get_node("GameOverPanel/Panel").visible, "显示通关结算面板")
	_check(restarted.get_node(PANEL_VBOX + "/TitleLabel").text == "通关！",
		"结算面板标题切换为“通关！”")
	_check(restarted.get_node("HUD/HintLabel").text.contains("通关"),
		"通关后 HUD 底部提示同步更新（%s）" % restarted.get_node("HUD/HintLabel").text)
	_check(not bool(restarted.get_node("Ball").get("visible")), "通关后球停止运动并隐藏")

	# 结算状态下不应再扣命：直接触发掉球信号，生命必须保持不变
	var lives_at_win: int = _gi(restarted, "_lives")
	ball3.fell_out_of_playfield.emit()
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

	# ---------- 16. 音效预设齐全 ----------
	var sfx_script: GDScript = load(SFX_SCRIPT) as GDScript
	var presets: Dictionary = {}
	if sfx_script != null:
		presets = sfx_script.get_script_constant_map().get("PRESETS", {})
	var used: Array = _sfx_names_in_use()
	var missing: Array = []
	for name in used:
		if not presets.has(name):
			missing.append(name)
	var unused: Array = []
	for key in presets:
		if not used.has(key):
			unused.append(key)
	_check(not used.is_empty() and missing.is_empty(),
		"脚本用到的 %d 个音效名在 Sfx 预设中全部存在（缺失：%s）" % [used.size(), str(missing)])
	_check(unused.is_empty(), "Sfx 预设里没有未被使用的死预设（未使用：%s）" % str(unused))

	# Web 音效分支依赖 AudioStreamPlayer.playback_type（4.7 的属性名，枚举挂在 AudioServer）。
	# 属性名写错时 GDScript 静态检查不报错，运行时才抛 "Invalid access to property or key"，
	# 后果是 Sfx._ready() 中断、音效全灭，所以这里直接核对运行时属性表。
	var probe_player := AudioStreamPlayer.new()
	var has_playback_type := false
	for prop: Dictionary in probe_player.get_property_list():
		if String(prop.name) == "playback_type":
			has_playback_type = true
			break
	probe_player.free()
	_check(has_playback_type, "AudioStreamPlayer 运行时暴露 playback_type（Web 音效分支依赖它）")
	var max_voices: int = int(sfx_script.get_script_constant_map().get("MAX_VOICES", 0))
	var voices: int = int(sfx_node.call("get_voice_count"))
	_check(max_voices > 0 and voices <= max_voices,
		"音效声部数受上限约束（%d <= %d）" % [voices, max_voices])

	# ---------- 17. 屏幕震动会衰减归零 ----------
	var shake_bus: Node = root.get_node("/root/Shake")
	shake_bus.call("shake", 0.9)
	await _wait(2)
	_check(float(shake_bus.call("get_trauma")) > 0.0, "触发震动后创伤值 > 0")
	await _wait(180)
	_check(float(shake_bus.call("get_trauma")) <= 0.0, "震动随时间自动衰减到 0")
	var camera: Camera2D = restarted2.get_node("Camera2D") if restarted2 != null else null
	if camera != null:
		_check(camera.offset.is_zero_approx(), "震动结束后相机偏移归零（%s）" % str(camera.offset))

	# ---------- 18. 存档健壮性 ----------
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("progress", "best_score", "not-a-number")
	cfg.save(SAVE_PATH)
	_check(HighScore.load_best() == 0, "存档字段被改坏时 load_best() 安全返回 0")
	_reset_save()
	_check(HighScore.load_best() == 0, "存档清空后 load_best() 返回 0")

	# ---------- 19. 收尾 ----------
	if restarted2 != null:
		await _wait(300)
		_check(restarted2.get_node("Fx").get_child_count() == 0,
			"重载后的新场景不残留粒子（剩余 %d 个）" % restarted2.get_node("Fx").get_child_count())

	# ---------- 20. 球速角度包络与防卡死 ----------
	# 「球在屏幕上横着弹来弹去」bug 的回归守卫。
	# 旧实现只有水平分量下限、没有垂直分量下限，砖块棱角会把垂直分量抹平：
	# 实测 93% 的帧处于水平 12° 以内、90% 的帧位移不足 0.5px（球卡死在砖块面上，
	# 速度被归一化成 (430, 0) 却一帧不动）。
	# 放在最后、用通关重开后的干净实例跑，避免这段长时间飞行影响前面各节的断言基线。
	if restarted2 != null:
		var env_ball: CharacterBody2D = restarted2.get_node("Ball") as CharacterBody2D
		var env_paddle: CharacterBody2D = restarted2.get_node("Paddle") as CharacterBody2D
		var env_consts: Dictionary = (env_ball.get_script() as GDScript).get_script_constant_map()
		var min_ang: float = float(env_consts.get("MIN_ANGLE_FROM_HORIZONTAL", 0.0))
		var max_ang: float = float(env_consts.get("MAX_ANGLE_FROM_HORIZONTAL", 0.0))
		var env_left: float = float(env_paddle.get("left_bound"))
		var env_right: float = float(env_paddle.get("right_bound"))
		var flat_frames := 0
		var frozen_frames := 0
		var sampled := 0
		var worst := 999.0
		var prev_ball_pos: Vector2 = env_ball.position
		for i in 400:
			env_paddle.position.x = clampf(env_ball.position.x, env_left, env_right)
			await physics_frame
			if not env_ball.is_physics_processing():
				break
			if bool(env_ball.get("attached_to_paddle")):
				env_ball.call("launch")
				prev_ball_pos = env_ball.position
				continue
			var v: Vector2 = env_ball.velocity
			if v.length_squared() < 0.001:
				prev_ball_pos = env_ball.position
				continue
			sampled += 1
			# 与水平面的夹角：0 = 纯水平，PI/2 = 纯垂直
			var angle := atan2(absf(v.y), absf(v.x))
			worst = minf(worst, minf(angle - min_ang, max_ang - angle))
			if angle < min_ang - 0.001 or angle > max_ang + 0.001:
				flat_frames += 1
			if prev_ball_pos.distance_to(env_ball.position) < 0.5:
				frozen_frames += 1
			prev_ball_pos = env_ball.position
		_check(min_ang > 0.0 and max_ang > min_ang,
			"Ball 定义了角度包络（%.2f ~ %.2f 弧度）" % [min_ang, max_ang])
		_check(sampled > 100, "角度包络检查采样到足够帧（%d 帧）" % sampled)
		_check(flat_frames == 0,
			"球速始终落在角度包络内，不会出现近平轨迹的横向来回弹（越界 %d 帧）" % flat_frames)
		_check(frozen_frames == 0,
			"球飞行中不会卡死在砖块面上（位移为 0 的帧 %d 帧）" % frozen_frames)
		# 钳制必须自洽：分量钳制后归一化会把分量缩回下限之下（实测 -0.0012 弧度），
		# 余量取「到两侧边界的距离最小值」，钳制生效时恰好为 0，因此只要求非负。
		_check(worst > -1e-6, "角度包络余量非负（最小余量 %.6f 弧度）" % worst)
		# 卡死脱离的落点必须落在砖墙下方的空场，否则脱离后立刻挤进下一行砖块
		var mc: Dictionary = (load(MAIN_SCRIPT) as GDScript).get_script_constant_map()
		var brick_size: Vector2 = mc.get("BRICK_SIZE", Vector2.ZERO)
		var wall_bottom: float = float(mc.get("BRICK_TOP", 0.0)) \
			+ (int(mc.get("BRICK_ROWS", 0)) - 1) * (brick_size.y + float(mc.get("BRICK_GAP", 0.0))) \
			+ brick_size.y
		var unstick_y: float = float(env_ball.get("unstick_y"))
		_check(unstick_y > wall_bottom and unstick_y < float(env_paddle.position.y),
			"卡死脱离落点在砖墙下方空场（%.1f > 砖墙底边 %.1f，且 < 挡板 %.1f）" % [
				unstick_y, wall_bottom, env_paddle.position.y])

	_finish()


func _finish() -> void:
	print("\n===== 冒烟测试结果：%d 项检查，%d 项失败 =====" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
