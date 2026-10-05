class_name Main
extends Node2D
## 2DBreakout 主控脚本：
## 运行时生成砖墙、驱动 BallManager 管理多球、连接球与砖块的信号、
## 管理分数/生命/暂停/关卡递进/通关/游戏结束、最高分存档，
## 以及音效、粒子碎屑、屏幕震动等手感反馈。

enum State { PLAYING, PAUSED, GAME_OVER, LEVEL_CLEAR, WON, MENU, DRAFT }

const VIEW_SIZE := Vector2(480, 720)
const WALL_THICKNESS := 14.0

# —— 砖墙 ——
# 网格尺寸、布局表、砖块分值与耐久都已经搬到 WallShapeProvider：
# 它们本来就是「墙」的事，而不是「关卡流程」的事。
# 这里保留同名别名，是为了让冒烟测试仍然能从 main.gd 的常量表里反查这些数字，
# 从而「测试读的和游戏用的确实是同一份」这件事不需要另立一条约定。
# 别名也意味着改值只需改一处，不会出现「墙按新值建、测试按旧值算」的分叉。
const BRICK_ROWS := WallShapeProvider.ROWS
const BRICK_COLUMNS := WallShapeProvider.COLUMNS
const BRICK_SIZE := WallShapeProvider.SIZE
const BRICK_GAP := WallShapeProvider.GAP
const BRICK_TOP := WallShapeProvider.TOP
const BRICK_LAYOUT := WallShapeProvider.TEMPLATE
const BRICK_TOTAL := WallShapeProvider.TEMPLATE_TOTAL
const POINTS_PER_BRICK := WallShapeProvider.POINTS_PER_BRICK
const KIND_POINTS_MULT := WallShapeProvider.KIND_POINTS_MULT
const ARMOR_EXTRA_HITS := WallShapeProvider.ARMOR_EXTRA_HITS

## 砖墙按行取色，索引越靠下越冷。调色板由 scripts/palette.gd 提供，
## 这里只保留第 1 关的默认色作为调色板缺失时的兜底。
const ROW_COLORS := [
	Color("f94144"), Color("f3722c"), Color("f9c74f"),
	Color("90be6d"), Color("43aa8b"), Color("4cc9f0"),
]

## 每关配色。索引按关卡循环，超出关卡数复用第一套。
## 空数组表示「全程用 ROW_COLORS」，即保持旧观感。
@export var level_palettes: Array[Palette] = []

# —— 玩法数值 ——
const START_LIVES := 3
const PADDLE_START_Y := 640.0
const DEATH_Y := 760.0
## 生命上限。生命砖是「+1 命」，但必须有天花板，
## 否则反复吃生命砖能把难度曲线整个抹平。
const MAX_LIVES := 5

# —— 特殊砖 ——
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
# 这五个常量已经搬到 CaughtBallFlow：蓄满秒数、提速倍率、最大偏转角、预测线段数与掩码
# 全都属于「发射循环」本身，Main 只负责在换关时把球速口径注入进去。
# 同名别名继续留在这里，原因同砖墙那组：冒烟测试从这里反查，
# 就不必知道哪一个常量搬到了哪个节点，也就不必跟着搬。
const CHARGE_SECONDS := CaughtBallFlow.CHARGE_SECONDS
const CHARGE_SPEED_MUL := CaughtBallFlow.CHARGE_SPEED_MUL
const MAX_CHARGE_TILT := CaughtBallFlow.MAX_CHARGE_TILT
const AIM_BOUNCES := CaughtBallFlow.AIM_BOUNCES
const AIM_MASK_WALL := CaughtBallFlow.AIM_MASK_WALL
const AIM_MASK_BRICK := CaughtBallFlow.AIM_MASK_BRICK

# —— 换肤 ——
## 换色过渡时长。0.35s 足够让「进入下一关」有视觉分量，又不至于让玩家等。
const PALETTE_FADE_TIME := 0.35

# —— 连击 ——
# 连击阈值属于 HeatSystem（它已经连同连击计数与热度一起搬走了）。
const COMBO_HIGHLIGHT := HeatSystem.COMBO_HIGHLIGHT

# —— 连击拖尾 ——
const COMBO_GLOW_AT := HeatSystem.COMBO_GLOW_AT

# —— 关卡递进 ——
const MAX_LEVEL := 3
## 每关砖块耐久（超出关卡数则循环取值）：第 1 关一击即碎，第 3 关需要打三次
const LEVEL_BRICK_HITS := [1, 2, 3]
## 每关球速，逐关加快
const LEVEL_BALL_SPEED := [430.0, 500.0, 570.0]
## 挡板宽度按「已失去的生命数」收窄，是主要的难度曲线
const PADDLE_WIDTH_STEPS := [108.0, 92.0, 76.0]

## 结算态集合：只有这三种状态下「继续/重开」输入才有效。
## MENU 与 DRAFT 不在其中：它们各有自己的界面与输入分支，
## 混进来会让「按空格继续」在菜单上把当前这局直接顶掉。
const SETTLE_STATES := [State.GAME_OVER, State.LEVEL_CLEAR, State.WON]

## —— P3：卡牌加成的安全区间 ——
## 球速倍率的钳制区间。叠满「疾风」是 1.08^n，数学上没有天花板，
## 但倍率不封顶就能把球速推到几百——角度包络再健康也救不回来，
## 球会退化成一发穿墙的直线弹。
const CARD_SPEED_MUL_MIN := 0.55
const CARD_SPEED_MUL_MAX := 1.65
## 挡板加宽上限（像素）
const CARD_PADDLE_BONUS_MAX := 60.0
## 「所有砖块多挨一下」类卡牌的累计耐久上限
const CARD_BRICK_HITS_MAX := 4

