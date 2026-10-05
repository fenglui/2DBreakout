class_name WallShapeProvider
extends Node2D
## 砖墙的属主：网格几何、每关的形状、特殊砖的分布，以及砖块本身的创建。
##
## 为什么要把建墙也收进来：网格尺寸、形状空位、每种砖的分数与耐久，
## 这三件事是同一个决策的三个侧面——「这一关的墙长什么样、每块砖多重、每块砖多硬」。
## 它们各自散在 Main 的常量表与 _build_bricks() 里时，想改一句「第 8 关起墙变高」
## 需要同时改四个地方，而漏掉的那一个不会报错，只会让第 8 关的墙悄悄还是 6 行。
##
## ## 形状不改变砖块总数——这是本节点最硬的一条约束
##
## 每种形状是一串「每行放几块砖」的数字，逐行相加恒等于 TEMPLATE_TOTAL（48）。
## 于是「砖块总数 == 48」从一句约定变成了可以被冒烟测试逐个形状验算的性质，
## 而依赖它的下游（通关判定、计分不变量、「总分是每块砖分值的整数倍」）
## 全部不用跟着改。形状换来的难度是**几何**而不是**工作量**：
## 墙更高更窄、有整行的桥、有掏空的口袋——球在里面的走法变了，
## 但「要打掉多少块」这个数字没变。
##
## 之所以把它写成硬约束而不是设计偏好：Main 里的通关判定读的是
## 「已清除计数 >= 本关砖数」。砖数一旦可变，判定、测试里
## 「把计数推到只剩最后一块」这类构造、计分不变量断言就三处一起变，
## 而它们之间没有任何一条会在失败时说清是哪一条变了。

# —— 网格 ——
const ROWS := 6
const COLUMNS := 8
const SIZE := Vector2(48, 20)
const GAP := 6.0
const TOP := 110.0
## 布局表里的空位哨兵。不是 Brick.Kind 的值，因此不会与任何砖种混淆。
const HOLE := -1

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
const TEMPLATE := [
	[0, 0, 0, 0, 0, 0, 0, 0],
	[0, 1, 0, 0, 3, 0, 0, 0],
	[0, 0, 0, 4, 0, 5, 0, 0],
	[0, 0, 2, 0, 0, 0, 4, 0],
	[0, 6, 0, 5, 0, 1, 0, 3],
	[0, 0, 2, 4, 0, 0, 0, 0],
]
const TEMPLATE_TOTAL := ROWS * COLUMNS

# —— 特殊砖数值 ——
## 每块砖的基础分。所有总分都是它的整数倍，冒烟测试守着这条不变量。
const POINTS_PER_BRICK := 10
## 各 kind 的分数倍率（乘 POINTS_PER_BRICK，索引与 Brick.Kind 对齐）。
## 刻意让每一项都是 POINTS_PER_BRICK 的整数倍，否则上面那条不变量就破了。
const KIND_POINTS_MULT := [1, 2, 3, 5, 4, 4, 3]
## 加固砖在本关标准耐久之上多挨几下
const ARMOR_EXTRA_HITS := 2

# —— 形状 ——
const SHAPE_NONE := 0
const SHAPE_PLATEAU := 1
const SHAPE_PYRAMID := 2
const SHAPE_RING := 3
const SHAPE_DIAMOND := 4
const SHAPE_COUNT := 5

## 每种形状的「每行放几块砖」轮廓，逐行相加必须等于 TEMPLATE_TOTAL。
##
## 键是 SHAPE_* 的字面整数（不是常量名）：GDScript 的 const 字典里
## 用另一个 const 当键要过一次常量求值，写成字面数则没有任何解析期依赖。
## 键与常量名的对应：1=PLATEAU / 2=PYRAMID / 3=RING / 4=DIAMOND。
##
## 数字本身的设计意图：
## - PLATEAU 7 行 / 中间整行留空：一条「桥」，球要么穿桥洞要么绕两侧，
##   同一面墙因此有两条完全不同的打法。
## - PYRAMID 8 行 / 上宽下窄：墙更深了，底部四行各只剩四块并居中，
##   球到底部时有两片空白可以随便走——容错更高，但也更难打到砖。
## - RING 7 行 / 中间一行满、上下各挖四块：一个正中的口袋。
## - DIAMOND 9 行 / 菱形：最高最瘦，把最难够到的砖压在墙心。
const SHAPE_PROFILES := {
	1: [8, 8, 8, 0, 8, 8, 8],
	2: [8, 8, 8, 8, 4, 4, 4, 4],
	3: [8, 8, 4, 8, 4, 8, 8],
	4: [4, 4, 6, 6, 8, 6, 6, 4, 4],
}

