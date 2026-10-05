extends SceneTree
## 无头自动冒烟测试（可选验证工具，不参与正式游戏流程）。
## 运行方式：
##   godot --headless --path . --script res://tests/headless_smoke_test.gd
## 它会真实实例化 Main.tscn，模拟输入并校验：
## 移动/发射/碰撞/计分/掉命/暂停/关卡递进/通关/重开/最高分/多耐久砖块/挡板收窄/
## 退出按钮/音效与粒子与震动，以及 P0 手感三件套与 P1 的 6 种特殊砖 + 多球。
## 用例开头会清掉 user:// 存档，因此可以任意次连续运行（幂等）。
##
## 测试不写死任何来自游戏脚本的数值：State 枚举、砖块总数、每块砖分数、生命数、
## 关卡数、砖块耐久、挡板宽度阶梯、碰撞层位值、Brick.Kind 枚举、
## 特殊砖倍率表、同屏球数上限，全部从脚本常量与 project.godot 的 layer_names
## 反查得到，游戏侧改名或调数不会让测试静默失效。
##
## 用例分成两批，这个划分是必要的，不是随手切的：
## - 第 1~21 节测核心流程，跑在一面【全普通砖】的墙上（见 _degrade_special_bricks）。
##   爆破砖会连带清掉周围砖块、分裂砖会给场上加球，两者都会改动「砖数」「球数」
##   这些被时序断言盯着的量——前一节让球自由飞 400 帧，墙就可能在断言取样前
##   被连锁清空，或者多出来的球先掉光把生命扣掉。降级之后这些用例的时序假设
##   与 P1 之前完全一致，断言的强度没有被稀释。
## - 第 22 节用一个专用场景把六种特殊砖与 BallManager 的每条规则逐个打开验证。

const MAIN_SCENE := "res://scenes/Main.tscn"
const MAIN_SCRIPT := "res://scripts/main.gd"
const SFX_SCRIPT := "res://scripts/sfx.gd"
const BALL_SCRIPT := "res://scripts/ball.gd"
const BRICK_SCRIPT := "res://scripts/brick.gd"
const BALL_MANAGER_SCRIPT := "res://scripts/ball_manager.gd"
const GAME_MODE_SCRIPT := "res://scripts/game_mode.gd"
const LEVEL_GENERATOR_SCRIPT := "res://scripts/level_generator.gd"
const CARD_POOL_SCRIPT := "res://scripts/card_pool.gd"
const META_PROGRESS_SCRIPT := "res://scripts/meta_progress.gd"
const WALL_SCRIPT := "res://scripts/wall_shape_provider.gd"
const HEAT_SCRIPT := "res://scripts/heat_system.gd"
const FLOW_SCRIPT := "res://scripts/caught_ball_flow.gd"
const ABILITY_SCRIPT := "res://scripts/ability_system.gd"
const SAVE_PATH := "user://2d_breakout_save.cfg"
const PANEL_VBOX := "GameOverPanel/Panel/Margin/VBox"
const PAUSE_VBOX := "PausePanel/Panel/Margin/VBox"

# 运行期从脚本常量与项目设置绑定，见 _bind_constants()
var _state_playing := -1
var _state_paused := -1
var _state_game_over := -1
var _state_level_clear := -1
var _state_won := -1
## P3 引入的两个界面态：Menu（启动玩法菜单）与 Draft（三选一抽卡）
var _state_menu := -1
var _state_draft := -1
var _brick_total := 0
var _points_per_brick := 0
var _start_lives := 0
var _max_level := 0
var _wall_thickness := 0.0
var _view_width := 0.0
var _view_height := 0.0
var _view_center := Vector2.ZERO
var _layer_wall := 0
var _layer_paddle := 0
var _layer_brick := 0
var _layer_ball := 0
var _level_hits: Array = []
var _paddle_widths: Array = []
## —— P0 手感三件套 ——
var _charge_seconds := 0.0
var _charge_speed_mul := 0.0
var _max_charge_tilt := 0.0
var _aim_bounces := 0
var _combo_highlight := 0
var _combo_glow_at := 0
## —— P1 特殊砖与多球 ——
var _brick_layout: Array = []
var _kind_mult: Array = []
var _kinds: Dictionary = {}
var _kind_names: Array = []
var _blast_radius := 0.0
var _armor_extra_hits := 0
var _slow_scale := 0.0
var _slow_seconds := 0.0
var _split_spread_deg := 0.0
var _max_lives := 0
var _max_balls := 0
## —— P4 四个新玩法系统 ——
## 砖墙：形状轮廓表与「砖数恒为 TEMPLATE_TOTAL」这条不变量的验算口径
var _wall_script: GDScript = null
var _shape_profiles: Dictionary = {}
var _shape_none := 0
var _shape_count := 0
var _shape_from_level := 0
var _template_total := 0
var _wall_columns := 0
## 热度：档位倍率表（断言「倍率必须是整数」）与逐秒回落速度
var _heat_script: GDScript = null
var _heat_tier_mult: Array = []
var _heat_tier_step := 0.0
var _heat_decay := 0.0
var _heat_penalty_step := 0.0
var _heat_penalty_max := 0.0
## 接球：凝滞的时间倍率与时长（断言还原的是「按下那一刻的全局倍率」而非写死 1.0）
var _ability_script: GDScript = null
var _bullet_time_scale := 0.0
var _bullet_time_seconds := 0.0
var _flow_script: GDScript = null
var _main_script: GDScript = null
var _sfx_script: GDScript = null
var _ball_script: GDScript = null
var _brick_script: GDScript = null

var _checks := 0
var _fails := 0


func _initialize() -> void:
	Engine.time_scale = 4.0  # 加速物理，缩短测试时间
	_reset_save()
	_bind_constants()
	_run()


## 删除历史存档，保证“最高分”断言不受上一次运行影响，测试可重复执行。
## P3 的 MetaProgress 档案（每日最佳 / 连续天数）同样要清：
## 它的连续打卡天数是跨运行累加的，不清的话第二次跑的 streak 断言必然失准。
func _reset_save() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	for name in ["2d_breakout_save.cfg", _meta_file_name()]:
		if dir.file_exists(name):
			dir.remove(name)
	_meta_progress().forget_cache()


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
	_state_menu = int(states.get("MENU", -1))
	_state_draft = int(states.get("DRAFT", -1))
	_brick_total = int(consts.get("BRICK_TOTAL", 0))
	_points_per_brick = int(consts.get("POINTS_PER_BRICK", 0))
	_start_lives = int(consts.get("START_LIVES", 0))
	_max_level = int(consts.get("MAX_LEVEL", 0))
	var view: Vector2 = consts.get("VIEW_SIZE", Vector2.ZERO)
	_view_width = view.x
	_view_height = view.y
	_view_center = view * 0.5
	_wall_thickness = float(consts.get("WALL_THICKNESS", 0.0))
	_level_hits = consts.get("LEVEL_BRICK_HITS", [])
	_paddle_widths = consts.get("PADDLE_WIDTH_STEPS", [])
	_charge_seconds = float(consts.get("CHARGE_SECONDS", 0.0))
	_charge_speed_mul = float(consts.get("CHARGE_SPEED_MUL", 0.0))
	_max_charge_tilt = float(consts.get("MAX_CHARGE_TILT", 0.0))
	_aim_bounces = int(consts.get("AIM_BOUNCES", 0))
	_combo_highlight = int(consts.get("COMBO_HIGHLIGHT", 0))
	_combo_glow_at = int(consts.get("COMBO_GLOW_AT", 0))
	_main_script = script
	_sfx_script = load(SFX_SCRIPT) as GDScript
	_ball_script = load(BALL_SCRIPT) as GDScript
	_brick_script = load(BRICK_SCRIPT) as GDScript

	# —— P1：布局表、倍率表、爆破/减速/分裂参数全部从脚本常量反查 ——
	_brick_layout = consts.get("BRICK_LAYOUT", [])
	_kind_mult = consts.get("KIND_POINTS_MULT", [])
	_blast_radius = float(consts.get("BLAST_RADIUS", 0.0))
	_armor_extra_hits = int(consts.get("ARMOR_EXTRA_HITS", 0))
	_slow_scale = float(consts.get("SLOW_SPEED_SCALE", 0.0))
	_slow_seconds = float(consts.get("SLOW_SECONDS", 0.0))
	_split_spread_deg = float(consts.get("SPLIT_SPREAD_DEG", 0.0))
	_max_lives = int(consts.get("MAX_LIVES", 0))
	if _brick_script != null:
		var bconsts: Dictionary = _brick_script.get_script_constant_map()
		_kinds = bconsts.get("Kind", {})
		_kind_names = bconsts.get("KIND_NAMES", [])
	if _ball_manager_script() != null:
		_max_balls = int(_ball_manager_script().get_script_constant_map().get("MAX_BALLS", 0))

	# —— P4：四个新系统的常量同样从各自的属主脚本反查 ——
	# 不从 main.god 取：main.gd 里那些是转发别名（const X := WallShapeProvider.X），
	# 读别名等于让测试验证「别名指向了别名的值」，绕一圈却没验到真正的定义。
	_bind_p4_constants()


## P4 常量绑定。单独一个函数是因为它们来自四个不同脚本，
## 塞进 _bind_constants 里会让人得往回翻才知道「这段在读谁的常量」。
func _bind_p4_constants() -> void:
	_wall_script = load(WALL_SCRIPT) as GDScript
	if _wall_script != null:
		var wc: Dictionary = _wall_script.get_script_constant_map()
		_shape_profiles = wc.get("SHAPE_PROFILES", {})
		_shape_none = int(wc.get("SHAPE_NONE", 0))
		_shape_count = int(wc.get("SHAPE_COUNT", 0))
		_shape_from_level = int(wc.get("SHAPE_FROM_LEVEL", 0))
		_wall_columns = int(wc.get("COLUMNS", 0))
		_template_total = int(wc.get("TEMPLATE_TOTAL", 0))
	_heat_script = load(HEAT_SCRIPT) as GDScript
	if _heat_script != null:
		var hc: Dictionary = _heat_script.get_script_constant_map()
		_heat_tier_mult = hc.get("HEAT_TIER_MULT", [])
		_heat_tier_step = float(hc.get("HEAT_TIER_STEP", 0.0))
		_heat_decay = float(hc.get("HEAT_DECAY_PER_SECOND", 0.0))
		_heat_penalty_step = float(hc.get("HEAT_PENALTY_STEP_PX", 0.0))
		_heat_penalty_max = float(hc.get("HEAT_PENALTY_MAX_PX", 0.0))
	_flow_script = load(FLOW_SCRIPT) as GDScript
	_ability_script = load(ABILITY_SCRIPT) as GDScript
	if _ability_script != null:
		var ac: Dictionary = _ability_script.get_script_constant_map()
		_bullet_time_scale = float(ac.get("BULLET_TIME_SCALE", 1.0))
		_bullet_time_seconds = float(ac.get("BULLET_TIME_SECONDS", 0.0))


## ball_manager.gd 的脚本对象。第 22 节要读 MAX_BALLS，
## 放在函数里而不是缓存成字段：同屏球数上限归 BallManager 所有，
## Main 里没有第二份副本，不缓存是为了逼测试每次都从真实来源取。
func _ball_manager_script() -> GDScript:
	return load(BALL_MANAGER_SCRIPT) as GDScript


## main.gd 的 GameMode.Mode.CLASSIC。用来给 _start_classic 传参，
## 同样不写字面数字 0 —— 玩法枚举一旦重排，写死的 0 就指到别的模式上去了。
func _mode_classic() -> int:
	var game_mode := load(GAME_MODE_SCRIPT) as GDScript
	if game_mode == null:
		return 0
	return int((game_mode.get_script_constant_map().get("Mode", {}) as Dictionary).get("CLASSIC", 0))


## 让场景离开玩法菜单、以经典模式开打，返回是否成功。
##
## P3 之后游戏启动时落在玩法菜单上（经典 / 无尽 / 每日三选一），
## 所以任何要断言「Playing 态下发生了什么」的用例都得先走过这一步。
##
## 这里调 Main._begin_run 而不是模拟按键：输入管线带一帧缓冲，
## 而 _begin_run 是同步的——每处插一次"送 launch + 等若干帧"会让整套用例
## 多出一批与被测逻辑无关的时序假设。菜单**按钮**点击路径由第 23 节单独验证，
## 那里才是真正该覆盖交互的地方。
func _start_classic(scene: Node) -> bool:
	if scene == null:
		return false
	if not scene.has_method("_begin_run"):
		push_error("Main 缺少 _begin_run，无法越过玩法菜单")
		return false
	scene.call("_begin_run", _mode_classic())
	return true


## 主球。球不再挂在 Main 下而是归 Balls(BallManager) 所有，
## 所以测试不能自己拼节点路径——路径是实现细节，primary() 才是契约。
func _balls(scene: Node) -> BallManager:
	return scene.get_node("Balls") as BallManager


## 取某个 kind 的枚举值。测试里不写字面数字：Brick.Kind 一旦重排，
## 写死的 4 就指向另一种砖，断言会「通过」但验的根本不是爆破砖。
func _kind(name: String) -> int:
	return int(_kinds.get(name, -1))


## 某关的标准砖块耐久（第 2 节的降级与第 14 节的期望值共用同一份口径）。
func _base_hits_for_level(level: int) -> int:
	if _level_hits.is_empty():
		return 1
	return int(_level_hits[(level - 1) % _level_hits.size()])


## 把场上所有特殊砖临时降级成普通砖（分数与耐久一并还原），返回改动块数。
##
## 理由见文件头：爆破砖会连带清掉周围砖块、分裂砖会给场上加球，
## 两者都会改动「砖数」「球数」这两个被时序断言盯着的量。
## 降级必须把 points / max_hits 一起还原成普通砖的值，否则加固砖多出来的
## 2 点耐久会让「分数 == 砖数 × 每块砖分值」这类算术断言在旧用例里失准。
func _degrade_special_bricks(bricks_root: Node2D, base_hits: int) -> int:
	var changed := 0
	for child in bricks_root.get_children():
		var brick := child as Brick
		if brick == null or not brick.is_special():
			continue
		brick.kind = Brick.Kind.NORMAL
		brick.points = _points_per_brick
		brick.max_hits = base_hits
		brick.hits_left = base_hits
		changed += 1
	return changed


## 清掉场上除主球以外的所有副球，返回清掉的数量。
## 用球自己的 fell_out_of_playfield 信号来回收，而不是 queue_free()：
## BallManager 只在该信号里维护 _extras，直接 free 会让它的计数与现实脱节，
## 后面所有关于球数的断言都会读到脏值。
func _drop_extra_balls(scene: Node) -> int:
	var balls := _balls(scene)
	var dropped := 0
	for extra in balls.all_balls():
		if extra == balls.primary():
			continue
		extra.emit_signal("fell_out_of_playfield")
		dropped += 1
	await _wait(2)
	return dropped


## 连击奖励公式直接问 main.gd 要，测试里不维护副本。
## 走 static 调用而不是抄公式：抄一份的话，改公式的提交会让断言静默变成"错误的期望"。
func _combo_bonus_for(combo: int) -> int:
	if _main_script == null or not _main_script.has_method("combo_bonus_for"):
		return 0
	return int(_main_script.call("combo_bonus_for", combo))


## main.gd 上的脚本常量。同一个来源取同一个值，避免各处再抄一遍名字。
func _main_const(name: String, fallback: Variant = null) -> Variant:
	if _main_script == null:
		return fallback
	return _main_script.get_script_constant_map().get(name, fallback)


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
##
## 必须同时补上 release：发射是「按住蓄力、松手打出去」，
## 只送按下的话球会一直停在蓄力态（_charging 永为真），后续所有“球在飞行”的断言全废。
func _send_action(action: StringName) -> void:
	_hold_action(action)
	_release_action(action)


## 只送按下，用于蓄力相关用例（「按住空格」这个中间态需要单独可达）。
##
## 两个动作缺一不可，而且不会互相重复（两条路径实测行为不同，踩过坑）：
## - Input.action_press 只更新 Input 的内部动作状态，Input.get_axis / is_action_pressed
##   才读得到，但它【不会】把事件派发给 _input / _unhandled_input。
##   只用它的话：方向键「按住了」可挡板纹丝不动，游戏自己的输入入口也收不到。
## - Input.parse_input_event(InputEventAction) 只派发事件，不更新动作状态。
##   只用它的话：游戏收得到 launch，可 Input.get_axis 恒为 0（幽灵输入）。
func _hold_action(action: StringName) -> void:
	Input.action_press(action, 1.0)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	event.strength = 1.0
	Input.parse_input_event(event)


