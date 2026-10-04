class_name BallManager
extends Node2D
## 球的总管：场上所有球的唯一所有者与「还剩几颗球」的唯一权威来源。
##
## 存在理由：P0 之前场上只有一颗球，Main 直接持有 $Ball 引用即可；
## 引入分裂砖与多球之后，「球」变成了一个会增减的集合——
## 谁负责生成、谁负责回收、什么时候算「掉光了要扣命」都必须有且只有一个答案。
## 这些问题全部收在本节点里，Main 只关心两条信号：
## last_ball_lost（扣命时机）与 count_changed（刷新 HUD 上的球数）。
##
## 主球（primary）由本节点在 _ready 里现场生成，不依赖场景里预置节点；
## 分裂出来的副球同样是运行时 Ball.new()。好处是 Main.tscn 里不会出现
## 「场景里有 1 颗球、代码却按 8 颗球维护」这种两套事实来源。

## 同屏球数上限（含主球）。场上球越多，物理碰撞与画面可读性都越差，
## 不设上限的话一整屏白点乱窜，反而更难玩。
##
## 这是**默认值**而不是硬上限：卡牌「蜂群」要能把它调高，
## 所以真正参与判定的是下面的 max_balls_cap 字段。留常量是为了让
## 「未经任何加成时的上限」有唯一权威来源，冒烟测试也按它铺满球数。
const MAX_BALLS := 8

## 单颗球掉出场地之外的任何碰撞（球自身发信号，这里转成「哪颗球 + 发生了什么」）
signal brick_hit(ball: Ball, brick: Node)
signal wall_hit(ball: Ball)
signal paddle_hit(ball: Ball)
## 场上最后一颗球掉出场地：Main 只在这时扣命
signal last_ball_lost()
## 场上球数变化（出生/回收），供 HUD 刷新球数显示
signal count_changed(count: int)

## —— 转发给所有球的公共配置 ——
## Main 在换关 / 建场时改这些字段，再调 apply_to_all() 同步给场上（含新生成的）每一颗球。
var ball_speed := Ball.DEFAULT_SPEED
var stick_offset := 24.0
var death_y := 780.0
var unstick_y := 275.0
var ball_color := Color("f8f9fa")
## 当前速度倍率（减速砖写入）。存一份权威值，新生成的球也按它出场，
## 否则「减速期间分裂出来的球」会以全速出现，规则立刻自相矛盾。
var speed_scale := 1.0
## 当前生效的同屏球数上限。换关时由 Main 按卡牌加成重新写入，
## 因此它必须是字段而不是到处直接读 MAX_BALLS 常量。
var max_balls_cap := MAX_BALLS

var _paddle: Node2D = null
var _primary: Ball = null
var _extras: Array[Ball] = []
## 主球是否已出界。主球不会被释放（掉球后 Main 会把它重新吸附回挡板），
## 所以光数子节点永远数不到 0，必须单独记一个「它此刻不在场上」的状态，
## 否则「最后一颗球掉光」永不触发，掉命也就永远不会发生。
var _primary_out := false


func _ready() -> void:
	# 暂停时球必须一起停：Main 是 PROCESS_MODE_ALWAYS，靠这里让子节点继承 PAUSABLE，
	# 就不必在 Main 里逐颗 set_physics_process。
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_primary = _create_ball()
	add_child(_primary)
	count_changed.emit(count())


## 主球。永远非空（_ready 里就建好了），调用方不必判空。
func primary() -> Ball:
	return _primary


## 场上所有球（主球在前），供换肤、减速、冻结这类「对全体球生效」的操作遍历。
func all_balls() -> Array[Ball]:
	var result: Array[Ball] = []
	if is_instance_valid(_primary):
		result.append(_primary)
	for extra in _extras:
		if is_instance_valid(extra):
			result.append(extra)
	return result


## 场上正在参与游戏的球数（主球出界后不计入）。
## 这个数字有三重身份：HUD 上的球数、MAX_BALLS 的分母、以及「是否该扣命」的判据。
func count() -> int:
	var total := _extras.size()
	if is_instance_valid(_primary) and not _primary_out:
		total += 1
	return total


func is_empty() -> bool:
	return count() == 0


## 主球是否正在飞行（已发射、未出界、也没吸附在挡板上）。
## Main 用它决定要不要采样拖尾：出界但尚未被重新吸附的那几帧里，
## 主球的坐标在屏幕外，跟着它画拖尾会拉出一道从画面外射进来的白线。
func is_primary_flying() -> bool:
	return is_instance_valid(_primary) and not _primary_out \
		and not _primary.attached_to_paddle


## 还有余量再生成一颗副球吗（分裂砖的效果上限就是它）。
func has_room() -> bool:
	return count() < max_balls_cap


