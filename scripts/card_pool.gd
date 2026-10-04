class_name CardPool
extends RefCounted
## 卡池与抽卡逻辑（纯静态函数，无实例状态）。
##
## 复玩性的第二条来源：每过一关给玩家三张牌选一张，牌永久生效到本局结束。
## 卡面数据放在 `const CARDS`（数组的数组元素是字典）而不是一堆 class_name 资源，
## 三个理由：
## 1) 冒烟测试要能通过 get_script_constant_map() 把整张卡表原样读出来交叉核对
##    （「每张卡的 id 不重复」「mods 的键都在白名单里」「倍率都是整数」这类断言），
##    内嵌类做不到这一点。
## 2) 卡的加成是数据不是行为。Main 用 ADDITIVE_KEYS / MULTIPLIED_KEYS 两个白名单
##    决定「叠加以数值叠加」还是「叠加以数值相乘」，加一张卡不用碰任何游戏逻辑。
## 3) 卡表能被人一眼读完，改平衡不用来回跳文件。

## 一次发几张
const DRAFT_SIZE := 3
## 从第几关起保证至少给一张稀有及以上
const RARE_FROM_LEVEL := 3
## 关卡号混入抽卡种子用的盐
const LEVEL_SALT := 104729
## 同一关多次抽卡（例如跳过后再抽）的盐基数
const SALT_STEP := 6151
## RARITY_NAMES 索引与卡面 rarity 对齐
const RARITY_NAMES := ["普通", "稀有", "史诗"]

## 叠加以数值相加的键。加法型一律「给一个固定量」，叠起来线性变强。
const ADDITIVE_KEYS := [
	"paddle_bonus", "brick_hits", "blast_add", "armor_add", "slow_add",
	"slow_scale_add", "split_deg_add", "max_balls_add", "max_lives_add", "shield",
]
## 叠加以数值相乘的键。
##
## 这三个键刻意要求整数倍率（score_mult / combo_mult）：冒烟测试有一条
## 「总分始终是每块砖分值的整数倍」的不变量断言，非整数倍率会打破它。
const MULTIPLIED_KEYS := ["speed_mul", "score_mult", "combo_mult"]
## 不进累积加成表、抽中当场结算的键。
const IMMEDIATE_KEYS := ["extra_lives", "reroll"]

## 卡面表。每项的字段：
## id        稳定标识（存档与测试按它认牌，不能改）
## name/desc 显示文案（新增汉字必须补进 fonts/ui-font.otf 的子集）
## rarity    0 普通 / 1 稀有 / 2 史诗
## max_stack 本局最多可叠几张，够池子见底时也不会空抽
## weight    抽中权重
## mods      加成字典，键必须在上面三个白名单里
const CARDS := [
	{
		"id": "wide", "name": "宽板", "desc": "挡板加宽 14 像素",
		"rarity": 0, "max_stack": 3, "weight": 10,
		"mods": {"paddle_bonus": 14.0},
	},
	{
		"id": "swift", "name": "疾风", "desc": "球速提高一成，更容易打出连击",
		"rarity": 0, "max_stack": 3, "weight": 10,
		"mods": {"speed_mul": 1.08},
	},
	{
		"id": "steady", "name": "缓速", "desc": "球速降低一成，更好控球",
		"rarity": 0, "max_stack": 3, "weight": 10,
		"mods": {"speed_mul": 0.92},
	},
	{
		"id": "greedy", "name": "贪婪", "desc": "每块砖的分数翻倍",
		"rarity": 1, "max_stack": 4, "weight": 6,
		"mods": {"score_mult": 2},
	},
	{
		"id": "duelist", "name": "连击大师", "desc": "连击奖励翻倍",
		"rarity": 1, "max_stack": 3, "weight": 6,
		"mods": {"combo_mult": 2},
	},
	{
		"id": "plated", "name": "镀层", "desc": "所有砖块多挨一下",
		"rarity": 1, "max_stack": 2, "weight": 6,
		"mods": {"brick_hits": 1},
	},
	{
		"id": "bombard", "name": "爆破强化", "desc": "爆炸半径增加 24 像素",
		"rarity": 1, "max_stack": 3, "weight": 6,
		"mods": {"blast_add": 24.0},
	},
	{
		"id": "sledge", "name": "破甲", "desc": "加固砖额外多挨两下",
		"rarity": 1, "max_stack": 2, "weight": 6,
		"mods": {"armor_add": 2},
	},
	{
		"id": "glacial", "name": "冰封", "desc": "减速持续时间增加 3 秒",
		"rarity": 1, "max_stack": 3, "weight": 6,
		"mods": {"slow_add": 3.0},
	},
	{
		"id": "thaw", "name": "速融", "desc": "减速效果明显减弱",
		"rarity": 1, "max_stack": 2, "weight": 6,
		"mods": {"slow_scale_add": 0.18},
	},
	{
		"id": "swarm", "name": "蜂群", "desc": "同屏球数上限加 3",
		"rarity": 2, "max_stack": 2, "weight": 3,
		"mods": {"max_balls_add": 3},
	},
	{
		"id": "scatter", "name": "散射", "desc": "分裂角度增加 20 度",
		"rarity": 2, "max_stack": 2, "weight": 3,
		"mods": {"split_deg_add": 20.0},
	},
	{
		"id": "fountain", "name": "生命之泉", "desc": "立刻加 2 生命，生命上限加 1",
		"rarity": 2, "max_stack": 1, "weight": 3,
		"mods": {"extra_lives": 2, "max_lives_add": 1},
	},
	{
		"id": "ward", "name": "护盾", "desc": "抵消 1 次掉球",
		"rarity": 2, "max_stack": 3, "weight": 3,
		"mods": {"shield": 1},
	},
	{
		"id": "reforge", "name": "重铸", "desc": "下一关砖墙重新生成",
		"rarity": 2, "max_stack": 9, "weight": 3,
		"mods": {"reroll": 1},
	},
]