## 只送松开，配对 _hold_action 使用。
func _release_action(action: StringName) -> void:
	Input.action_release(action)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = false
	event.strength = 0.0
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

	# P3：启动后先落在玩法菜单上，先选经典模式进入 Playing 态。
	_check(_state_menu >= 0, "main.gd 声明了 Menu 状态（启动界面）")
	_check(_state_draft >= 0, "main.gd 声明了 Draft 状态（三选一抽卡）")
	_check(bool(scene.get_node("MenuPanel/Panel").visible), "启动即打开玩法菜单")
	_check(_gi(scene, "_state") == _state_menu, "菜单态下 Main 处于 Menu 状态")
	_check(not bool(scene.get_node("Paddle").get("input_enabled")),
		"菜单期间挡板不可操控（否则在菜单上按方向键会把背景挡板推走）")
	_check(_start_classic(scene), "调用 _begin_run 进入经典模式")
	await _wait(2)
	_check(_gi(scene, "_state") == _state_playing, "选定玩法后回到 Playing 状态")
	_check(not scene.get_node("MenuPanel/Panel").visible, "玩法菜单收起")
	_check(bool(scene.get_node("Paddle").get("input_enabled")), "开局挡板恢复可操控")

	var paddle: CharacterBody2D = scene.get_node("Paddle")
	var balls: BallManager = _balls(scene)
	var ball: Ball = balls.primary()
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
	# P1 之后的墙含有特殊砖，这里就地降级成全普通砖墙——理由见文件头，
	# 六种特殊砖的真实行为由第 22 节单独验证。放在第 1 节断言之后，
	# 是为了让「砖块总数 / 初始状态」这几条仍然断言真正的初始布局。
	_check(_degrade_special_bricks(bricks, _base_hits_for_level(1)) > 0,
		"第 1~21 节把特殊砖降级为普通砖（含分数与耐久还原）")

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
	var ball2: Ball = ball
	var fx_before: int = fx_root.get_child_count()
	ball2.brick_hit.emit(bricks.get_child(0))
	await _wait(2)
	var fx_after: int = fx_root.get_child_count()
	_check(fx_after > fx_before, "击破砖块时在 Fx 下生成碎屑粒子（%d -> %d）" % [fx_before, fx_after])
	var burst: Node = fx_root.get_child(fx_root.get_child_count() - 1)
	# 只断言「本次生成的是一次性粒子」而不是「Fx 的最后一个子节点就是它」：
	# P1 之后爆破砖还会在 Fx 里同时挂冲击波节点，节点顺序不该被这条用例锁死。
	var has_burst := false
	for fx_child in fx_root.get_children():
		if fx_child is CPUParticles2D and bool(fx_child.get("one_shot")):
			has_burst = true
			break
	_check(has_burst, "碎屑是一次性(one_shot) CPUParticles2D")
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
	# 重开是整场景重载，新实例停在玩法菜单上，挡板此时刻意不可操控
	# （在菜单上按方向键会把背景挡板推走）。恢复可操控由下一节断言。
	_check(_gi(restarted, "_state") == _state_menu, "重开后重新停在玩法菜单上")
	_check(not bool(restarted.get_node("Paddle").get("input_enabled")),
		"菜单态下挡板不可操控")
	_check(restarted.get_node("Bricks").get_child_count() == _brick_total,
		"重开后砖墙重新生成（%d 块）" % restarted.get_node("Bricks").get_child_count())
	_check(absf(_gf(restarted.get_node("Paddle"), "paddle_width") - float(_paddle_widths[0])) < 0.01,
		"重开后挡板恢复初始宽度（%.1f）" % _gf(restarted.get_node("Paddle"), "paddle_width"))

	# ---------- 13. 关卡递进：清空砖墙先进入“关卡通过”，不是直接结束 ----------
	# 重开是整场景重载，新场景同样停在玩法菜单上，得再选一次经典模式
	_check(_start_classic(restarted), "重载后的新场景重新选定经典模式")
	await _wait(2)
	_check(_gi(restarted, "_state") == _state_playing, "重开后回到 Playing 状态")
	_check(bool(restarted.get_node("Paddle").get("input_enabled")), "选定玩法后挡板恢复可操控")
	# 重开是整场景重载，墙是重新生成的，得再降级一次（文件头说明了为什么）
	_degrade_special_bricks(restarted.get_node("Bricks") as Node2D, _base_hits_for_level(1))
	var bricks3: Node2D = restarted.get_node("Bricks")
	var ball3: Ball = _balls(restarted).primary()
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
	# 进入第 2 关同样要重降级，否则第 14/15 节会在含爆破砖的墙上取样
	_degrade_special_bricks(restarted.get_node("Bricks") as Node2D, _base_hits_for_level(2))
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
	var hits_expected: int = _base_hits_for_level(2)
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
	# 这一击之前还挂着未入账的连击（14b 节一连打掉了很多块）。
	# 结算时 Main 会把它折算成额外分数入账，所以期望值必须把连击奖励算进去——
	# 公式直接复用 main.gd 的静态函数，测试里不抄第二份副本。
	var combo_before_win: int = _gi(restarted, "_combo")
	ball3.brick_hit.emit(last_bricks.get_child(0))
	ball3.brick_hit.emit(last_bricks.get_child(1))
	await _wait(3)
	_check(_gi(restarted, "_state") == _state_won, "最后一关同一帧击破最后两块砖也进入通关状态")
	var win_expected := score_before_win + 2 * _points_per_brick \
		+ _combo_bonus_for(combo_before_win + 2)
	_check(_gi(restarted, "_score") == win_expected,
		"通关时两块砖都计分，未入账连击同时折算入账（%d -> %d，期望 %d）"
		% [score_before_win, _gi(restarted, "_score"), win_expected])
	_check(_gi(restarted, "_combo") == 0, "通关结算后待结算连击清零")
	_check(restarted.get_node("GameOverPanel/Panel").visible, "显示通关结算面板")
	_check(restarted.get_node(PANEL_VBOX + "/TitleLabel").text == "通关！",
		"结算面板标题切换为“通关！”")
	_check(restarted.get_node("HUD/HintLabel").text.contains("通关"),
		"通关后 HUD 底部提示同步更新（%s）" % restarted.get_node("HUD/HintLabel").text)
	_check(not bool(_balls(restarted).primary().get("visible")), "通关后球停止运动并隐藏")

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
		# 这个实例同样是重载出来的，一样停在菜单上
		_start_classic(restarted2)
		await _wait(2)
		_degrade_special_bricks(restarted2.get_node("Bricks") as Node2D,
			_base_hits_for_level(_gi(restarted2, "_level")))
		var env_ball: Ball = _balls(restarted2).primary()
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

	# ---------- 21. P0 手感三件套：蓄力发射 / 预测线 / 连击 / 换肤 ----------
	# 放最后，且【自己 new 一个场景】，不复用 restarted2：
	# 上一节让球飞了 400 帧，实例很可能已经掉光生命进入 GAME_OVER。
	# 而 GAME_OVER 下按 launch 走的是「结算后重开」分支（_on_continue_requested），
	# 蓄力根本不会被触发，缓存下来的节点引用也全部指向被释放的旧场景。
	var p0_scene: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(p0_scene)
	await _wait(3)
	_start_classic(p0_scene)
	await _wait(2)
	_check(_gi(p0_scene, "_state") == _state_playing,
		"P0 用例的专用场景处于 Playing 态（%d）" % _gi(p0_scene, "_state"))
	await _finish_p0_suite(p0_scene)


## —— 第 22 节：P1 六种特殊砖 + 多球 ——
## 单独 new 一个场景，不复用前面任何实例：这一节要主动破坏砖墙与球数，
## 复用会直接踩到第 15 节「最后两块砖判通关」与第 20 节「球速角度包络」的基线。
func _finish_p1_suite() -> void:
	var scene: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	await _wait(3)
	await _run_p1_suite(scene)
	scene.queue_free()
	await _wait(2)
	await _finish_p3_suite()


func _run_p1_suite(scene: Node) -> void:
	_start_classic(scene)
	await _wait(2)
	var bricks: Node2D = scene.get_node("Bricks")
	var balls: BallManager = _balls(scene)
	var ball: Ball = balls.primary()
	var base_hits := _base_hits_for_level(1)
	var k_normal := _kind("NORMAL")
	var k_armored := _kind("ARMORED")
	var k_life := _kind("LIFE")
	var k_bonus := _kind("BONUS")
	var k_boom := _kind("EXPLOSIVE")
	var k_split := _kind("SPLIT")
	var k_slow := _kind("SLOW")

	# ---------- 22a. 三张 kind 表与布局表自洽 ----------
	_check(k_normal == 0,
		"Brick.Kind.NORMAL 仍是 0（布局表写的是字面数字，序号不能重排）")
	_check(_kinds.size() == 7 and _kind_names.size() == _kinds.size() and _kind_mult.size() == _kinds.size(),
		"Brick.Kind / KIND_NAMES / KIND_POINTS_MULT 三张表等长（%d / %d / %d）"
		% [_kinds.size(), _kind_names.size(), _kind_mult.size()])
	var mult_ok := true
	for m in _kind_mult:
		if float(m) != roundf(float(m)) or int(m) < 1:
			mult_ok = false
	_check(mult_ok,
		"KIND_POINTS_MULT 全为 >= 1 的整数（否则会打破「总分是每块砖分值整数倍」的不变量）")
	_check(_armor_extra_hits >= 1 and _blast_radius > 0.0 and _slow_scale > 0.0 and _slow_scale < 1.0
			and _slow_seconds > 0.0 and _split_spread_deg > 0.0 and _max_balls >= 2
			and _max_lives >= _start_lives,
		"加固耐久 / 爆破半径 / 减速倍率与时长 / 分裂夹角 / 同屏上限 / 生命上限均为有效值")

	var rows: int = _brick_layout.size()
	var cols: int = int((_brick_layout[0] as Array).size()) if rows > 0 else 0
	_check(rows == int(_main_const("BRICK_ROWS", 0)) and cols == int(_main_const("BRICK_COLUMNS", 0)),
		"BRICK_LAYOUT 尺寸与 BRICK_ROWS / BRICK_COLUMNS 一致（%d × %d）" % [rows, cols])
	var bad_kind := 0
	var ragged := 0
	for r in rows:
		var row: Array = _brick_layout[r] as Array
		if row.size() != cols:
			ragged += 1
		for k in row:
			if int(k) < 0 or int(k) >= _kinds.size():
				bad_kind += 1
	_check(ragged == 0 and bad_kind == 0,
		"布局表每行等长且每个取值都落在 Brick.Kind 范围内（不齐 %d 行，越界 %d 项）" % [ragged, bad_kind])
	var first_row_clean := true
	for k in (_brick_layout[0] as Array):
		if int(k) != k_normal:
			first_row_clean = false
	var last_row: Array = _brick_layout[rows - 1] as Array
	_check(first_row_clean and int(last_row[cols - 2]) == k_normal and int(last_row[cols - 1]) == k_normal,
		"第 1 行整行与末行末两位都是普通砖（第 14 / 15 节的断言锚点）")

	# ---------- 22b. 真实砖墙与布局表逐格对得上 ----------
	var built: Array = bricks.get_children()
	var kind_bad := 0
	var points_bad := 0
	var hits_bad := 0
	for i in built.size():
		var kind: int = int(_brick_layout[i / cols][i % cols])
		var b := built[i] as Brick
		if int(b.kind) != kind:
			kind_bad += 1
		if b.points != _points_per_brick * int(_kind_mult[kind]):
			points_bad += 1
		var want_hits := base_hits + (_armor_extra_hits if kind == k_armored else 0)
		if b.max_hits != want_hits:
			hits_bad += 1
	_check(built.size() == rows * cols and kind_bad == 0,
		"运行时生成的 %d 块砖逐格对上 BRICK_LAYOUT 的 kind（错位 %d 块）" % [built.size(), kind_bad])
	_check(points_bad == 0,
		"每块砖的分数 == 每块砖分值 × 对应 kind 的倍率（错 %d 块）" % points_bad)
	_check(hits_bad == 0,
		"只有加固砖的耐久高于本关标准（错 %d 块，标准 %d + 加固 %d）"
		% [hits_bad, base_hits, _armor_extra_hits])

	var present := {}
	for child in built:
		present[int((child as Brick).kind)] = true
	var absent: Array = []
	for key: String in _kinds:
		if int(_kinds[key]) != k_normal and not present.has(int(_kinds[key])):
			absent.append(key)
	_check(absent.is_empty(), "第 1 关真实覆盖全部 6 种特殊砖（缺 %s）" % str(absent))

	var expected_names: Array[String] = []
	for r in rows:
		for k in (_brick_layout[r] as Array):
			if int(k) == k_normal:
				continue
			var nm := String(_kind_names[int(k)])
			if not expected_names.has(nm):
				expected_names.append(nm)
	_check(String(scene.call("_level_legend")) == " · ".join(expected_names),
		"结算图例按行优先去重列出本关特殊砖（%s）" % " · ".join(expected_names))

	# ---------- 22c. 结算面板的图例行（带默认参数，老调用方不受影响） ----------
	var legend_row: Label = scene.get_node_or_null(PANEL_VBOX + "/LegendLabel") as Label
	_check(legend_row != null and not legend_row.visible, "结算面板带图例行且默认隐藏")
	(scene.get_node("GameOverPanel") as GameOverPanel).show_result(
		0, 0, false, _state_game_over, 1, 0, 0, null, "特殊砖 " + " · ".join(expected_names))
	await _wait(2)
	_check(legend_row != null and legend_row.visible
			and legend_row.text == "特殊砖 " + " · ".join(expected_names),
		"传入图例后结算面板显示特殊砖图例行（%s）" % legend_row.text)
	(scene.get_node("GameOverPanel") as GameOverPanel).show_result(0, 0, false, _state_game_over)
	await _wait(2)
	_check(not legend_row.visible, "不传图例时 show_result() 退回旧行为（图例行保持隐藏）")

	# ---------- 22d. 加固砖：耐久高于本关标准 ----------
	var staged := await _stage_bricks(scene, [[k_armored, Vector2(240.0, 200.0)]])
	var armor: Brick = staged[0]
	_check(armor.is_special() and armor.max_hits == base_hits + _armor_extra_hits,
		"加固砖耐久 = 本关标准 %d + %d（实际 %d）" % [base_hits, _armor_extra_hits, armor.max_hits])
	_freeze_ball_physics(balls)
	var score_before: int = _gi(scene, "_score")
	var armor_points: int = armor.points
	ball.brick_hit.emit(armor)
	await _wait(2)
	_check(_gi(scene, "_score") == score_before + armor_points, "加固砖受击同样计分（%d 分）" % armor_points)
	_check(_gi(scene, "_bricks_cleared") == 0 and int(armor.get("hits_left")) > 0,
		"加固砖没打透就不消失、也不计入清除数")
	for i in _armor_extra_hits:
		ball.brick_hit.emit(armor)
	await _wait(2)
	_check(not is_instance_valid(armor) and _gi(scene, "_bricks_cleared") == 1,
		"加固砖挨满 %d 次额外受击后碎掉并计入清除数" % _armor_extra_hits)

	# ---------- 22e. 分数砖：倍率最高，但只是分多 ----------
	staged = await _stage_bricks(scene, [[k_bonus, Vector2(240.0, 200.0)]])
	var bonus: Brick = staged[0]
	var bonus_points: int = bonus.points
	score_before = _gi(scene, "_score")
	ball.brick_hit.emit(bonus)
	await _wait(2)
	# 注意：分数必须在击破前取出来。砖被 queue_free 后再读它的字段，
	# 拿到的是「previously freed」，整条断言会被静默跳过——那正是这条检查最不该出的错法。
	_check(_gi(scene, "_score") == score_before + bonus_points,
		"分数砖按自身倍率计分（%d 分）" % bonus_points)
	_check(bonus_points == _points_per_brick * _max_kind_mult(),
		"分数砖倍率是全表最高（×%d）" % _max_kind_mult())
	_check(_gi(scene, "_lives") == _start_lives and balls.count() == 1,
		"分数砖不额外改生命或球数")

	# ---------- 22f. 生命砖：+1 但封顶 ----------
	scene.set("_lives", _max_lives - 1)
	staged = await _stage_bricks(scene, [[k_life, Vector2(240.0, 200.0)]])
	var life_points: int = (staged[0] as Brick).points
	ball.brick_hit.emit(staged[0])
	await _wait(2)
	_check(_gi(scene, "_lives") == _max_lives, "生命砖把生命补到上限 %d（实际 %d）"
		% [_max_lives, _gi(scene, "_lives")])
	staged = await _stage_bricks(scene, [[k_life, Vector2(240.0, 200.0)]])
	life_points = (staged[0] as Brick).points
	score_before = _gi(scene, "_score")
	ball.brick_hit.emit(staged[0])
	await _wait(2)
	_check(_gi(scene, "_lives") == _max_lives, "生命已满时再吃生命砖不加命（上限 %d）" % _max_lives)
	_check(_gi(scene, "_score") == score_before + life_points,
		"生命已满时生命砖照样计分（不打断连击节奏）")

	# ---------- 22g. 爆破砖：半径内波及、半径外不波及 ----------
	# 邻居按「刚好在半径的 0.5 / 1.5 倍处」摆，期望值是手算的，不靠复算游戏算法
	staged = await _stage_bricks(scene, [
		[k_boom, Vector2(240.0, 200.0)],
		[k_normal, Vector2(240.0 + _blast_radius * 0.5, 200.0)],
		[k_normal, Vector2(240.0, 200.0 - _blast_radius * 0.5)],
		[k_normal, Vector2(240.0 + _blast_radius * 1.5, 200.0)],
	])
	var center: Brick = staged[0]
	var inside_h: Brick = staged[1]
	var inside_v: Brick = staged[2]
	var outside: Brick = staged[3]
	# 存下坐标与耐久：被波及的三块砖在下一条断言前就已被 queue_free，
	# 而半径外那块还活着，可以直接读
	var outside_at: Vector2 = outside.position
	var outside_hits: int = outside.max_hits
	var blast_expected: int = center.points + inside_h.points + inside_v.points
	_freeze_ball_physics(balls)
	score_before = _gi(scene, "_score")
	ball.brick_hit.emit(center)
	await _wait(2)
	var wave_shown := false
	for fx_child in (scene.get_node("Fx") as Node2D).get_children():
		if fx_child is BlastWave:
			wave_shown = true
	_check(wave_shown, "爆破砖击破时在 Fx 下生成冲击波")
	_check(not is_instance_valid(inside_h) and not is_instance_valid(inside_v),
		"爆破半径 0.5 倍处的两个邻居被清掉")
	_check(is_instance_valid(outside) and int(outside.get("hits_left")) == outside_hits,
		"爆破半径 1.5 倍处的砖毫发无损（distance %.1f > %.1f）"
		% [Vector2(240.0, 200.0).distance_to(outside_at), _blast_radius])
	_check(_gi(scene, "_score") == score_before + blast_expected,
		"爆破得分 = 波及到的每块砖的分值之和（+%d）" % blast_expected)
	_check(_gi(scene, "_bricks_cleared") == 3 and (bricks as Node2D).get_child_count() == 1,
		"爆破把 3 块砖计入清除数（含半径外的存活者，实际剩余 %d 块）"
		% (bricks as Node2D).get_child_count())
	_check(_gi(scene, "_score") % _points_per_brick == 0,
		"爆破波及后的总分仍是每块砖分值的整数倍")

	# ---------- 22h. 爆破连锁 ----------
	staged = await _stage_bricks(scene, [
		[k_boom, Vector2(240.0, 200.0)],
		[k_boom, Vector2(240.0 + _blast_radius * 0.5, 200.0)],
		[k_normal, Vector2(240.0 + _blast_radius * 1.4, 200.0)],
		[k_normal, Vector2(240.0 + _blast_radius * 2.2, 200.0)],
	])
	_freeze_ball_physics(balls)
	ball.brick_hit.emit(staged[0])
	await _wait(3)
	_check(not is_instance_valid(staged[0]) and not is_instance_valid(staged[1]),
		"连锁的第一环：正中心的砖与 0.5 倍处的第二颗炸弹都被清掉")
	_check(not is_instance_valid(staged[2]),
		"连锁的第二环：第二颗炸弹把离中心 1.4 倍、离自己 0.9 倍处的砖也炸掉")
	_check(is_instance_valid(staged[3]), "隔得够远的砖在两环波及之外")
	_check(_gi(scene, "_bricks_cleared") == 3,
		"一次连锁按波及到的砖数逐块计入清除数（%d）" % _gi(scene, "_bricks_cleared"))

	# ---------- 22i. 波及不触发被波及砖自身的效果（否则可无限刷球/刷命） ----------
	scene.set("_lives", 2)
	staged = await _stage_bricks(scene, [
		[k_boom, Vector2(240.0, 200.0)],
		[k_split, Vector2(240.0 + _blast_radius * 0.5, 200.0)],
		[k_life, Vector2(240.0, 200.0 - _blast_radius * 0.5)],
	])
	_freeze_ball_physics(balls)
	ball.brick_hit.emit(staged[0])
	await _wait(3)
	_check(balls.count() == 1, "被波及清掉的分裂砖不额外弹球（仍是 %d 颗）" % balls.count())
	_check(_gi(scene, "_lives") == 2, "被波及清掉的生命砖不额外加命")

	# ---------- 22j. 分裂砖：新球方向与出场位置 ----------
	staged = await _stage_bricks(scene, [[k_split, Vector2(240.0, 300.0)]])
	var split_brick: Brick = staged[0]
	_freeze_ball_physics(balls)
	ball.set("attached_to_paddle", false)
	ball.velocity = Vector2(300.0, -300.0)
	var heading := Vector2(300.0, -300.0).normalized()
	var expected_dir := heading.rotated(deg_to_rad(_split_spread_deg))
	var expected_at := Vector2(split_brick.position.x, split_brick.position.y + split_brick.size.y * 0.5 + 6.0)
	var split_points: int = split_brick.points
	var points_before_split: int = _gi(scene, "_score")
	ball.brick_hit.emit(split_brick)
	# 同步读：信号派发是同步的，这一刻新球还在生成点上，一个物理帧都没走
	var spawned: Array[Ball] = balls.all_balls()
	var new_ball: Ball = spawned[spawned.size() - 1]
	var dir_error := new_ball.velocity.normalized().angle_to(expected_dir)
	var at_error := new_ball.global_position.distance_to(expected_at)
	_freeze_ball_physics(balls)
	await _wait(2)
	_check(balls.count() == 2, "分裂砖把场上球数从 1 变成 %d" % balls.count())
	_check(not bool(new_ball.get("attached_to_paddle")),
		"新球出厂即发射（不是吸附在挡板上）")
	_check(dir_error < 0.01, "新球方向 = 原球方向偏开 %.0f°（实际偏差 %.4f 弧度）"
		% [_split_spread_deg, dir_error])
	_check(at_error < 1.0, "新球从砖块下沿生成（位置偏差 %.2f px）" % at_error)
	_check(_gi(scene, "_score") == points_before_split + split_points,
		"分裂砖自身照样计分")
	var balls_label: Label = scene.get_node("HUD/BallsLabel") as Label
	_check(balls_label.visible and balls_label.text == "球 ×%d" % balls.count(),
		"HUD 同步显示球数（%s）" % balls_label.text)

	# ---------- 22k. 同屏球数上限 ----------
	var guard := 0
	while balls.count() < _max_balls and guard < _max_balls + 2:
		guard += 1
		var more := await _stage_bricks(scene, [[k_split, Vector2(240.0, 300.0)]])
		ball.brick_hit.emit(more[0])
		_freeze_ball_physics(balls)
		await _wait(1)
	_check(balls.count() == _max_balls,
		"连续吃分裂砖能把球数补到上限 %d（实际 %d）" % [_max_balls, balls.count()])
	staged = await _stage_bricks(scene, [[k_split, Vector2(240.0, 300.0)]])
	var capped_points: int = (staged[0] as Brick).points
	score_before = _gi(scene, "_score")
	ball.brick_hit.emit(staged[0])
	await _wait(2)
	_check(balls.count() == _max_balls,
		"达到上限后再打分裂砖不再加球（仍为 %d 颗）" % balls.count())
	_check(_gi(scene, "_score") == score_before + capped_points,
		"上限下分裂砖仍然计分")
	_check(_gi(scene, "_state") == _state_playing, "满屏 8 球也没有误判通关或结算")

	# ---------- 22l. 减速砖：全场降速 + 到点自动恢复 ----------
	# 先把上一小节攒满的 7 颗副球清掉：满屏状态下再断言「新球以减速状态出场」，
	# 拿到的只会是 spawn_extra 的 null，测的就不是减速规则而是球数上限了。
	_check(await _drop_extra_balls(scene) > 0, "先清空上一小节攒下的副球")
	staged = await _stage_bricks(scene, [[k_slow, Vector2(240.0, 200.0)]])
	var base_speed := _gf(balls, "ball_speed")
	_freeze_ball_physics(balls)
	ball.brick_hit.emit(staged[0])
	await _wait(2)
	_check(_gi(scene, "_slow_left") > 0.0, "减速砖开出一个正数的倒计时")
	_check(absf(_gf(balls, "speed_scale") - _slow_scale) < 0.001
			and all_frozen_slow(balls, _slow_scale),
		"场上全部 %d 颗球都被压到 ×%.2f" % [balls.count(), _slow_scale])
	_check(_gf(balls, "ball_speed") == base_speed,
		"减速只改倍率、不改本关基准速率（否则倍率恢复后球会永久变慢）")
	var hinted := String(scene.get_node("HUD/HintLabel").text)
	_check(hinted.contains("减速") and hinted.contains("%.1f" % _slow_seconds),
		"HUD 提示写明减速剩余时间（%s）" % hinted)
	# 减速期间分裂出来的球也必须带减速，否则规则自相矛盾
	var born_slow := balls.spawn_extra(Vector2(120.0, 300.0), Vector2(0.4, -1.0))
	_freeze_ball_physics(balls)
	_check(born_slow != null and absf(_gf(born_slow, "speed_scale") - _slow_scale) < 0.001,
		"减速期间新生成的球也以减速状态出场")
	# SLOW_SECONDS 游戏秒 / time_scale 4 = 四分之一真实秒，等它自然走完
	await _wait(int(ceil(_slow_seconds * 60.0 / Engine.time_scale)) + 12)
	_check(_gi(scene, "_slow_left") == 0.0
			and absf(_gf(balls, "speed_scale") - 1.0) < 0.001
			and all_frozen_slow(balls, 1.0),
		"倒计时走完后全场球速自动恢复 ×1.00")
	_check(absf(_gf(ball, "speed") - base_speed) < 0.001
			and absf(float(ball.call("effective_speed")) - base_speed) < 0.001,
		"恢复后的实际速率回到本关基准值 %.1f" % base_speed)
	_check(String(scene.get_node("HUD/HintLabel").text).contains("蓄力"),
		"减速结束后提示切回发射提示（%s）" % scene.get_node("HUD/HintLabel").text)

	# ---------- 22m. 多球扣命规则：全部掉光才扣一条命 ----------
	_freeze_ball_physics(balls)
	await _wait(1)
	scene.set("_lives", 2)
	var topup_guard := 0
	while balls.count() < 2 and topup_guard < _max_balls + 2:
		topup_guard += 1
		if balls.spawn_extra(Vector2(160.0, 320.0), Vector2(0.4, -1.0)) == null:
			break
		_freeze_ball_physics(balls)
		await _wait(1)
	scene.set("_lives", 2)
	var lost_extra: Ball = balls.all_balls()[balls.all_balls().size() - 1]
	lost_extra.emit_signal("fell_out_of_playfield")
	await _wait(2)
	_check(balls.count() >= 1 and _gi(scene, "_lives") == 2,
		"掉一颗副球不扣命（还剩 %d 颗球，生命 %d）" % [balls.count(), _gi(scene, "_lives")])
	# 每轮循环都带上界：掉球信号一旦失灵，这里就会变成一个永不结束的 while，
	# CI 只会看到一个「跑到超时被杀」的作业，而看不到是哪条断言先坏掉。
	var drain_guard := 0
	while balls.count() > 1 and drain_guard < _max_balls + 2:
		drain_guard += 1
		(balls.all_balls()[balls.all_balls().size() - 1] as Ball).emit_signal("fell_out_of_playfield")
		await _wait(1)
	# 顺带验一条只有「多球」才存在的规则：掉光时整段连击作废而不是入账。
	# 单球玩法里这条本来就成立，多球把它从「一次往返」变成「全部球都掉光」，判据必须重测。
	scene.set("_combo", 5)
	ball.emit_signal("fell_out_of_playfield")
	await _wait(3)
	_check(_gi(scene, "_combo") == 0, "全部球掉光时整段连击作废（不因掉球白送分）")
	_check(_gi(scene, "_lives") == 1, "球全部掉光才扣 1 条命（2 -> %d）" % _gi(scene, "_lives"))
	_check(bool(ball.get("attached_to_paddle")), "扣命后主球重新吸附到挡板等待再发射")
	_check(balls.count() == 1, "重新吸附后场上又算 1 颗球")
	_check(not bool(scene.get_node("HUD/BallsLabel").visible),
		"回到单球后 HUD 收起球数显示")

	# ---------- 22n. 换关清场：副球与减速状态都不跨关累积 ----------
	# 走真实的关卡递进路径（清空砖墙 -> Level Clear -> 下一关）而不是直接调内部函数：
	# 「新一关的第一颗球是不是干净的」正是玩家实际会遇到的情况。
	# 直接按 PLAYING 态发 restart 是没用的——那个键只在结算态有效。
	_check(balls.spawn_extra(Vector2(160.0, 320.0), Vector2(0.4, -1.0)) != null,
		"换关前刻意攒出多球")
	balls.apply_speed_scale(0.5)
	await _wait(1)
	_check(balls.count() == 2 and _gf(balls, "speed_scale") < 1.0,
		"换关前场上有 2 颗球且处于减速中")
	scene.set("_bricks_cleared", int(_main_const("BRICK_TOTAL", 0)))
	scene.call("_check_level_cleared")
	await _wait(3)
	_check(_gi(scene, "_state") == _state_level_clear, "清空砖墙先进入 Level Clear")
	_send_action(&"restart")
	await _wait(8)
	_check(_gi(scene, "_level") == 2 and balls.count() == 1,
		"进入下一关清掉全部副球、只留主球（球数 %d）" % balls.count())
	_check(absf(_gf(balls, "speed_scale") - 1.0) < 0.001,
		"进入下一关清掉减速状态（新关不会带着上一关的慢球开局）")