@onready var bricks_root: Node2D = $Bricks
@onready var fx_root: Node2D = $Fx
@onready var background: ColorRect = $Background
@onready var aim_line: AimLine = $AimLine
@onready var ball_trail: BallTrail = $BallTrail
@onready var paddle: Paddle = $Paddle
@onready var balls: BallManager = $Balls
## —— 四个玩法系统节点 ——
## Main 只做编排：注入依赖、订阅信号、决定分数与生命怎么变。
## 每块玩法逻辑的**内部状态**都在各自的节点里，Main 不再持有副本。
@onready var ball_flow: CaughtBallFlow = $CaughtBallFlow
@onready var heat: HeatSystem = $HeatSystem
@onready var abilities: AbilitySystem = $AbilitySystem
@onready var wall: WallShapeProvider = $WallShapeProvider
@onready var hud: GameHUD = $HUD
@onready var game_over_panel: GameOverPanel = $GameOverPanel
@onready var pause_panel: PausePanel = $PausePanel
@onready var menu_panel: MenuPanel = $MenuPanel
@onready var card_draft_panel: CardDraftPanel = $CardDraftPanel
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

## —— 连击 ——
## _combo / _charge 这类字段已经不再是 Main 的权威来源，它们变成了转发到
## HeatSystem 与 CaughtBallFlow 的门面属性。
##
## 刻意保留它们（而不是让所有调用点直接改写成 heat.combo()）：
## 冒烟测试有二十多处用 node.get("_combo") / node.set("_combo", …) 直接读写，
## 而这套测试是这个项目唯一的安全网。让 Main 继续提供同名门面，
## 网就不必跟着重构一起重写；同时「Main 是门面、系统是属主」这件事
## 在代码上也变得一眼可见——想改规则的人会走到节点里去。

## 当前这次飞行中连续击破的砖数。转发到 HeatSystem。
var _combo: int:
	get:
		return heat.combo() if heat != null else 0
	set(value):
		if heat != null:
			heat.set_combo(value)

## 连击总数与最好连击**没有**门面：冒烟测试从不读它们，
## 而 Main 里也只有结算面板一处在用。为两个「只有一处读者」的字段包一层
## 转发属性，读者看到的是一个不存在的来源（「_best_combo 是真的还是转发来的？」），
## 排查时要多绕一层。所以它们直接读 heat.combo_total() / heat.best_combo()。

## —— 蓄力发射 ——
## _charging / _charge / _charge_dir 转发到 CaughtBallFlow。
var _charging: bool:
	get:
		return ball_flow != null and ball_flow.is_charging()
	set(value):
		# 外部（测试）把它写成 true 时无法凭空造出一颗可蓄力的球，
		# 因此这里只保证「后续读到的状态与写入意图一致」——具体见
		# CaughtBallFlow.on_launch_pressed()，正常路径不走这个 setter。
		if ball_flow != null and not value:
			ball_flow.reset()

## 蓄力进度 0~1
var _charge: float:
	get:
		return ball_flow.charge_ratio() if ball_flow != null else 0.0

## 本关布局表。转发到 WallShapeProvider（砖墙的属主）。
## 冒烟测试有三处读它做交叉核对（「本关布局 == BRICK_LAYOUT」类断言），
## 所以门面必须留着；写入方向也留着，是为了让任何一处「换一堵墙」都能走同一条路。
var _level_layout: Array:
	get:
		return wall.layout if wall != null else []
	set(value):
		if wall != null:
			wall.layout = value

## —— 减速砖 ——
## 剩余减速秒数。用秒数递减而不是记结束时刻：暂停时物理帧停摆，
## 记时刻会让「暂停一秒」凭空吃掉一秒减速。
var _slow_left := 0.0

## —— 玩法模式与种子 ——
## _mode 决定「有没有最后一关」与「要不要抽卡」，_seed 决定这一局的砖墙与卡序。
## 两者在选完玩法的那一刻定死，中途不变——每日挑战的全部意义就在这里。
var _mode := GameMode.Mode.CLASSIC
var _seed := GameMode.CLASSIC_SEED

## —— 卡牌 ——
## 本局累积的加成表 {mod_key: 数值}。加法型累加、乘法型累乘，
## 两类语义的划分由 CardPool.ADDITIVE_KEYS / MULTIPLIED_KEYS 定义，
## 这里只负责执行，不认识任何一张具体的牌。
var _card_mods := {}
## 本局已选卡牌 {id: 次数}，用于上限判定与界面展示
var _card_owned := {}
## 本局总共选了几张
var _card_taken := 0
## 同一关内多次抽卡的盐。抽到「重铸」或跳过之后要能看到不同的牌，
## 否则这两个操作就完全没有反馈。
var _draft_salt := 0
## 护盾剩余次数：抵消 N 次掉球
var _shield := 0


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
	# 接球流程同样 ALWAYS：它由 Main 的 _process 驱动，而 Main 是 ALWAYS，
	# 于是暂停时那一次 tick() 仍然会发生，才能把蓄力条与预测线清干净。
	# 反过来设 PAUSABLE 的话暂停面板上会留一条静止的预测线，
	# 恢复后玩家会发现球已经不在蓄力态——「暂停把蓄力弄丢了」。
	ball_flow.process_mode = Node.PROCESS_MODE_ALWAYS
	# 热度与主动技相反：暂停时它们必须真的停表。
	# 热度继续回落的话，暂停回来就白攒了一半；凝滞继续倒数的话，
	# 玩家会看到「暂停了一秒，凝滞已经结束了」。AbilitySystem 自己在
	# _ready 里设 PAUSABLE，这里不重复写。
	heat.process_mode = Node.PROCESS_MODE_PAUSABLE

	# —— 依赖注入：把四个玩法节点的协作对象交给它们 ——
	# 用代码注入而不是 @export，是为了让「谁认识谁」只有代码这一处答案。
	# 如果用 @export，Main.tscn 里也会有一份连线，于是「这条引用指向谁」
	# 有两个可能的来源，而线断了不会有任何报错——球只是不再被接住。
	ball_flow.balls = balls
	ball_flow.paddle = paddle
	ball_flow.aim_line = aim_line
	ball_flow.ball_trail = ball_trail

	# 连接信号。注意连的是 BallManager 而不是某颗球：
	# 副球随时出生，逐球 connect 迟早会漏一颗，漏掉的那颗就是一个
	# 静默失效的「球打中了砖但没加分」。
	balls.brick_hit.connect(_on_brick_hit)
	balls.wall_hit.connect(_on_wall_hit)
	balls.paddle_hit.connect(_on_paddle_hit)
	balls.last_ball_lost.connect(_on_last_ball_lost)
	balls.count_changed.connect(_on_ball_count_changed)
	paddle.ball_on_paddle.connect(_on_ball_on_paddle)
	# 接球流程的反馈信号：Main 只负责播音效与震动，不重复它的状态判定。
	ball_flow.caught.connect(_on_ball_caught)
	ball_flow.charge_filled.connect(_on_charge_filled)
	ball_flow.launched.connect(_on_ball_launched)
	# 热度换档：分数倍率直接进计分，挡板变窄是当场就能感觉到的那一半代价。
	heat.heat_changed.connect(_on_heat_changed)
	# 扳挡：AbilitySystem 不认识球，球也不认识按键，两边由 Main 搭线。
	abilities.flip_changed.connect(_on_flip_changed)
	abilities.bullet_time_changed.connect(_on_bullet_time_changed)
	game_over_panel.continue_requested.connect(_on_continue_requested)
	game_over_panel.quit_requested.connect(_on_quit_requested)
	pause_panel.resume_requested.connect(_on_resume_requested)
	pause_panel.menu_requested.connect(_on_menu_requested)
	pause_panel.quit_requested.connect(_on_quit_requested)
	menu_panel.mode_chosen.connect(_on_mode_chosen)
	menu_panel.quit_requested.connect(_on_quit_requested)
	card_draft_panel.card_chosen.connect(_on_card_chosen)
	card_draft_panel.draft_skipped.connect(_on_draft_skipped)

	_configure_playfield()
	_start_new_game()
	# 启动后先落在玩法菜单上：经典 / 无尽 / 每日是三种结构完全不同的局，
	# 让玩家在开局前选，而不是打完三关才发现还有别的玩法。
	# _start_new_game() 已经建好第 1 关的墙，所以菜单背后不是空白，而是马上要打的那一局。
	_open_menu()


