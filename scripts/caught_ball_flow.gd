class_name CaughtBallFlow
extends Node2D
## 「接住 → 蓄力 → 瞄准 → 发射」这条循环的属主。
##
## 为什么值得独立成一个节点：这条循环自己就是一台完整状态机——
## 四个状态（等球 / 待接 / 蓄力 / 发射）只靠两个布尔量就能完整表达，
## 它的输入只有 launch 的按下与松开两个边沿，输出只有「把某一颗球打出去」这一件事。
## 它此前长在 Main 里，与关卡推进、抽卡、暂停分支共用同一条 _process 与
## _unhandled_input，于是每加一个条件都要重新确认「这一帧到底归谁管」，
## 而它真正的行为契约——按住 launch 时碰到挡板的球被粘住、而不是自动弹开——
## 恰恰是最容易被别人的分支顺手改掉的那一条。
##
## 它不认识 Main、不认识关卡号、不认识卡牌，也不碰任何 autoload：
## - 本关基准球速与球速倍率由 Main 在换关时注入（configure_speed）；
## - 发射由 ball.launch() 完成，本节点不替球决定速率语义；
## - 音效、震动、HUD 文案一律走信号交给 Main。
##
## 「接住」这件事为什么值一个独立机制：原来的球一离开挡板就再也不受玩家控制，
## _deflect_from_paddle() 每次碰板都自动弹开，于是蓄力与预测线这两项
## 手感投入在一颗球的一生里只生效一次。接住把「每次回板」变成一次主动决策，
## 蓄力与瞄准才重新变成贯穿整局的核心循环，而不是开局五秒的一次性花招。

## 蓄满所需秒数。取 0.45s：短到连续点按不会觉得黏，长到刻意蓄力能拉出角度差。
const CHARGE_SECONDS := 0.45
## 蓄满时球速相对本关基准的倍率
const CHARGE_SPEED_MUL := 1.35
## 蓄力时横向可偏转的最大角度（弧度，0 = 正上方）
## 取 0.62（≈35.5°）而不是更大：再大就基本是贴墙平射，
## 玩家会失去「打向砖墙中部」的能力。
const MAX_CHARGE_TILT := 0.62
## 预测的反射次数。3 次足够看出「会打到哪一行的哪一列」，再多只是噪点。
const AIM_BOUNCES := 3
## 预测线只关心墙体与砖块，位值与 project.godot 的 layer_names 一致
## （1=Wall，4=Brick）。挡板是第 2 层、球是第 4 位，这里都不参与。
const AIM_MASK_WALL := 1
const AIM_MASK_BRICK := 4

## 球在飞行途中被接住、开始蓄力。此时球已经钉在挡板上了。
signal caught(ball: Ball)
## 蓄力条刚刚蓄满的那一帧（只发一次，不是每帧）。
signal charge_filled()
## 球被打出去了。power 是本次的蓄力比例 0~1。
signal launched(ball: Ball, power: float)

## 由 Main 在 _ready 里注入。本节点不声明 @export，
## 是为了避免「场景里连了一份、代码里又写了一份」的两套事实来源。
var balls: BallManager = null
var paddle: Paddle = null
var aim_line: AimLine = null
var ball_trail: BallTrail = null

## 当前正在蓄力的球。为 null 时 _charging 必然为 false。
var _ball: Ball = null
var _charging := false
var _charge := 0.0
var _charge_dir := 0.0
## 「按住 launch 等球回来」这个意图正在挂着，等这颗球真的碰上挡板时兑现。
var _catch_armed := false
## 本关基准球速与球速倍率（乘法卡）。换关时由 Main 写入。
var _base_speed := Ball.DEFAULT_SPEED
var _speed_mul := 1.0


## 注入本关的发射速率口径。两个参数都由 Main 从关卡与卡牌算好后写入，
## 本节点不反向读取任何一方的规则。
func configure_speed(base_speed: float, speed_mul: float) -> void:
	_base_speed = base_speed
	_speed_mul = speed_mul