## 所有被冻住的球是否都处于给定倍率。逐颗比对而不是只看 BallManager 的字段：
## 字段只说明「打算这么设」，逐颗读回才能抓住漏配某颗球的实现漏洞。
func all_frozen_slow(balls: BallManager, scale: float) -> bool:
	for b in balls.all_balls():
		if absf(_gf(b, "speed_scale") - scale) > 0.001:
			return false
	return true


## 倍率表里的最大值。maxi() 只接受标量，倍率表是数组，所以自己走一遍。
func _max_kind_mult() -> int:
	var top := 0
	for m in _kind_mult:
		top = maxi(top, int(m))
	return top


## 停掉场上所有球的物理。
## P1 各条用例只靠信号驱动球：让球真的飞起来，一次偶然的碰撞就会改掉
## 「刚好在爆破半径内 / 外」的邻居布置，于是期望值不再是手算出来的那个数——
## 那时测的就不是游戏，是测试自己选的碰撞时机。
func _freeze_ball_physics(balls: BallManager) -> void:
	for b in balls.all_balls():
		b.set_physics_process(false)


## 让 ball 按当前 flipped 算一次挡板反弹，返回归一化方向（纯计算，不移动球）。
##
## 直接调私有方法而不是模拟一次真实碰撞：反弹只取决于球相对挡板的横向偏移，
## 模拟碰撞要多等若干帧并依赖球恰好没被别的东西拦住，
## 那时测的是「这一帧球在哪」而不是「镜像算得对不对」。
## 速度分量里还叠了挡板横向速度（真实擦球），所以比的是**符号与相对关系**，
## 而非逐位相等。
func _deflection_of(ball: Ball, flipped: bool) -> Vector2:
	ball.set("flipped", flipped)
	ball.call("_deflect_from_paddle")
	return (ball.velocity as Vector2).normalized()


## 按「kind + 坐标」清单摆一组砖，返回同顺序的砖数组，并把清除计数归零。
## 用显式坐标而不是网格：爆破半径的断言需要「刚好在半径内」与「刚好在半径外」
## 两个邻居，网格间距给不出这种精度，只能靠猜——那样这条用例就变成在测自己的猜测。
func _stage_bricks(scene: Node, spec: Array) -> Array[Brick]:
	var bricks_root: Node2D = scene.get_node("Bricks")
	for child in bricks_root.get_children():
		child.queue_free()
	await _wait(2)
	scene.set("_bricks_cleared", 0)
	var base_hits := _base_hits_for_level(_gi(scene, "_level"))
	var staged: Array[Brick] = []
	for entry in spec:
		var brick := Brick.new()
		brick.kind = int(entry[0]) as Brick.Kind
		brick.color = Color("4cc9f0")
		brick.points = _points_per_brick * int(_kind_mult[int(entry[0])])
		brick.max_hits = base_hits + (_armor_extra_hits if int(entry[0]) == _kind("ARMORED") else 0)
		brick.position = entry[1] as Vector2
		bricks_root.add_child(brick)
		staged.append(brick)
	await _wait(1)
	return staged


## 跑完 P0 用例后释放专用场景，避免与前面各节的实例叠加。
## 紧接第 22 节：P1 用例有自己的场景，同样在跑完后释放。
func _finish_p0_suite(scene: Node) -> void:
	await _run_p0_suite(scene)
	scene.queue_free()
	await _wait(2)

	await _finish_p1_suite()


## 把球恢复到「吸附在挡板上、等待发射」的干净状态。
## 上一节长时间飞行后球可能正在下落，直接改 y 不会触发掉球判定（吸附态每帧都被拉回），
## 所以先确保球真的在飞行中。
func _ensure_attached(scene: Node) -> Ball:
	var ball: Ball = _balls(scene).primary()
	if not bool(ball.get("attached_to_paddle")):
		await _wait(2)
	if not bool(ball.get("attached_to_paddle")):
		ball.call("stick_to", scene.get_node("Paddle"))
		await _wait(2)
	return ball


