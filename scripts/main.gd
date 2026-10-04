class_name Main
extends Node2D
## 2DBreakout 主控脚本：
## 运行时生成砖墙、连接球与砖块的信号、管理分数/生命/暂停/关卡递进/通关/游戏结束、
## 最高分存档，以及音效、粒子碎屑、屏幕震动等手感反馈。

enum State { PLAYING, PAUSED, GAME_OVER, LEVEL_CLEAR, WON }

const VIEW_SIZE := Vector2(480, 720)
const WALL_THICKNESS := 14.0

# —— 砖墙布局 ——
const BRICK_ROWS := 6
const BRICK_COLUMNS := 8
const BRICK_SIZE := Vector2(48, 20)
const BRICK_GAP := 6.0
const BRICK_TOP := 110.0
const BRICK_TOTAL := BRICK_ROWS * BRICK_COLUMNS
const ROW_COLORS := [
	Color("f94144"), Color("f3722c"), Color("f9c74f"),
	Color("90be6d"), Color("43aa8b"), Color("4cc9f0"),
]

# —— 玩法数值 ——
const START_LIVES := 3
const POINTS_PER_BRICK := 10
const PADDLE_START_Y := 640.0
const DEATH_Y := 760.0

# —— 关卡递进 ——
const MAX_LEVEL := 3
## 每关砖块耐久（超出关卡数则循环取值）：第 1 关一击即碎，第 3 关需要打三次
const LEVEL_BRICK_HITS := [1, 2, 3]
## 每关球速，逐关加快
const LEVEL_BALL_SPEED := [430.0, 500.0, 570.0]
## 挡板宽度按「已失去的生命数」收窄，是主要的难度曲线
const PADDLE_WIDTH_STEPS := [108.0, 92.0, 76.0]

## 结算态集合：只有这三种状态下「继续/重开」输入才有效
const SETTLE_STATES := [State.GAME_OVER, State.LEVEL_CLEAR, State.WON]

@onready var bricks_root: Node2D = $Bricks
@onready var fx_root: Node2D = $Fx
@onready var paddle: Paddle = $Paddle
@onready var ball: Ball = $Ball
@onready var hud: GameHUD = $HUD
@onready var game_over_panel: GameOverPanel = $GameOverPanel
@onready var pause_panel: PausePanel = $PausePanel
## 音效与震动单例（autoload），用类型化引用访问
@onready var sfx: SfxBus = SfxBus.instance(self)
@onready var shake: ShakeBus = ShakeBus.instance(self)

var _state := State.PLAYING
var _score := 0
var _lives := START_LIVES
var _best := 0
var _level := 1
var _bricks_cleared := 0
var _restarting := false


func _ready() -> void:
	# 先从 user:// 下的存档读取历史最高分
	_best = HighScore.load_best()

	# 主控需要在暂停时依然接收输入，因此设为 ALWAYS；
	# 球与挡板单独设为 PAUSABLE，暂停时才会真正静止。
	process_mode = Node.PROCESS_MODE_ALWAYS
	ball.process_mode = Node.PROCESS_MODE_PAUSABLE
	paddle.process_mode = Node.PROCESS_MODE_PAUSABLE

	# 连接信号
	ball.brick_hit.connect(_on_brick_hit)
	ball.wall_hit.connect(_on_wall_hit)
	ball.paddle_hit.connect(_on_paddle_hit)
	ball.fell_out_of_playfield.connect(_on_ball_fell_out)
	paddle.ball_on_paddle.connect(_on_ball_on_paddle)
	game_over_panel.continue_requested.connect(_on_continue_requested)
	game_over_panel.quit_requested.connect(_on_quit_requested)
	pause_panel.resume_requested.connect(_on_resume_requested)
	pause_panel.quit_requested.connect(_on_quit_requested)

	_configure_playfield()
	_start_new_game()


## 依据墙体位置计算挡板活动范围与球的吸附/出界高度。
func _configure_playfield() -> void:
	paddle.position = Vector2(VIEW_SIZE.x * 0.5, PADDLE_START_Y)
	ball.stick_offset = paddle.paddle_height * 0.5 + ball.radius + 4.0
	ball.death_y = DEATH_Y
	# 卡死脱离的安全落点：砖墙最底边 + 球半径 + 余量，这条线以下一定是空场，
	# 球脱离后不会立刻又挤进下一行砖块里。
	ball.unstick_y = BRICK_TOP + (BRICK_ROWS - 1) * (BRICK_SIZE.y + BRICK_GAP) \
		+ BRICK_SIZE.y + ball.radius + 6.0