## 依据墙体位置计算挡板活动范围与球的吸附/出界高度。
##
## unstick_y 依赖「这一关的墙有多高」，而墙的行数会随形状变化（第 4 关起不再恒为 6 行），
## 所以它不能只在 _ready 里算一次：_sync_wall_metrics() 在每次 _start_level() 时重算。
## 这里仍然调一次，是因为 balls.reset() 之前 unstick_y 需要已经是本关的值。
func _configure_playfield() -> void:
	paddle.position = Vector2(VIEW_SIZE.x * 0.5, PADDLE_START_Y)
	balls.attach(paddle)
	balls.stick_offset = paddle.paddle_height * 0.5 + balls.primary().radius + 4.0
	balls.death_y = DEATH_Y
	_sync_wall_metrics()
	balls.apply_to_all()


## 把「这面墙有多高」换算成球需要跟着调整的两个量。
##
## unstick_y 是卡死脱离的安全落点：砖墙最底边 + 球半径 + 余量，这条线以下一定是空场，
## 球脱离后不会立刻又挤进下一行砖块里。
## 它必须跟着本关行数走——墙长高之后还用旧的落点，脱离的球会正好停在最高一行砖上，
## 下一秒又被推回砖堆里，看起来就是「球卡住了怎么打都不掉」。
func _sync_wall_metrics() -> void:
	balls.unstick_y = wall.bottom_edge() + balls.primary().radius + 6.0


## 按当前关卡与卡牌加成建出本关砖墙。
##
## 建墙本身已经搬到 WallShapeProvider（它拥有网格几何、形状与砖块数值），
## Main 在这里只负责把「这一关怎么打」翻译成四个数字再递过去：
## 本关标准耐久、分数倍率、额外耐久、加固砖额外耐久。
## 翻译留在 Main 的理由是这四项全部来自 Main 的关卡表与卡牌表——
## 砖墙不该知道 LEVEL_BRICK_HITS，也不该知道「加固」这张牌。
func _build_bricks() -> void:
	var base_hits: int = LEVEL_BRICK_HITS[(_level - 1) % LEVEL_BRICK_HITS.size()]
	var palette := current_palette()
	var row_colors: Array = palette.row_colors if palette != null else ROW_COLORS
	wall.configure_build(base_hits, _card_score_mult(),
		_card_brick_hits_add(), _card_armor_add())
	wall.build(bricks_root, row_colors, VIEW_SIZE.x)


## 本关出现的特殊砖名（行优先去重），用于结算面板的图例行。转发到砖墙的属主。
func _level_legend() -> String:
	return wall.legend()


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
	heat.reset_run()
	abilities.reset_run()
	_reset_cards()
	_start_level()


## 清空全部卡牌状态。卡牌是「本局内」的成长：跨局继承会让第二局一开始
## 就没牌可抽（owned 已经全部顶到 max_stack），复玩性反而归零。
func _reset_cards() -> void:
	_card_mods = {}
	_card_owned = {}
	_card_taken = 0
	_draft_salt = 0
	_shield = 0


## 开新一关：保留分数与生命，重建砖墙、套用本关球速、挡板宽度与配色。
func _start_level() -> void:
	_state = State.PLAYING
	_bricks_cleared = 0
	# 连击是「单次飞行内」的临时计数，换关必须清零，否则新关第一球就带着旧计数结算
	ball_flow.reset()
	# 热度同样按关清：它衡量的是「这一关里接球的连续性」，
	# 跨关累计会让第 30 关一开始就顶在满档，玩家反而不敢再接球。
	heat.reset_level()
	# 停掉凝滞与扳挡：它们是「这一关的瞬时操作状态」，不是本局资源。
	# 凝滞次数本身留在 AbilitySystem 里跨关保留（同护盾），停的只是计时器与扳挡开关。
	abilities.reset()
	_slow_left = 0.0
	# 先让墙算出本关的形状与布局，再据此同步落点高度——顺序反了的话
	# 第 4 关起 unstick_y 用的还是上一关 6 行墙的高度。
	wall.generate(_layout_seed(), _level)
	_sync_wall_metrics()
	var base_speed: float = LEVEL_BALL_SPEED[(_level - 1) % LEVEL_BALL_SPEED.size()]
	balls.ball_speed = base_speed
	# 发射速率口径注入接球流程：它要知道自己这一发该按哪一档球速算，
	# 但不该自己去查关卡表或卡牌表。
	ball_flow.configure_speed(base_speed, _card_speed_mul())
	balls.max_balls_cap = _card_max_balls()
	_build_bricks()
	_apply_paddle_width()
	_apply_palette()
	# 结算时球被冻结，关卡推进不走场景重载，必须在这里显式恢复操控，
	# 否则从第 2 关起挡板永远是死的。
	paddle.input_enabled = true
	# reset() 顺手清掉上一关残留的副球与减速状态：多球跨关累积会让新关一开局
	# 就飘着五六颗球，关卡递进的「难度台阶」直接失效。
	balls.reset()
	# 球被重新吸附到挡板上之后，接球流程里可能还指着上一关那颗已被回收的球。
	# 不清的话下一次按下 launch 会去访问一个已释放的实例。
	ball_flow.on_ball_attached(balls.primary())
	ball_trail.clear_trail()
	_update_hud()
	hud.set_hint(_launch_hint())