func _run_p0_suite(scene: Node) -> void:
	# 与前面各节同一个理由：P1 的特殊砖不进这一节，否则爆破链与多球会改动
	# 蓄力/连击/换肤这些用例依赖的砖数与时序基线
	_degrade_special_bricks(scene.get_node("Bricks") as Node2D, _base_hits_for_level(1))
	var p_ball: Ball = await _ensure_attached(scene)
	var p_paddle: CharacterBody2D = scene.get_node("Paddle") as CharacterBody2D
	var aim_line: Node2D = scene.get_node("AimLine")
	var ball_trail: Node2D = scene.get_node("BallTrail")
	var background := scene.get_node("Background") as ColorRect

	# ---------- 21a. Palette：配置存在 / 每关不同 / library() 不共享实例 ----------
	# 不要求恰好一套/关：配 fewer 套时 current_palette() 会按取模循环，行为仍然正确。
	# 这里守的是「换了皮」这件事本身——至少两套，且两两不同。
	var level_palettes: Array = scene.get("level_palettes")
	_check(level_palettes.size() >= 2,
		"Main 至少配了 2 套关卡配色用于换肤（实际 %d 套）" % level_palettes.size())
	var distinct_bg := {}
	for i in level_palettes.size():
		distinct_bg[(level_palettes[i] as Palette).background] = true
	_check(distinct_bg.size() == level_palettes.size(),
		"每套配色的背景色互不相同（%d 套 -> %d 种）" % [level_palettes.size(), distinct_bg.size()])

	# library() 必须每次新建：共享 Resource 会让「改 A 关的色把 B 关也改了」
	var lib_a := Palette.library()
	var lib_b := Palette.library()
	_check(lib_a.size() == lib_b.size() and lib_a.size() > 0,
		"Palette.library() 每次返回同样套数的配色（%d / %d 套）" % [lib_a.size(), lib_b.size()])
	_check(lib_a[0] != lib_b[0], "Palette.library() 每次返回全新实例（未共享 Resource）")
	(lib_a[0] as Palette).background = Color("010203")
	_check((lib_b[0] as Palette).background != Color("010203"),
		"改一份 library() 配色不会污染另一份（Resource 共享坑的回归守卫）")

	# ---------- 21b. 蓄力：按下 -> 蓄力条涨 / 预测线出现，但球还没飞 ----------
	# 只送按下、不送松开：这是蓄力中间态，也是第 5 节那 4 条失败的根因。
	_hold_action(&"launch")
	await _wait(1)
	_check(_gi(scene, "_charging") == 1, "按住 launch 进入蓄力态")
	_check(bool(p_ball.get("attached_to_paddle")), "蓄力中球仍吸附在挡板上（按下不发射）")

	# 蓄力条与预测线都要真的画出来：这两条是「玩家能瞄」的全部依据
	await _wait(3)
	var charge_mid := float(scene.get("_charge"))
	_check(charge_mid > 0.0 and charge_mid <= 1.0,
		"蓄力进度随时间增长且不超过 1（%.2f）" % charge_mid)
	_check(float(p_paddle.get("charge_ratio")) > 0.0,
		"挡板蓄力条同步点亮（charge_ratio=%.2f）" % float(p_paddle.get("charge_ratio")))

	# 预测线必须真的打在什么东西上。只断言「点数 >= 2」太松：
	# 线一路飞出屏幕没撞到任何东西时也是 2 个点，那不叫预测。
	# 球贴着挡板向上打必然先撞上砖墙底面，反弹 >= 1 才是有效断言
	#（注意：这里最多也就 1 次反弹，撞完砖底就垂直掉出场地了，
	#  所以下面另有一条与砖块布局无关的用例专门验多段反射）。
	var aim_points := int(aim_line.call("get_point_count"))
	var aim_bounces := int(aim_line.call("get_bounce_count"))
	var aim_segments := int(aim_line.call("get_segment_count"))
	_check(aim_bounces >= 1,
		"蓄力时预测线真的打在墙/砖上而不是直接飞出场地（%d 次反射 / %d 个点）"
		% [aim_bounces, aim_points])
	_check(aim_segments == aim_bounces or aim_segments == aim_bounces + 1,
		"预测线段数与反射次数自洽（%d 段 / %d 次反射）" % [aim_segments, aim_bounces])

	# 预测线掩码只能含墙与砖：算上挡板的话线会在脚边撞上自己，画出一段无意义短线
	var aim_masks: Dictionary = (load(MAIN_SCRIPT) as GDScript).get_script_constant_map()
	var aim_mask: int = int(aim_masks.get("AIM_MASK_WALL", 0)) | int(aim_masks.get("AIM_MASK_BRICK", 0))
	_check(aim_mask == _layer_wall | _layer_brick,
		"预测线掩码只含 Wall/Brick（%d，期望 %d）"
		% [aim_mask, _layer_wall | _layer_brick])
	# 这是配置与实现的一致性检查：AIM_BOUNCES 一旦超过 MAX_SEGMENTS，
	# predict() 会静默钳到上限，表现为「配了 5 段却只看到 4 段」而不是报错。
	_check(_aim_bounces > 0 and _aim_bounces <= AimLine.MAX_SEGMENTS,
		"Main 请求的反射次数不超过 AimLine 的实现上限（%d <= %d）"
		% [_aim_bounces, AimLine.MAX_SEGMENTS])

	# 多段反射本身：单独喂一条「贴地平飞」的射线再验一遍。
	# y 取砖墙下方，砖完全够不着；掩码又只有墙，排除了挡板与球。
	# 于是这条射线只会在左右墙之间来回，反弹次数完全由 AIM_BOUNCES 决定——
	# 与砖块布局、关卡进度都无关，测的正是 predict() 与 _draw() 的分段本身。
	aim_line.call("predict", Vector2(_view_center.x, _view_height - 30.0),
		Vector2.RIGHT, _aim_bounces, int(aim_masks.get("AIM_MASK_WALL", 0)), 0.55)
	var flat_bounces := int(aim_line.call("get_bounce_count"))
	var flat_segments := int(aim_line.call("get_segment_count"))
	_check(flat_bounces == _aim_bounces and flat_segments == _aim_bounces,
		"贴地平飞的预测线在左右墙之间反射满 %d 次（%d 次反射 / %d 段 / %d 个点）"
		% [_aim_bounces, flat_bounces, flat_segments, int(aim_line.call("get_point_count"))])

	# ---------- 21c. 蓄满自动发射：按住不放也会出球 ----------
	# 不做自动发射的话，玩家可以把空格按住不放看着满蓄力条却不发球，像卡住。
	# 蓄力进度在 _process 里按 delta 累加，time_scale=4.0 会把 delta 一起放大 4 倍，
	# 所以实际需要的物理帧数是 charge_seconds / (1/60) / 4，再留足余量。
	var full_charge_frames := int(ceil(_charge_seconds * 60.0 / 4.0)) + 12
	await _wait(full_charge_frames)
	_check(not bool(p_ball.get("attached_to_paddle")),
		"蓄满后自动发射，不必一直按住空格（等 %d 帧）" % full_charge_frames)
	_check(_gi(scene, "_charging") == 0, "自动发射后回到未蓄力态")
	_check(int(aim_line.call("get_point_count")) == 0, "发射后预测线清空")

	# ---------- 21d. 发射方向与速度由蓄力强度决定 ----------
	# 竖直上弹是原版行为，只有蓄力才能选角度与提速——这一条正是 P0 的核心收益。
	#
	# 用「半蓄力」而不是满蓄力：满蓄力会被 21c 的自动发射抢走，根本轮不到这里松手。
	await _ensure_attached(scene)
	var y_stuck := p_ball.position.y
	_hold_action(&"move_left")
	_hold_action(&"launch")
	await _wait(2)
	var power := float(scene.get("_charge"))
	_check(_gi(scene, "_charging") == 1 and power > 0.0 and power < 1.0,
		"半蓄力态仍在蓄力中（power=%.3f，未被自动发射抢走）" % power)
	_check(is_equal_approx(p_ball.position.y, y_stuck),
		"蓄力期间球还钉在挡板上没动（y %.1f -> %.1f）" % [y_stuck, p_ball.position.y])
	_release_action(&"launch")
	# 必须等一拍再读速度：Input.parse_input_event 只把事件缓冲到下一帧才送进
	# _unhandled_input（同一帧同步读的话拿到的是吸附态的 (0, 0)，不是发射速度）。
	# 一拍是安全的：球刚出手只移动 speed/60 ≈ 8px，离砖墙还有 300px，不会碰到东西改方向。
	await _wait(1)
	var vel: Vector2 = p_ball.velocity
	_release_action(&"move_left")

	# 这里不去猜「松手瞬间的 power 到底是多少」：蓄力进度逐帧累加，
	# 上面的 await 还会让 power 再涨一帧，按测试读到的值算期望必然对不上（实测差一倍）。
	# 改成验证不随帧时序漂移的不变量：发射角与球速必须来自同一个 power，且 0 < power < 1。
	var level_speeds: Array = aim_masks.get("LEVEL_BALL_SPEED", [])
	_check(level_speeds.size() > 0 and _charge_speed_mul > 1.0,
		"关卡球速表与蓄力提速倍率都已配置（%d 档速率，满蓄力 ×%.2f）"
		% [level_speeds.size(), _charge_speed_mul])
	var base_speed := float(level_speeds[(_gi(scene, "_level") - 1) % maxi(1, level_speeds.size())])
	# 反解 power：speed = base × lerp(1.0, CHARGE_SPEED_MUL, power)
	var power_used := (vel.length() / base_speed - 1.0) / (_charge_speed_mul - 1.0)
	var tilt: float = absf(atan2(vel.x, -vel.y)) if vel.y < 0.0 else 99.0
	_check(power_used > 0.0 and power_used < 1.0,
		"半蓄力发射的球速落在「基础速」与「满蓄力速」之间（power=%.3f，%.1f ~ %.1f）"
		% [power_used, base_speed, base_speed * _charge_speed_mul])
	# 角度必须按同一个 power 偏转：按住左所以 x 分量为负，倾角 = power × MAX_CHARGE_TILT
	_check(vel.x < 0.0 and absf(tilt - power_used * _max_charge_tilt) < 0.01,
		"发射角 == power × MAX_CHARGE_TILT 且与球速同源（实测 %.4f，期望 %.4f）"
		% [tilt, power_used * _max_charge_tilt])
	_check(tilt < _max_charge_tilt - 0.01,
		"半蓄力的发射角明显小于满蓄力（%.4f < %.4f），角度可控而非固定"
		% [tilt, _max_charge_tilt])
	await _wait(1)
	_check(not bool(p_ball.get("attached_to_paddle")) and p_ball.position.y < y_stuck - 1.0,
		"松手后球真的斜飞出去（y %.1f -> %.1f）" % [y_stuck, p_ball.position.y])

	# ---------- 21e. 拖尾：飞行中增长、吸附时清空 ----------
	# 蓄力待发时球不动，画拖尾就是一坨原地堆积的色块
	var trail_after_launch := int(ball_trail.call("get_point_count"))
	await _wait(6)
	var trail_grown := int(ball_trail.call("get_point_count"))
	_check(trail_grown > trail_after_launch,
		"球飞行时拖尾持续增长（%d -> %d）" % [trail_after_launch, trail_grown])
	await _ensure_attached(scene)
	await _wait(2)
	_check(int(ball_trail.call("get_point_count")) == 0,
		"球吸附回挡板后拖尾清空（剩余 %d 个点）" % int(ball_trail.call("get_point_count")))

	# ---------- 21f. 连击：回挡板入账 / 掉球作废 ----------
	# 走真实信号，不直接改 _combo：combo 的产生路径只有 _on_brick_hit 一条。
	#
	# 关键：先把球的物理处理关掉。不关的话球在飞行途中会自然撞砖，
	# _combo 与 _score 会被自然碰撞污染，「连击恰好等于 4」这种断言就变成 flaky。
	# 关物理只冻结球自己（move_and_slide / 碰撞），Main 仍照常处理我们手动 emit 的信号。
	p_ball.set_physics_process(false)
	# 前面 21b~21e 让球真飞了一段，途中自然撞砖已经攒了连击。
	# 不清零的话「连击恰好等于 4」这种断言永远对不上，且回挡板入账时
	# 会把上一段飞行遗留的连击一起算进去。
	scene.set("_combo", 0)
	scene.call("_update_hud")
	await _wait(1)
	var combo_bricks: Node2D = scene.get_node("Bricks")
	# 全部调到「再挨一下就碎」，这样点几下就能攒够连击，不用真打完 48 块
	for child in combo_bricks.get_children():
		(child as Brick).max_hits = 1
		(child as Brick).hits_left = 1
	await _wait(2)
	var score_at_combo: int = _gi(scene, "_score")
	# 每次都取最后一块：被击破的那块 queue_free() 到帧末才真正移除，
	# 中间这一帧它仍留在子节点里，重复取到同一块会少算连击。
	# 打击次数按「场上还剩几块」封顶：前面几节让球真飞过，砖墙可能已经残破。
	var hits := mini(4, combo_bricks.get_child_count())
	for i in hits:
		var target := combo_bricks.get_child(combo_bricks.get_child_count() - 1)
		(target as Brick).hits_left = 1
		p_ball.emit_signal("brick_hit", target)
		await _wait(1)
	var combo_built: int = _gi(scene, "_combo")
	_check(combo_built == hits, "连续击破 %d 块砖累计 %d 连击（实际 %d）"
		% [hits, hits, combo_built])
	_check(_gi(scene, "_score") == score_at_combo + hits * _points_per_brick,
		"连击未入账前分数只有砖块基础分（%d -> %d）"
		% [score_at_combo, _gi(scene, "_score")])
	_check(_combo_highlight > 0, "连击显示阈值已配置（COMBO_HIGHLIGHT=%d）" % _combo_highlight)
	_check(_combo_glow_at >= _combo_highlight,
		"拖尾增粗阈值不低于连击显示阈值（%d >= %d）" % [_combo_glow_at, _combo_highlight])
	# HUD 只在达到阈值后才显示连击：1 连击每次都在闪，纯噪音。
	# 双向都验：低于阈值隐藏、达到阈值显示且带上数字。
	var combo_label: Label = scene.get_node("HUD/ComboLabel")
	scene.set("_combo", 0)
	scene.call("_update_hud")
	await _wait(1)
	_check(not combo_label.visible, "连击为 0 时 HUD 不显示连击")
	scene.set("_combo", _combo_highlight - 1)
	scene.call("_update_hud")
	await _wait(1)
	_check(not combo_label.visible,
		"连击未达 COMBO_HIGHLIGHT 时 HUD 隐藏连击（%d < %d）"
		% [_combo_highlight - 1, _combo_highlight])
	scene.set("_combo", _combo_highlight)
	scene.call("_update_hud")
	await _wait(1)
	_check(combo_label.visible and combo_label.text.contains(str(_combo_highlight)),
		"连击达到阈值时 HUD 显示连击数（%s）" % combo_label.text)
	scene.set("_combo", combo_built)

	# 回挡板 = 把这次飞行的连击折算成分数入账
	var expected_bonus := _combo_bonus_for(combo_built)
	_check(expected_bonus > 0, "%d 连击的奖励公式给出正奖励（%d）" % [combo_built, expected_bonus])
	p_ball.emit_signal("paddle_hit")
	await _wait(2)
	_check(_gi(scene, "_score") == score_at_combo + hits * _points_per_brick + expected_bonus,
		"球回挡板时连击折算入账（%d -> %d，期望 %d）"
		% [score_at_combo, _gi(scene, "_score"),
			score_at_combo + hits * _points_per_brick + expected_bonus])
	_check(_gi(scene, "_combo") == 0, "入账后连击计数清零")

	# 掉球 = 这段连击整段作废，一分不加（combo 的风险面）
	var score_before_drop: int = _gi(scene, "_score")
	var hits2 := mini(3, combo_bricks.get_child_count())
	for i in hits2:
		var target2 := combo_bricks.get_child(combo_bricks.get_child_count() - 1)
		(target2 as Brick).hits_left = 1
		p_ball.emit_signal("brick_hit", target2)
		await _wait(1)
	_check(_gi(scene, "_combo") == hits2, "掉球前又攒了 %d 连击（实际 %d）"
		% [hits2, _gi(scene, "_combo")])
	p_ball.emit_signal("fell_out_of_playfield")
	await _wait(3)
	_check(_gi(scene, "_combo") == 0, "掉球后连击整段作废（清零）")
	_check(_gi(scene, "_score") == score_before_drop + hits2 * _points_per_brick,
		"掉球时连击不入账，分数只含砖块基础分（%d -> %d）"
		% [score_before_drop, _gi(scene, "_score")])
	# 解冻：后面几节还要正常飞行
	p_ball.set_physics_process(true)

	# ---------- 21g. 换肤真的换了背景色 ----------
	# 背景是 tween 过渡的（PALETTE_FADE_TIME），要给够帧才能读到终值
	await _ensure_attached(scene)
	var bg_level_1 := background.color
	var palette_level_1: Palette = scene.call("current_palette")
	scene.set("_level", 2)
	scene.call("_start_level")
	await _wait(40)
	var palette_level_2: Palette = scene.call("current_palette")
	_check(palette_level_2 != palette_level_1, "第 2 关取到另一套配色")
	_check(background.color != bg_level_1,
		"进入第 2 关后背景色改变（%s -> %s）" % [bg_level_1.to_html(false), background.color.to_html(false)])
	_check(background.color.is_equal_approx((palette_level_2 as Palette).background),
		"背景色收敛到第 2 关配色（%s）" % background.color.to_html(false))
	scene.set("_level", 1)
	scene.call("_start_level")
	await _wait(40)
	_check(background.color.is_equal_approx(bg_level_1),
		"回到第 1 关后背景色还原（%s）" % background.color.to_html(false))

	# 换肤不只换背景：Palette 里声明的每个字段都要真的落到画面上。
	# Palette 里躺着没人用的字段是典型的「配置看起来很全、实际改了没反应」，
	# 所以这里逐项核对，而不是只查背景色。
	scene.set("_level", 3)
	scene.call("_start_level")
	await _wait(40)
	var palette_level_3: Palette = scene.call("current_palette")
	var hud := scene.get_node("HUD")
	var score_label := hud.get_node("ScoreLabel") as Label
	var best_label := hud.get_node("BestLabel") as Label
	var aim_line_now: AimLine = scene.get_node("AimLine")
	var trail_now: BallTrail = scene.get_node("BallTrail")
	_check(p_ball.color.is_equal_approx(palette_level_3.ball),
		"球色收敛到第 3 关配色（%s）" % p_ball.color.to_html(false))
	_check(p_paddle.color.is_equal_approx(palette_level_3.paddle),
		"挡板色收敛到第 3 关配色（%s）" % p_paddle.color.to_html(false))
	_check(aim_line_now.color.is_equal_approx(palette_level_3.aim),
		"预测线用调色板的 aim 色而不是球的颜色（%s）"
		% aim_line_now.color.to_html(false))
	_check(trail_now.base_color.is_equal_approx(palette_level_3.trail),
		"拖尾基色收敛到调色板的 trail 色（%s）" % trail_now.base_color.to_html(false))
	# base_color 还不等于「玩家看到的颜色」：Main 每帧按连击强度从基色派生 color，
	# 而球吸附在挡板上时 _physics_process 直接 return，根本不会去写 color。
	# 所以实际颜色必须在球真的在飞的时候采，否则测的是没人覆盖的残留值。
	await _ensure_attached(scene)
	p_ball.call("launch")
	await _wait(8)
	_check(trail_now.get_point_count() > 0,
		"球飞行中拖尾确实有点可画（%d 个点）" % trail_now.get_point_count())
	_check(trail_now.color.is_equal_approx(palette_level_3.trail),
		"飞行中的拖尾用的仍是调色板 trail 色（%s）" % trail_now.color.to_html(false))
	_check(p_paddle.charge_color.is_equal_approx(palette_level_3.accent),
		"蓄力条吃 accent 色（%s）" % p_paddle.charge_color.to_html(false))
	_check(score_label.get_theme_color("font_color").is_equal_approx(palette_level_3.text_primary),
		"HUD 主要文字色换成 text_primary（%s）"
		% score_label.get_theme_color("font_color").to_html(false))
	_check(best_label.get_theme_color("font_color").is_equal_approx(palette_level_3.text_secondary),
		"HUD 次要文字色换成 text_secondary（%s）"
		% best_label.get_theme_color("font_color").to_html(false))
	# 结算面板在 show_result() 里吃同一套配色，顺手确认它没被面板自身的主题盖回去
	var panel := scene.get_node("GameOverPanel")
	panel.call("show_result", 0, 0, false, _state_game_over, 3, 4, 1, palette_level_3)
	await _wait(1)
	var stats_label := panel.get_node("Panel/Margin/VBox/StatsLabel") as Label
	_check(stats_label.get_theme_color("font_color").is_equal_approx(palette_level_3.accent),
		"结算面板连击统计行吃 accent 色（%s）"
		% stats_label.get_theme_color("font_color").to_html(false))
	panel.call("hide_result")

	scene.set("_level", 1)
	scene.call("_start_level")
	await _wait(40)

	# ---------- 21h. Ball.launch() 无参调用仍然可用（向后兼容） ----------
	# 旧调用点（以及外部 mod / 存档回放）都是 ball.launch()，
	# 加了 direction 参数后不保留默认值就会全部崩掉。
	_check(_ball_launch_arity() == 0,
		"Ball.launch() 的必填参数为 0 个（无参调用合法，实际 %d）" % _ball_launch_arity())
	await _ensure_attached(scene)
	p_ball.call("launch")
	await _wait(2)
	_check(not bool(p_ball.get("attached_to_paddle")), "Ball.launch() 无参调用仍能把球打出去")
	var random_dir: Vector2 = p_ball.velocity.normalized()
	_check(random_dir.y < 0.0, "无参 launch() 仍朝上方飞行（y 分量 %.2f）" % random_dir.y)
	var ball_consts: Dictionary = _ball_script.get_script_constant_map() \
		if _ball_script != null else {}
	var launch_min: float = float(ball_consts.get("MIN_ANGLE_FROM_HORIZONTAL", 0.0))
	var launch_max: float = float(ball_consts.get("MAX_ANGLE_FROM_HORIZONTAL", 0.0))
	# 无参 launch() 走的随机方向是 Vector2(randf_range(-0.22, 0.22), -1)，
	# 正摆时角度可到 1.57 > 上界 1.40，靠 _clamp_direction() 拉回来——
	# 这条断言守的就是「兜底钳制真的生效」。
	# 比较留 1e-6 容差：钳到边界上再 atan2 读回来会有最后一位的浮点误差。
	var random_angle := atan2(absf(random_dir.y), absf(random_dir.x))
	_check(launch_min > 0.0 and launch_max > launch_min
			and random_angle >= launch_min - 1e-6 and random_angle <= launch_max + 1e-6,
		"无参 launch() 的随机角度被钳回包络内（%.4f 弧度，区间 %.2f ~ %.2f）"
		% [random_angle, launch_min, launch_max])

	# ---------- 21i. Sfx.play(preset, pitch) 的 pitch 只缩放本声部的 f0/f1 ----------
	# 不用 playback.pitch_scale：那是整个播放器的属性，会把同时在响的其它音效
	# （掉命、砖裂）一起拖慢，语义就串了。
	# 这里走 pitched_notes() 这个纯函数验证：无头模式下音频驱动是 Dummy，
	# play() 第一行就 return，靠调 play() 根本验证不到缩放。
	var combo_notes: Array = _sfx_script.call("pitched_notes", "combo", 1.0)
	var half_notes: Array = _sfx_script.call("pitched_notes", "combo", 0.5)
	var combo_preset: Array = _sfx_script.get_script_constant_map().get("PRESETS", {}).get("combo", [])
	_check(combo_notes.size() == combo_preset.size() and not combo_notes.is_empty(),
		"pitched_notes() 返回的音符数与预设一致（%d / %d）"
		% [combo_notes.size(), combo_preset.size()])
	var half_ok := not combo_notes.is_empty()
	for i in mini(combo_notes.size(), half_notes.size()):
		if absf(float(combo_notes[i]["f0"]) - 2.0 * float(half_notes[i]["f0"])) > 0.01 \
				or absf(float(combo_notes[i]["f1"]) - 2.0 * float(half_notes[i]["f1"])) > 0.01:
			half_ok = false
			break
	_check(half_ok, "pitch=0.5 时 f0/f1 正好减半（只缩放频率，不改音量与包络）")
	_check(float(half_notes[0]["vol"]) == float(combo_notes[0]["vol"])
			and float(half_notes[0]["dur"]) == float(combo_notes[0]["dur"]),
		"pitch 缩放不改动 vol / dur（连击变高但不该变得更响或更长）")
	# 下限保护：pitch 过小会让频率掉到次声，听感反而是「没声音」
	var tiny_notes: Array = _sfx_script.call("pitched_notes", "combo", 0.01)
	_check(float(tiny_notes[0]["f0"]) == float(combo_notes[0]["f0"]) * 0.25,
		"pitch 低于 0.25 时被夹到下限，避免次声（%.1f）" % float(tiny_notes[0]["f0"]))
	# pitched_notes 不得污染 PRESETS 本身
	var reread: Array = _sfx_script.get_script_constant_map().get("PRESETS", {}).get("combo", [])
	_check(float(reread[0]["f0"]) == float(combo_preset[0]["f0"]),
		"pitched_notes() 不修改 PRESETS 常量表（改一份不会污染下一次）")


## Ball.launch() 的必填参数个数（无默认值的参数数）。
## launch() 加了 direction 参数后必须仍是 0 个必填，否则旧的 ball.launch() 调用点全崩。
func _ball_launch_arity() -> int:
	var ball_script := load("res://scripts/ball.gd") as GDScript
	if ball_script == null:
		return -1
	for method: Dictionary in ball_script.get_script_method_list():
		if String(method.name) != "launch":
			continue
		var args: Array = method.get("args", [])
		var defaults: Array = method.get("default_args", [])
		return maxi(0, args.size() - defaults.size())
	return -1