## 运行时按行按列生成砖块，耐久与球速按当前关卡取值。
func _build_bricks() -> void:
	for old_brick in bricks_root.get_children():
		old_brick.queue_free()

	var grid_width := BRICK_COLUMNS * BRICK_SIZE.x + (BRICK_COLUMNS - 1) * BRICK_GAP
	var start_x := (VIEW_SIZE.x - grid_width) * 0.5
	var hits: int = LEVEL_BRICK_HITS[(_level - 1) % LEVEL_BRICK_HITS.size()]

	for row in BRICK_ROWS:
		for column in BRICK_COLUMNS:
			var brick := Brick.new()
			brick.size = BRICK_SIZE
			brick.points = POINTS_PER_BRICK
			brick.color = ROW_COLORS[row % ROW_COLORS.size()]
			brick.max_hits = hits
			brick.hits_left = hits
			brick.position = Vector2(
				start_x + column * (BRICK_SIZE.x + BRICK_GAP) + BRICK_SIZE.x * 0.5,
				BRICK_TOP + row * (BRICK_SIZE.y + BRICK_GAP) + BRICK_SIZE.y * 0.5
			)
			bricks_root.add_child(brick)


## 开新一局：分数、生命、关卡全部归零。
func _start_new_game() -> void:
	_score = 0
	_lives = START_LIVES
	_level = 1
	_start_level()


## 开新一关：保留分数与生命，重建砖墙、套用本关球速与挡板宽度。
func _start_level() -> void:
	_state = State.PLAYING
	_bricks_cleared = 0
	ball.speed = LEVEL_BALL_SPEED[(_level - 1) % LEVEL_BALL_SPEED.size()]
	_build_bricks()
	_apply_paddle_width()
	# 结算时挡板被冻结，关卡推进不走场景重载，必须在这里显式恢复操控，
	# 否则从第 2 关起挡板永远是死的。
	paddle.input_enabled = true
	ball.stick_to(paddle)
	_update_hud()
	hud.set_hint(_launch_hint())


## 吸附等待发射时的统一提示文本（关卡推进后由传感器回调覆盖，两处必须一致）。
func _launch_hint() -> String:
	return "按 空格 发射球（第 %d 关 · 剩余生命 %d）" % [_level, _lives]


## 挡板宽度随已失去的生命收窄，并同步重算可活动范围。
func _apply_paddle_width() -> void:
	var lost := clampi(START_LIVES - _lives, 0, PADDLE_WIDTH_STEPS.size() - 1)
	paddle.set_width(PADDLE_WIDTH_STEPS[lost])
	paddle.left_bound = WALL_THICKNESS + paddle.paddle_width * 0.5
	paddle.right_bound = VIEW_SIZE.x - WALL_THICKNESS - paddle.paddle_width * 0.5
	paddle.global_position.x = clampf(paddle.global_position.x, paddle.left_bound, paddle.right_bound)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if _state == State.PLAYING:
			_set_paused(true)
		elif _state == State.PAUSED:
			_set_paused(false)
		get_viewport().set_input_as_handled()
	elif _state in SETTLE_STATES \
			and (event.is_action_pressed("launch") or event.is_action_pressed("restart")):
		_on_continue_requested()
	elif _state == State.PLAYING and event.is_action_pressed("launch"):
		# 球已在飞行时 launch() 内部会直接返回，音效也必须跟着一起跳过
		if ball.attached_to_paddle:
			ball.launch()
			_play_sfx("launch")


func _set_paused(paused: bool) -> void:
	_state = State.PAUSED if paused else State.PLAYING
	get_tree().paused = paused
	pause_panel.set_paused(paused)
	_play_sfx("ui")
	# 暂停瞬间归零震动，避免「已暂停」画面上相机还在随机跳动
	if paused:
		_reset_shake()


## 球撞到砖块：加分、播碎屑与音效；耐久耗尽才计入“已清除”，全部清除即结算。
func _on_brick_hit(brick: Node) -> void:
	if _state != State.PLAYING or not is_instance_valid(brick):
		return
	var typed := brick as Brick
	if typed == null:
		return

	_score += typed.hit()
	var destroyed := typed.is_destroyed()

	_spawn_sparks(typed.global_position, typed.color,
		22 if destroyed else 8, 1.0 if destroyed else 0.5)
	_play_sfx("brick" if destroyed else "crack")
	_add_shake(0.24 if destroyed else 0.12)
	_update_hud()

	if destroyed:
		_bricks_cleared += 1
		# 用计数器而不是 get_child_count() 判定通关：Brick.hit() 内部是 queue_free()，
		# 被击破的砖块要到帧末才从子节点移除，若最后一帧同时击破两块砖，
		# 计数会一直停在 2 之上，只查子节点数就会漏判。
		if _bricks_cleared >= BRICK_TOTAL:
			_settle(State.LEVEL_CLEAR if _level < MAX_LEVEL else State.WON)