## 第几关开始启用形状。经典模式只有 MAX_LEVEL=3 关，因此形状对经典模式完全不可见，
## TEMPLATE 逐位复现的承诺也就不会被新系统动摇。
##
## 行数不另设上限：它由形状轮廓自己决定（最高的 DIAMOND 是 9 行），
## 多一个「最大行数」常量就多一处可能与轮廓表打架的配置。
const SHAPE_FROM_LEVEL := 4

## 砖墙建好了，总砖数在 wall_built 里给出。
signal wall_built(total: int)

## 本关网格行数与形状，由 generate() 写入。
var rows := ROWS
var shape := SHAPE_NONE
## 本关布局表：TEMPLATE 经形状与 LevelGenerator 处理后的结果。
var layout: Array = []
## 本关砖块总数。恒为 TEMPLATE_TOTAL（形状只改几何不改数量，见类注释）。
var total := TEMPLATE_TOTAL

# —— 建墙时注入的数值（由 Main 从关卡与卡牌算好写入）——
var base_hits := 1
var score_mult := 1
var extra_hits := 0
var armor_extra := ARMOR_EXTRA_HITS

## rows × COLUMNS 的占位表：true 表示该格有砖。
## 单独存一份而不是从 layout 推断，是因为 layout 在空位上写的是 NORMAL
## （见 _mask_out_holes），从它推断会把空位当成砖。
var _occupied: Array[Array] = []


## 注入建墙所需的数值。四个参数全部来自 Main 的关卡与卡牌计算，
## 本节点不反向读取任何一方的规则——砖墙不知道「疾风」这张牌长什么样。
func configure_build(base: int, mult: int, hits_add: int, armor_add: int) -> void:
	base_hits = base
	score_mult = mult
	extra_hits = hits_add
	armor_extra = ARMOR_EXTRA_HITS + armor_add


## 算出本关的形状与布局，不创建任何砖块。
##
## layout_seed == 0（经典模式）时逐位返回 TEMPLATE，
## 于是经典模式与冒烟测试里所有锚在布局表上的断言都不需要改。
func generate(layout_seed: int, level: int) -> void:
	var picked := _shape_for(layout_seed, level)
	var profile: Array = SHAPE_PROFILES.get(picked, [])
	if level < SHAPE_FROM_LEVEL or profile.is_empty():
		rows = ROWS
		shape = SHAPE_NONE
		_occupied = _filled_occupancy(ROWS)
		layout = LevelGenerator.generate(layout_seed, level, TEMPLATE)
	else:
		rows = profile.size()
		shape = picked
		_occupied = _profile_occupancy(profile)
		# 先在满网格上跑 LevelGenerator（它的三条硬约束都建立在「满矩形网格」上，
		# 直接喂带洞的表会让它按错误尺寸算锚点），再用 _mask_out_holes 摘掉空位。
		layout = LevelGenerator.generate(layout_seed, level, _shape_template())
		_mask_out_holes(layout)
	total = _count_occupied()


## 在 parent 下建出本关的全部砖块，并清掉上一关的残留。
##
## 分数与耐久写进砖块属性而不是每次命中时现算，因此「本关中途改加成」这种操作不存在。
## 砖色按行取自当前关卡调色板；行色数量与 rows 不一致时按取模循环。
func build(parent: Node2D, row_colors: Array, view_width: float) -> void:
	for old_brick in parent.get_children():
		old_brick.queue_free()

	var grid_width := COLUMNS * SIZE.x + (COLUMNS - 1) * GAP
	var start_x := (view_width - grid_width) * 0.5

	for row in rows:
		var row_color: Color = row_colors[row % row_colors.size()]
		for column in COLUMNS:
			if not is_occupied(row, column):
				continue
			var kind: int = int(layout[row][column])
			var brick := Brick.new()
			brick.size = SIZE
			brick.kind = kind
			brick.points = POINTS_PER_BRICK * int(KIND_POINTS_MULT[kind]) * score_mult
			brick.color = row_color
			# 只有加固砖额外加耐久；其余特殊砖沿用本关标准，
			# 免得「特殊砖更难打」与「难度曲线由关卡决定」两条规则打架。
			brick.max_hits = base_hits + extra_hits + \
				(armor_extra if kind == Brick.Kind.ARMORED else 0)
			brick.hits_left = brick.max_hits
			brick.position = Vector2(
				start_x + column * (SIZE.x + GAP) + SIZE.x * 0.5,
				TOP + row * (SIZE.y + GAP) + SIZE.y * 0.5
			)
			parent.add_child(brick)
	wall_built.emit(total)


## 该格位有没有砖。形状留空的地方返回 false。
func is_occupied(row: int, column: int) -> bool:
	if row < 0 or row >= rows or column < 0 or column >= COLUMNS:
		return false
	return bool((_occupied[row] as Array)[column])


