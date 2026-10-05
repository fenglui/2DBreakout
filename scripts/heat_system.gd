class_name HeatSystem
extends Node2D
## 连击与热度的属主。
##
## 拆出来的理由：连击原本是 Main 里三个平行字段（当前 / 合计 / 最好）加三个方法，
## 但它真正的规则是「一次往返内的连击，回板时折算成额外分数，掉球整段作废」——
## 这是一条自带时序的小状态机，散在 Main 里时每次改计分都要重新确认
## 「这次改动会不会漏掉某条结算路径」。热度则是叠在它之上的第二条轴：
## 连击管「这一趟打穿了几块」，热度管「玩家主动接了多少次球」。
##
## 两者的关系写在下面的注释里，这里只强调一句：热度只认「主动接住」，
## 不认「碰一下挡板」。理由是碰挡板在原版里是被动的、无法拒绝的，
## 按它涨热度等于奖励什么都不做，几次之后玩家就只会用最省力的方式刷分。
##
## 热度倍率刻意全是整数：冒烟测试有一条「总分始终是每块砖分值的整数倍」
## 的不变量断言，热度倍率一旦出现 1.5 这种小数，这条断言就会在真实游玩里炸掉，
## 而它在 headless 里因为热度始终为 0 反而看不出问题。
## 这类「测试环境恰好绕过的坑」比它挡住的 bug 更危险，所以从数值表这一层就掐死。

## 连击计数达到该值才在 HUD 上打出连击数字、并触发连击飘字
const COMBO_HIGHLIGHT := 3
## 连击达到该值时拖尾增粗并偏暖到 BallTrail.GLOW_COLOR
const COMBO_GLOW_AT := 5
## 每多一连给的分数。当前与 Main.POINTS_PER_BRICK 同值，但两者是不同的概念
## （一个讲砖块单价、一个讲连击奖励），冒烟测试有一条断言专门钉住这个同值关系。
const COMBO_UNIT_POINTS := 10

# —— 热度 ——
## 一次「主动接住」攒多少热度。
const HEAT_PER_CATCH := 1.0
## 每秒回落多少热度。取 0.55：停手大约 7 秒就掉回零档，
## 逼玩家把接球接成连续动作而不是开局猛按一阵然后晾着。
const HEAT_DECAY_PER_SECOND := 0.55
## 每攒够多少热度升一档
const HEAT_TIER_STEP := 4.0
## 各档的分数倍率。全部是整数，理由见类注释。
const HEAT_TIER_MULT := [1, 2, 3]
## 每档让挡板窄多少像素。热度是「拿操作精度换分数」：
## 分数倍率看不见也摸不着，挡板变窄是当场就能感觉到的那一半代价。
const HEAT_PENALTY_STEP_PX := 6.0
## 挡板收窄上限（像素）。挡板本身有 Paddle.MIN_WIDTH 的硬下限，
## 这里再加一道上限是为了不让高热度把挡板压到几乎接不住球。
const HEAT_PENALTY_MAX_PX := 18.0

## 热度变化（档位变化时发）。ratio 是 0~1 的热度条，mult / penalty 是这一档的取值。
## Main 收到后刷新 HUD 与挡板宽度——热度要在**变化的那一刻**就反映到挡板上，
## 隔一帧会让玩家觉得「我明明打中了，挡板怎么自己变窄了」。
signal heat_changed(ratio: float, mult: int, penalty: float)
## 连击已入账（combo >= 2 时才发）。Main 在这里播飘字、音高随连击升高。
signal combo_banked(combo: int, bonus: int)
## 连击被丢弃（掉球 / 换关），本次没有拿到任何连击奖励。
signal combo_discarded(combo: int)

## 连击倍率（乘法型卡）。由 Main 在结算前注入，本节点不认任何具体的牌。
var combo_mult := 1

## 当前这次飞行中连续击破的砖数。
var _combo := 0
var _combo_total := 0
var _best_combo := 0
var _heat := 0.0
## 上一帧结算时热度的最终取值，用于判断档位有没有真的变了。
## 不记它的话每帧回落都会发一次 heat_changed，
## 挡板宽度于是被每帧重算一遍（虽然结果相同，但白花开销 + 逼出多余的重绘）。
var _last_tier := 0


## 注入连击倍率。在 Main 每次结算连击之前调用。
func configure_combo_mult(mult: int) -> void:
	combo_mult = maxi(1, mult)


func combo() -> int:
	return _combo


func combo_total() -> int:
	return _combo_total


func best_combo() -> int:
	return _best_combo


## 直接写入连击数。
##
## 存在这个口子只有一个理由：Main 把 _combo 声明成转发属性，
## 而冒烟测试有两处需要把连击「摆」到某个值再观察结算口径
## （先验「低于阈值不上 HUD」，再验「达到阈值上 HUD」）。
## 走一次正常的击破路径要打四块砖才能到这个状态，测试会因此变成慢且脆的构造。
func set_combo(value: int) -> void:
	_combo = maxi(0, value)
	_best_combo = maxi(_best_combo, _combo)


## HUD 上该显示的连击数：不到阈值就返回 0（1 连击每次都在闪，纯粹是噪音）。
func display_combo() -> int:
	return _combo if _combo >= COMBO_HIGHLIGHT else 0


