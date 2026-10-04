class_name Main
extends Node2D
## 2DBreakout 主控脚本：
## 运行时生成砖墙、驱动 BallManager 管理多球、连接球与砖块的信号、
## 管理分数/生命/暂停/关卡递进/通关/游戏结束、最高分存档，
## 以及音效、粒子碎屑、屏幕震动等手感反馈。

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
## 砖墙按行取色，索引越靠下越冷。调色板由 scripts/palette.gd 提供，
## 这里只保留第 1 关的默认色作为调色板缺失时的兜底。
const ROW_COLORS := [
	Color("f94144"), Color("f3722c"), Color("f9c74f"),
	Color("90be6d"), Color("43aa8b"), Color("4cc9f0"),
]

## 砖墙布局表：6 行 × 8 列，数字对应 Brick.Kind
## （0 普通 / 1 加固 / 2 生命 / 3 分数 / 4 爆破 / 5 分裂 / 6 减速）。
##
## 用字面数字而不是 Brick.Kind.ARMORED：这张表要能被冒烟测试原样读出来做交叉核对
## （每一项都必须是合法 kind，且六种特殊砖都真实出现在墙上），
## 写成符号反而多一层需要同步的约定。
##
## 第 0 行整行保持普通砖，两个理由：
## 1) 它是最容易够到的一行，玩家第一眼看到的仍是熟悉的东西；
## 2) 冒烟测试有一条「第 2 关首个砖块耐久 == 本关标准」的断言，而 get_child(0)
##    正好是这块砖。它一旦变成加固砖，断言就得跟着改；让测试锚点与
##    「设计上本来就该保持普通」的那一行重合，比在测试里写例外便宜得多。
##
## 末行也留了两块普通砖：通关用例靠「最后两块砖」模拟最后一击，
## 那两块必须是纯计分的普通砖，否则爆破连锁会在结算前改掉分数口径。
const BRICK_LAYOUT := [
	[0, 0, 0, 0, 0, 0, 0, 0],
	[0, 1, 0, 0, 3, 0, 0, 0],
	[0, 0, 0, 4, 0, 5, 0, 0],
	[0, 0, 2, 0, 0, 0, 4, 0],
	[0, 6, 0, 5, 0, 1, 0, 3],
	[0, 0, 2, 4, 0, 0, 0, 0],
]

## 每关配色。索引按关卡循环，超出关卡数复用第一套。
## 空数组表示「全程用 ROW_COLORS」，即保持旧观感。
@export var level_palettes: Array[Palette] = []

# —— 玩法数值 ——
const START_LIVES := 3
const POINTS_PER_BRICK := 10
const PADDLE_START_Y := 640.0
const DEATH_Y := 760.0
## 生命上限。生命砖是「+1 命」，但必须有天花板，
## 否则反复吃生命砖能把难度曲线整个抹平。
const MAX_LIVES := 5

# —— 特殊砖 ——
## 各 kind 的分数倍率（乘 POINTS_PER_BRICK，索引与 Brick.Kind 对齐）。
## 刻意让每一项都是 POINTS_PER_BRICK 的整数倍：冒烟测试有一条
## 「总分始终是每块砖分值的整数倍」的不变量断言，倍率不是整数倍就会打破它。
const KIND_POINTS_MULT := [1, 2, 3, 5, 4, 4, 3]
## 加固砖在本关标准耐久之上多挨几下
const ARMOR_EXTRA_HITS := 2
## 爆破砖的波及半径（像素）。砖格间距是 54×26，这个值刚好覆盖八邻域
## （对角距离 sqrt(54²+26²) ≈ 60 < 66）而不波及隔一个的砖。
const BLAST_RADIUS := 66.0
## 减速砖：球速倍率与持续秒数
const SLOW_SPEED_SCALE := 0.62
const SLOW_SECONDS := 4.0
## 分裂砖新球相对原球方向的偏转角（度）。给一个固定偏移而不是 ±random：
## 同向同角会让新球和原球重叠成一条线，看起来像根本没分裂。
const SPLIT_SPREAD_DEG := 24.0

# —— 蓄力发射 ——
## 蓄满所需秒数。取 0.45s：短到连续点按不会觉得黏，长到刻意蓄力能拉出角度差。
const CHARGE_SECONDS := 0.45
## 蓄满时球速相对本关基准的倍率
const CHARGE_SPEED_MUL := 1.35
## 蓄力时横向可偏转的最大角度（弧度，0 = 正上方）
## 取 0.62（≈35.5°）而不是更大：再大就基本是贴墙平射，
## 玩家会失去「打向砖墙中部」的能力。
const MAX_CHARGE_TILT := 0.62