## 球撞墙：轻震 + 短促音效。
func _on_wall_hit() -> void:
	if _state != State.PLAYING:
		return
	_play_sfx("wall")
	_add_shake(0.10)


## 球撞挡板：比墙稍强一点的反馈。
func _on_paddle_hit() -> void:
	if _state != State.PLAYING:
		return
	_play_sfx("paddle")
	_add_shake(0.14)


## 球掉出底部：生命 -1、挡板收窄，归零则游戏结束。
func _on_ball_fell_out() -> void:
	# 结算/暂停状态下不再扣命，避免球被重新吸附、盖掉结算面板
	if _state != State.PLAYING:
		return
	_lives -= 1
	_play_sfx("life")
	_add_shake(0.75)
	_apply_paddle_width()

	if _lives <= 0:
		_lives = 0
		_update_hud()
		_settle(State.GAME_OVER)
		return

	ball.stick_to(paddle)
	_update_hud()
	hud.set_hint(_launch_hint())


## 球吸附在挡板上时的提示（由 Paddle 的 Area2D 检测触发）。
func _on_ball_on_paddle(_ball: Node2D) -> void:
	if _state == State.PLAYING and ball.attached_to_paddle:
		hud.set_hint(_launch_hint())


## 在指定位置生成一次性碎屑粒子，播放完毕自行销毁。
## 参数必须在入树前配置好：CPUParticles2D 的 emitting 默认就是 true，
## 入树后再改 one_shot / 重力 / 颜色，依赖的是「新节点本帧不被粒子系统更新」这一隐含前提。
func _spawn_sparks(at: Vector2, color: Color, count: int, power: float) -> void:
	var burst := SparkBurst.new()
	burst.position = at
	burst.launch(color, count, power)
	fx_root.add_child(burst)


## 结算本局：破纪录则写存档并弹出结算面板。
## final_state 取 GAME_OVER / LEVEL_CLEAR / WON 之一。
func _settle(final_state: int) -> void:
	_state = final_state
	get_tree().paused = false
	pause_panel.set_paused(false)
	ball.set_active(false)
	# 结算后挡板不再响应输入，避免挡板在结算面板后面滑来滑去
	paddle.input_enabled = false

	var is_new_best := _save_best()
	_update_hud()

	match final_state:
		State.LEVEL_CLEAR:
			_play_sfx("clear")
			_add_shake(0.5)
			hud.set_hint("第 %d 关通过！按 空格 / R 进入下一关" % _level)
		State.WON:
			_play_sfx("win")
			_add_shake(0.9)
			hud.set_hint("全部通关！按 空格 / R 再来一局")
		_:
			_play_sfx("over")
			_add_shake(0.8)
			hud.set_hint("按 空格 / R 重开")

	game_over_panel.show_result(_score, _best, is_new_best, final_state, _level)


## 破纪录则写入 user:// 存档，返回是否刷新纪录。
func _save_best() -> bool:
	var is_new_best := _score > _best
	if is_new_best:
		# 写入失败（Web 导出的 IndexedDB 配额/隐私模式）时不要把内存里的最高分改成新值，
		# 否则面板显示「新纪录」而下次启动又回到旧值，且无任何提示。
		if HighScore.save_best(_score):
			_best = _score
		else:
			push_warning("最高分存档写入失败，本次纪录仅在本局内有效")
			return false
	return is_new_best


## 结算面板的“继续”：关卡通过则推进到下一关，否则整局重开。
## 只有结算态才接受该请求：按钮点击走 _gui_input、键盘走 _unhandled_input，
## 同一帧内两路先后到达时若不守状态，推进完第 2 关会立刻被第二次调用整局清零。
func _on_continue_requested() -> void:
	if _restarting or not _state in SETTLE_STATES:
		return

	if _state == State.LEVEL_CLEAR:
		_restarting = true
		_level += 1
		game_over_panel.hide_result()
		_start_level()
		_restarting = false
		return

	_restarting = true
	get_tree().paused = false
	_reset_shake()
	get_tree().reload_current_scene()


func _on_resume_requested() -> void:
	if _state == State.PAUSED:
		_set_paused(false)


func _on_quit_requested() -> void:
	get_tree().paused = false
	_reset_shake()
	get_tree().quit()


func _update_hud() -> void:
	hud.set_score(_score, _best)
	hud.set_lives(_lives)
	hud.set_level(_level, MAX_LEVEL)


# —— 手感反馈的空安全包装 ——
# autoload 缺失时（例如被临时移除、或在无 autoload 的环境里跑场景）静默跳过，不让游戏崩溃。

func _play_sfx(preset: String) -> void:
	if sfx != null:
		sfx.play(preset)


func _add_shake(amount: float) -> void:
	if shake != null:
		shake.shake(amount)


func _reset_shake() -> void:
	if shake != null:
		shake.reset()
