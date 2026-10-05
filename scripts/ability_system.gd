class_name AbilitySystem
extends Node2D
## 空中主动技的属主：凝滞（子弹时间）与扳挡（镜像反弹）。
##
## 为什么这两件事必须住在同一个节点里：它们共用同一条「有代价、可重复、限时」的规则——
## 有使用次数、按下是无边沿的（键盘有 key repeat，摇杆没有）、暂停与换关必须停表。
## 这三条规则一旦分散在两处，典型的后果是「按住扳挡键不放，挡板每帧翻一次，
## 球在两次反弹之间左右横跳」。放在一个节点里，按键去抖与冷却只有一份实现。
##
## 凝滞改的是 Engine.time_scale 这个全局量，因此本节点额外承担一个责任：
## **必须能把它改过的值原样还回去**。这里刻意记下「按下那一刻的全局时间倍率」
## 而不是记一个写死的 1.0 —— headless 冒烟测试整轮都跑在 time_scale=4.0 上，
## 写死还原会把测试的加速悄悄抹掉，而症状是「某个时序断言偶尔慢十倍」，
## 极难往这个方向查。场景重载走 _exit_tree 还原，避免时间倍率泄漏到下一局。

## 凝滞期间的全局时间倍率。0.35 是「明显变慢但还能看清球在动」：
## 再慢玩家会觉得画面卡死，再快就打不出「在慢动作里调整站位」的收益。
const BULLET_TIME_SCALE := 0.35
## 一次凝滞持续秒数。0.6s 足够把挡板挪到球落点，也短到不可能拿来farm。
const BULLET_TIME_SECONDS := 0.6
## 两秒内按两次键只算一次。键盘的 key repeat 会把「按住」变成每帧一次
## is_action_pressed()==true，没有这道闸门一次按键能连放好几次凝滞。
const BULLET_TIME_REPEAT_LOCK := 0.4
## 扳挡的连按锁。同上，只是扳挡不吃充能，锁一记就够。
const FLIP_REPEAT_LOCK := 0.3

## 凝滞开始 / 结束。
signal bullet_time_changed(active: bool)
## 扳挡开关状态变化。
signal flip_changed(flipped: bool)

var _max_charges := 1
var _charges := 1
var _left := 0.0
var _repeat_lock := 0.0
var _flipped := false
var _flip_lock := 0.0
## 本节点按下凝滞那一刻的全局时间倍率。还原时用它，而不是 1.0。
var _base_time_scale := 1.0
## 当前全局时间倍率是不是本节点改的。
##
## 这道标记比「拿 Engine.time_scale 和 _base_time_scale * BULLET_TIME_SCALE 比一下」
## 可靠得多：后者在「本节点从来没按过凝滞」时会把 Engine.time_scale 无声改回
## _base_time_scale（初值 1.0），而 headless 冒烟测试整轮都跑在 time_scale=4.0 上——
## reset() 与 _exit_tree 都会被调用一次，于是测试的 4 倍加速被抹成 1 倍，
## 症状是「某个时序断言偶尔慢四倍」，根本查不到这个节点头上。
var _owns_time_scale := false


func _ready() -> void:
	# 暂停时两样主动技都要停表：凝滞是全局时间倍率，暂停中继续倒计时的话
	# 玩家会看到「暂停一秒，回来凝滞已经结束了」。
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _exit_tree() -> void:
	# 场景重载（结算面板的「再来一局」就走这条路）会走这里。
	# 不还原的话 Engine.time_scale 会带着凝滞的倍率泄漏进新场景，
	# 表现是「重开之后整个游戏变成慢动作」，而且再也不会自己恢复。
	_restore_time_scale()


func _process(delta: float) -> void:
	_repeat_lock = maxf(0.0, _repeat_lock - delta)
	_flip_lock = maxf(0.0, _flip_lock - delta)
	if _left <= 0.0:
		return
	_left = maxf(0.0, _left - delta)
	if _left > 0.0:
		return
	_restore_time_scale()
	bullet_time_changed.emit(false)


## 凝滞剩余次数 / 上限。HUD 用它显示按键提示。
func charges() -> int:
	return _charges


func max_charges() -> int:
	return _max_charges


## 设置本局的凝滞上限（开场 1 次，卡牌可以抬）。会同步补满当前次数。
func set_max_charges(value: int) -> void:
	_max_charges = maxi(0, value)
	_charges = _max_charges


## 加一次凝滞充能（生命砖 / 卡牌用）。
func grant_charges(count: int) -> void:
	_max_charges = maxi(_max_charges, _charges + maxi(0, count))
	_charges = mini(_max_charges, _charges + maxi(0, count))


func is_bullet_time_active() -> bool:
	return _left > 0.0


func is_flipped() -> bool:
	return _flipped


## bullet_time 动作的按下 / 松开。做成带 down 参数而不是只收按下，
## 是为了让「连按锁」有个确定的解除时机（松开即归零），
## 否则玩家按住不放就只能等冷却走完。
func on_bullet_time_input(down: bool) -> void:
	if down:
		_try_bullet_time()
	else:
		_repeat_lock = 0.0


## flip 动作的按下。扳挡不吃充能（它的代价是「反弹角反了」这件事本身
## 对准砖墙更难），因此只有连按锁，没有次数。
func on_flip_pressed() -> void:
	if _flip_lock > 0.0:
		return
	_flip_lock = FLIP_REPEAT_LOCK
	_flipped = not _flipped
	flip_changed.emit(_flipped)


## 停表：凝滞立刻结束、扳挡复位。
## **不退还凝滞次数** —— 次数是本局资源（同 Main 里的护盾），
## 跨关保留；而「凝滞还剩 0.4 秒」这种瞬时状态必须在换关 / 暂停 / 结算时清干净。
## Main 在新一局时另外调 reset_run() 把次数也归零。
func reset() -> void:
	_restore_time_scale()
	_left = 0.0
	_repeat_lock = 0.0
	_flip_lock = 0.0
	if _flipped:
		_flipped = false
		flip_changed.emit(false)


## 开新一局：连次数一起归零。
func reset_run() -> void:
	reset()
	_max_charges = 1
	_charges = 1


# —— 内部实现 ——

func _try_bullet_time() -> void:
	if _repeat_lock > 0.0 or _charges <= 0 or _left > 0.0:
		return
	_charges -= 1
	_repeat_lock = BULLET_TIME_REPEAT_LOCK
	_left = BULLET_TIME_SECONDS
	_base_time_scale = Engine.time_scale
	Engine.time_scale = _base_time_scale * BULLET_TIME_SCALE
	_owns_time_scale = true
	bullet_time_changed.emit(true)


func _restore_time_scale() -> void:
	# 没持有过就不碰全局量：reset() 与 _exit_tree 都会被无条件调用，
	# 没有这道门它们会把别人设的时间倍率也一并改掉。
	if not _owns_time_scale:
		return
	_owns_time_scale = false
	Engine.time_scale = _base_time_scale