# —— 换肤 ——
## 换色过渡时长。0.35s 足够让「进入下一关」有视觉分量，又不至于让玩家等。
const PALETTE_FADE_TIME := 0.35

# —— 连击 ——
## 连击计数达到该值才在 HUD 上打出连击数字、并触发连击飘字
const COMBO_HIGHLIGHT := 3

# —— 预测线 ——
## 预测的反射次数。3 次足够看出「会打到哪一行的哪一列」，再多只是噪点。
const AIM_BOUNCES := 3
## 预测线只关心墙体与砖块，位值与 project.godot 的 layer_names 一致
## （1=Wall，4=Brick）。挡板是第 2 层、球是第 4 位，这里都不参与。
const AIM_MASK_WALL := 1
const AIM_MASK_BRICK := 4

# —— 连击拖尾 ——
## 连击达到该值时拖尾增粗并偏暖到 BallTrail.GLOW_COLOR
const COMBO_GLOW_AT := 5

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
@onready var background: ColorRect = $Background
@onready var aim_line: AimLine = $AimLine
@onready var ball_trail: BallTrail = $BallTrail
@onready var paddle: Paddle = $Paddle
@onready var balls: BallManager = $Balls
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

## —— 蓄力发射 ——
## 蓄力进度 0~1；_charging 为按下空格但尚未松手的窗口。
## _charge_dir 记录蓄力期间按下的左右键，让玩家能主动选择发射方向，
## 而不是像原版那样交给随机数。
var _charging := false
var _charge := 0.0
var _charge_dir := 0.0

## —— 连击 ——
## _combo 统计「当前这次飞行中连续击破的砖数」。
## 规则：任意一颗球被挡板接住时清零并把计数折算成额外分数结算；
## 场上球全部掉光则整段作废。这让「一球打穿更多砖」有了明确收益。
var _combo := 0
## 已入账的连击总次数，仅用于结算面板展示
var _combo_total := 0
var _best_combo := 0

## —— 减速砖 ——
## 剩余减速秒数。用秒数递减而不是记结束时刻：暂停时物理帧停摆，
## 记时刻会让「暂停一秒」凭空吃掉一秒减速。
var _slow_left := 0.0


func _ready() -> void:
	# 先从 user:// 下的存档读取历史最高分
	_best = HighScore.load_best()

	# 主控需要在暂停时依然接收输入，因此设为 ALWAYS；
	# 球与挡板单独设为 PAUSABLE，暂停时物理与操控才真正静止。
	# 球由 Balls(BallManager) 整组声明 PAUSABLE，主球与副球都继承它，
	# 免得每生成一颗副球就要记得补一次 set_physics_process。
	# 两条可视化辅助线同样声明为 PAUSABLE：它们自身没有 _process，
	# 数据完全由 Main 推过来，但写死在这里可以让将来挂在它们身上的
	# tween / 计时在暂停时自动停摆，不必再记得补。
	process_mode = Node.PROCESS_MODE_ALWAYS
	paddle.process_mode = Node.PROCESS_MODE_PAUSABLE
	aim_line.process_mode = Node.PROCESS_MODE_PAUSABLE
	ball_trail.process_mode = Node.PROCESS_MODE_PAUSABLE
	balls.process_mode = Node.PROCESS_MODE_PAUSABLE

	# 连接信号。注意连的是 BallManager 而不是某颗球：
	# 副球随时出生，逐球 connect 迟早会漏一颗，漏掉的那颗就是一个
	# 静默失效的「球打中了砖但没加分」。
	balls.brick_hit.connect(_on_brick_hit)
	balls.wall_hit.connect(_on_wall_hit)
	balls.paddle_hit.connect(_on_paddle_hit)
	balls.last_ball_lost.connect(_on_last_ball_lost)
	balls.count_changed.connect(_on_ball_count_changed)
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
	balls.attach(paddle)
	balls.stick_offset = paddle.paddle_height * 0.5 + balls.primary().radius + 4.0
	balls.death_y = DEATH_Y
	# 卡死脱离的安全落点：砖墙最底边 + 球半径 + 余量，这条线以下一定是空场，
	# 球脱离后不会立刻又挤进下一行砖块里。
	balls.unstick_y = BRICK_TOP + (BRICK_ROWS - 1) * (BRICK_SIZE.y + BRICK_GAP) \
		+ BRICK_SIZE.y + balls.primary().radius + 6.0
	balls.apply_to_all()