## 记住挡板引用。挡板只是「吸附时的锚点」，本节点不持有它的所有权。
func attach(paddle: Node2D) -> void:
	_paddle = paddle


## 把当前公共配置同步给场上所有球。
func apply_to_all() -> void:
	for ball in all_balls():
		_configure(ball)


## 从指定位置生成一颗副球并立刻按 direction 发射。
## 达到 MAX_BALLS 时返回 null（不给球、不报错），调用方据此放弃这次分裂。
func spawn_extra(at: Vector2, direction: Vector2) -> Ball:
	if not has_room():
		return null
	var ball := _create_ball()
	add_child(ball)
	ball.global_position = at
	_extras.append(ball)
	# Ball.launch() 只在「吸附态」生效，新球出厂就是吸附态，直接 launch 即出球。
	ball.launch(direction)
	count_changed.emit(count())
	return ball


## 换关 / 重开局：清掉所有副球，主球重新吸附到挡板上等待发射。
func reset() -> void:
	for extra in _extras:
		if is_instance_valid(extra):
			extra.queue_free()
	_extras.clear()
	speed_scale = 1.0
	_primary_out = false
	_configure(_primary)
	_primary.set_active(true)
	_primary.stick_to(_paddle)
	count_changed.emit(count())


## 主球回到「吸附待发」状态（掉光扣命之后用）。
func stick_primary() -> void:
	_configure(_primary)
	_primary_out = false
	_primary.stick_to(_paddle)
	count_changed.emit(count())


## 结算时冻结/恢复全场。visible 也要一起管：结算画面上飞着的球只会抢注意力。
func set_active(active: bool) -> void:
	for ball in all_balls():
		ball.set_active(active)


## 全场减速/恢复。倍率会被记住，之后生成的副球也按它出场。
func apply_speed_scale(scale: float) -> void:
	speed_scale = scale
	for ball in all_balls():
		ball.speed_scale = scale


func _create_ball() -> Ball:
	var ball := Ball.new()
	ball.name = "Ball" if _primary == null else "BallExtra"
	# 显式写 PAUSABLE 而不是靠 Balls 节点的 INHERIT：
	# 副球随时可能被 reparent 到别处，显式声明才不会因为父节点变了而意外在暂停中继续飞。
	ball.process_mode = Node.PROCESS_MODE_PAUSABLE
	_configure(ball)
	# Ball.launch() 的前置条件是「吸附态」，新球必须以吸附态出厂。
	ball.attached_to_paddle = true
	# 四条信号全部用 bind(ball) 把「是谁发的」补进回调。
	# 不改 Ball 的信号签名：它们在只有一颗球的年代就已定型，冒烟测试与存档回放
	# 都是按原样 emit_signal("brick_hit", target) 驱动它们的，改签名会让旧调用点当场崩。
	# 代价是 bind 追加的参数排在最后，因此回调里 ball 总是最后一个形参——
	ball.brick_hit.connect(_on_ball_brick_hit.bind(ball))
	ball.wall_hit.connect(_on_ball_wall_hit.bind(ball))
	ball.paddle_hit.connect(_on_ball_paddle_hit.bind(ball))
	ball.fell_out_of_playfield.connect(_on_ball_fell_out.bind(ball))
	return ball


func _configure(ball: Ball) -> void:
	if not is_instance_valid(ball):
		return
	ball.speed = ball_speed
	ball.color = ball_color
	ball.stick_offset = stick_offset
	ball.death_y = death_y
	ball.unstick_y = unstick_y
	ball.speed_scale = speed_scale


# —— 球的信号转接：对外只暴露「哪颗球发生了什么」，不暴露信号来源 ——
# 直接把球的信号 connect 到 Main 的方法上是行不通的：副球随时出生，
# 每颗球都要在 Main 侧重连一遍，漏一颗就是一条静默失效的连接。
# 形参顺序 = 信号实参在前、bind 追加的 ball 在后（见 _create_ball 的说明）。


func _on_ball_brick_hit(brick: Node, ball: Ball) -> void:
	brick_hit.emit(ball, brick)


func _on_ball_wall_hit(ball: Ball) -> void:
	wall_hit.emit(ball)


func _on_ball_paddle_hit(ball: Ball) -> void:
	paddle_hit.emit(ball)


func _on_ball_fell_out(ball: Ball) -> void:
	# 主球掉出场地不删除：Main 会把它重新吸附回挡板再发一次，
	# 在这里 free 掉的话玩家就永远失去了那颗可瞄准、可蓄力的球。
	if ball != _primary:
		_extras.erase(ball)
		ball.queue_free()
	else:
		_primary_out = true
	# 扣命只在最后一颗球掉光时发生。多球是玩家的资产：
	# 掉一颗就扣命的话，分裂砖反而成了惩罚，与它的设计意图正好相反。
	if is_empty():
		last_ball_lost.emit()
	count_changed.emit(count())