## 是否处于蓄力中（球已接住、蓄力条正在涨）。
func is_charging() -> bool:
	return _charging


## 当前蓄力进度 0~1。
func charge_ratio() -> float:
	return _charge


## 「按住 launch 等球回来」的意图是否正挂着。
## HUD 用它在提示里区分「空格 = 发射」与「空格 = 接住」。
func is_catch_armed() -> bool:
	return _catch_armed


## 当前被蓄力的球，未蓄力时返回 null。
func charging_ball() -> Ball:
	if _charging and is_instance_valid(_ball):
		return _ball
	return null


# —— 输入入口 ——
# Main 的 _unhandled_input 只负责把动作边沿转过来，
# 「这条边沿在四个状态下各自意味着什么」全部由本节点回答。

## launch 按下。没有可蓄力的球时不报错，而是把「接住」的意图挂起：
## 玩家在球飞回来之前就按下空格，等到球真的碰上挡板才兑现——
## 这正是「接住」应有的手感（不需要精确到帧去点接触的那一瞬间）。
func on_launch_pressed() -> void:
	if _charging:
		return
	var attached := _attached_ball()
	if attached != null:
		_begin_charge(attached)
	else:
		_catch_armed = true


## launch 松开。蓄力中就发射，否则只是撤销挂起的接球意图。
func on_launch_released() -> void:
	if _charging:
		_release()
	else:
		_catch_armed = false


## 球碰到了挡板（BallManager.paddle_hit 转来）。
## 挂着接球意图就把它粘住并开始蓄力，否则什么都不做——
## 「不按键 = 原版自动弹开」这条规则必须是不作为，而不是另一条分支。
func on_paddle_contact(ball: Ball) -> void:
	if _charging or not _catch_armed or ball == null:
		return
	_catch_armed = false
	_begin_charge(ball)


## 一颗球刚被重新吸附到挡板上（换关 / 掉球后由 Main 转来）。
## 只清掉可能指向已释放球的引用：此刻玩家若正按着 launch，
## 他要的是「球到了就让我蓄力」，那件事由下一次按下边沿触发。
func on_ball_attached(_ball: Ball) -> void:
	_ball = null
	_catch_armed = false


## 每帧推进蓄力。gameplay_active 为 false（暂停 / 结算）时强行中断。
##
## 放在 Main 的 _process 里按帧调用而不是自带 _process：
## 本节点需要 PROCESS_MODE_ALWAYS 才能在暂停时立刻把蓄力条清掉，
## 而「谁来驱动」交给 Main 决定，比在两处各写一套 process_mode 更容易读。
func tick(delta: float, gameplay_active: bool) -> void:
	if not _charging:
		if aim_line != null:
			aim_line.clear_path()
		return
	if not gameplay_active:
		# 暂停 / 结算 / 掉球时蓄力被强行中断：必须回到未蓄力态，
		# 否则恢复后玩家会看到一个满蓄力条却按不动。
		reset()
		return
	var before := _charge
	_charge = minf(1.0, _charge + delta / CHARGE_SECONDS)
	if paddle != null:
		paddle.set_charge(_charge)
	if before < 1.0 and _charge >= 1.0:
		# 只在「刚刚蓄满」这一帧发信号：放进每帧判断也能跑，
		# 但 Main 那边每帧都会新建一次 Tween，蓄满后没人松手就会一直空转。
		# 蓄满自动发射：不这么做玩家可以把空格按住不放，
		# 满蓄力条亮着却迟迟不出球，看起来像卡住。
		# 自动发射只在这一帧触发（_charge 已被钳在 1.0，下一帧 before == 1.0）。
		charge_filled.emit()
		_release()
		return
	_refresh_aim()


## 回到未蓄力态。清掉预测线与挡板蓄力条，并撤销挂起的接球意图。
func reset() -> void:
	_charging = false
	_catch_armed = false
	_charge = 0.0
	_charge_dir = 0.0
	_ball = null
	if aim_line != null:
		aim_line.clear_path()
	if paddle != null:
		paddle.set_charge(0.0)