## 运行时按行按列生成砖块，耐久与球速按当前关卡取值。
## 砖色取自当前关卡调色板；调色板行色数量与 BRICK_ROWS 不一致时按取模循环。
## 特殊砖按 BRICK_LAYOUT 就地替换普通砖（砖块总数不变，因此 BRICK_TOTAL
## 与「已清除计数达标即通关」这条判定都不用改）。
func _build_bricks() -> void:
	for old_brick in bricks_root.get_children():
		old_brick.queue_free()

	var grid_width := BRICK_COLUMNS * BRICK_SIZE.x + (BRICK_COLUMNS - 1) * BRICK_GAP
	var start_x := (VIEW_SIZE.x - grid_width) * 0.5
	var base_hits: int = LEVEL_BRICK_HITS[(_level - 1) % LEVEL_BRICK_HITS.size()]
	var palette := current_palette()
	var row_colors: Array = palette.row_colors if palette != null else ROW_COLORS

	for row in BRICK_ROWS:
		var row_color: Color = row_colors[row % row_colors.size()]
		for column in BRICK_COLUMNS:
			var kind: int = BRICK_LAYOUT[row][column]
			var brick := Brick.new()
			brick.size = BRICK_SIZE
			brick.kind = kind
			brick.points = POINTS_PER_BRICK * int(KIND_POINTS_MULT[kind])
			brick.color = row_color
			# 只有加固砖额外加耐久；其余特殊砖沿用本关标准，
			# 免得「特殊砖更难打」与「难度曲线由 LEVEL_BRICK_HITS 决定」两条规则打架。
			brick.max_hits = base_hits + ARMOR_EXTRA_HITS if kind == Brick.Kind.ARMORED \
				else base_hits
			brick.hits_left = brick.max_hits
			brick.position = Vector2(
				start_x + column * (BRICK_SIZE.x + BRICK_GAP) + BRICK_SIZE.x * 0.5,
				BRICK_TOP + row * (BRICK_SIZE.y + BRICK_GAP) + BRICK_SIZE.y * 0.5
			)
			bricks_root.add_child(brick)


## 本关出现的特殊砖名（行优先去重），用于结算面板的图例行。
## 从布局表现算而不是统计场上残砖：结算时砖几乎被打光了，
## 拿「还剩什么砖」去反推本关有什么砖，最后一行永远是空的。
func _level_legend() -> String:
	var names: Array[String] = []
	for row in BRICK_LAYOUT:
		for kind: int in row:
			if kind == Brick.Kind.NORMAL:
				continue
			var kind_name := String(Brick.KIND_NAMES[kind])
			if not names.has(kind_name):
				names.append(kind_name)
	return " · ".join(names)


## 当前生效的调色板；level_palettes 为空时返回 null（表示沿用默认色）。
func current_palette() -> Palette:
	if level_palettes.is_empty():
		return null
	return level_palettes[(_level - 1) % level_palettes.size()]


## 换肤：把背景、球、挡板、HUD 文字一起切到当前关卡配色。
## 用 tween 过渡而不是瞬切，是为了让「进入下一关」这件事有视觉分量。
func _apply_palette() -> void:
	_apply_palette_colors(current_palette())


## 把一套配色应用到背景、球、挡板、两条辅助线与 HUD 文字。
## palette 为 null（未配置 level_palettes）时退回 library() 里的第一套，
## 那套就是原版配色，因此老存档 / 老场景配置照样能跑。
func _apply_palette_colors(palette: Palette) -> void:
	if palette == null:
		palette = Palette.library()[0]
	# 球色先落到 BallManager 的权威字段上：副球随时可能被分裂砖生成，
	# 只 tween 现有几颗的话，新球会带着上一关的颜色出场。
	balls.ball_color = palette.ball
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(background, "color", palette.background, PALETTE_FADE_TIME)
	tween.tween_property(paddle, "color", palette.paddle, PALETTE_FADE_TIME)
	tween.tween_property(aim_line, "color", palette.aim, PALETTE_FADE_TIME)
	tween.tween_property(paddle, "charge_color", palette.accent, PALETTE_FADE_TIME)
	# 场上已有的每一颗球都各自补一段过渡；正在飞的那颗也不会漏。
	for ball in balls.all_balls():
		tween.tween_property(ball, "color", palette.ball, PALETTE_FADE_TIME)
	# 拖尾色写 base_color 而不是 color：color 每帧都会被连击强度重新算一遍，
	# tween 直接写它会被立刻盖掉，palette.trail 就成了永远看不见的死配置。
	tween.tween_property(ball_trail, "base_color", palette.trail, PALETTE_FADE_TIME)
	# 文字与强调色直接换，不参与 tween：Label 上的 theme override 逐帧插值没有意义
	hud.set_accent(palette.accent)
	hud.set_text_colors(palette.text_primary, palette.text_secondary)
	# 砖块不在这里补色：唯一的调用点在 _build_bricks() 之后，
	# 而 _build_bricks() 本身就按 palette.row_colors 上好了色，再刷一遍是空操作。