## 本关砖墙生成用的种子。
##
## 经典模式恒为 0 —— 0 是 LevelGenerator 的「原样返回模板」开关，
## 于是经典模式的砖墙逐位等于 BRICK_LAYOUT，新系统对老玩法完全透明。
## 抽到「重铸」时改用一次性随机种子，并**在这里就地清掉标记**：
## 否则它会在之后每一关各触发一次，一张牌换来了整局换墙。
func _layout_seed() -> int:
	if _mode == GameMode.Mode.CLASSIC:
		return GameMode.CLASSIC_SEED
	if int(_card_mods.get("reroll", 0)) > 0:
		_card_mods["reroll"] = 0
		return GameMode.random_seed()
	return _seed


## 吸附等待发射时的统一提示文本（关卡推进后由传感器回调覆盖，两处必须一致）。
func _launch_hint() -> String:
	return "按住 %s 蓄力，松开发射 · 飞行中按住可接住 · Q 扳挡 · Shift 凝滞" \
		% _launch_key_hint()


## 从 InputMap 反查 launch 的键位，而不是把「空格」写死在文案里。
## 键位一旦重映射，硬编码的提示就会开始撒谎——而提示撒谎比没有提示更糟，
## 玩家会去找一个根本不存在的键。
func _launch_key_hint() -> String:
	var events := InputMap.action_get_events(&"launch")
	for event: InputEvent in events:
		if event is InputEventKey:
			return OS.get_keycode_string((event as InputEventKey).physical_keycode)
	return "空格"


## 挡板宽度随已失去的生命收窄，并同步重算可活动范围。
## 卡牌加宽是叠加在阶梯之上的偏置而不是改写阶梯本身：
## 直接把某一级替换成加宽值，「已失去 N 条命」这条难度曲线就断了。
##
## 热度惩罚也叠在这条链上——它是**减去**而不是「换一档」：
## 热度换档时必须让挡板当场变窄（见 _on_heat_changed），
## 所以这里只需要在算式里减一次，换档与扣命两条路径就共用同一个算式，
## 不会出现「两处各写一遍减法，改了一处忘了另一处」。
func _apply_paddle_width() -> void:
	var lost := clampi(START_LIVES - _lives, 0, PADDLE_WIDTH_STEPS.size() - 1)
	paddle.set_width(PADDLE_WIDTH_STEPS[lost] + _card_paddle_bonus() - heat.paddle_penalty())
	paddle.left_bound = WALL_THICKNESS + paddle.paddle_width * 0.5
	paddle.right_bound = VIEW_SIZE.x - WALL_THICKNESS - paddle.paddle_width * 0.5
	paddle.global_position.x = clampf(paddle.global_position.x, paddle.left_bound, paddle.right_bound)


## 打开玩法菜单。菜单背后保留着已经建好的第 1 关墙，球仍吸附在挡板上。
## 这里刻意**不**把墙清掉：玩家在菜单上就该先看见这局长什么样，
## 而不是点完按钮之后从一片空白开始。
func _open_menu() -> void:
	_state = State.MENU
	menu_panel.present()
	# 菜单期间挡板不可操控：否则玩家在菜单上顺手按方向键，
	# 背景里的挡板就跟着滑走了，看起来像菜单把游戏操控弄坏了。
	paddle.input_enabled = false
	hud.set_hint("选择玩法开始")


## 以指定模式开一局。
##
## run_seed < 0 表示按模式自动分配（经典恒为 0、每日按当天日期、无尽随机）；
## 传 0 以上则强制沿用该种子，用于「这副牌再来一次」的重开诉求。
func _begin_run(mode: int, run_seed: int = -1) -> void:
	_mode = mode
	_seed = GameMode.begin_seed(mode) if run_seed < 0 else GameMode.seed_for_mode(mode, run_seed)
	menu_panel.hide_menu()
	card_draft_panel.hide_panel()
	_start_new_game()


func _on_mode_chosen(mode: int) -> void:
	# 只在菜单态接受：面板是常驻节点，隐藏时理论上收不到按钮点击，
	# 但同一帧内「点模式」与「结算面板收起」先后到达的情况完全可能发生。
	if _state != State.MENU:
		return
	_begin_run(mode)


## 发一手三选一。
## 牌池见底（所有牌都叠到 max_stack）时 CardDraftPanel 会直接发 draft_skipped，
## 于是「没牌可发」不需要在这里再判一次，也就不会出现卡住的死界面。
func _open_draft() -> void:
	_state = State.DRAFT
	var cards := CardPool.draft(_seed, _level, _card_owned, _draft_salt)
	card_draft_panel.present(cards, _level, _card_taken, current_palette())
	hud.set_hint("选择一张卡牌带进下一关")


func _on_card_chosen(index: int) -> void:
	if _state != State.DRAFT:
		return
	var cards: Array = card_draft_panel.offered
	if index < 0 or index >= cards.size():
		return
	_apply_card(cards[index])
	card_draft_panel.hide_panel()
	_advance_after_draft()


func _on_draft_skipped() -> void:
	if _state != State.DRAFT:
		return
	card_draft_panel.hide_panel()
	_advance_after_draft()


## 离开抽卡界面并进入下一关。
## 「选牌」与「跳过」两条出口共用它，保证换关副作用只有一个实现——
## 分开写两遍的话，跳过路径迟早会漏掉清副球或重置连击。
func _advance_after_draft() -> void:
	_level += 1
	_start_level()