## 蓄力强度 -> 发射方向。power=0 垂直向上，power=1 按 _charge_dir 偏转到最大角。
## 横移方向同时由「当前是否按住左/右」决定：只蓄力不按键就是垂直上弹。
## 注意这里读轴只是为了「锁存」方向到 _charge_dir：轴可能在蓄力中途松开，
## 但已经锁定的方向要留到松开发射那一刻才作废，由 reset() 负责清零。
func launch_direction(power: float) -> Vector2:
	var axis := Input.get_axis("move_left", "move_right")
	if not is_zero_approx(axis):
		_charge_dir = signf(axis)
	var tilt := power * MAX_CHARGE_TILT * _charge_dir
	return Vector2(sin(tilt), -cos(tilt))


# —— 内部实现 ——

## 开始蓄力一颗球。
##
## 先 stick_to 再记状态：stick_to 会把球吸附到挡板正上方，
## 而蓄力期间球必须一动不动，否则蓄力条涨着、球却在往外飘。
## 被接住的球正是靠这一步从「已弹开的飞行态」回到「吸附态」，
## 否则 launch() 的前置条件（attached_to_paddle）不成立。
func _begin_charge(ball: Ball) -> void:
	_ball = ball
	_charging = true
	_charge = 0.0
	_charge_dir = 0.0
	_catch_armed = false
	if not is_instance_valid(ball):
		_charging = false
		_ball = null
		return
	if paddle != null:
		ball.stick_to(paddle)
	if ball_trail != null:
		ball_trail.clear_trail()
	caught.emit(ball)


## 松开发射。
func _release() -> void:
	var ball := _ball
	var power := clampf(_charge, 0.0, 1.0)
	var direction := launch_direction(power)
	reset()
	if ball == null or not is_instance_valid(ball) or not ball.attached_to_paddle:
		return
	# 只给这一颗球提速，不动 balls.ball_speed：副球按本关基准速率飞行。
	# 如果把蓄力倍率写进权威字段，一次弱蓄力就会把场上所有球一起拽慢，
	# 玩家会看到「我只是轻轻点了一下，飞着的球全变慢了」。
	#
	# 先改 speed 再 launch：launch() 用当前 speed 算初速度，
	# 顺序反了的话第一帧会以旧速度出球，要等下一次 _physics_process 归一化才对，
	# 表现为「满蓄力打出去的第一帧明显偏慢」。
	#
	# 速度与角度是两条独立的轴：Ball._clamp_direction() 是「归一化到 speed 后再钳角度」，
	# 所以抬速度不会改变角度包络，MAX_CHARGE_TILT 才是发射角的唯一来源。
	ball.speed = _base_speed * lerpf(1.0, CHARGE_SPEED_MUL, power) * _speed_mul
	ball.launch(direction)
	launched.emit(ball, power)


## 此刻可以被蓄力的球：优先本节点记住的那颗（可能是一颗被接住的副球），
## 否则在场上所有球里找第一颗吸附态的。
##
## 多球下「该让玩家控制哪一颗」是开放问题，因此不写死主球：
## 玩家接住哪颗就发射哪颗，没接住就退回「球吸附在板上」这条唯一线索。
func _attached_ball() -> Ball:
	if is_instance_valid(_ball) and _ball.attached_to_paddle:
		return _ball
	if balls == null:
		return null
	for ball in balls.all_balls():
		if ball.attached_to_paddle:
			return ball
	return null


## 沿预测方向画反射预测线，让「角度可瞄」这件事真正可见。
## 只在被蓄力的球确实吸附着时画：球已经在飞的话方向是确定的，再画线是噪音。
func _refresh_aim() -> void:
	if aim_line == null:
		return
	var ball := charging_ball()
	if ball == null or not ball.attached_to_paddle:
		aim_line.clear_path()
		return
	# 预测线只看墙与砖（层 1 与层 4）：把挡板算进去会让线在脚边就撞上自己
	aim_line.predict(ball.global_position, launch_direction(_charge),
		AIM_BOUNCES, AIM_MASK_WALL | AIM_MASK_BRICK, 0.55)