## 开新一局：分数、生命、关卡全部归零。
func _start_new_game() -> void:
	_score = 0
	_lives = START_LIVES
	_level = 1
	_combo_total = 0
	_best_combo = 0
	_start_level()


## 开新一关：保留分数与生命，重建砖墙、套用本关球速、挡板宽度与配色。
func _start_level() -> void:
	_state = State.PLAYING
	_bricks_cleared = 0
	# 连击是「单次飞行内」的临时计数，换关必须清零，否则新关第一球就带着旧计数结算
	_reset_charge()
	_reset_combo()
	_slow_left = 0.0
	balls.ball_speed = LEVEL_BALL_SPEED[(_level - 1) % LEVEL_BALL_SPEED.size()]
	_build_bricks()
	_apply_paddle_width()
	_apply_palette()
	# 结算时球被冻结，关卡推进不走场景重载，必须在这里显式恢复操控，
	# 否则从第 2 关起挡板永远是死的。
	paddle.input_enabled = true
	# reset() 顺手清掉上一关残留的副球与减速状态：多球跨关累积会让新关一开局
	# 就飘着五六颗球，关卡递进的「难度台阶」直接失效。
	balls.reset()
	ball_trail.clear_trail()
	_update_hud()
	hud.set_hint(_launch_hint())


## 吸附等待发射时的统一提示文本（关卡推进后由传感器回调覆盖，两处必须一致）。
func _launch_hint() -> String:
	return "按住 空格 蓄力，松开发射（第 %d 关 · 剩余生命 %d）" % [_level, _lives]


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
	elif _state == State.PLAYING:
		if event.is_action_pressed("launch"):
			# 球已在飞行时直接跳过：_begin_charge() 自身不判断 attached_to_paddle，
			# 这道门在这里，否则会把已经飞出去的球重新拉回蓄力态。
			if balls.primary().attached_to_paddle:
				_begin_charge()
			get_viewport().set_input_as_handled()
		elif event.is_action_released("launch") and _charging:
			_release_charge()
			get_viewport().set_input_as_handled()


## 蓄力与发射：按住 launch 累积蓄力，松开时按蓄力强度决定发射角与球速。
##
## 这里把「按下」和「松开」拆成两个分支，而不是像原版那样按下即发射，
## 是为了让发射角与球速变成玩家的主动选择。仍然必须走 is_action_released：
## 只看按下的话玩家没法控制发射时机。
func _begin_charge() -> void:
	_charging = true
	_charge = 0.0
	_charge_dir = 0.0
	ball_trail.clear_trail()


## 松开发射。蓄满（_charge >= 1）时按满力度打出去，没蓄满则按当前比例。
func _release_charge() -> void:
	if not _charging:
		return
	var power := clampf(_charge, 0.0, 1.0)
	var direction := _launch_direction(power)
	_reset_charge()
	# 只给主球提速，不动 balls.ball_speed：副球按本关基准速率飞行。
	# 如果把蓄力倍率写进权威字段，一次弱蓄力就会把场上所有球一起拽慢，
	# 玩家会看到「我只是轻轻点了一下，飞着的球全变慢了」。
	#
	# 先改 speed 再 launch：launch() 用当前 speed 算初速度，
	# 顺序反了的话第一帧会以旧速度出球，要等下一次 _physics_process 归一化才对，
	# 表现为「满蓄力打出去的第一帧明显偏慢」。
	#
	# 速度与角度是两条独立的轴：Ball._clamp_direction() 是「归一化到 speed 后再钳角度」，
	# 所以抬速度不会改变角度包络，MAX_CHARGE_TILT 才是发射角的唯一来源。
	var launched := balls.primary()
	launched.speed = LEVEL_BALL_SPEED[(_level - 1) % LEVEL_BALL_SPEED.size()] \
		* lerpf(1.0, CHARGE_SPEED_MUL, power)
	launched.launch(direction)
	_play_sfx("launch")
	_add_shake(0.06 + power * 0.06)