func _finish() -> void:
	print("\n===== 冒烟测试结果：%d 项检查，%d 项失败 =====" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


# ================================================================
#  第 23 节：P3 复玩性三件套 —— 三选一卡牌 / 程序化关卡 / 每日种子挑战
# ================================================================
# 与第 1~22 节分成独立的一节，原因和第 22 节一样但方向相反：
# P3 的三条规则都会**主动破坏**「砖墙逐格等于 BRICK_LAYOUT」这条基线
# （程序化生成会改墙、卡牌会改分数与耐久、抽卡界面会占住输入），
# 复用前面的实例等于让 250 条旧断言在 P3 的规则下运行——它们当然会红，
# 但红的原因是新系统的设计而不是回归，分不清就等于白跑。
#
# 这一节同时是「旧玩法没被 P3 破坏」的正面证据：
# 23a~23c 是三套新系统的纯静态契约（不需要场景），
# 23d~23k 才是真实的界面与对局流程。

## —— 23 的外部辅助 ——

## GameMode 脚本对象。
func _game_mode() -> GDScript:
	return load(GAME_MODE_SCRIPT) as GDScript


## LevelGenerator 脚本对象。
func _level_generator() -> GDScript:
	return load(LEVEL_GENERATOR_SCRIPT) as GDScript


## CardPool 脚本对象。
func _card_pool() -> GDScript:
	return load(CARD_POOL_SCRIPT) as GDScript


## MetaProgress 脚本对象。
func _meta_progress() -> GDScript:
	return load(META_PROGRESS_SCRIPT) as GDScript


## MetaProgress 的存档路径（user:// 全路径）。
## 从脚本常量反查而不是在测试里再写一遍字面量：路径改了测试不该跟着改。
func _meta_path() -> String:
	return String(_meta_progress().get_script_constant_map().get("SAVE_PATH", ""))


## MetaProgress 的存档文件名（user:// 下的纯文件名）。
func _meta_file_name() -> String:
	return _meta_path().get_file()


## 往 MetaProgress 档案里直接塞一组字段，再丢掉内存缓存强制重读。
## 用来把「连续打卡天数」推到指定的起点——真实的「昨天打过」没法在一次运行里造出来。
##
## 只改 fields 里出现的键，其余保持文件里的原值。
## 要「从空白档案起步」必须先调 _clear_meta()：往已存在的档案上写几个字段
## 并不会把没提到的字段复位（record_run 里 daily_best=700 会一直留在盘上）。
func _seed_meta(fields: Dictionary) -> void:
	_meta_progress().forget_cache()
	var config := ConfigFile.new()
	# 文件不存在时 load 返回非 OK；这是预期情况，下面就是往一份空档案上写。
	config.load(_meta_path())
	for key: String in fields:
		config.set_value("meta", key, fields[key])
	config.save(_meta_path())
	_meta_progress().forget_cache()


## 删掉 MetaProgress 的存档文件，回到「从没用过每日挑战」的状态。
func _clear_meta() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(_meta_file_name()):
		dir.remove(_meta_file_name())
	_meta_progress().forget_cache()


## 取某个玩法模式的值。
func _mode(mode_name: String) -> int:
	var modes: Dictionary = _game_mode().get_script_constant_map().get("Mode", {})
	return int(modes.get(mode_name, -1))


## 抽卡面板上第 index 张牌的「选择」按钮。点它走的是真实按钮路径，
## 而不是直接调面板的 choose()——那条是键盘分支的入口，鼠标分支得单独覆盖。
func _draft_button(panel: Node, index: int) -> Button:
	var cards: HBoxContainer = panel.get_node_or_null("Panel/Margin/VBox/Cards") as HBoxContainer
	if cards == null or index >= cards.get_child_count():
		return null
	return cards.get_child(index).get_node_or_null("VBox/ChooseButton") as Button


## 在砖墙里找第一块指定 kind 的砖。
func _find_kind(bricks: Node2D, kind: int) -> Brick:
	for child in bricks.get_children():
		var brick := child as Brick
		if brick != null and int(brick.kind) == kind:
			return brick
	return null


## 生成一个全新场景并挂进树，等它进入 Menu 态。
func _spawn_scene() -> Node:
	var scene: Node = (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	current_scene = scene
	await _wait(3)
	return scene


## 把某个场景开到指定模式 / 种子（同步，便于断言前后的差异）。
func _open_run(scene: Node, mode: int, run_seed: int = -1) -> void:
	scene.call("_begin_run", mode, run_seed)
	await _wait(2)


## 把关卡推进到指定关（无尽 / 每日模式才需要，经典模式到顶会结算）。
##
## 逐关走真实结算路径而不是直接 set("_level", n)：_level 只是个序号，
## 直接改它不会触发 _start_level()，于是不会建墙、不会换球速，
## 而 P4 的形状用例要验的恰恰是「按关卡号换形状」这条逻辑——
## 绕过 _start_level() 就等于把被测代码整段跳过了，断言会一直绿而功能是坏的。
## 每一步都确认确实推进了，否则这里会变成一个死循环。
func _advance_to_level(scene: Node, target_level: int) -> bool:
	for guard in 64:
		if _gi(scene, "_level") >= target_level:
			return true
		var state := _gi(scene, "_state")
		if state == _state_game_over or state == _state_won:
			return false
		await _clear_current_level(scene, 1)
		_send_action(&"restart")
		await _wait(4)
		# 抽卡界面要再按一次：无尽模式每过一关都抽
		if _gi(scene, "_state") == _state_draft:
			_send_action(&"restart")
			await _wait(4)
	return _gi(scene, "_level") >= target_level


## 让当前关立刻判定通关：把计数推到只剩最后一块，释放其余，再真实击破最后一块。
## 复用第 13 / 15 节的做法——直接调 _settle() 会跳过结算面板与图例，
## 而 P3 的抽卡入口正是挂在结算面板上的。
func _clear_current_level(scene: Node, keep: int) -> void:
	var bricks: Node2D = scene.get_node("Bricks")
	var snapshot: Array = bricks.get_children()
	# queue_free 帧末才生效，先把要点的最后几块的字段取好快照
	var survivors: Array = snapshot.slice(maxi(0, snapshot.size() - keep))
	scene.set("_bricks_cleared", _brick_total - survivors.size())
	for i in snapshot.size() - survivors.size():
		snapshot[i].queue_free()
	await _wait(3)
	for node in survivors:
		if is_instance_valid(node):
			node.set("hits_left", 1)
	for node in survivors:
		if is_instance_valid(node):
			(_balls(scene).primary().brick_hit as Signal).emit(node)
			break
	await _wait(3)


## 字体子集必须盖住全部界面文案。
##
## 手工测试第 19 条说「Web 版不能出现豆腐块」，但它只有在真的导出 Web、
## 在浏览器里翻遍每一屏才看得出来。豆腐块本身不会报任何错：
## Godot 对缺字形静默画空白，headless 冒烟测试一路全绿，
## 问题要等到玩家打开网页才发现。唯一能提前抓住它的办法是
## 在这里把「界面可能显示的字符」和「字体子集里有的字符」对一遍。
##
## 扫描规则必须和重建子集的脚本一致，否则会漏判：
##   - 只扫**双引号字符串字面量**，不扫注释。注释里为了讲清规则会引几十个
##     从不上屏的词（照扫会把子集从两百多字撑到几千字）。
##   - 覆盖 scripts/ 与 scenes/；tests/ 里的断言文案不上屏，不算。
## 判据用 Font.has_char()——它走 Godot 自己的字体栈（含 fallback），
## 比「cmap 里有没有这个码位」更接近屏幕上的真实结果。
const FONT_SCENES_DIR := "res://scenes"
const FONT_SCRIPTS_DIR := "res://scripts"
const FONT_RESOURCE := "res://fonts/ui-font.otf"


## 界面文案可能出现的码位区间。刻意只收这三段：把整个 CJK 区块拉进来
## 就等于放弃子集的意义了。
func _is_ui_glyph_candidate(code: int) -> bool:
	return (code >= 0x3000 and code <= 0x303F) \
		or (code >= 0x4E00 and code <= 0x9FFF) \
		or (code >= 0xFF00 and code <= 0xFFEF)


## 从一个目录下的 .gd / .tscn 里收集双引号字面量中的界面字符。
func _scan_ui_characters(dir_path: String, into: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not (file_name.ends_with(".gd") or file_name.ends_with(".tscn")):
			continue
		var text := FileAccess.get_file_as_string(dir_path.path_join(file_name))
		if text.is_empty():
			continue
		var from := 0
		while true:
			var open_at := text.find("\"", from)
			if open_at < 0:
				break
			var close_at := text.find("\"", open_at + 1)
			if close_at < 0:
				break
			from = close_at + 1
			# 双引号之间的内容就是一个字面量；转义在本项目里不存在
			for i in range(open_at + 1, close_at):
				var code := text.unicode_at(i)
				if _is_ui_glyph_candidate(code):
					into[code] = true


func _run_p3_font_subset() -> void:
	var font := load(FONT_RESOURCE) as FontFile
	_check(font != null, "字体资源可加载（%s）" % FONT_RESOURCE)
	if font == null:
		return

	var needed := {}
	_scan_ui_characters(FONT_SCRIPTS_DIR, needed)
	_scan_ui_characters(FONT_SCENES_DIR, needed)
	_check(not needed.is_empty(), "扫到了界面文案（%d 个字符）" % needed.size())

	var missing: Array[int] = []
	for code: int in needed:
		if not font.has_char(code):
			missing.append(code)
	missing.sort()
	var missing_text := ""
	for code in missing:
		missing_text += String.chr(code)
	_check(missing.is_empty(),
		"字体子集盖住全部界面文案（缺 %d/%d 个字形：%s）"
		% [missing.size(), needed.size(), missing_text])


# —— 23a~23k ——

func _finish_p3_suite() -> void:
	_run_p3_static_contracts()
	_run_p3_level_generator()
	_run_p3_card_pool()
	await _run_p3_menu_flow()
	await _run_p3_endless_flow()
	await _run_p3_card_algebra()
	await _run_p3_shield()
	await _run_p3_reforge()
	await _run_p3_daily()
	await _run_p3_draft_panel_rebuild()
	_run_p3_font_subset()
	await _finish_p4_suite()
	_finish()


# —— 24. P4：接球 / 热度 / 凝滞 / 形状 ——


## 四个新系统放在一批，但**用例顺序不能随意调**：
## 凝滞用例动过 Engine.time_scale，它必须在最后跑并自行还原，
## 否则一旦它失败，后面所有依赖物理帧推进的断言都会被时间尺度带偏，
## 症状是「一批毫不相干的用例集体变慢」——那是最难回溯的一类失败。
func _finish_p4_suite() -> void:
	_run_p4_static_contracts()
	await _run_p4_wall_shapes()
	await _run_p4_catch_flow()
	await _run_p4_heat()
	await _run_p4_bullet_time()


## ---------- 24a. 四个新系统的静态契约 ----------
func _run_p4_static_contracts() -> void:
	_check(_wall_script != null and _heat_script != null
			and _flow_script != null and _ability_script != null,
		"P4 四套脚本都能加载（wall_shape_provider / heat_system / caught_ball_flow / ability_system）")
	if _wall_script == null or _heat_script == null:
		return

	_check(_shape_count > 1 and _shape_profiles.size() == _shape_count - 1,
		"形状轮廓表覆盖除 SHAPE_NONE 外的每一种形状（%d 种，表里 %d 条）"
		% [_shape_count, _shape_profiles.size()])

	# 热度倍率必须是整数。这是「总分始终是每块砖分值的整数倍」这条不变量
	# 在新系统上不被打破的唯一前提——倍率一旦出现 1.5 这类小数，
	# 玩家拿到的分数就除不尽砖块单价，而这条不变量在 headless 里因为
	# 热度恒为 0 照样通过，只有真实游玩才炸。所以在这里守住表的**取值域**。
	var non_integer := 0
	for value in _heat_tier_mult:
		if typeof(value) != TYPE_INT:
			non_integer += 1
	_check(non_integer == 0 and not _heat_tier_mult.is_empty(),
		"热度倍率全部是整数（%s）" % str(_heat_tier_mult))

	# 每块砖分数与连击单位分必须相等，否则「连击奖励也是每块砖分值的整数倍」
	# 这条推导在 HeatSystem 那边就断了。
	_check(_points_per_brick > 0 and int(_heat_script.get_script_constant_map()
			.get("COMBO_UNIT_POINTS", 0)) == _points_per_brick,
		"连击单位分 == 每块砖基础分（连击奖励同样是整数倍）")

	# 经典模式只有 3 关，形状从第 4 关起才生效：这条不成立的话
	# 「经典模式的墙逐位等于 BRICK_LAYOUT」这条既有断言会被新系统直接推翻。
	_check(_shape_from_level > _max_level,
		"形状启用关卡（%d）晚于经典模式最后一关（%d）" % [_shape_from_level, _max_level])


## ---------- 24b. 形状墙：砖数恒定 ----------
##
## 这一节验证的是新系统唯一会动到「通关判定」的那条性质。
## Main 的通关判定读 wall.total，所以形状一旦改变总砖数，
## 「已清除计数达标即通关」就会错判——而这条性质在真实游玩里极难察觉：
## 多一块砖则永远差一下打不完，少一块则最后一击提前结算。
func _run_p4_wall_shapes() -> void:
	if _wall_script == null:
		return

	# 静态验算：每种轮廓逐行相加恒等于 TEMPLATE_TOTAL。
	# 这是最快的守门方式——不建场就能抓住「往表里加一行却忘了改总数」。
	var bad_profiles: Array = []
	for shape_value in _shape_profiles:
		if not bool(_wall_script.call("profile_sums_to_total", int(shape_value))):
			bad_profiles.append(int(shape_value))
	_check(bad_profiles.is_empty(),
		"每种形状轮廓的砖数都等于 %d（不对的形状：%s）"
		% [_template_total, str(bad_profiles)])

	# 动态验算：真的建出来，数一数场上到底几块砖。
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 20261005)
	var wall: Node2D = scene.get_node("WallShapeProvider") as Node2D
	_check(wall != null, "Main.tscn 挂了 WallShapeProvider 节点")

	# 第 1 关先原地验：形状必须还没生效。
	var level := _gi(scene, "_level")
	var bricks_l1: Node2D = scene.get_node("Bricks") as Node2D
	_check(_gi(wall, "shape") == _shape_none
			and bricks_l1.get_child_count() == _template_total,
		"第 1 关仍是满墙 %d 块（形状从第 %d 关起才生效）"
		% [_template_total, _shape_from_level])

	# 然后一路推进，每过一关取一次快照。
	# 用 seed 20261005 而不是写死某个种子：_shape_for() 同时掺入种子与关卡号，
	# 一个种子未必能在前若干关里凑齐所有形状，而「表里有没有一条永远抽不到」
	# 正是这类查表驱动的设计最容易留下的洞。
	var seen: Dictionary = {}
	var rows_seen: Dictionary = {}
	var total_mismatch: Array = []
	var last_level := _gi(scene, "_level")
	for step in 28:
		level = _gi(scene, "_level")
		last_level = level
		var shape_value := _gi(wall, "shape")
		seen[shape_value] = true
		rows_seen[_gi(wall, "rows")] = true
		# 通关判定的阈值是 wall.total：它必须等于场上真实砖数，
		# 否则差一块就永远打不完、差一块就提前结算。
		var on_wall := (scene.get_node("Bricks") as Node2D).get_child_count()
		if on_wall != _gi(wall, "total"):
			total_mismatch.append(level)
		# 墙的行数必须与轮廓表一致（形状表改了行数但 build() 没跟上时这里会炸）
		if shape_value != _shape_none:
			var profile: Array = _shape_profiles.get(shape_value, [])
			if profile.size() != _gi(wall, "rows"):
				total_mismatch.append(-level)
		if not await _advance_to_level(scene, level + 1):
			break

	_check(last_level >= _shape_from_level + 1,
		"推进到了形状生效之后（第 %d 关，形状从第 %d 关起生效）"
		% [last_level, _shape_from_level])
	_check(seen.size() >= 3,
		"一路推进撞见至少 3 种形状（含 none，实际 %d 种）" % seen.size())
	_check(rows_seen.size() >= 3,
		"墙高至少出现 3 种（实际 %s 行）" % str(rows_seen.keys()))
	_check(total_mismatch.is_empty(),
		"每关 wall.total 与场上真实砖数一致，且行数与轮廓表相符（异常关卡 %s）"
		% str(total_mismatch))
	scene.queue_free()
	await _wait(2)


## ---------- 24c. 接球：蓄力与主动接住 ----------
##
## 这一节全部靠**驱动 CaughtBallFlow 的输入入口**而不是模拟真实碰撞。
## 让球真的飞回挡板需要几百帧的物理推演，而接住这一帧具体落在哪一帧
## 取决于球速与挡板位置——那样测的就不是「接住规则对不对」，
## 而是「这一帧球恰好在哪」。
func _run_p4_catch_flow() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 424242)
	var flow: Node = scene.get_node("CaughtBallFlow")
	var balls := _balls(scene)

	_check(not bool(flow.call("is_charging")), "开局未在蓄力态")

	# 按下 launch：此刻球吸附在挡板上，应当立刻进入蓄力。
	# 必须用 _hold_action 而不是 _send_action：后者是「按下 + 立刻松开」，
	# 而「松开」正是发射——用它测蓄力会在同一个调用里把球打出去，
	# 于是 is_charging() 读到 false，看起来像是「按下没生效」。
	_hold_action(&"launch")
	await _wait(2)
	_check(bool(flow.call("is_charging")), "球吸附时按下 launch 进入蓄力态")
	_check(_gf(scene, "_charge") >= 0.0 and _gf(scene, "_charge") <= 1.0,
		"蓄力进度可经 Main 的转发属性读到且在 0~1 内（%.3f）" % _gf(scene, "_charge"))

	# 蓄力条应当随帧推进（这一条挡住「tick 忘了接」这种静默失效）。
	var before_charge := _gf(scene, "_charge")
	await _wait(2)
	_check(_gf(scene, "_charge") > before_charge,
		"蓄力进度逐帧增长（%.3f -> %.3f）" % [before_charge, _gf(scene, "_charge")])

	# 松开发射：球应当离手且脱离吸附态。
	_release_action(&"launch")
	await _wait(2)
	_check(not bool(flow.call("is_charging")), "松开发射后回到未蓄力态")
	_check(not bool(balls.primary().get("attached_to_paddle")), "松手后球已脱板飞出")

	# —— 飞行中按下 launch：挂起接球意图，而不是把飞行中的球拉回来 ——
	# 这一条是老 bug 的正面回归：`main.gd` 以前用 attached_to_paddle 当闸门，
	# 球在飞行时按空格什么都不会发生，于是蓄力在一颗球的一生里只生效一次。
	_hold_action(&"launch")
	await _wait(2)
	_check(bool(flow.call("is_catch_armed")),
		"球在飞行时按下 launch 会挂起接球意图")
	_check(not bool(flow.call("is_charging")),
		"飞行中按下 launch 不会把在飞的球拉回蓄力态")

	# 球碰上挡板时兑现接住意图。
	var caught_ball: Ball = balls.primary()
	(flow as Object).call("on_paddle_contact", caught_ball)
	await _wait(2)
	_check(bool(flow.call("is_charging")), "球碰上挡板时接球意图兑现，��入蓄力")
	_check(not bool(caught_ball.get("attached_to_paddle")) == false,
		"被接住的球回到吸附态（蓄力期间必须一动不动）")
	_check(not bool(flow.call("is_catch_armed")),
		"兑现后不再重复兑现（否则一颗球能被接住好几次）")

	# —— 不按 = 经典自动反弹 ——
	# 「不作为」必须是不作为而不是另一条分支：这条断了就是
	# 「玩家想让它弹开，它非要把球粘住」。
	flow.call("reset")
	await _wait(2)
	_send_action(&"launch")
	await _wait(2)
	var free_ball: Ball = balls.primary()
	flow.call("on_paddle_contact", free_ball)
	await _wait(2)
	_check(not bool(flow.call("is_charging")),
		"没挂接球意图时碰板只是普通反弹，不会把球粘住")

	# —— 暂停必须中断蓄力 ——
	# 否则恢复后玩家看到一条满蓄力条却按不动。
	# 先把球收吸附态：上一段结束时球是弹飞出去的，而飞行中按下 launch
	# 会挂起接球意图而不是蓄力——那正是 24c 要验的规则，这里不该反过来依赖它。
	balls.stick_primary()
	flow.call("on_ball_attached", balls.primary())
	await _wait(2)
	_hold_action(&"launch")
	await _wait(2)
	_check(bool(flow.call("is_charging")), "重新进入蓄力态")
	_send_action(&"pause")
	await _wait(2)
	_check(_gi(scene, "_state") == _state_paused, "蓄力中可暂停")
	_check(not bool(flow.call("is_charging")), "暂停立刻中断蓄力（不留满蓄力条）")
	_release_action(&"launch")
	_send_action(&"pause")
	await _wait(3)
	_check(_gi(scene, "_state") == _state_playing, "可恢复")

	# —— 方向锁存：满蓄力时按住右，发射角应当偏离正上方 ——
	flow.call("reset")
	await _wait(2)
	_hold_action(&"move_right")
	_hold_action(&"launch")
	await _wait(2)
	var straight: Vector2 = flow.call("launch_direction", 0.0)
	var tilted: Vector2 = flow.call("launch_direction", 1.0)
	_release_action(&"launch")
	_release_action(&"move_right")
	_check(is_equal_approx(straight.x, 0.0) and tilted.x > straight.x,
		"按住右时蓄力越满发射角越偏右（%.3f -> %.3f）" % [straight.x, tilted.x])
	_check(tilted.y < 0.0, "发射方向恒指向斜上方（不会朝下打）")

	scene.queue_free()
	await _wait(2)


## ---------- 24d. 热度：整数倍率与不变量 ----------
##
## 关键设计取舍在这里被验证：**热度只认「主动接住」，不认普通碰挡板。**
## 所以这一节全部直接驱动 HeatSystem 的事件入口——
## 真去模拟「玩家恰好在球碰到挡板的那一帧按下空格」既慢又不确定。
## 直接驱动事件入口验的是规则本身（倍率整数、回落、代价、清零），
## 而「接住」到「register_catch」这条连线由 24c 的接球用例覆盖。
func _run_p4_heat() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 987654)
	var heat: Node = scene.get_node("HeatSystem")
	var paddle: Paddle = scene.get_node("Paddle") as Paddle

	_check(int(heat.call("score_mult")) == _heat_tier_mult[0],
		"开局热度倍率为最低档 %d" % _heat_tier_mult[0])
	_check(is_zero_approx(_gf(heat, "_heat")), "开局热度为 0")

	# 普通碰挡板不涨热度。这条是刻意的：碰挡板是被动行为，
	# 按它涨热度等于奖励玩家什么都不做。
	heat.call("register_break")
	_check(is_zero_approx(_gf(heat, "_heat")), "击碎砖块不涨热度（只有接球才涨）")

	# 逐档接球，每档都验一次倍率与挡板代价。
	var width_at_peace := paddle.paddle_width
	var tier_ok := true
	var penalty_ok := true
	var int_ok := true
	# 只走到第 size-1 档：倍率表有 N 项就意味着 N 个档位（0..N-1），
	# 而档位索引是 clampi(heat / HEAT_TIER_STEP, 0, N-1)——
	# 循环写成 range(N) 会去够一个取不到的档，于是「倍率等于表第 N 项」永远不成立，
	# 症状看起来像「热度爬不上去」，实际是断言问了一个不存在的问题。
	for i in range(_heat_tier_mult.size() - 1):
		heat.call("reset_heat")
		# 涨到第 i+1 档：register_catch 每次加 HEAT_PER_CATCH，
		# 用它自己涨到刚好越过档线，避免测试里复算一遍加法（会跟着常量一起过期）。
		for n in 400:
			heat.call("register_catch")
			if _gi(heat, "_last_tier") >= i + 1:
				break
		if int(heat.call("score_mult")) != int(_heat_tier_mult[i + 1]):
			tier_ok = false
		if _gi(heat, "_last_tier") != i + 1:
			tier_ok = false
		# 挡板代价 = 档位 × 每档步长，封顶在 HEAT_PENALTY_MAX_PX
		var want_penalty := minf(float(i + 1) * _heat_penalty_step, _heat_penalty_max)
		if not is_equal_approx(float(heat.call("paddle_penalty")), want_penalty):
			penalty_ok = false
		if typeof(heat.call("score_mult")) != TYPE_INT:
			int_ok = false
	_check(tier_ok, "热度逐档爬升时倍率跟着 HEAT_TIER_MULT 走")
	_check(penalty_ok, "热度代价按档位 × 步长并封顶（上限 %.0f px）" % _heat_penalty_max)
	_check(int_ok, "score_mult() 返回的是 int 而非 float")

	# 热度满档时的挡板确实比平静时窄——这是玩家当场能感觉到的代价。
	heat.call("reset_heat")
	scene.call("_apply_paddle_width")
	await _wait(1)
	var width_calm := paddle.paddle_width
	heat.call("reset_heat")
	for n in 200:
		heat.call("register_catch")
	scene.call("_apply_paddle_width")
	await _wait(1)
	_check(paddle.paddle_width < width_calm,
		"满热度时挡板比平静时窄（%.1f -> %.1f）" % [width_calm, paddle.paddle_width])
	_check(is_equal_approx(width_calm, width_at_peace) or width_calm <= width_at_peace,
		"清零热度后挡板宽度回到基准")

	# —— 核心不变量：分数倍率是整数，「总分是每块砖分值的整数倍」不被打破 ——
	# 这条必须在满倍率下验。倍率 1 时任何乘数都成立，验了等于没验。
	var score_mult := int(heat.call("score_mult"))
	_check(score_mult > 1, "现在处于非最低档（×%d），下面的整数性断言才有意义" % score_mult)
	var brick_points := _points_per_brick * int(_kind_mult[_kind("NORMAL")]) \
		* int(scene.call("_card_score_mult"))
	var gained := brick_points * score_mult
	_check(gained % brick_points == 0 and gained / brick_points == score_mult,
		"砖块分 × 热度倍率仍是砖块分值的整数倍（%d × %d = %d）"
		% [brick_points, score_mult, gained])

	# 真打一块砖验一遍：分数走 _brick_score，必须真的乘上倍率。
	heat.call("reset_heat")
	await _wait(1)
	var bricks: Node2D = scene.get_node("Bricks")
	var normal := _find_kind(bricks, _kind("NORMAL"))
	_check(normal != null, "墙上有一块普通砖可用于打倍率")
	if normal != null:
		for n in 200:
			heat.call("register_catch")
		var mult := int(heat.call("score_mult"))
		# 先把砖的分值取好：击碎的那一帧砖就 queue_free 了，
		# 断言里再读 normal.points 拿到的是「previously freed」，
		# 而症状是一行 Invalid access 打断整个函数——后面所有断言都不再执行，
		# 看起来像「测试没跑」，实际是被一行过期的引用腰斩了。
		var brick_points_hit := normal.points
		normal.hits_left = 1
		normal.max_hits = 1
		var score_before := _gi(scene, "_score")
		(_balls(scene).primary().brick_hit as Signal).emit(normal)
		await _wait(3)
		var delta := _gi(scene, "_score") - score_before
		_check(delta == brick_points_hit * mult,
			"实际击碎砖块时分数乘上了热度倍率（期望 %d × %d = %d，实得 %d）"
			% [brick_points_hit, mult, brick_points_hit * mult, delta])

	# —— 回落 —— 热度是计时器，不回落就只涨不跌，退化成纯增益。
	var before_decay := _gf(heat, "_heat")
	for n in 400:
		heat.call("tick", 1.0 / 60.0)
	_check(_gf(heat, "_heat") < before_decay,
		"热度随时间回落（%.2f -> %.2f）" % [before_decay, _gf(heat, "_heat")])
	for n in 2000:
		heat.call("tick", 1.0 / 60.0)
	_check(is_zero_approx(_gf(heat, "_heat")), "热度不会跌成负数")
	_check(int(heat.call("score_mult")) == _heat_tier_mult[0], "回落后倍率回到最低档")

	# —— 换关清热度但保留跨关统计 ——
	heat.call("register_break")
	heat.call("register_break")
	var best_before := int(heat.call("best_combo"))
	heat.call("reset_level")
	_check(is_zero_approx(_gf(heat, "_heat")), "换关清热度")
	_check(int(heat.call("best_combo")) == best_before,
		"换关保留最好连击（整局口径，不该按关重算）")

	# —— 开新一局全清 ——
	heat.call("register_catch")
	heat.call("register_break")
	heat.call("reset_run")
	_check(is_zero_approx(_gf(heat, "_heat")) and int(heat.call("best_combo")) == 0
			and int(heat.call("combo_total")) == 0,
		"开新一局把热度与连击统计全部归零")

	scene.queue_free()
	await _wait(2)