## 连击越高，拖尾越粗越亮。返回 0~1 的强度，颜色与线宽由 BallTrail 自己派生。
func trail_intensity() -> float:
	return clampf(float(_combo) / float(COMBO_GLOW_AT), 0.0, 1.0)


func heat() -> float:
	return _heat


## 热度条 0~1（相对满档 HEAT_TIER_STEP × 可升档数）。
func heat_ratio() -> float:
	var top := HEAT_TIER_STEP * float(HEAT_TIER_MULT.size() - 1)
	return clampf(_heat / maxf(top, 1.0), 0.0, 1.0)


## 当前档位的分数倍率。恒为整数，见类注释。
func score_mult() -> int:
	return int(HEAT_TIER_MULT[clampi(_last_tier, 0, HEAT_TIER_MULT.size() - 1)])


## 当前档位让挡板窄了多少像素（取正值用，调用方自己减）。
func paddle_penalty() -> float:
	return minf(float(_last_tier) * HEAT_PENALTY_STEP_PX, HEAT_PENALTY_MAX_PX)


# —— 事件入口 ——

## 一块砖被击破。返回累计后的连击数。
func register_break() -> int:
	_combo += 1
	_best_combo = maxi(_best_combo, _combo)
	return _combo


## 玩家主动接住了一颗球（CaughtBallFlow.caught）。
## 只涨热度，不动连击：连击由击破砖块累计，
## 把两者混在一起会出现「我没打砖只是接了个球也算连击」的错觉。
func register_catch() -> void:
	_heat = minf(_heat + HEAT_PER_CATCH, HEAT_TIER_STEP * float(HEAT_TIER_MULT.size() - 1))
	_sync_tier()


## 连击结算：把「这一次飞行打掉几块砖」折算成额外分数，返回入账的分数。
## 与 register_break() 共用同一条路径，保证球撞碎与爆破波及口径完全一致。
func bank() -> int:
	var settled := _combo
	if settled <= 0:
		reset_combo()
		return 0
	var bonus := combo_bonus_for(settled) * maxi(1, combo_mult)
	if bonus > 0:
		_combo_total += 1
	reset_combo()
	combo_banked.emit(settled, bonus)
	return bonus


## 连击作废（掉球 / 换关）：整段丢弃而不入账。
## 这是 combo 的风险面。如果掉球也结算，玩家会无脑刷砖等结算，反而不会去接球。
func discard() -> void:
	var dropped := _combo
	reset_combo()
	if dropped > 0:
		combo_discarded.emit(dropped)


## 清零连击计数。已结算、已作废、换关三条路径都走这里。
func reset_combo() -> void:
	_combo = 0


## 开新一局：连击统计与热度全部归零。
func reset_run() -> void:
	_combo = 0
	_combo_total = 0
	_best_combo = 0
	reset_heat()


## 换关：热度清零，但保留跨关统计（最好连击 / 结算次数是整局口径）。
## 热度不该跨关——它衡量的是「这一关里接球的连续性」，跨关累计会让
## 第 30 关一开始就顶在满档，玩家反而不敢再接球。
func reset_level() -> void:
	reset_combo()
	reset_heat()


## 掉光球时把热度一并清掉：热度本来就是「拿精度换分数」，
## 掉了球说明这次精度没押中，惩罚不兑现就等于热度没有风险面。
func reset_heat() -> void:
	_heat = 0.0
	_sync_tier()


## 每秒回落热度。放在物理帧里：热度是计时器，与球的移动无关，
## 而 Main 在暂停时照样会跑 _physics_process，所以状态检查由调用方负责。
func tick(delta: float) -> void:
	if _heat <= 0.0:
		return
	_heat = maxf(0.0, _heat - HEAT_DECAY_PER_SECOND * delta)
	_sync_tier()


## 连击奖励公式（纯函数）。
##
## 取 `(combo - 1) * COMBO_UNIT_POINTS`：第 2 块砖起每多一块多给一份，
## 于是 2→1×、3→2×、4→3×，线性递增。刻意避开三角数公式 `combo*(combo+1)/2`：
## 那会让 1 块砖也白送一份分，而 1 块砖是完全不需要技巧的默认操作，
## 送分等于告诉玩家「乱打也有奖励」。这里从 2 起算，第一块只拿基础分。
## 全程只做整数乘加，总分始终是每块砖分值的整数倍——
## 冒烟测试有一条断言专门守这个不变量。
##
## 声明成 static 是刻意的：冒烟测试直接调用它算期望值，
## 而不是把公式抄一份进测试——抄副本的话，公式一改测试就会静默失效。
static func combo_bonus_for(combo: int) -> int:
	return maxi(0, combo - 1) * COMBO_UNIT_POINTS


# —— 内部实现 ——

## 热度跨过档位线时同步一次，变了才发信号。
func _sync_tier() -> void:
	var tier := clampi(int(_heat / HEAT_TIER_STEP), 0, HEAT_TIER_MULT.size() - 1)
	if tier == _last_tier:
		return
	_last_tier = tier
	heat_changed.emit(heat_ratio(), score_mult(), paddle_penalty())