## 蓄力强度 -> 发射方向。power=0 垂直向上，power=1 按 _charge_dir 偏转到最大角。
## 横移方向同时由「当前是否按住左/右」决定：只蓄力不按键就是垂直上弹。
## 注意这里读轴只是为了「锁存」方向到 _charge_dir：轴可能在蓄力中途松开，
## 但已经锁定的方向要留到松开发射那一刻才作废，由 _reset_charge() 负责清零。
func _launch_direction(power: float) -> Vector2:
	var axis := Input.get_axis("move_left", "move_right")
	if not is_zero_approx(axis):
		_charge_dir = signf(axis)
	var tilt := power * MAX_CHARGE_TILT * _charge_dir
	return Vector2(sin(tilt), -cos(tilt))


func _reset_charge() -> void:
	_charging = false
	_charge = 0.0
	_charge_dir = 0.0
	aim_line.clear_path()
	paddle.set_charge(0.0)


## 每帧推进蓄力进度并刷新预测线。
## 放在 _process 而不是 _physics_process：蓄力是输入反馈，帧率无关；
## 且 Main 是 PROCESS_MODE_ALWAYS，暂停时也能立刻把蓄力清掉。
func _process(delta: float) -> void:
	if _charging and _state == State.PLAYING:
		var before := _charge
		_charge = minf(1.0, _charge + delta / CHARGE_SECONDS)
		paddle.set_charge(_charge)
		# 只在「刚刚蓄满」这一帧播提示音。放进 _process 每帧判断也能work，
		# 但那样每帧都会新建一次 Tween，蓄满后没人松手就会一直空转。
		if before < 1.0 and _charge >= 1.0:
			_play_sfx("charge")
			_add_shake(0.05)
			# 蓄满自动发射：不这么做玩家可以把空格按住不放，
			# 满蓄力条亮着却迟迟不出球，看起来像卡住。
			# auto-fire 只在这一帧触发（_charge 已被钳在 1.0，下一帧 before == 1.0）。
			_release_charge()
			return
		_update_aim_line()
	elif _charging:
		# 暂停 / 结算 / 掉球时蓄力被强行中断：必须回到未蓄力态，
		# 否则恢复后玩家会看到一个满蓄力条却按不动。
		_reset_charge()
	else:
		aim_line.clear_path()


## 蓄力时沿预测方向画反射预测线，让「角度可瞄」这件事真正可见。
## 只在吸附态画：飞行中球已经有了确定的运动方向，再画线是噪音。
func _update_aim_line() -> void:
	if not balls.primary().attached_to_paddle:
		aim_line.clear_path()
		return
	# 预测线只看墙与砖（层 1 与层 4）：把挡板算进去会让线在脚边就撞上自己
	aim_line.predict(balls.primary().global_position, _launch_direction(_charge),
		AIM_BOUNCES, AIM_MASK_WALL | AIM_MASK_BRICK, 0.55)


func _set_paused(paused: bool) -> void:
	_state = State.PAUSED if paused else State.PLAYING
	get_tree().paused = paused
	pause_panel.set_paused(paused)
	_play_sfx("ui")
	# 暂停瞬间归零震动，避免「已暂停」画面上相机还在随机跳动
	if paused:
		_reset_shake()


## 球撞到砖块：加分、播碎屑与音效；耐久耗尽才计入“已清除”，全部清除即结算。
## ball 由 BallManager 带上：分裂砖要知道「是哪颗球撞碎的」才能算出新球的出射方向。
func _on_brick_hit(ball: Ball, brick: Node) -> void:
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

	if destroyed:
		_register_break(typed)
		# 特殊效果只在真正击破时触发：擦着加固砖打过不该凭空多出一颗球。
		_apply_special(typed, ball)
		_check_level_cleared()
	else:
		_update_hud()


## 记一次「砖块被击破」：清空计数、连击与最好连击，并刷新 HUD。
## 球直接撞碎与爆破波及都走这里，保证两条路径的计分与连击口径完全一致——
## 分成两份的话，迟早会出现「炸掉的砖不计数」这种通关判定漏判。
func _register_break(_brick: Brick) -> void:
	_bricks_cleared += 1
	# 只有真正击破才累计连击：擦着打不动的砖不该给玩家「我在连击」的错觉
	_combo += 1
	_best_combo = maxi(_best_combo, _combo)
	_update_hud()


## 砖墙是否已被清空，达到阈值就结算。
## 用计数器而不是 get_child_count() 判定：Brick.hit() 内部是 queue_free()，
## 被击破的砖块要到帧末才从子节点移除，若最后一帧同时击破两块砖，
## 计数会一直停在 2 之上，只查子节点数就会漏判。
func _check_level_cleared() -> void:
	if _bricks_cleared >= BRICK_TOTAL:
		_settle(State.LEVEL_CLEAR if _level < MAX_LEVEL else State.WON)