## ---------- 24e. 凝滞：Engine.time_scale 的所有权 ----------
##
## 这一节最后跑，因为它动的是全局时间倍率。
## 最要紧的一条断言是**还原**：整套测试自己就靠 Engine.time_scale = 4.0
## 加速（见 _initialize），而 reset() 与 _exit_tree 都会被无条件调用。
## 若 AbilitySystem 在「没持有过倍率」时也去写 Engine.time_scale，
## 就会把 4.0 抹成 1.0——后果是整个测试从那一刻起慢四倍并开始大面积超时，
## 而错误信息指向的却是某个毫不相干的用例。
## 所以守卫不是「还原成 1.0」，而是一道持有标记。
func _run_p4_bullet_time() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 555111)
	var abilities: Node = scene.get_node("AbilitySystem")
	var balls := _balls(scene)

	var global_scale := Engine.time_scale
	_check(global_scale > 0.0, "凝滞用例开始前记录全局倍率（%.2f）" % global_scale)

	# —— 没持有时不许碰全局量 ——
	abilities.call("reset")
	await _wait(2)
	_check(is_equal_approx(Engine.time_scale, global_scale),
		"没开过凝滞时 reset() 不动 Engine.time_scale（仍为 %.2f）" % global_scale)

	# —— 开凝滞：应当是「当前全局倍率 × BULLET_TIME_SCALE」，不是写死成某个值 ——
	var charges_before := int(abilities.call("charges"))
	_check(charges_before > 0, "开局至少有一次凝滞（%d 次）" % charges_before)
	abilities.call("on_bullet_time_input", true)
	await _wait(1)
	_check(bool(abilities.call("is_bullet_time_active")), "按下 bullet_time 进入凝滞")
	_check(is_equal_approx(Engine.time_scale, global_scale * _bullet_time_scale),
		"凝滞把时间倍率压到全局值的 %.0f%%（%.3f）"
		% [_bullet_time_scale * 100.0, Engine.time_scale])
	_check(int(abilities.call("charges")) == charges_before - 1,
		"用掉一次凝滞次数（%d -> %d）" % [charges_before, int(abilities.call("charges"))])

	# —— 次数耗尽后不再生效 ——
	abilities.call("on_bullet_time_input", false)
	await _wait(1)
	var left := 0.0
	while bool(abilities.call("is_bullet_time_active")) and left < 600:
		await _wait(1)
		left += 1
	_check(not bool(abilities.call("is_bullet_time_active")), "凝滞按时长自动结束")
	_check(is_equal_approx(Engine.time_scale, global_scale),
		"凝滞结束后 Engine.time_scale 还原为 %.2f" % global_scale)

	while int(abilities.call("charges")) > 0:
		abilities.call("on_bullet_time_input", false)
		await _wait(1)
		abilities.call("on_bullet_time_input", true)
		await _wait(2)
		abilities.call("on_bullet_time_input", false)
		await _wait(2)
		await _wait(60)
	_check(int(abilities.call("charges")) == 0, "凝滞次数可以被耗尽")
	abilities.call("on_bullet_time_input", true)
	await _wait(1)
	_check(not bool(abilities.call("is_bullet_time_active")), "次数耗尽后凝滞不再生效")
	_check(is_equal_approx(Engine.time_scale, global_scale),
		"没生效的凝滞不该动过 Engine.time_scale")

	# —— reset() 必须在持有期间还原 ——
	abilities.call("grant_charges", 1)
	await _wait(1)
	abilities.call("on_bullet_time_input", true)
	await _wait(1)
	_check(bool(abilities.call("is_bullet_time_active")), "补给后能再次凝滞")
	_check(is_equal_approx(Engine.time_scale, global_scale * _bullet_time_scale),
		"补给后时间倍率再次被压低")
	abilities.call("reset")
	await _wait(2)
	_check(not bool(abilities.call("is_bullet_time_active")), "reset() 结束凝滞")
	_check(is_equal_approx(Engine.time_scale, global_scale),
		"reset() 把 Engine.time_scale 还原为 %.2f（不是写死 1.0）" % global_scale)

	# —— 扳挡 ——
	var paddle: Paddle = scene.get_node("Paddle") as Paddle
	_check(not bool(abilities.call("is_flipped")), "开局未扳挡")
	abilities.call("on_flip_pressed")
	await _wait(2)
	_check(bool(abilities.call("is_flipped")), "按下 flip 进入扳挡态")
	_check(bool(paddle.get("flipped")), "扳挡状态同步到挡板（视觉可读）")
	var flipped_ball: Ball = balls.primary()
	_check(bool(flipped_ball.get("flipped")), "扳挡状态同步到场上每颗球")
	# 连按锁：按住不放不该把挡板来回翻
	abilities.call("on_flip_pressed")
	await _wait(2)
	_check(bool(abilities.call("is_flipped")), "扳挡有连按锁，按第二下不会立刻翻回去")

	# 镜像正确性：同样偏移的球，扳挡后横向分量取反、纵向不变。
	# 校验纵向量是为了挡住「整个速度向量取负」那种改法——
	# 它会让球朝下飞，而「速度朝下」这件事在断言里看不出来。
	var probe: Ball = balls.primary()
	probe.global_position = paddle.global_position + Vector2(40.0, -10.0)
	var normal_dir := _deflection_of(probe, false)
	var flipped_dir := _deflection_of(probe, true)
	# 两个数都按「正常 → 扳挡」的顺序打印：反过来的话「纵向不变」这条
	# 会打印成 (0.738 vs -0.738)，读起来像自相矛盾，而它其实只是在说相等。
	_check(is_equal_approx(flipped_dir.y, normal_dir.y),
		"扳挡只镜像横向分量，纵向不变（正常 %.3f → 扳挡 %.3f）"
		% [normal_dir.y, flipped_dir.y])
	_check(not is_equal_approx(flipped_dir.x, normal_dir.x),
		"扳挡确实把横向分量取了反（正常 %.3f → 扳挡 %.3f）"
		% [normal_dir.x, flipped_dir.x])
	_check(flipped_dir.y < 0.0 and flipped_dir.x < 0.0,
		"偏右的球在扳挡后往左上方飞（%.3f, %.3f）" % [flipped_dir.x, flipped_dir.y])

	# reset() 复位扳挡，且不碰时间倍率（此刻没持有）
	abilities.call("reset")
	await _wait(2)
	_check(not bool(abilities.call("is_flipped")), "reset() 复位扳挡")
	_check(not bool(paddle.get("flipped")), "挡板视觉同步复位")
	_check(is_equal_approx(Engine.time_scale, global_scale), "复位扳挡不动时间倍率")

	scene.queue_free()
	await _wait(2)
	_check(is_equal_approx(Engine.time_scale, global_scale),
		"场景释放后 Engine.time_scale 仍为 %.2f（_exit_tree 兜底）" % global_scale)


## ---------- 23a. GameMode 的静态契约 ----------
func _run_p3_static_contracts() -> void:
	var gm := _game_mode()
	var pool := _card_pool()
	var gen := _level_generator()
	_check(gm != null and pool != null and gen != null,
		"三套 P3 脚本都能加载（game_mode / card_pool / level_generator）")
	if gm == null or pool == null or gen == null:
		return

	var gconsts: Dictionary = gm.get_script_constant_map()
	var modes: Dictionary = gconsts.get("Mode", {})
	var mode_names: Array = gconsts.get("MODE_NAMES", [])
	var mode_count := int(gconsts.get("MODE_COUNT", 0))
	_check(modes.size() == 3 and mode_names.size() == mode_count,
		"GameMode.Mode 有 3 项且与 MODE_NAMES / MODE_COUNT 等长（%d/%d/%d）"
		% [modes.size(), mode_names.size(), mode_count])
	_check(int(gconsts.get("CLASSIC_SEED", -1)) == 0,
		"CLASSIC_SEED 是 0（0 是 LevelGenerator「原样返回模板」的保留语义）")

	var classic := int(modes.get("CLASSIC", -1))
	var run_mode := int(modes.get("RUN", -1))
	var daily := int(modes.get("DAILY", -1))
	for m: int in [classic, run_mode, daily]:
		if m < 0:
			return
	var name_bad: Array = []
	for m: int in [classic, run_mode, daily]:
		if gm.call("mode_name", m) != String(mode_names[m]):
			name_bad.append(m)
	_check(name_bad.is_empty(), "mode_name(i) == MODE_NAMES[i]（错 %s）" % str(name_bad))
	_check(not bool(gm.call("is_endless", classic)) and bool(gm.call("is_endless", run_mode))
			and bool(gm.call("is_endless", daily)),
		"只有无尽与每日是无尽关卡（经典有最后一关）")
	_check(not bool(gm.call("has_cards", classic)) and bool(gm.call("has_cards", run_mode)),
		"只有无尽与每日抽卡（经典保持 P0/P1 的原样流程）")
	_check(not bool(gm.call("tracks_progress", classic))
			and bool(gm.call("tracks_progress", daily)),
		"经典模式不写长期档案")

	# 稳定哈希：每日挑战的全部前提。同一输入必得同值，不同输入不得同值。
	var hash_script_ok := true
	if int(gm.call("stable_hash", "abc")) != int(gm.call("stable_hash", "abc")) \
			or int(gm.call("stable_hash", "abc")) == int(gm.call("stable_hash", "abd")) \
			or int(gm.call("stable_hash", "")) != 2166136261:
		hash_script_ok = false
	_check(hash_script_ok,
		"stable_hash 是自实现的 FNV-1a（不是随引擎版本漂移的内置 hash）")

	var date_text := String(gm.call("daily_date_text"))
	var date_ok := date_text.length() == 10 and date_text.substr(4, 1) == "-" \
		and date_text.substr(7, 1) == "-"
	_check(date_ok, "每日日期为 YYYY-MM-DD 格式（%s）" % date_text)
	var daily_seed := int(gm.call("daily_seed"))
	var expected_seed := int(gm.call("stable_hash", "daily:" + date_text)) \
		& int(gconsts.get("SEED_MASK", 0x7FFFFFFF))
	_check(daily_seed == expected_seed and daily_seed > 0,
		"每日种子只由日期推导，重复调用恒等（%d）" % daily_seed)
	_check(int(gm.call("daily_day_index")) > 0, "每日 UTC 天序号可用于连续天数计算")

	# 种子码：可抄写，长度固定，字符表受限
	var seed_len := int(gconsts.get("SEED_TEXT_LENGTH", 0))
	var alphabet := String(gconsts.get("SEED_ALPHABET", ""))
	var code := String(gm.call("seed_text", 123456789))
	var code_chars_ok := code.length() == seed_len
	for i in code.length():
		if not alphabet.contains(code[i]):
			code_chars_ok = false
	_check(code_chars_ok and seed_len > 0,
		"种子码长度固定且只用去混淆字符表（%s）" % code)
	var codes_unique := true
	var seen_codes := {}
	for v: int in [1, 2, 3, 4, 5, 12345, 999999, 1073741823]:
		var text := String(gm.call("seed_text", v))
		if seen_codes.has(text):
			codes_unique = false
		seen_codes[text] = true
	_check(codes_unique, "不同种子的种子码互不相同")

	# seed_for_mode 必须挡住非经典模式拿到保留值 0，
	# 否则无尽模式会拿到「原样模板」的墙，整局和经典没区别。
	var forced := int(gm.call("seed_for_mode", run_mode, 0))
	_check(forced != 0, "非经典模式不会拿到保留种子 0（得到 %d）" % forced)
	_check(int(gm.call("seed_for_mode", classic, 987654)) == 0,
		"经典模式无论传什么都固定为 0（种子 0 就是模板原样）")
	_check(int(gm.call("begin_seed", classic)) == 0
			and int(gm.call("begin_seed", daily)) == daily_seed,
		"begin_seed：经典恒 0、每日按当天日期")


