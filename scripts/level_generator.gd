class_name LevelGenerator
extends RefCounted
## 带种子的砖墙布局生成器（纯静态函数，无实例状态）。
##
## 设计目标只有一个：**经典模式必须逐位复现模板**。
## 所以规则是「模板 + 按种子打补丁」而不是「从零随机生成」：
## - run_seed == 0 时原样返回模板副本，一格都不动。
##   Main 的 BRICK_LAYOUT 因此同时是「经典模式的墙」与「变体生成的底图」，
##   老玩家与冒烟测试的锚点断言都不需要改。
## - run_seed != 0 时在底图上做三种改写：把普通砖升级成特殊砖、
##   换掉一部分既有特殊砖的种类、最后修复丢失的种类。
##
## 三条硬约束（保证任何种子下墙都是合法且可玩的）：
## 1) 锚点格位永远是普通砖（第 0 行整行 + 末行最后两块）。
##    这不只是「留点普通砖」，更是冒烟测试的两处锚点
##    （第 2 关 get_child(0) 的耐久、末行最后两块砖的通关判定）。
## 2) 模板里出现过的每一种特殊砖，墙上至少还剩一块。
##    没有这条，随机改写可能把某一类抹干净，而「本关图例」与
##    「玩家能见到全部机制」两件事都会随种子漂移。
## 3) 砖块总数不变（只换 kind，不删格子）。
##    通关判定是「已清除计数 == BRICK_TOTAL」，改数量就得连判定一起改。

## 关卡号混入种子，让同一局的不同关卡长得不一样。
const LEVEL_SALT := 7919
## 第 1 关额外升级成特殊砖的格数
const SPECIAL_BASE := 6
## 每往后一关，额外升级的格数增加这么多
const SPECIAL_PER_LEVEL := 2
## 升级格数上限（再高整面墙就没法看了）
const SPECIAL_CAP := 30
## 改写既有特殊砖「种类」的格数上限
const SWAP_CAP := 8
const SWAP_PER_LEVEL := 2


## 该格位是否为锚点（永远保持普通砖）。
## rows/columns 显式传入而不是从模板推断：调用方已经知道尺寸，
## 而测试也需要能单独问「这个格位算不算锚点」。
static func is_anchor(row: int, column: int, rows: int, columns: int) -> bool:
	if row == 0:
		return true
	return row == rows - 1 and (column == columns - 1 or column == columns - 2)


## 生成一关的布局表：返回 rows × columns 的二维数组，元素是 Brick.Kind 的整数值。
##
## run_seed 为 0 时原样返回模板副本；否则按 run_seed + level 打补丁。
## 同一对 (run_seed, level) 永远得到同一张表——这是每日挑战能成立的前提。
static func generate(run_seed: int, level: int, template: Array) -> Array:
	var rows: int = template.size()
	var layout := copy_layout(template)
	if run_seed == 0 or rows == 0:
		return layout
	var columns: int = (template[0] as Array).size()
	if columns <= 0:
		return layout

	var rng := RandomNumberGenerator.new()
	rng.seed = int(run_seed) + maxi(level, 1) * LEVEL_SALT

	var free_cells := _free_cells(rows, columns)
	if free_cells.is_empty():
		return layout
	var specials := special_kinds()
	var order := _shuffled(free_cells, rng)

	# ① 普通砖升级为特殊砖。只升不降：模板里的特殊砖一个都不会被抹掉，
	#    于是「模板有哪几种特殊砖」这条下界天然成立。
	var budget := mini(SPECIAL_BASE + maxi(level - 1, 0) * SPECIAL_PER_LEVEL, SPECIAL_CAP)
	var upgraded := 0
	for cell in order:
		if upgraded >= budget:
			break
		if int(layout[cell.x][cell.y]) != Brick.Kind.NORMAL:
			continue
		layout[cell.x][cell.y] = specials[rng.randi_range(0, specials.size() - 1)]
		upgraded += 1

	# ② 换掉一部分既有特殊砖的种类。只改种类不改格位，砖块总数依旧不变。
	var swaps := mini(maxi(level - 1, 0) * SWAP_PER_LEVEL, SWAP_CAP)
	for i in swaps:
		var targets := _special_cells(layout, free_cells)
		if targets.is_empty():
			break
		var cell: Vector2i = targets[rng.randi_range(0, targets.size() - 1)]
		layout[cell.x][cell.y] = specials[rng.randi_range(0, specials.size() - 1)]

	# ③ 修复：② 可能把某一类彻底换没了，把它补回某块仍是普通砖的非锚点格位。
	_restore_kinds(layout, template, rng, free_cells)
	return layout


## 深拷贝布局表。模板是 const 数组（只读），直接改会报错，
## 而且就算能改也会让「同一份模板生成两关时互相污染」。
static func copy_layout(template: Array) -> Array:
	var layout: Array = []
	for row in template:
		layout.append((row as Array).duplicate())
	return layout


## 全部特殊砖的 kind 值（排除 NORMAL）。
static func special_kinds() -> Array[int]:
	var kinds: Array[int] = []
	for kind in range(1, Brick.KIND_NAMES.size()):
		kinds.append(kind)
	return kinds


## 布局里特殊砖的总数。
static func count_specials(layout: Array) -> int:
	var total := 0
	for row in layout:
		for kind in row:
			if int(kind) != Brick.Kind.NORMAL:
				total += 1
	return total


## 布局里某一种 kind 出现了几次。
static func count_kind(layout: Array, kind: int) -> int:
	var total := 0
	for row in layout:
		for value in row:
			if int(value) == kind:
				total += 1
	return total


# —— 内部实现 ——

## 全部非锚点格位。
static func _free_cells(rows: int, columns: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for row in rows:
		for column in columns:
			if not is_anchor(row, column, rows, columns):
				cells.append(Vector2i(row, column))
	return cells


## 当前是特殊砖的非锚点格位。
static func _special_cells(layout: Array, free_cells: Array[Vector2i]) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell in free_cells:
		if int(layout[cell.x][cell.y]) != Brick.Kind.NORMAL:
			cells.append(cell)
	return cells


## Fisher-Yates 洗牌（就地），返回同一个数组方便链式使用。
static func _shuffled(cells: Array[Vector2i], rng: RandomNumberGenerator) -> Array[Vector2i]:
	for i in range(cells.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := cells[i]
		cells[i] = cells[j]
		cells[j] = tmp
	return cells


## 模板里出现过的每一种特殊砖，在结果墙上至少保留一块。
static func _restore_kinds(layout: Array, template: Array, rng: RandomNumberGenerator,
		free_cells: Array[Vector2i]) -> void:
	var required := {}
	for row in template:
		for value in row:
			var kind := int(value)
			if kind != Brick.Kind.NORMAL:
				required[kind] = true
	for kind_value in required.keys():
		if count_kind(layout, int(kind_value)) > 0:
			continue
		var candidates: Array[Vector2i] = []
		for cell in free_cells:
			if int(layout[cell.x][cell.y]) == Brick.Kind.NORMAL:
				candidates.append(cell)
		if candidates.is_empty():
			# 非锚点格位全是特殊砖：宁可不动，也不要破坏锚点约束。
			return
		var pick: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
		layout[pick.x][pick.y] = int(kind_value)