## 特殊砖的「击破时效果」。
## 加固砖与分数砖的效果全写在属性上（额外耐久 / 分数倍率），击破瞬间无事可做，
## 所以这里只处理真正会改变战局的四种。
## ball 可能为 null（爆演出波及、测试直接调 _on_brick_hit），各分支都要能兜住。
func _apply_special(brick: Brick, ball: Ball) -> void:
	match brick.kind:
		Brick.Kind.LIFE:
			_grant_life()
		Brick.Kind.EXPLOSIVE:
			_blast(brick)
		Brick.Kind.SPLIT:
			_split_ball(brick, ball)
		Brick.Kind.SLOW:
			_slow_balls()


## 生命砖：生命 +1，但不超过 MAX_LIVES。
## 满了也要给分给连击——不给反馈的话玩家会以为砖是坏的。
func _grant_life() -> void:
	_lives = mini(_lives + 1, MAX_LIVES)
	_play_sfx("powerup")
	_add_shake(0.2)
	_update_hud()


## 爆破砖：清掉 BLAST_RADIUS 内的邻居，邻居里若还有爆破砖则继续炸（连锁）。
##
## 用显式队列而不是递归：整墙有 3 块爆破砖，一次连锁的深度不可控，
## 递归爆栈在运行期只会留下一句难以定位的报错。
##
## 两条规则刻意如此：
## 1) 波及无视耐久，直接清除——加固砖在炸弹面前不硬，这是它作为「炸弹」的可预期性来源；
## 2) 被波及清掉的砖【不触发】自身效果，所以连锁不会凭空发一堆球或生命。
func _blast(center: Brick) -> void:
	var pending: Array[Brick] = [center]
	var visited := {}
	var origin_color := center.color
	_spawn_wave(center.global_position, origin_color)
	_play_sfx("boom")
	_add_shake(0.42)
	_spawn_sparks(center.global_position, origin_color, 34, 1.5)

	while not pending.is_empty():
		var epicenter: Brick = pending.pop_back()
		for node in bricks_root.get_children():
			if not (node is Brick):
				continue
			var neighbor := node as Brick
			# 本帧已被别的路径击破的砖（queue_free 还没生效，仍挂在子节点里）
			# 必须跳过：再 hit() 一次会二次计分、二次入账，连击直接虚高。
			if neighbor == epicenter or neighbor.hits_left <= 0:
				continue
			if visited.has(neighbor.get_instance_id()):
				continue
			if neighbor.global_position.distance_to(epicenter.global_position) > BLAST_RADIUS:
				continue
			visited[neighbor.get_instance_id()] = true
			_score += neighbor.hit()
			_spawn_sparks(neighbor.global_position, neighbor.color, 14, 0.9)
			_register_break(neighbor)
			if neighbor.kind == Brick.Kind.EXPLOSIVE:
				pending.append(neighbor)
		# 通关判定必须在连锁过程中随时复查：连锁把最后几块砖清掉时
		# 场上的球已经被 _settle() 冻结，剩下的波及就不该再改分数了。
		if _bricks_cleared >= BRICK_TOTAL:
			_settle(State.LEVEL_CLEAR if _level < MAX_LEVEL else State.WON)
			return
	_update_hud()


## 分裂砖：从砖块下沿多弹出一颗球。
## 出射方向 = 击碎它的那颗球反弹后的方向再偏开 SPLIT_SPREAD_DEG，
## 于是新球一定与原球分道扬镳，不会重叠成一条「看起来没分裂」的线。
## 达到同屏上限时静默放弃：少一颗球不该打断连击节奏。
func _split_ball(brick: Brick, ball: Ball) -> void:
	var heading := Vector2.DOWN
	if is_instance_valid(ball) and ball.velocity.length_squared() > 0.01:
		heading = ball.velocity.normalized()
	var direction := heading.rotated(deg_to_rad(SPLIT_SPREAD_DEG))
	var spawn_at := brick.global_position + Vector2(0.0, brick.size.y * 0.5 + 6.0)
	if balls.spawn_extra(spawn_at, direction) == null:
		return
	_play_sfx("split")
	_add_shake(0.18)


## 减速砖：全场球速打折 SLOW_SECONDS 秒。
func _slow_balls() -> void:
	_slow_left = SLOW_SECONDS
	balls.apply_speed_scale(SLOW_SPEED_SCALE)
	_play_sfx("slow")
	_add_shake(0.12)
	hud.set_hint("减速 %.1f 秒" % SLOW_SECONDS)