## 把一张卡的加成并入本局。
##
## 加法型累加、乘法型累乘，划分标准来自 CardPool 的两张白名单而不是卡面自带标志：
## 白名单是「这张游戏认识哪些 mod 键」的唯一事实来源，
## 卡面出现白名单之外的键就是数据写错了（冒烟测试有一条断言专门守这个）。
## 两类之外的键（extra_lives / reroll）是当场结算的即时效果，不进累积表——
## 累加起来会让「加 2 命」被反复执行。
func _apply_card(card: Dictionary) -> void:
	if card.is_empty():
		return
	var card_id := String(card["id"])
	_card_owned[card_id] = int(_card_owned.get(card_id, 0)) + 1
	_card_taken += 1
	for key: String in (card["mods"] as Dictionary):
		var value: Variant = (card["mods"] as Dictionary)[key]
		if CardPool.is_multiplied(key):
			_card_mods[key] = float(_card_mods.get(key, 1.0)) * float(value)
		elif CardPool.is_additive(key):
			_card_mods[key] = float(_card_mods.get(key, 0.0)) + float(value)
		else:
			match key:
				"extra_lives":
					_lives = mini(_lives + int(value), _max_lives())
				"reroll":
					_card_mods["reroll"] = int(_card_mods.get("reroll", 0)) + int(value)
				_:
					push_error("未知的卡牌加成键「%s」（卡 %s）" % [key, card_id])
	# 护盾是「次数」而不是「属性」：它要在 _on_last_ball_lost 里逐次消耗，
	# 所以 _card_mods 里的累计值必须同步成运行期计数，否则抽到卡却看不到效果。
	_shield = int(_card_mods.get("shield", 0.0))
	_play_sfx("powerup")
	MetaProgress.record_card(card_id)
	_update_hud()


# —— 卡牌加成的读取 ——
# 全部从 _card_mods 这一个字典取，游戏逻辑只关心「加了多少」而不关心「是哪张牌」，
# 所以加一张新卡不需要在这里补一行分支。


## 每块砖的分数倍率。
## 刻意是整数（CardPool.MULTIPLIED_KEYS 的约定）：
## 冒烟测试有一条「总分始终是每块砖分值的整数倍」的不变量断言，
## 非整数倍率会直接打破它。
func _card_score_mult() -> int:
	return maxi(1, int(_card_mods.get("score_mult", 1.0)))


func _card_combo_mult() -> int:
	return maxi(1, int(_card_mods.get("combo_mult", 1.0)))


func _card_speed_mul() -> float:
	return clampf(float(_card_mods.get("speed_mul", 1.0)),
		CARD_SPEED_MUL_MIN, CARD_SPEED_MUL_MAX)


func _card_paddle_bonus() -> float:
	return clampf(float(_card_mods.get("paddle_bonus", 0.0)), 0.0, CARD_PADDLE_BONUS_MAX)


func _card_brick_hits_add() -> int:
	return clampi(int(_card_mods.get("brick_hits", 0.0)), 0, CARD_BRICK_HITS_MAX)


func _card_armor_add() -> int:
	return maxi(0, int(_card_mods.get("armor_add", 0.0)))


func _card_blast_radius() -> float:
	return BLAST_RADIUS + maxf(0.0, float(_card_mods.get("blast_add", 0.0)))


func _card_slow_seconds() -> float:
	return maxf(0.5, SLOW_SECONDS + float(_card_mods.get("slow_add", 0.0)))


## 减速倍率（越大越慢）。
## 「速融」往正方向加而不是做减法：SLOW_SPEED_SCALE 是「慢多少」的刻度，
## 减法写法在数值写错时会得到 0（球全速）或负数（球倒飞），
## 加法写法最坏也只是「减速不明显」这种无害的退化。
func _card_slow_scale() -> float:
	return clampf(SLOW_SPEED_SCALE + float(_card_mods.get("slow_scale_add", 0.0)), 0.2, 1.0)


func _card_split_spread_deg() -> float:
	return maxf(0.0, SPLIT_SPREAD_DEG + float(_card_mods.get("split_deg_add", 0.0)))


func _card_max_balls() -> int:
	return BallManager.MAX_BALLS + maxi(0, int(_card_mods.get("max_balls_add", 0.0)))


## 生命上限。「生命之泉」抬的是上限而不是 START_LIVES：
## 直接抬高开局血量等于让生命系统整局失效，那不是一张有取舍的卡。
func _max_lives() -> int:
	return MAX_LIVES + maxi(0, int(_card_mods.get("max_lives_add", 0.0)))


func _unhandled_input(event: InputEvent) -> void:
	# MENU / DRAFT 各有自己的界面与输入分支，先在这里整段截走。
	# 不截的话下面按 _state 排的那串判断会把菜单上的空格当成「发射」或「继续」。
	if _state == State.MENU:
		if event.is_action_pressed("launch") or event.is_action_pressed("restart"):
			_begin_run(GameMode.Mode.CLASSIC)
			get_viewport().set_input_as_handled()
		return
	if _state == State.DRAFT:
		_handle_draft_input(event)
		return

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
		# 这里只做「把动作转交给属主」，不再判断这一帧归谁管：
		# 按下 launch 时此刻有没有球、球是不是吸附的、要不要挂起接球意图，
		# 全部由 CaughtBallFlow 自己回答。
		# Main 以前在这里写着 `if balls.primary().attached_to_paddle` 这道门，
		# 正是它让「球飞出去之后按空格」变成一个没有意义的动作——
		# 接住球、蓄力瞄准这些手感投入因此在一颗球的一生里只生效一次。
		if event.is_action_pressed("launch"):
			ball_flow.on_launch_pressed()
			get_viewport().set_input_as_handled()
		elif event.is_action_released("launch"):
			ball_flow.on_launch_released()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("bullet_time"):
			abilities.on_bullet_time_input(true)
			get_viewport().set_input_as_handled()
		elif event.is_action_released("bullet_time"):
			abilities.on_bullet_time_input(false)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("flip"):
			abilities.on_flip_pressed()
			get_viewport().set_input_as_handled()


