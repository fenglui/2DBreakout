extends Node2D
## 2DBreakout 主控脚本：
## 运行时生成砖墙、连接球与砖块的信号、管理分数/生命/暂停/通关/游戏结束与最高分存档。

enum State { PLAYING, PAUSED, GAME_OVER, WON }

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

@onready var bricks_root: Node2D = $Bricks
@onready var paddle: Paddle = $Paddle
@onready var ball: Ball = $Ball
@onready var hud: GameHUD = $HUD
@onready var game_over_panel: GameOverPanel = $GameOverPanel
@onready var pause_panel: PausePanel = $PausePanel

var _state := State.PLAYING
var _score := 0
var _lives := START_LIVES
var _best := 0
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
	ball.fell_out_of_playfield.connect(_on_ball_fell_out)
	paddle.ball_on_paddle.connect(_on_ball_on_paddle)
	game_over_panel.restart_requested.connect(_on_restart_requested)

	_configure_playfield()
	_build_bricks()
	_start_new_game()


## 依据墙体位置计算挡板活动范围与球的吸附/出界高度。
func _configure_playfield() -> void:
	paddle.position = Vector2(VIEW_SIZE.x * 0.5, PADDLE_START_Y)
	paddle.left_bound = WALL_THICKNESS + paddle.paddle_width * 0.5
	paddle.right_bound = VIEW_SIZE.x - WALL_THICKNESS - paddle.paddle_width * 0.5
	ball.stick_offset = paddle.paddle_height * 0.5 + ball.radius + 4.0
	ball.death_y = DEATH_Y


## 运行时按行按列生成砖块。
func _build_bricks() -> void:
	for old_brick in bricks_root.get_children():
		old_brick.queue_free()

	var grid_width := BRICK_COLUMNS * BRICK_SIZE.x + (BRICK_COLUMNS - 1) * BRICK_GAP
	var start_x := (VIEW_SIZE.x - grid_width) * 0.5

	for row in BRICK_ROWS:
		for column in BRICK_COLUMNS:
			var brick := Brick.new()
			brick.size = BRICK_SIZE
			brick.points = POINTS_PER_BRICK
			brick.color = ROW_COLORS[row % ROW_COLORS.size()]
			brick.position = Vector2(
				start_x + column * (BRICK_SIZE.x + BRICK_GAP) + BRICK_SIZE.x * 0.5,
				BRICK_TOP + row * (BRICK_SIZE.y + BRICK_GAP) + BRICK_SIZE.y * 0.5
			)
			bricks_root.add_child(brick)


func _start_new_game() -> void:
	_score = 0
	_lives = START_LIVES
	_bricks_cleared = 0
	_state = State.PLAYING
	ball.stick_to(paddle)
	_update_hud()
	hud.set_hint("按 空格 发射球")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if _state == State.PLAYING:
			_set_paused(true)
		elif _state == State.PAUSED:
			_set_paused(false)
		get_viewport().set_input_as_handled()
	elif _state in [State.GAME_OVER, State.WON] and (event.is_action_pressed("launch") or event.is_action_pressed("restart")):
		_on_restart_requested()
	elif _state == State.PLAYING and event.is_action_pressed("launch"):
		ball.launch()


func _set_paused(paused: bool) -> void:
	_state = State.PAUSED if paused else State.PLAYING
	get_tree().paused = paused
	pause_panel.set_paused(paused)


## 球撞到砖块：砖块消失并加分；清空最后一块即通关。
func _on_brick_hit(brick: Node) -> void:
	if _state != State.PLAYING or not is_instance_valid(brick):
		return
	_score += brick.hit()
	_bricks_cleared += 1
	_update_hud()
	# 用计数器而不是 get_child_count() 判定通关：Brick.hit() 内部是 queue_free()，
	# 被击破的砖块要到帧末才从子节点移除，若最后一帧同时击破两块砖，
	# 计数会一直停在 2 之上，只查子节点数就会漏判通关。
	if _bricks_cleared >= BRICK_TOTAL:
		_settle(true)


## 球掉出底部：生命 -1，归零则游戏结束。
func _on_ball_fell_out() -> void:
	# 结算/暂停状态下不再扣命，避免球被重新吸附、盖掉结算面板
	if _state != State.PLAYING:
		return
	_lives -= 1
	if _lives <= 0:
		_lives = 0
		_update_hud()
		_settle(false)
		return

	ball.stick_to(paddle)
	_update_hud()
	hud.set_hint("按 空格 发射球（剩余生命 %d）" % _lives)


## 球吸附在挡板上时的提示（由 Paddle 的 Area2D 检测触发）。
func _on_ball_on_paddle(_ball: Node2D) -> void:
	if _state == State.PLAYING and ball.attached_to_paddle:
		hud.set_hint("按 空格 发射球（剩余生命 %d）" % _lives)


## 结算本局：破纪录则写存档并弹出结算面板。victory 为真表示全部通关。
func _settle(victory: bool) -> void:
	_state = State.WON if victory else State.GAME_OVER
	get_tree().paused = false
	pause_panel.set_paused(false)
	ball.set_active(false)
	# 结算后挡板不再响应输入，避免挡板在结算面板后面滑来滑去
	paddle.input_enabled = false

	# 破纪录则写入 user:// 下的存档
	var is_new_best := _score > _best
	if is_new_best:
		_best = _score
		HighScore.save_best(_best)
	_update_hud()
	# 结算时清掉“发射球”的旧提示，避免与面板上的重开提示自相矛盾
	hud.set_hint("全部通关！按 空格 / R 再来一局" if victory else "按 空格 / R 重开")
	game_over_panel.show_result(_score, _best, is_new_best, victory)


func _on_restart_requested() -> void:
	if _restarting:
		return
	_restarting = true
	get_tree().paused = false
	get_tree().reload_current_scene()


func _update_hud() -> void:
	hud.set_score(_score, _best)
	hud.set_lives(_lives)