## 连击奖励公式（纯函数）。
##
## 取 `(combo - 1) * POINTS_PER_BRICK`：第 2 块砖起每多一块多给一份，
## 于是 2→1×、3→2×、4→3×，线性递增。刻意避开三角数公式 `combo*(combo+1)/2`：
## 那会让 1 块砖也白送一份分，而 1 块砖是完全不需要技巧的默认操作，
## 送分等于告诉玩家「乱打也有奖励」。这里从 2 起算，第一块只拿基础分。
## 全程只做整数乘加，总分始终是每块砖分值的整数倍——
## 冒烟测试有一条断言专门守这个不变量。
##
## 声明成 static 是刻意的：冒烟测试直接调用它算期望值，
## 而不是把公式抄一份进测试——抄副本的话，公式一改测试就会静默失效。
static func combo_bonus_for(combo: int) -> int:
	return maxi(0, combo - 1) * POINTS_PER_BRICK


## 连击结算：把「这一次飞行打掉几块砖」折算成额外分数。
func _bank_combo() -> int:
	if _combo <= 0:
		_reset_combo()
		return 0
	var bonus := combo_bonus_for(_combo)
	if bonus > 0:
		_score += bonus
		_combo_total += 1
	_reset_combo()
	return bonus


## 清零连击计数。回挡板（已结算）、掉光（作废）、换关（跨关不算）都走这里。
func _reset_combo() -> void:
	_combo = 0


## 球撞墙：轻震 + 短促音效。撞墙会打断连击节奏，但不结算也不清零——
## 只在「回到挡板」和「球全掉光」这两个明确节点处理连击。
func _on_wall_hit(_ball: Ball) -> void:
	if _state != State.PLAYING:
		return
	_play_sfx("wall")
	_add_shake(0.10)


## 球撞挡板：比墙稍强一点的反馈，并把本次飞行的连击入账。
##
## 多球下任意一颗球回到挡板都算这一段结束：连击本来就是「一次往返」的奖励，
## 让第一颗球回来就入账，之后回来的球自然无事可做。
func _on_paddle_hit(_ball: Ball) -> void:
	if _state != State.PLAYING:
		return
	_play_sfx("paddle")
	_add_shake(0.14)
	var combo := _combo
	var bonus := _bank_combo()
	_update_hud()
	if combo >= COMBO_HIGHLIGHT:
		hud.flash_combo(combo, bonus)
		# 音高随连击升高，上限 2.0：combo 预设基频最高 1320Hz，
		# 翻到 2 倍也就 2640Hz，远在可听区里，继续拉只是刺耳而不是更有张力。
		var pitch := clampf(1.0 + float(combo - COMBO_HIGHLIGHT) * 0.06, 1.0, 2.0)
		_play_sfx("combo", pitch)
		_add_shake(minf(0.1 + float(combo) * 0.02, 0.35))


## 场上最后一颗球掉出底部：生命 -1、挡板收窄，连击作废，归零则游戏结束。
##
## 连击在掉球时整段丢弃而不入账：这是 combo 的风险面。
## 如果掉球也结算，玩家会无脑刷砖等结算，反而不会去接球。
func _on_last_ball_lost() -> void:
	# 结算/暂停状态下不再扣命，避免球被重新吸附、盖掉结算面板
	if _state != State.PLAYING:
		return
	_lives -= 1
	_play_sfx("life")
	_add_shake(0.75)
	_reset_combo()
	_apply_paddle_width()

	if _lives <= 0:
		_lives = 0
		_update_hud()
		_settle(State.GAME_OVER)
		return

	balls.stick_primary()
	_update_hud()
	hud.set_hint(_launch_hint())


## 球数变化（HUD 的「球 ×N」）。由 BallManager 的 count_changed 驱动，
## 副球掉光这种「不加分也不换关」的变化也就不会把球数显示留在旧值上。
func _on_ball_count_changed(count: int) -> void:
	hud.set_balls(count)


## 球吸附在挡板上时的提示（由 Paddle 的 Area2D 检测触发）。
## 用信号带过来的 body 而不是主球：多球下「谁停在板面上」是开放问题，
## 写死主球的话，副球万一停在板上就会被漏掉。
func _on_ball_on_paddle(body: Node2D) -> void:
	if _state == State.PLAYING and bool(body.get("attached_to_paddle")):
		hud.set_hint(_launch_hint())


## 在指定位置生成一次性碎屑粒子，播放完毕自行销毁。
## 参数必须在入树前配置好：CPUParticles2D 的 emitting 默认就是 true，
## 入树后再改 one_shot / 重力 / 颜色，依赖的是「新节点本帧不被粒子系统更新」这一隐含前提。
func _spawn_sparks(at: Vector2, color: Color, count: int, power: float) -> void:
	var burst := SparkBurst.new()
	burst.position = at
	burst.launch(color, count, power)
	fx_root.add_child(burst)