## RARITY_WEIGHTS 索引与 rarity 对齐。史诗权重压到 3：
## 抽卡是「每关一次」的高频事件，史诗太容易出反而没有惊喜。
const RARITY_WEIGHTS := [10, 6, 3]


static func rarity_name(rarity: int) -> String:
	if rarity < 0 or rarity >= RARITY_NAMES.size():
		return String(RARITY_NAMES[0])
	return String(RARITY_NAMES[rarity])


static func is_additive(key: String) -> bool:
	return key in ADDITIVE_KEYS


static func is_multiplied(key: String) -> bool:
	return key in MULTIPLIED_KEYS


static func is_immediate(key: String) -> bool:
	return key in IMMEDIATE_KEYS


## 按 id 查卡；查不到返回空字典（不是 null：调用方不用判两次）。
static func card_by_id(card_id: String) -> Dictionary:
	for card in CARDS:
		if String(card["id"]) == card_id:
			return card as Dictionary
	return {}


## 还能抽的牌：叠加次数没到 max_stack 的全部卡。
## owned 是 {id: 已叠次数}。
static func eligible(owned: Dictionary) -> Array:
	var pool: Array = []
	for card in CARDS:
		var card_id := String(card["id"])
		if int(owned.get(card_id, 0)) < int(card["max_stack"]):
			pool.append(card)
	return pool


## 还能抽的牌的 id（供测试与界面展示）。
static func eligible_ids(owned: Dictionary) -> Array:
	var ids: Array = []
	for card in eligible(owned):
		ids.append(String(card["id"]))
	return ids


## 抽一次三选一。返回卡面字典数组，长度 ≤ DRAFT_SIZE（牌池见底时会更短）。
##
## 同一对 (run_seed, level, owned, salt) 必然得到同一手牌：
## rng 完全由这四项播种，不碰全局 randi()。每日挑战因此是「同一天所有人
## 在同一关看到同一手牌」，这是它和普通随机数最难的地方。
##
## salt 给同一关的重复抽卡用（玩家跳过之后又抽），否则每次都是同一手，
## 「跳过」这个操作就变得毫无意义。
static func draft(run_seed: int, level: int, owned: Dictionary, salt: int = 0) -> Array:
	var pool := eligible(owned)
	if pool.is_empty():
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = int(run_seed) + maxi(level, 1) * LEVEL_SALT + salt * SALT_STEP

	var picked: Array = []
	while picked.size() < DRAFT_SIZE and not pool.is_empty():
		picked.append(_weighted_pop(pool, rng))
	if picked.size() < 2:
		return picked
	if maxi(level, 1) >= RARE_FROM_LEVEL and not _has_rare(picked):
		_guarantee_rare(picked, pool)
	return picked


# —— 内部实现 ——

## 按权重从池子里取一张并移出池子。
static func _weighted_pop(pool: Array, rng: RandomNumberGenerator) -> Dictionary:
	var total := 0
	for card in pool:
		total += maxi(1, int(card["weight"]))
	var roll := rng.randi_range(0, total - 1)
	var walk := 0
	for i in pool.size():
		walk += maxi(1, int(pool[i]["weight"]))
		if roll < walk:
			var chosen: Dictionary = pool[i]
			pool.remove_at(i)
			return chosen
	# 权重全为 0 时 randi_range(0, -1) 不可用；退化成取第一张。
	var fallback: Dictionary = pool[0]
	pool.remove_at(0)
	return fallback


static func _has_rare(picked: Array) -> bool:
	for card in picked:
		if int(card["rarity"]) > 0:
			return true
	return false


## 保底：把最后一张换成池子里稀有度最高的一张（史诗优先）。
## 池里已经抽走的那几张由 picked 保证不会被重复选到。
static func _guarantee_rare(picked: Array, pool: Array) -> void:
	var best_index := -1
	var best_rarity := 0
	for i in pool.size():
		var rarity := int(pool[i]["rarity"])
		if rarity > best_rarity:
			best_rarity = rarity
			best_index = i
	if best_index < 0:
		return
	picked[picked.size() - 1] = pool[best_index]