## 本关出现的特殊砖名（行优先去重），用于结算面板的图例行。
## 从布局表现算而不是统计场上残砖：结算时砖几乎被打光了，
## 拿「还剩什么砖」去反推本关有什么砖，最后一行永远是空的。
func legend() -> String:
	var names: Array[String] = []
	for row in rows:
		for column in COLUMNS:
			if not is_occupied(row, column):
				continue
			var kind := int(layout[row][column])
			if kind == Brick.Kind.NORMAL:
				continue
			var kind_name := String(Brick.KIND_NAMES[kind])
			if not names.has(kind_name):
				names.append(kind_name)
	return " · ".join(names)


## 砖墙最下沿的 Y。Main 用它算球卡死脱离的安全落点。
func bottom_edge() -> float:
	return TOP + float(rows - 1) * (SIZE.y + GAP) + SIZE.y


## 该形状轮廓是否逐行相加等于 TEMPLATE_TOTAL。
## 冒烟测试拿它把「砖数恒定」从约定变成可验算的性质——
## 有人日后往表里加一行却忘了改总数，靠的就是这条断言拦住。
static func profile_sums_to_total(shape_value: int) -> bool:
	var profile: Array = SHAPE_PROFILES.get(shape_value, [])
	if profile.is_empty():
		return false
	var summed := 0
	for count: int in profile:
		summed += count
	return summed == TEMPLATE_TOTAL


# —— 内部实现 ——

## 形状的选择同时掺入种子与关卡号：每日挑战的不同种子要给出不同的墙，
## 而同一 (种子, 关卡) 必须永远给出同一面墙。
## 抽到 0 号（SHAPE_NONE）就用原始模板，于是约五分之一的关卡是
## 「没形状的普通墙」，避免玩家被形状套路住。
func _shape_for(layout_seed: int, level: int) -> int:
	return (absi(layout_seed) / 7 + level * 3) % SHAPE_COUNT


func _filled_occupancy(row_count: int) -> Array[Array]:
	var grid: Array[Array] = []
	for row in row_count:
		var line: Array = []
		line.resize(COLUMNS)
		line.fill(true)
		grid.append(line)
	return grid


## 把「每行放几块」翻译成占位表，每行的砖居中。
func _profile_occupancy(profile: Array) -> Array[Array]:
	var grid: Array[Array] = []
	for count: int in profile:
		var line: Array = []
		line.resize(COLUMNS)
		var lead := int(floorf(float(COLUMNS - count) * 0.5))
		for column in COLUMNS:
			line[column] = column >= lead and column < lead + count
		grid.append(line)
	return grid


## 满网格模板：有砖处一律填普通砖。形状的空位由 _occupied 单独表达，
## 不写进模板里——LevelGenerator 只认识「一张满的矩形网格」，
## 它的锚点与种类下界两条硬约束都建立在那个前提上。
##
## 形状不把空位写进模板，是刻意的：LevelGenerator 会把空位当成可升级的普通砖，
## 于是「这一关有 48 块砖」与「生成器在满网格上工作」两件事必须分开表达，
## 否则二选一，另一条都得破。空位上的砖由 _mask_out_holes 事后处理。
func _shape_template() -> Array:
	var template: Array = []
	for row in rows:
		var line: Array = []
		line.resize(COLUMNS)
		for column in COLUMNS:
			line[column] = Brick.Kind.NORMAL
		template.append(line)
	return template


## 把落在空位上的特殊砖「挪」到最近的合法普通砖上，然后把空位写成 HOLE。
##
## 挪这一步不是为了凑数：LevelGenerator 的第 2 条硬约束是
## 「模板里出现过的每种特殊砖，墙上至少还剩一块」，而它在满网格上验证了这一点。
## 直接删空位就会把刚补回来的那一块也删掉，某一类特殊砖可能整关不出现，
## 「玩家能见到全部机制」与「本关图例」两件事都随形状漂移。
func _mask_out_holes(layout: Array) -> void:
	for row in rows:
		for column in COLUMNS:
			if is_occupied(row, column):
				continue
			var kind := int(layout[row][column])
			layout[row][column] = HOLE
			if kind != Brick.Kind.NORMAL:
				_relocate(layout, row, column, kind)


## 把 kind 挪到同一行里第一个「有砖 + 普通 + 非锚点」的格位；本行没有就放弃。
## 放弃是可接受的降级：宁可某一类砖在这一关少一格分布，也不要为了守住
## 「每类至少一块」而去改写锚点格——锚点是冒烟测试的断言锚点。
func _relocate(layout: Array, row: int, column: int, kind: int) -> void:
	for offset in range(1, COLUMNS):
		for direction: int in [1, -1]:
			var target := column + direction * offset
			if not is_occupied(row, target):
				continue
			if LevelGenerator.is_anchor(row, target, rows, COLUMNS):
				continue
			if int(layout[row][target]) != Brick.Kind.NORMAL:
				continue
			layout[row][target] = kind
			return


func _count_occupied() -> int:
	var counted := 0
	for row in rows:
		for column in COLUMNS:
			if is_occupied(row, column):
				counted += 1
	return counted