## 在指定位置生成一次冲击波，播完自行销毁。
## 参数同样必须在入树前写好（与 _spawn_sparks 同一个隐含前提）。
func _spawn_wave(at: Vector2, color: Color) -> void:
	var wave := BlastWave.new()
	wave.position = at
	wave.launch(color)
	fx_root.add_child(wave)


## 结算本局：破纪录则写存档并弹出结算面板。
## final_state 取 GAME_OVER / LEVEL_CLEAR / WON 之一。
func _settle(final_state: int) -> void:
	_state = final_state
	get_tree().paused = false
	pause_panel.set_paused(false)
	# 冻结全场而不只是主球：结算画面上还有三四颗球在飞的话，
	# 玩家的注意力会被分走，也盖不住结算面板。
	balls.set_active(false)
	# 结算后挡板不再响应输入，避免挡板在结算面板后面滑来滑去
	paddle.input_enabled = false
	# 清掉蓄力与预测线：结算时球已冻结，蓄力条还亮着会让人以为还能操作
	_reset_charge()
	ball_trail.clear_trail()
	# 最后一球打空砖墙时连击还没入账，这里补结算，否则玩家会丢掉通关那一击的奖励
	if _combo > 0:
		_bank_combo()

	var is_new_best := _save_best()
	# _save_best() 可能把 _best 顶上去，所以 HUD 要在它之后再刷一次
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

	game_over_panel.show_result(_score, _best, is_new_best, final_state, _level,
		_best_combo, _combo_total, current_palette(), "特殊砖 " + _level_legend())


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
	# 连击达到阈值才在 HUD 上显示：1 连击每次都在闪，纯粹是噪音
	hud.set_combo(_combo if _combo >= COMBO_HIGHLIGHT else 0)
	# 球数只在 >1 时显示：单球是常态，一直占着 HUD 只会让特殊状态不显眼
	hud.set_balls(balls.count())


## 物理帧里累积拖尾采样并推进减速倒计时。放在 _physics_process 而不是 _process：
## 拖尾必须和球的移动同频，否则高刷屏上会画出不等距的锯齿。
func _physics_process(delta: float) -> void:
	if _state != State.PLAYING:
		return

	# 减速倒计时：恢复速率与球的位置无关，所以放在物理帧里最省事；
	# 早返回放在它之后，暂停/结算时倒计时自然冻结。
	if _slow_left > 0.0:
		_slow_left -= delta
		if _slow_left <= 0.0:
			_slow_left = 0.0
			balls.apply_speed_scale(1.0)
			hud.set_hint(_launch_hint())

	# 拖尾只跟主球。多球下若把各球的采样点混进同一条折线，
	# 出来的形状取决于每帧的遍历顺序——同一次游玩两次跑出的轨迹会不一样，
	# 既不好看也无法用来做视觉回归。多出来的球靠爆破碎屑和速度差自己读得出来。
	if not balls.is_primary_flying():
		# 蓄力待发时不画拖尾：球贴着挡板不动，画出来是一坨原地堆积的色块
		ball_trail.clear_trail()
		return
	ball_trail.push_point(balls.primary().global_position)
	# 连击越高，拖尾越粗越亮：把 combo 数值直接映射到视觉权重上。
	# 颜色与线宽都交给 BallTrail 自己派生（基色 = 当前调色板 trail），
	# 这里只给一个 0~1 的强度——反过来在 Main 里拼颜色，
	# 换肤 tween 写进来的基色会被下一帧的逐帧赋值立刻盖掉。
	var intensity := clampf(float(_combo) / float(COMBO_GLOW_AT), 0.0, 1.0)
	ball_trail.line_width = lerpf(BallTrail.MIN_WIDTH, BallTrail.MAX_WIDTH, intensity)
	ball_trail.set_intensity(intensity)


# —— 手感反馈的空安全包装 ——
# autoload 缺失时（例如被临时移除、或在无 autoload 的环境里跑场景）静默跳过，不让游戏崩溃。

## pitch 是音高倍率，供连击越高音调越高的听感使用。
func _play_sfx(preset: String, pitch: float = 1.0) -> void:
	if sfx != null:
		sfx.play(preset, pitch)


func _add_shake(amount: float) -> void:
	if shake != null:
		shake.shake(amount)


func _reset_shake() -> void:
	if shake != null:
		shake.reset()