## 抽卡界面的键盘操作：1 / 2 / 3 选牌，R 跳过。
##
## 这几个键刻意**不**进 project.godot 的 InputMap：它们只在抽卡这一个界面里有意义，
## 塞进全局动作表等于给「移动 / 发射 / 暂停」旁边平白多出一条任何时候都无效的规则。
##
## 回车/空格留给获得焦点的「选择」按钮（面板 present() 时会 grab_focus 第一张），
## 所以这里不重复处理 ui_accept —— 两条路径同时响应的话一次按键会选两次。
func _handle_draft_input(event: InputEvent) -> void:
	if event.is_action_pressed("restart"):
		_on_draft_skipped()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	var slot := -1
	match key:
		KEY_1, KEY_KP_1:
			slot = 0
		KEY_2, KEY_KP_2:
			slot = 1
		KEY_3, KEY_KP_3:
			slot = 2
	if slot < 0:
		return
	card_draft_panel.choose(slot)
	get_viewport().set_input_as_handled()


## 每帧把推进权交给接球流程。
##
## Main 保留 _process 而不是让 CaughtBallFlow 自带一个，是为了守住一条既有约定：
## Main 是 PROCESS_MODE_ALWAYS，所以暂停时这里仍然会跑，
## 而「暂停时蓄力条与预测线必须立刻消失」这条行为正是靠这一点成立的。
## 换句话说：驱动权在 Main（谁在跑帧），状态权属在 ball_flow（跑帧时算什么）——
## 两件事分开之后，暂停/换关/结算三个分支只需要各自调一次 ball_flow.reset()。
func _process(delta: float) -> void:
	ball_flow.tick(delta, _state == State.PLAYING)


func _set_paused(paused: bool) -> void:
	_state = State.PAUSED if paused else State.PLAYING
	get_tree().paused = paused
	pause_panel.set_paused(paused)
	_play_sfx("ui")
	# 暂停瞬间归零震动，避免「已暂停」画面上相机还在随机跳动
	if paused:
		_reset_shake()
	# 停掉凝滞与扳挡。它们是「正在进行的操作」，不是「暂停前的状态快照」——
	# 暂停时若让凝滞继续倒数，玩家会看到「我暂停了一秒，回来凝滞已经结束了」。
	abilities.reset()
	# 蓄力同理：暂停时若保留，恢复后会看到一个按不动的满蓄力条。
	# ball_flow 是 PROCESS_MODE_ALWAYS，暂停中仍会跑 tick()，
	# 但那次 tick 只负责清空，真正在这里再清一次是为了让
	# 「暂停面板上不该有一条还在涨的预测线」这件事在同一帧就成立。
	ball_flow.reset()


## 球撞到砖块：加分、播碎屑与音效；耐久耗尽才计入“已清除”，全部清除即结算。
## ball 由 BallManager 带上：分裂砖要知道「是哪颗球撞碎的」才能算出新球的出射方向。
func _on_brick_hit(ball: Ball, brick: Node) -> void:
	if _state != State.PLAYING or not is_instance_valid(brick):
		return
	var typed := brick as Brick
	if typed == null:
		return

	_score += _brick_score(typed.hit())
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
	heat.register_break()
	_update_hud()


## 砖墙是否已被清空，达到阈值就结算。
## 用计数器而不是 get_child_count() 判定：Brick.hit() 内部是 queue_free()，
## 被击破的砖块要到帧末才从子节点移除，若最后一帧同时击破两块砖，
## 计数会一直停在 2 之上，只查子节点数就会漏判。
##
## 阈值取 wall.total 而不是写死 BRICK_TOTAL：墙的行数会随形状变化，
## 「这一关有几块砖」这件事的唯一权威是砖墙自己。
## 阈值取自属主而不是在判定处重算一遍形状，是为了让「加一种形状」只需要改一个文件。
func _check_level_cleared() -> void:
	if _bricks_cleared >= wall.total:
		_settle(_level_clear_state())


## 清空砖墙后进入的结算态。无尽模式没有最后一关，永远是 LEVEL_CLEAR；
## 经典模式打满最后一关才是 WON。
## 两处调用点（_check_level_cleared 与 _blast 的连锁复查）都必须走这个函数：
## 分开写就会出现「最后一击是爆破连锁时判成了 WON，而正常打碎时判成了 LEVEL_CLEAR」。
func _level_clear_state() -> int:
	if GameMode.is_endless(_mode) or _level < MAX_LEVEL:
		return State.LEVEL_CLEAR
	return State.WON


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


## 生命砖：生命 +1，但不超过生命上限（卡牌可以抬高上限）。
## 满了也要给分给连击——不给反馈的话玩家会以为砖是坏的。
func _grant_life() -> void:
	_lives = mini(_lives + 1, _max_lives())
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
	# 半径只在开头取一次：整段连锁共用同一个值，
	# 中途重读的话卡牌面板开着也不会变，但函数会看起来像是随时可改。
	var radius := _card_blast_radius()
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
			if neighbor.global_position.distance_to(epicenter.global_position) > radius:
				continue
			visited[neighbor.get_instance_id()] = true
			_score += _brick_score(neighbor.hit())
			_spawn_sparks(neighbor.global_position, neighbor.color, 14, 0.9)
			_register_break(neighbor)
			if neighbor.kind == Brick.Kind.EXPLOSIVE:
				pending.append(neighbor)
		# 通关判定必须在连锁过程中随时复查：连锁把最后几块砖清掉时
		# 场上的球已经被 _settle() 冻结，剩下的波及就不该再改分数了。
		if _bricks_cleared >= wall.total:
			_settle(_level_clear_state())
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
	var direction := heading.rotated(deg_to_rad(_card_split_spread_deg()))
	var spawn_at := brick.global_position + Vector2(0.0, brick.size.y * 0.5 + 6.0)
	if balls.spawn_extra(spawn_at, direction) == null:
		return
	_play_sfx("split")
	_add_shake(0.18)


## 减速砖：全场球速打折若干秒（时长与倍率都可能被卡牌改过）。
func _slow_balls() -> void:
	_slow_left = _card_slow_seconds()
	balls.apply_speed_scale(_card_slow_scale())
	_play_sfx("slow")
	_add_shake(0.12)
	hud.set_hint("减速 %.1f 秒" % _slow_left)