## ---------- 23b. LevelGenerator 的静态契约 ----------
func _run_p3_level_generator() -> void:
	var gm := _game_mode()
	var gen := _level_generator()
	if gm == null or gen == null:
		return
	var rows: int = _brick_layout.size()
	var cols: int = int((_brick_layout[0] as Array).size()) if rows > 0 else 0
	var template_pristine := LevelGenerator.copy_layout(_brick_layout)

	# 种子 0 必须逐位等于模板：经典模式的墙、老玩家的肌肉记忆、
	# 以及第 22b 节那条「运行时砖墙逐格对上 BRICK_LAYOUT」全靠这一条。
	var verbatim := 0
	for level in 5:
		var zero_layout: Array = gen.call("generate", 0, level + 1, _brick_layout)
		for r in rows:
			for c in cols:
				if int(zero_layout[r][c]) != int(template_pristine[r][c]):
					verbatim += 1
	_check(verbatim == 0, "种子 0 在任意关卡都逐位等于模板（差异 %d 格）" % verbatim)

	# 模板本身不能被生成过程写脏（BRICK_LAYOUT 是只读常量，
	# 但生成器要是图省事直接返回原引用，改的就会是玩家的下一关）
	gen.call("generate", 4242, 2, _brick_layout)
	var template_dirty := 0
	for r in rows:
		for c in cols:
			if int(_brick_layout[r][c]) != int(template_pristine[r][c]):
				template_dirty += 1
	_check(template_dirty == 0, "生成过程不回写传入的模板（被改 %d 格）" % template_dirty)

	var anchors_ok := true
	for r in rows:
		for c in cols:
			var want_anchor := r == 0 or (r == rows - 1 and (c == cols - 1 or c == cols - 2))
			if bool(gen.call("is_anchor", r, c, rows, cols)) != want_anchor:
				anchors_ok = false
	_check(anchors_ok,
		"is_anchor 只认「第 0 行整行 + 末行最后两块」（第 14 / 15 节的断言锚点）")

	var k_normal := _kind("NORMAL")
	var template_kinds := {}
	for row in template_pristine:
		for value in row:
			if int(value) != k_normal:
				template_kinds[int(value)] = true

	var shape_bad := 0
	var anchor_bad := 0
	var kind_bad := 0
	var missing_kinds: Array = []
	var deterministic_bad := 0
	var different_from_template := 0
	var total_specials := {}
	var test_seeds := [1, 7, 12345, 99991, 20261005, 2147483647]
	for run_seed: int in test_seeds:
		for level in 4:
			var layout: Array = gen.call("generate", run_seed, level + 1, _brick_layout)
			if layout.size() != rows:
				shape_bad += 1
				continue
			var again: Array = gen.call("generate", run_seed, level + 1, _brick_layout)
			if _layout_diff(layout, again) > 0:
				deterministic_bad += 1
			if _layout_diff(layout, template_pristine) > 0:
				different_from_template += 1
			total_specials[level + 1] = maxi(int(total_specials.get(level + 1, 0)),
				int(gen.call("count_specials", layout)))
			var present := {}
			for r in rows:
				var row: Array = layout[r] as Array
				if row.size() != cols:
					shape_bad += 1
				for c in cols:
					var kind := int(row[c])
					if kind < 0 or kind >= _kinds.size():
						kind_bad += 1
					elif kind != k_normal:
						present[kind] = true
					if bool(gen.call("is_anchor", r, c, rows, cols)) and kind != k_normal:
						anchor_bad += 1
			for kind_value: int in template_kinds.keys():
				if not present.has(kind_value):
					missing_kinds.append("%d:L%d" % [kind_value, level + 1])

	_check(shape_bad == 0, "任意种子下砖墙行列数不变（形状异常 %d 次）" % shape_bad)
	_check(kind_bad == 0, "任意种子下每个 kind 都落在 Brick.Kind 范围内（越界 %d 处）" % kind_bad)
	_check(anchor_bad == 0,
		"任意种子下锚点格位始终是普通砖（被改 %d 格）" % anchor_bad)
	_check(missing_kinds.is_empty(),
		"任意种子下模板出现过的特殊砖都至少保留一块（缺 %s）" % str(missing_kinds))
	_check(deterministic_bad == 0,
		"同一对 (种子, 关卡) 必然生成同一张墙（不一致 %d 次）" % deterministic_bad)
	_check(different_from_template == test_seeds.size() * 4,
		"非 0 种子的墙与模板都不相同（%d/%d 组）"
		% [different_from_template, test_seeds.size() * 4])
	_check(int(total_specials.get(4, 0)) > int(total_specials.get(1, 0)),
		"特殊砖数量随关卡递增（第 1 关 %d → 第 4 关 %d）"
		% [int(total_specials.get(1, 0)), int(total_specials.get(4, 0))])

	# 同一局不同关必须是不同的墙，否则「每关重新生成」这件事对玩家不可见
	var per_level_same := 0
	for run_seed: int in test_seeds:
		var l1: Array = gen.call("generate", run_seed, 1, _brick_layout)
		var l2: Array = gen.call("generate", run_seed, 2, _brick_layout)
		if _layout_diff(l1, l2) == 0:
			per_level_same += 1
	_check(per_level_same == 0,
		"同一局的第 1 / 2 关长得不一样（相同 %d 组）" % per_level_same)

	# 两个不同种子之间也应当拉开距离，否则种子只是装饰
	var too_similar := 0
	for i in test_seeds.size():
		for j in range(i + 1, test_seeds.size()):
			var a: Array = gen.call("generate", test_seeds[i], 1, _brick_layout)
			var b: Array = gen.call("generate", test_seeds[j], 1, _brick_layout)
			var differing := 0
			for r in rows:
				for c in cols:
					if int(a[r][c]) != int(b[r][c]):
						differing += 1
			if differing < 2:
				too_similar += 1
	_check(too_similar == 0,
		"任意两个种子生成的墙都有可见差异（过近 %d 组）" % too_similar)


## 两张布局表逐格比对，返回不同的格数。
func _layout_diff(a: Array, b: Array) -> int:
	var differing := 0
	var rows: int = mini(a.size(), b.size())
	for r in rows:
		var row_a: Array = a[r] as Array
		var row_b: Array = b[r] as Array
		for c in mini(row_a.size(), row_b.size()):
			if int(row_a[c]) != int(row_b[c]):
				differing += 1
	return differing


## ---------- 23c. 菜单按钮 -> 开局（真实点击路径） ----------
func _run_p3_menu_flow() -> void:
	var gm := _game_mode()
	if gm == null:
		return
	var run_mode := _mode("RUN")
	var daily := _mode("DAILY")

	# —— 无尽：从菜单点「无尽挑战」 ——
	var scene: Node = await _spawn_scene()
	var menu := scene.get_node("MenuPanel") as MenuPanel
	_check(menu.has_signal("mode_chosen"), "玩法菜单暴露 mode_chosen 信号")
	_check(scene.get_node("MenuPanel/Panel/Margin/VBox/ClassicButton") is Button,
		"菜单提供经典模式按钮")
	_check(scene.get_node("MenuPanel/Panel/Margin/VBox/RunButton") is Button,
		"菜单提供无尽挑战按钮")
	_check(scene.get_node("MenuPanel/Panel/Margin/VBox/DailyButton") is Button,
		"菜单提供每日挑战按钮")
	var daily_info := String(scene.get_node("MenuPanel/Panel/Margin/VBox/DailyInfoLabel").text)
	_check(daily_info.contains(String(gm.call("seed_text", gm.call("daily_seed")))),
		"菜单上直接显示今日种子码（%s）" % daily_info)

	(menu.get_node("Panel/Margin/VBox/RunButton") as Button).pressed.emit()
	await _wait(3)
	_check(_gi(scene, "_state") == _state_playing, "点无尽挑战后进入 Playing 状态")
	_check(_gi(scene, "_mode") == run_mode, "无尽模式生效（mode = %d）" % _gi(scene, "_mode"))
	var run_seed := _gi(scene, "_seed")
	_check(run_seed != 0, "无尽模式拿到非 0 的随机种子（%d）" % run_seed)
	_check(not scene.get_node("MenuPanel/Panel").visible, "选完玩法后菜单收起")

	var mode_label: Label = scene.get_node("HUD/ModeLabel") as Label
	_check(mode_label.visible and mode_label.text.contains(String(gm.call("mode_name", run_mode)))
			and mode_label.text.contains(String(gm.call("seed_text", run_seed))),
		"HUD 常驻显示玩法与种子码（%s）" % mode_label.text)
	var level_label := String(scene.get_node("HUD/LevelLabel").text)
	_check(not level_label.contains("/"),
		"无尽模式关卡号不写「第 N / 3 关」（%s）" % level_label)

	# 顶层的「换玩法」：结算后的再来一局应该能回到菜单，而不是把模式打回经典
	scene.call("_settle", _state_game_over)
	await _wait(2)
	_send_action(&"launch")
	await _wait(4)
	_check(_gi(scene, "_mode") == run_mode,
		"无尽模式结算后重开仍是无尽（不会被场景重载打回经典）")
	_check(_gi(scene, "_seed") == run_seed, "重开沿用同一副牌（种子 %d）" % _gi(scene, "_seed"))
	_check(_gi(scene, "_level") == 1 and _gi(scene, "_score") == 0,
		"重开回到第 1 关且分数归零")
	_check(current_scene == scene, "无尽模式重开不整场景重载（节点是同一个）")
	scene.queue_free()
	await _wait(2)

	# —— 每日：从菜单点「每日挑战」 ——
	scene = await _spawn_scene()
	var daily_seed := int(gm.call("daily_seed"))
	(scene.get_node("MenuPanel/Panel/Margin/VBox/DailyButton") as Button).pressed.emit()
	await _wait(3)
	_check(_gi(scene, "_mode") == daily, "每日模式生效")
	_check(_gi(scene, "_seed") == daily_seed,
		"每日种子就是 GameMode.daily_seed()（%d）" % _gi(scene, "_seed"))
	var daily_layout: Array = scene.get("_level_layout") as Array
	var want_layout: Array = LevelGenerator.generate(daily_seed, 1, _brick_layout)
	_check(_layout_diff(daily_layout, want_layout) == 0,
		"每日第 1 关的墙 == 按今日种子生成的墙")
	_check(_layout_diff(daily_layout, _brick_layout) > 0,
		"每日第 1 关确实被程序化改写过（不是模板）")
	scene.queue_free()
	await _wait(2)

	# —— 经典：种子 0，墙逐位等于模板 ——
	scene = await _spawn_scene()
	(scene.get_node("MenuPanel/Panel/Margin/VBox/ClassicButton") as Button).pressed.emit()
	await _wait(3)
	_check(_gi(scene, "_seed") == 0, "经典模式种子为 0")
	_check(_layout_diff(scene.get("_level_layout") as Array, _brick_layout) == 0,
		"经典模式的墙逐位等于 BRICK_LAYOUT（P3 对老玩法完全透明）")
	_check(not (scene.get_node("HUD/ModeLabel") as Label).visible,
		"经典模式不显示玩法徽标（固定关卡不需要）")

	# —— 暂停面板上的「换个玩法」：不重开同一种子，而是回菜单 ——
	# 走真实按钮路径：这条线一旦只在代码里接好、按钮忘了连线，
	# 玩家按下去什么都不会发生，而自动测试完全看不出来。
	_send_action(&"pause")
	await _wait(2)
	_check(_gi(scene, "_state") == _state_paused and paused, "经典局可暂停")
	var menu_button := scene.get_node(PAUSE_VBOX + "/MenuButton") as Button
	_check(menu_button != null and menu_button.visible,
		"暂停面板提供「换个玩法」按钮（%s）"
		% ("" if menu_button == null else String(menu_button.text)))
	menu_button.pressed.emit()
	await _wait(3)
	_check(not paused, "点「换个玩法」后自动解除暂停")
	_check(_gi(scene, "_state") == _state_menu, "点「换个玩法」回到 Menu 状态")
	_check(scene.get_node("MenuPanel/Panel").visible, "玩法菜单重新打开")
	_check(not scene.get_node("PausePanel/Panel").visible, "暂停遮罩同时收起")
	# 换玩法的语义是「换」：同模式同种子重开会被玩家当成按钮坏了
	_check(_gi(scene, "_level") == 1, "回菜单不推进关卡进度")
	scene.queue_free()
	await _wait(2)


## ---------- 23d. 无尽对局：通关 -> 三选一 -> 卡牌生效 ----------
func _run_p3_endless_flow() -> void:
	var pool := _card_pool()
	if pool == null:
		return
	var gm := _game_mode()
	var run_mode := _mode("RUN")
	var scene: Node = await _spawn_scene()
	await _open_run(scene, run_mode, 20261005)

	var layout: Array = scene.get("_level_layout") as Array
	_check(_layout_diff(layout, _brick_layout) > 0,
		"无尽模式第 1 关的墙被种子改写过")
	var draft_panel := scene.get_node("CardDraftPanel") as CardDraftPanel
	_check(not draft_panel.is_open() and (draft_panel.offered as Array).is_empty(),
		"开局不发牌（发牌只发生在关卡通过之后）")

	# —— 清空第 1 关 -> 关卡通过 ——
	await _clear_current_level(scene, 1)
	_check(_gi(scene, "_state") == _state_level_clear,
		"无尽模式第 1 关清空后进入 Level Clear（没有 WON 这一说）")
	_check(String(scene.get_node(PANEL_VBOX + "/ContinueButton").text) == "抽卡牌",
		"结算面板按钮文案预告下一步是抽卡（%s）"
		% scene.get_node(PANEL_VBOX + "/ContinueButton").text)
	_check(String(scene.get_node("HUD/HintLabel").text).contains("卡牌"),
		"HUD 提示同步预告抽卡（%s）" % scene.get_node("HUD/HintLabel").text)

	# —— 继续 -> 抽卡界面 ——
	_send_action(&"restart")
	await _wait(4)
	_check(_gi(scene, "_state") == _state_draft, "关卡通过后进入 Draft 状态")
	_check(draft_panel.is_open(), "抽卡面板弹出")
	_check(not scene.get_node("GameOverPanel/Panel").visible, "抽卡时结算面板收起")
	var offered: Array = draft_panel.offered
	_check(offered.size() == int(pool.get_script_constant_map().get("DRAFT_SIZE", 0)),
		"发出 %d 张牌（实际 %d）" % [int(pool.get_script_constant_map().get("DRAFT_SIZE", 0)),
			offered.size()])
	var offered_ids := {}
	var offered_unique := true
	for card: Dictionary in offered:
		var card_id := String(card["id"])
		if offered_ids.has(card_id):
			offered_unique = false
		offered_ids[card_id] = true
	_check(offered_unique, "同一手牌不重复")
	var cards_root := draft_panel.get_node("Panel/Margin/VBox/Cards") as HBoxContainer
	_check(cards_root.get_child_count() == offered.size(),
		"卡面节点数与牌数一致（%d 个）" % cards_root.get_child_count())
	var first_button := _draft_button(draft_panel, 0)
	_check(first_button != null and first_button.has_focus(),
		"抽卡面板把焦点落在第一张牌上（回车即可确认）")
	var sub_text := String(draft_panel.get_node("Panel/Margin/VBox/SubLabel").text)
	_check(sub_text.contains("第 1 关通过") and sub_text.contains("0 张"),
		"副标题写明刚通过的关卡与本局已选张数（%s）" % sub_text)

	# 同一手牌必须是「这一关的这个种子」唯一确定的，否则每日挑战无法比较成绩
	var replay: Array = pool.call("draft", 20261005, 1, {}, 0)
	var replay_ids := {}
	for card: Dictionary in replay:
		replay_ids[String(card["id"])] = true
	var replay_match := replay_ids.size() == offered_ids.size()
	for card_id: String in offered_ids.keys():
		if not replay_ids.has(card_id):
			replay_match = false
	_check(replay_match, "同一关同一子数的抽卡结果可复现（每日挑战同一天必须一致）")

	# —— 点第一张牌的「选择」按钮 ——
	var chosen: Dictionary = offered[0]
	var mods: Dictionary = chosen["mods"] as Dictionary
	var score_mult := int(mods.get("score_mult", 1))
	var brick_hits_add := int(mods.get("brick_hits", 0))
	var armor_add := int(mods.get("armor_add", 0))
	var paddle_bonus := float(mods.get("paddle_bonus", 0.0))
	var lives_bonus := int(mods.get("extra_lives", 0))
	var max_lives_add := int(mods.get("max_lives_add", 0))

	first_button.pressed.emit()
	await _wait(4)
	_check(not draft_panel.is_open(), "选牌后面板收起")
	_check(_gi(scene, "_state") == _state_playing, "选牌后回到 Playing 状态")
	_check(_gi(scene, "_level") == 2, "选牌后进入第 2 关（当前 %d）" % _gi(scene, "_level"))
	_check(_gi(scene, "_card_taken") == 1, "本局已选卡数记为 1")
	var owned: Dictionary = scene.get("_card_owned") as Dictionary
	_check(int(owned.get(String(chosen["id"]), 0)) == 1,
		"选中的卡记进本局持有表（%s）" % String(chosen["id"]))

	# 卡面每一类加成都在游戏里有着落
	var want_speed_mul := clampf(float(mods.get("speed_mul", 1.0)),
		float(_main_const("CARD_SPEED_MUL_MIN", 0.0)), float(_main_const("CARD_SPEED_MUL_MAX", 9.0)))
	_check(is_equal_approx(float(scene.call("_card_speed_mul")), want_speed_mul),
		"球速倍率生效（%.4f）" % float(scene.call("_card_speed_mul")))
	_check(is_equal_approx(float(scene.call("_card_blast_radius")),
			_blast_radius + float(mods.get("blast_add", 0.0))),
		"爆炸半径生效（%.1f）" % float(scene.call("_card_blast_radius")))
	_check(is_equal_approx(float(scene.call("_card_slow_seconds")),
			_slow_seconds + float(mods.get("slow_add", 0.0))),
		"减速时长生效（%.1f 秒）" % float(scene.call("_card_slow_seconds")))
	_check(float(scene.call("_card_split_spread_deg"))
			>= _split_spread_deg - 0.001,
		"分裂夹角随卡牌不减小（%.1f 度）" % float(scene.call("_card_split_spread_deg")))

	var balls := _balls(scene)
	var want_cap := _max_balls + int(mods.get("max_balls_add", 0))
	_check(int(scene.call("_card_max_balls")) == want_cap
			and int(balls.get("max_balls_cap")) == want_cap,
		"同屏球数上限写入 BallManager（%d）" % int(balls.get("max_balls_cap")))

	# 加成要真正落到砖块属性上，而不是只存在卡表里
	var bricks2: Node2D = scene.get_node("Bricks")
	var base_hits2 := _base_hits_for_level(2)
	var points_bad := 0
	var hits_bad := 0
	for child in bricks2.get_children():
		var brick := child as Brick
		var want_points := _points_per_brick * int(_kind_mult[int(brick.kind)]) * score_mult
		var want_hits := base_hits2 + brick_hits_add \
			+ (_armor_extra_hits + armor_add if int(brick.kind) == _kind("ARMORED") else 0)
		if brick.points != want_points:
			points_bad += 1
		if int(brick.max_hits) != want_hits:
			hits_bad += 1
	_check(points_bad == 0, "分数倍率写进每块砖的 points（错 %d 块）" % points_bad)
	_check(hits_bad == 0,
		"耐久加成写进每块砖的 max_hits（错 %d 块，本关标准 %d）" % [hits_bad, base_hits2])
	_check(absf(_gf(scene.get_node("Paddle"), "paddle_width")
			- (float(_paddle_widths[0]) + paddle_bonus)) < 0.01,
		"挡板加宽落到挡板（%.1f）" % _gf(scene.get_node("Paddle"), "paddle_width"))
	_check(_gi(scene, "_lives") == mini(_start_lives + lives_bonus, _max_lives + max_lives_add),
		"即时生命加成当场生效（%d 条命）" % _gi(scene, "_lives"))

	# 分数倍率是整数，「总分是每块砖分值整数倍」这条不变量才成立
	var first_points := (_find_kind(bricks2, _kind("NORMAL")) as Brick).points
	_check(first_points % _points_per_brick == 0,
		"分数倍率是整数倍，分值 %d 仍是每块砖基础分的整数倍" % first_points)

	# —— 跳过也能进下一关 ——
	await _clear_current_level(scene, 1)
	_send_action(&"restart")
	await _wait(4)
	_check(_gi(scene, "_state") == _state_draft and draft_panel.is_open(),
		"第 2 关通过后再次抽卡")
	_send_action(&"restart")
	await _wait(4)
	_check(_gi(scene, "_level") == 3 and _gi(scene, "_state") == _state_playing,
		"跳过抽卡直接进第 3 关（当前 %d 关）" % _gi(scene, "_level"))
	_check(_gi(scene, "_card_taken") == 1, "跳过不增加已选张数")
	scene.queue_free()
	await _wait(2)

	# —— 键盘 1 / 2 / 3 选牌与 R 跳过 ——
	scene = await _spawn_scene()
	await _open_run(scene, run_mode, 777)
	await _clear_current_level(scene, 1)
	_send_action(&"restart")
	await _wait(4)
	_check(_gi(scene, "_state") == _state_draft, "无尽模式可重复进入抽卡界面")
	draft_panel = scene.get_node("CardDraftPanel") as CardDraftPanel
	_send_key(KEY_2)
	await _wait(4)
	_check(_gi(scene, "_level") == 2 and _gi(scene, "_card_taken") == 1,
		"数字键 2 选中第二张牌并进入下一关")
	await _clear_current_level(scene, 1)
	_send_action(&"restart")
	await _wait(4)
	_send_key(KEY_R)
	await _wait(4)
	_check(_gi(scene, "_level") == 3 and _gi(scene, "_card_taken") == 1,
		"R 键跳过抽卡（已选张数不变）")
	scene.queue_free()
	await _wait(2)


## 送一次按键（走真实的 _unhandled_input 分发）。
## 用 parse_input_event 而不是 action_press：数字键不在 InputMap 里，
## 只有事件派发这一条路能到达 Main 的 keycode 分支。
func _send_key(keycode: Key) -> void:
	var press := InputEventKey.new()
	press.keycode = keycode
	press.physical_keycode = keycode
	press.pressed = true
	Input.parse_input_event(press)
	var release := InputEventKey.new()
	release.keycode = keycode
	release.physical_keycode = keycode
	release.pressed = false
	Input.parse_input_event(release)


## ---------- 23e. 卡牌加成的叠算规则（加法 / 乘法 / 即时） ----------
func _run_p3_card_algebra() -> void:
	var pool := _card_pool()
	if pool == null:
		return
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 31337)

	var wide := CardPool.card_by_id("wide")
	var swift := CardPool.card_by_id("swift")
	var greedy := CardPool.card_by_id("greedy")
	var ward := CardPool.card_by_id("ward")
	var fountain := CardPool.card_by_id("fountain")
	_check(not wide.is_empty() and not swift.is_empty() and not greedy.is_empty()
			and not ward.is_empty() and not fountain.is_empty(),
		"卡表里能找到加法 / 乘法 / 即时三类代表卡")

	# 加法型：两张「宽板」叠成两倍加宽
	var wide_add := float((wide["mods"] as Dictionary).get("paddle_bonus", 0.0))
	scene.call("_apply_card", wide)
	scene.call("_apply_card", wide)
	_check(is_equal_approx(float(scene.call("_card_paddle_bonus")), wide_add * 2.0),
		"加法型卡叠加（挡板 +%.1f）" % float(scene.call("_card_paddle_bonus")))
	# 乘法型：两张「疾风」叠成倍率的平方
	var swift_mul := float((swift["mods"] as Dictionary).get("speed_mul", 1.0))
	scene.call("_apply_card", swift)
	scene.call("_apply_card", swift)
	_check(is_equal_approx(float(scene.call("_card_speed_mul")), swift_mul * swift_mul),
		"乘法型卡叠乘（球速 ×%.4f）" % float(scene.call("_card_speed_mul")))

	scene.call("_reset_cards")
	scene.call("_apply_card", greedy)
	scene.call("_apply_card", greedy)
	_check(int(scene.call("_card_score_mult")) == 4,
		"两张「贪婪」把分数倍率叠到 4 倍（实际 %d）" % int(scene.call("_card_score_mult")))
	scene.call("_reset_cards")
	scene.call("_apply_card", ward)
	scene.call("_apply_card", ward)
	_check(_gi(scene, "_shield") == 2, "两张「护盾」叠出 2 次抵消（实际 %d）" % _gi(scene, "_shield"))

	scene.call("_reset_cards")
	var extra := int((fountain["mods"] as Dictionary).get("extra_lives", 0))
	var cap_add := int((fountain["mods"] as Dictionary).get("max_lives_add", 0))
	scene.call("_apply_card", fountain)
	_check(_gi(scene, "_lives") == mini(_start_lives + extra, _max_lives + cap_add),
		"「生命之泉」当场加命并抬高上限（%d 条命 / 上限 %d）"
		% [_gi(scene, "_lives"), int(scene.call("_max_lives"))])
	# 即时键不进累积表：否则「加 2 命」会在之后每次查询时被重复执行
	var mods_now: Dictionary = scene.get("_card_mods") as Dictionary
	_check(not mods_now.has("extra_lives"),
		"即时型键不进累积加成表（不会被反复结算）")

	# 空卡防御：面板在牌池见底时会发 draft_skipped 而不是选中一张空卡
	scene.call("_reset_cards")
	scene.call("_apply_card", {})
	_check(_gi(scene, "_card_taken") == 0, "空卡字典被安全忽略")

	# 新一局清空全部卡牌：卡牌是「本局内」的成长，跨局继承会让第二局没牌可抽
	scene.call("_apply_card", greedy)
	scene.call("_start_new_game")
	_check(_gi(scene, "_card_taken") == 0 and int(scene.call("_card_score_mult")) == 1,
		"新一局清空全部卡牌状态")
	scene.queue_free()
	await _wait(2)


## ---------- 23f. 卡池：上限、确定性、保底 ----------
func _run_p3_card_pool() -> void:
	var pool := _card_pool()
	if pool == null:
		return
	var pconsts := pool.get_script_constant_map()
	var cards: Array = pconsts.get("CARDS", [])
	var rarity_names: Array = pconsts.get("RARITY_NAMES", [])
	var rarity_weights: Array = pconsts.get("RARITY_WEIGHTS", [])
	var rare_from := int(pconsts.get("RARE_FROM_LEVEL", 0))
	_check(cards.size() >= 10,
		"卡池至少 10 张（实际 %d 张，够三选一重复出牌不重样）" % cards.size())
	_check(rarity_weights.size() == rarity_names.size(),
		"稀有度权重表与名称表等长（%d/%d）"
		% [rarity_weights.size(), rarity_names.size()])

	var id_bad: Array = []
	var rarity_bad: Array = []
	var stack_bad: Array = []
	var weight_bad: Array = []
	var unknown_key: Array = []
	var non_int_mult: Array = []
	var empty_copy: Array = []
	var seen_ids := {}
	for card: Dictionary in cards:
		var card_id := String(card["id"])
		if seen_ids.has(card_id):
			id_bad.append(card_id)
		seen_ids[card_id] = true
		if String(card["name"]).is_empty() or String(card["desc"]).is_empty():
			empty_copy.append(card_id)
		var rarity := int(card["rarity"])
		if rarity < 0 or rarity >= rarity_names.size():
			rarity_bad.append(card_id)
		if int(card["max_stack"]) < 1:
			stack_bad.append(card_id)
		if int(card["weight"]) < 1:
			weight_bad.append(card_id)
		for key: String in (card["mods"] as Dictionary):
			if not CardPool.is_additive(key) and not CardPool.is_multiplied(key) \
					and not CardPool.is_immediate(key):
				unknown_key.append("%s:%s" % [card_id, key])
			if CardPool.is_multiplied(key) and key != "speed_mul" \
					and float((card["mods"] as Dictionary)[key]) != roundf(float((card["mods"] as Dictionary)[key])):
				non_int_mult.append("%s:%s" % [card_id, key])
	_check(id_bad.is_empty(), "每张卡的 id 唯一（重复 %s）" % str(id_bad))
	_check(empty_copy.is_empty(), "每张卡都有名字与说明（缺文案 %s）" % str(empty_copy))
	_check(rarity_bad.is_empty(), "稀有度落在名称表范围内（越界 %s）" % str(rarity_bad))
	_check(stack_bad.is_empty(), "每张卡都有可用的叠加上限（错 %s）" % str(stack_bad))
	_check(weight_bad.is_empty(), "每张卡都有正权重（错 %s）" % str(weight_bad))
	_check(unknown_key.is_empty(),
		"每张卡的 mods 键都在三张白名单里（未知键 %s）" % str(unknown_key))
	_check(non_int_mult.is_empty(),
		"分数 / 连击倍率都是整数（否则打破「总分是基础分整数倍」的不变量）：%s" % str(non_int_mult))

	_check(CardPool.card_by_id("__不存在__").is_empty(), "查不到 id 时返回空字典而不是 null")
	_check(CardPool.eligible_ids({}).size() == cards.size(), "没选过牌时全部卡都可抽")

	# 叠满的卡不再出现
	var owned := {}
	var maxed_id := String(cards[0]["id"])
	owned[maxed_id] = int(cards[0]["max_stack"])
	var leaked := 0
	for s in 8:
		for card: Dictionary in pool.call("draft", s * 7919 + 1, 1, owned, 0):
			if String(card["id"]) == maxed_id:
				leaked += 1
	_check(leaked == 0, "叠满 %s（%d 张）之后不再出现（漏 %d 次）"
		% [maxed_id, int(cards[0]["max_stack"]), leaked])

	# 全叠满时抽卡返回空数组，Main 靠它走「跳过」而不是卡在空界面
	var all_maxed := {}
	for card: Dictionary in cards:
		all_maxed[String(card["id"])] = int(card["max_stack"])
	_check((pool.call("draft", 1234, 1, all_maxed, 0) as Array).is_empty()
			and CardPool.eligible_ids(all_maxed).is_empty(),
		"全部叠满时牌池见底（发空数组，界面自动跳过）")

	# 确定性 + 无重复 + 保底
	var size := int(pconsts.get("DRAFT_SIZE", 0))
	var nondeterministic := 0
	var repeated := 0
	var rare_miss := 0
	var salt_varied := false
	for s in 20:
		var run_seed := 1000 + s * 104729
		var hand: Array = pool.call("draft", run_seed, 1, {}, 0)
		var again: Array = pool.call("draft", run_seed, 1, {}, 0)
		if _hand_ids(hand) != _hand_ids(again):
			nondeterministic += 1
		if hand.size() != mini(size, cards.size()):
			repeated += 1
		var unique := {}
		for card_id: String in _hand_ids(hand):
			if unique.has(card_id):
				repeated += 1
			unique[card_id] = true
		# 盐必须真的参与抽卡，否则玩家「跳过再抽」永远看到同一手牌。
		# 不断言「每次换盐都换一手」——15 选 3 的两张手牌本来就可能撞车，
		# 把它写成硬要求等于给自己埋一条偶发红灯。真正要保证的是
		# 「盐参与了运算」：固定种子下扫一批盐，必须出现过不止一手牌。
		for salt in 8:
			var salted := _hand_ids(pool.call("draft", run_seed, 1, {}, salt))
			if salted != _hand_ids(hand):
				salt_varied = true
				break
		# 保底：第 RARE_FROM_LEVEL 关起至少一张稀有及以上
		var has_rare := false
		for card: Dictionary in pool.call("draft", run_seed, rare_from, {}, 0):
			if int(card["rarity"]) > 0:
				has_rare = true
		if not has_rare:
			rare_miss += 1
		# 稀有度名称与索引对齐
		for card: Dictionary in hand:
			var rarity := int(card["rarity"])
			if CardPool.rarity_name(rarity) != String(rarity_names[rarity]):
				repeated += 1
	_check(nondeterministic == 0,
		"抽卡只由 (种子, 关卡, 持有, 盐) 决定，不碰全局随机（漂移 %d 次）" % nondeterministic)
	_check(rare_miss == 0,
		"第 %d 关起每次都至少给一张稀有及以上（缺 %d/%d）" % [rare_from, rare_miss, 20])
	_check(repeated == 0, "每手牌张数正确、互不重复，稀有度名称与索引对齐")
	_check(salt_varied, "盐参与抽卡运算（跳过再抽能看到不同的一手牌）")


## 手牌 id 列表（保持顺序，用于逐项比对）。
func _hand_ids(hand: Array) -> Array:
	var ids: Array = []
	for card: Dictionary in hand:
		ids.append(String(card["id"]))
	return ids


## ---------- 23g. 护盾：抵消一次掉球 ----------
func _run_p3_shield() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 555)
	scene.set("_lives", _start_lives - 1)
	var width_before := _gf(scene.get_node("Paddle"), "paddle_width")
	scene.call("_apply_card", CardPool.card_by_id("ward"))
	await _wait(1)
	_check(_gi(scene, "_shield") == 1, "「护盾」给出 1 次抵消")

	var balls := _balls(scene)
	(balls.primary().fell_out_of_playfield as Signal).emit()
	await _wait(3)
	_check(_gi(scene, "_shield") == 0, "掉球被护盾吃掉（剩余 %d）" % _gi(scene, "_shield"))
	_check(_gi(scene, "_lives") == _start_lives - 1,
		"护盾生效时不扣命（仍 %d 条）" % _gi(scene, "_lives"))
	_check(_gi(scene, "_state") == _state_playing, "护盾生效后仍在 Playing 状态")
	_check(absf(_gf(scene.get_node("Paddle"), "paddle_width") - width_before) < 0.01,
		"护盾生效时挡板不收窄（护盾只挡球，不该顺手降低难度）")
	_check(bool(balls.primary().get("attached_to_paddle")),
		"护盾生效后主球重新吸附待发")
	# 护盾必须真的把球救回来：球已经出界，「不扣命」本身不够，
	# 否则玩家看到的是球凭空消失，还得再发一次。
	_check(balls.primary().position.y < _view_height, "护盾生效后主球回到场内（%.0f）"
		% balls.primary().position.y)

	(balls.primary().fell_out_of_playfield as Signal).emit()
	await _wait(3)
	_check(_gi(scene, "_lives") == _start_lives - 2,
		"护盾用尽后再掉球正常扣命（%d 条）" % _gi(scene, "_lives"))
	_check(_gf(scene.get_node("Paddle"), "paddle_width") < width_before,
		"真正扣命后挡板照常收窄")
	scene.queue_free()
	await _wait(2)


## ---------- 23h. 「重铸」：一次性改写下一关的墙 ----------
func _run_p3_reforge() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 24680)
	scene.call("_apply_card", CardPool.card_by_id("reforge"))
	_check(int((scene.get("_card_mods") as Dictionary).get("reroll", 0)) == 1,
		"「重铸」待生效标记已置位")

	var reforge_seed := int(scene.call("_layout_seed"))
	_check(reforge_seed != 0,
		"待生效时本关种子改用一次性随机值（%d）" % reforge_seed)
	_check(int((scene.get("_card_mods") as Dictionary).get("reroll", 0)) == 0,
		"标记在取种子的同一次调用里被清掉（否则之后每关都会换墙）")
	_check(int(scene.call("_layout_seed")) == 24680,
		"下一关起恢复用本局种子（%d）" % int(scene.call("_layout_seed")))

	scene.queue_free()
	await _wait(2)


## ---------- 23i. 每日挑战：种子、档案、连续天数 ----------
func _run_p3_daily() -> void:
	var gm := _game_mode()
	if gm == null:
		return
	var daily := _mode("DAILY")
	var today := int(gm.call("daily_day_index"))
	var meta := _meta_progress()

	# —— 连续天数的三条分支 ——
	# 先删盘：record_run 是单调的，不清盘的话「档案为空」这条断言必然失败，
	# 而后面几条又会因为盘上残留着旧值而测不出真实的分支行为。
	_clear_meta()
	_check(int(meta.call("daily_streak")) == 0 and int(meta.call("daily_best")) == 0,
		"档案为空时每日最佳与连续天数都是 0")

	meta.call("record_run", daily, 100, 500)
	_check(int(meta.call("daily_best")) == 500 and int(meta.call("daily_streak")) == 1,
		"第一次打每日挑战：记当日最佳 %d、连续 1 天"
		% int(meta.call("daily_best")))

	# 同一天再打一次：分数更低不许覆盖，连击天数也不能重复 +1
	meta.call("record_run", daily, 100, 300)
	_check(int(meta.call("daily_best")) == 500 and int(meta.call("daily_streak")) == 1,
		"同日低分不覆盖当日最佳、连续天数不重复累加")

	# 昨天打过 -> 连续 +1
	_seed_meta({"daily_best": 500, "daily_day": today - 1, "daily_streak": 4})
	meta.call("record_run", daily, 100, 600)
	_check(int(meta.call("daily_streak")) == 5 and int(meta.call("daily_best")) == 600,
		"隔一天续上：连续天数 4 -> %d，当日最佳刷到 600"
		% int(meta.call("daily_streak")))

	# 断档 -> 连续天数重置为 1
	_seed_meta({"daily_day": today - 3, "daily_streak": 9})
	meta.call("record_run", daily, 100, 700)
	_check(int(meta.call("daily_streak")) == 1,
		"断档三天后重新计数（连续 %d 天）" % int(meta.call("daily_streak")))

	# 无尽模式记在它自己的档案里，不污染每日
	var run_mode := _mode("RUN")
	meta.call("record_run", run_mode, 8888, 1234)
	_check(int(meta.call("run_best")) == 1234 and int(meta.call("daily_best")) == 700,
		"无尽成绩写进无尽档案，不影响每日最佳")
	meta.call("record_run", _mode_classic(), 0, 9999)
	_check(int(meta.call("run_best")) == 1234 and int(meta.call("daily_best")) == 700,
		"经典模式不写长期档案")

	# —— 真实对局：每日种子决定整局的墙与牌 ——
	var scene: Node = await _spawn_scene()
	await _open_run(scene, daily)
	var daily_seed := _gi(scene, "_seed")
	_check(daily_seed == int(gm.call("daily_seed")),
		"每日模式开局拿到今日种子（%d）" % daily_seed)
	_clear_meta()
	await _clear_current_level(scene, 1)
	_check(_gi(scene, "_state") == _state_level_clear, "每日模式也能清关进入结算")
	_check(int(meta.call("daily_best")) == _gi(scene, "_score"),
		"清关即记账：当日最佳 %d == 本局分数 %d"
		% [int(meta.call("daily_best")), _gi(scene, "_score")])
	_check(int(meta.call("daily_streak")) == 1,
		"清一次每日挑战把连续天数记成 1")
	var run_info := String(scene.get_node("MenuPanel/Panel/Margin/VBox/RunInfoLabel").text)
	_check(run_info.contains("无尽最佳"), "菜单上的无尽成绩行存在（%s）" % run_info)
	scene.queue_free()
	await _wait(2)


## ---------- 23j. 抽卡面板反复发牌不堆残影 ----------
func _run_p3_draft_panel_rebuild() -> void:
	var scene: Node = await _spawn_scene()
	await _open_run(scene, _mode("RUN"), 4242)
	var panel := scene.get_node("CardDraftPanel") as CardDraftPanel
	var cards_root := panel.get_node("Panel/Margin/VBox/Cards") as HBoxContainer
	for round_index in 3:
		panel.present(CardPool.draft(4242, round_index + 1, {}, round_index), round_index + 1,
			round_index, null)
		await _wait(2)
	_check(cards_root.get_child_count() == CardPool.DRAFT_SIZE,
		"连续发 3 手牌后卡面容器仍是 %d 个（不堆残影）" % cards_root.get_child_count())

	# 空牌 = 自动跳过，界面不会卡住
	var skipped := [false]
	panel.draft_skipped.connect(func() -> void: skipped[0] = true)
	panel.present([], 9, 0, null)
	await _wait(2)
	_check(skipped[0] and not panel.is_open(),
		"发空牌（牌池见底）时面板自动跳过而不是卡在空界面")
	panel.hide_panel()
	scene.queue_free()
	await _wait(2)