## 连击奖励公式（纯函数）的转发入口。真实实现已经搬到 HeatSystem（它连同连击状态一起搬走了）。
##
## 这里保留同名转发，理由和砖墙常量那组一样：冒烟测试用
## `_main_script.call("combo_bonus_for", combo)` 来算期望值，
## 转发能让测试不必知道公式搬到了哪个节点，也就不必跟着搬。
## 转发而不是把公式抄一份，是关键——抄副本的话公式一改测试就静默失效。
static func combo_bonus_for(combo: int) -> int:
	return HeatSystem.combo_bonus_for(combo)


## 连击结算：把「这一次飞行打掉几块砖」折算成额外分数。
## 连击的计数、公式、清零全在 HeatSystem 里，Main 只做「把这笔分加进总分」。
func _bank_combo() -> int:
	heat.configure_combo_mult(_card_combo_mult())
	var bonus := heat.bank()
	if bonus > 0:
		_score += bonus
	return bonus


## 连击作废。掉球时整段丢弃而不入账：这是 combo 的风险面。
## 如果掉球也结算，玩家会无脑刷砖等结算，反而不会去接球。
func _discard_combo() -> void:
	heat.discard()


## 一块砖该加多少分：砖块基础分 × 当前热度倍率。
##
## 热度倍率必须是整数（HeatSystem 的 HEAT_TIER_MULT 全部是整数），
## 这是「总分始终是每块砖分值的整数倍」这条不变量不被打破的前提。
##
## 之所以包一个函数而不是在两处写 `x * heat.score_mult()`：
## 球撞碎与爆破连锁是两条计分路径，抄两遍的话将来有人给其中一条漏乘，
## 症状是「靠爆破打完的墙，总分除不尽砖块单价」。
## 而这条不变量在 headless 里因为热度恒为 0 照样通过，只有真实游玩才炸——
## 属于「测试环境恰好绕过的那类坑」，比它挡住的 bug 更难查。
func _brick_score(points: int) -> int:
	return points * heat.score_mult()


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
##
## 接球流程必须先被通知：它要在「这一颗球碰板」这一帧判断要不要把它粘住，
## 而它拿到的是球本身，判断依据全在球身上（是否已吸附）。
## 顺序反过来（先入账再通知）也不会错——接住本来也该结算连击——但先通知能让
## 「接住」这件事在这次碰板里第一时间生效，反馈顺序与玩家的直觉一致。
func _on_paddle_hit(ball: Ball) -> void:
	if _state != State.PLAYING:
		return
	ball_flow.on_paddle_contact(ball)
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


## 球被主动接住了：热度 +1，并给出一次「接住了」而不是「碰了一下」的反馈。
##
## 音效复用 paddle：新增一个接球专属预设要动 SfxBus 的预设表与测试的
## 「用到的音效必须在表里」断言，收益却不明显——两者在听觉上本来就是同一件事。
## 区分靠震动强度与 HUD 提示，不靠音色。
func _on_ball_caught(_ball: Ball) -> void:
	heat.register_catch()
	_play_sfx("paddle")
	_add_shake(0.22)
	hud.set_hint("接住！按住 %s 蓄力，松开发射" % _launch_key_hint())


## 蓄满的那一帧。sfx 走 ball_flow 的 charge_filled，而不是在这发信号里重算，
## 这样「什么算蓄满」只有一个定义。
func _on_charge_filled() -> void:
	_play_sfx("charge")
	_add_shake(0.05)


## 球被打出去了。
##
## 这条信号只用来做反馈。发射本身已经由 CaughtBallFlow 直接对球完成了——
## 结算分数的路径刻意不开在这里，否则「谁负责把分加进去」会同时有两个答案：
## 一份在接球流程里（它算的 power），一份在 Main 里（它算的分数）。
func _on_ball_launched(_ball: Ball, power: float) -> void:
	_play_sfx("launch")
	_add_shake(0.06 + power * 0.06)


## 热度换档：立刻反映到挡板宽度与 HUD 分数倍率上。
##
## 「立刻」是这条连接存在的全部理由。如果等到下一次 _apply_paddle_width() 才生效，
## 玩家会先看到分数倍率变成 2、过一会儿挡板才窄——两件事看起来像两个不相干的系统。
func _on_heat_changed(ratio: float, mult: int, penalty: float) -> void:
	# 直接写 heat_ratio 字段而不是调一个 set_heat()：
	# paddle.gd 里 heat_ratio 自带 setter（写值即重绘），所以「赋值」就是全部协议。
	# 另写一个 set_heat() 只会多出第二个能改这块布尔的入口，
	# 而两个入口里漏掉其中一个的后果是「重绘有时不发生」——极难查。
	paddle.heat_ratio = ratio
	_apply_paddle_width()
	if mult > 1:
		hud.set_hint("热度 ×%d（挡板窄 %.0f px）" % [mult, penalty])


## 扳挡开关变化：把状态同步给场上所有球，并让挡板给出可见反馈。
func _on_flip_changed(flipped: bool) -> void:
	balls.apply_flip(flipped)
	paddle.flipped = flipped


## 凝滞开始 / 结束。发提示而不是自己改任何东西：
## Engine.time_scale 由 AbilitySystem 自己持有与还原，Main 碰它就等于多一个能改坏它的点。
func _on_bullet_time_changed(active: bool) -> void:
	hud.set_hint("凝滞" if active else _launch_hint())


## 场上最后一颗球掉出底部：生命 -1、挡板收窄，连击作废，归零则游戏结束。
##
## 连击在掉球时整段丢弃而不入账：这是 combo 的风险面。
## 如果掉球也结算，玩家会无脑刷砖等结算，反而不会去接球。
func _on_last_ball_lost() -> void:
	# 结算/暂停状态下不再扣命，避免球被重新吸附、盖掉结算面板
	if _state != State.PLAYING:
		return
	# 护盾优先：抵消掉这一次掉球，生命、连击与挡板宽度都不动。
	# 必须放在扣命之前，否则会出现「护盾挡下了球，命还是照扣」这种自相矛盾的结果。
	if _shield > 0:
		_shield -= 1
		_play_sfx("powerup")
		_add_shake(0.4)
		_discard_combo()
		balls.stick_primary()
		_update_hud()
		hud.set_hint("护盾挡下一次掉球（剩余 %d）" % _shield)
		return
	_lives -= 1
	_play_sfx("life")
	_add_shake(0.75)
	_discard_combo()
	# 热度一并清掉：热度本来是「拿操作精度换分数」，
	# 掉了球说明这次精度没押中，惩罚不兑现等于热度没有风险面——
	# 那样它就退化成一个只涨不跌、越攒越好的纯增益。
	heat.reset_heat()
	_apply_paddle_width()

	if _lives <= 0:
		_lives = 0
		_update_hud()
		_settle(State.GAME_OVER)
		return

	balls.stick_primary()
	ball_flow.on_ball_attached(balls.primary())
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
	ball_flow.reset()
	# 凝滞必须停：结算面板上游戏仍然是「慢动作」的话，
	# 面板自己的 Tween 会跟着一起变慢，「再来一局」的响应也变得黏。
	# 结算面板的「再来一局」走场景重载，_exit_tree 里还有一道还原兜底。
	abilities.reset()
	ball_trail.clear_trail()
	# 最后一球打空砖墙时连击还没入账，这里补结算，否则玩家会丢掉通关那一击的奖励
	if _combo > 0:
		_bank_combo()

	var is_new_best := _save_best()
	# 无尽/每日模式把成绩记进长期档案（当日最佳、连续打卡天数、上局种子）。
	# 经典模式不记：它的分数已经被最高分存档覆盖，再记一份只会让档案条数膨胀。
	if GameMode.tracks_progress(_mode):
		MetaProgress.record_run(_mode, _seed, _score)
	# _save_best() 可能把 _best 顶上去，所以 HUD 要在它之后再刷一次
	_update_hud()

	var card_step := GameMode.has_cards(_mode)
	match final_state:
		State.LEVEL_CLEAR:
			_play_sfx("clear")
			_add_shake(0.5)
			hud.set_hint("第 %d 关通过！按 空格 / R %s"
				% [_level, "抽一张卡牌" if card_step else "进入下一关"])
		State.WON:
			_play_sfx("win")
			_add_shake(0.9)
			hud.set_hint("全部通关！按 空格 / R 再来一局")
		_:
			_play_sfx("over")
			_add_shake(0.8)
			hud.set_hint("按 空格 / R 重开")

	var continue_text := ""
	if final_state == State.LEVEL_CLEAR:
		continue_text = "抽卡牌" if card_step else "下一关"
	game_over_panel.show_result(_score, _best, is_new_best, final_state, _level,
		heat.best_combo(), heat.combo_total(), current_palette(),
		"特殊砖 " + _level_legend(), continue_text)


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


## 结算面板的“继续”：关卡通过则推进到下一关（无尽模式先进抽卡界面），
## 否则整局重开。
## 只有结算态才接受该请求：按钮点击走 _gui_input、键盘走 _unhandled_input，
## 同一帧内两路先后到达时若不守状态，推进完第 2 关会立刻被第二次调用整局清零。
func _on_continue_requested() -> void:
	if _restarting or not _state in SETTLE_STATES:
		return

	if _state == State.LEVEL_CLEAR:
		_restarting = true
		if GameMode.has_cards(_mode):
			game_over_panel.hide_result()
			_open_draft()
		else:
			_level += 1
			game_over_panel.hide_result()
			_start_level()
		_restarting = false
		return

	_restarting = true
	get_tree().paused = false
	_reset_shake()
	if GameMode.is_endless(_mode):
		# 「这副牌再来一次」：沿用当前模式与种子重开，而不是整场景重载
		# （重载会把模式打回经典，每日挑战与无尽就再也回不去了）。
		# 结算面板只是被 _begin_run 顺带收起，不走 reload 的副作用。
		_begin_run(_mode, _seed)
		_restarting = false
		return
	get_tree().reload_current_scene()


func _on_resume_requested() -> void:
	if _state == State.PAUSED:
		_set_paused(false)


## 暂停面板上的「换个玩法」：直接回玩法菜单，让玩家重新选模式。
##
## 不用 _begin_run 重开当前局——这条路的语义是「换」，不是在原地续命：
## 玩家的本意通常是「这局没戏了，换每日挑战试试」，
## 若把他送回同一模式同一种子，他会以为按钮坏了。
func _on_menu_requested() -> void:
	get_tree().paused = false
	pause_panel.set_paused(false)
	_reset_shake()
	_open_menu()


func _on_quit_requested() -> void:
	get_tree().paused = false
	_reset_shake()
	get_tree().quit()


func _update_hud() -> void:
	hud.set_score(_score, _best)
	hud.set_lives(_lives)
	# 无尽模式没有最后一关，max_level 传 0 让 HUD 走「第 N 关」的单数写法；
	# 硬塞 MAX_LEVEL 会让玩家在第 40 关看到「第 40 / 3 关」。
	hud.set_level(_level, 0 if GameMode.is_endless(_mode) else MAX_LEVEL)
	# 「低于阈值不上 HUD」这条规则住在 HeatSystem 里（display_combo），
	# Main 不再自己抄一遍阈值比较——抄一遍的话，改阈值就得记得改两处，
	# 而漏掉的那处症状是「连击数偶尔在 HUD 上闪一下」，极难定位。
	hud.set_combo(heat.display_combo())
	# 球数只在 >1 时显示：单球是常态，一直占着 HUD 只会让特殊状态不显眼
	hud.set_balls(balls.count())
	hud.set_mode(_mode_label())


## HUD 上的玩法徽标（模式名 + 种子码）。经典模式返回空串即不显示：
## 三关固定砖墙本来就在每个人的记忆里，多这一行只是噪音；
## 而无尽/每日必须常驻——玩家被打断之后回来，靠它才知道自己玩的是哪一局。
func _mode_label() -> String:
	if _mode == GameMode.Mode.CLASSIC:
		return ""
	return "%s · %s" % [GameMode.mode_name(_mode), GameMode.seed_text(_seed)]


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
	var intensity := heat.trail_intensity()
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
