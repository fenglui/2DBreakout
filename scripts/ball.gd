class_name Ball
extends CharacterBody2D
## 球：用 CharacterBody2D + 手动反射实现稳定可控的反弹，避免刚体带来的抖动。
## 初始吸附在挡板上，按空格（launch）发射。

signal brick_hit(brick: Node)
signal fell_out_of_playfield()
## 球撞到墙体（既不是砖块也不是挡板）时发出，供 Main 播放音效与轻微震动
signal wall_hit()
## 球撞到挡板时发出
signal paddle_hit()

const DEFAULT_SPEED := 430.0
## 轨迹角度包络：球速与水平面的夹角被强制限制在这个区间内（弧度）。
## 两个边界缺一不可：
## - 低于下限（太接近水平）：球横着飞来飞去，并被挤进砖块面里卡死
## - 高于上限（太接近垂直）：球在砖块下方垂直来回弹，长时间不落地
## 必须用角度而不是「分量下限」来钳制：把分量抬到下限后再归一化到固定速率，
## 会把分量重新缩回下限之下（实测 x 分量 67.93 < 下限 68.8），钳制自己违反自己。
const MIN_ANGLE_FROM_HORIZONTAL := 0.35
const MAX_ANGLE_FROM_HORIZONTAL := 1.40
## 连续多少帧位移接近 0 判定为卡死，随后强制脱离
const STUCK_FRAMES := 8
## 击中挡板时允许的最大偏转角（弧度）
const MAX_DEFLECT_ANGLE := 1.0

@export var radius := 9.0
@export var speed := DEFAULT_SPEED
@export var color := Color("f8f9fa")
## 吸附状态下，球心距离挡板中心的距离（Main 按布局写入）
@export var stick_offset := 24.0
## 球心 Y 超过该值即判定为掉出底部（Main 按布局写入）
@export var death_y := 780.0
## 卡死脱离时把球至少放到这条线以下（Main 按砖墙布局写入），此线以下一定是空场
@export var unstick_y := 275.0

var attached_to_paddle := true

var _paddle: Node2D = null
var _stuck_frames := 0


func _ready() -> void:
	collision_layer = 8  # 第 4 层：Ball
	collision_mask = 1 | 2 | 4  # 撞墙 / 挡板 / 砖块
	# 用 radius 生成圆形碰撞形状（场景中已挂好 CollisionShape2D）
	var circle := CircleShape2D.new()
	circle.radius = radius
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision != null:
		collision.shape = circle
	queue_redraw()


## 吸附到挡板上，等待发射。
func stick_to(paddle: Node2D) -> void:
	_paddle = paddle
	attached_to_paddle = true
	velocity = Vector2.ZERO
	set_physics_process(true)
	visible = true
	if is_instance_valid(_paddle):
		global_position = Vector2(_paddle.global_position.x, _paddle.global_position.y - stick_offset)
	queue_redraw()


## 发射：给一个略微带水平偏移的初速度，避免每次都是笔直向上。
func launch() -> void:
	if not attached_to_paddle:
		return
	attached_to_paddle = false
	velocity = Vector2(randf_range(-0.22, 0.22), -1.0).normalized() * speed
	# 吸附态画下的发射提示箭头必须主动重绘才会消失，否则会被缓存一路跟着球飞
	queue_redraw()


## 游戏结束时冻结球。
func set_active(active: bool) -> void:
	set_physics_process(active)
	visible = active


func _physics_process(_delta: float) -> void:
	if attached_to_paddle:
		# 跟随挡板移动，等待发射
		if is_instance_valid(_paddle):
			global_position = Vector2(_paddle.global_position.x, _paddle.global_position.y - stick_offset)
		velocity = Vector2.ZERO
		return

	# 每一帧保持恒定速率，手感稳定
	velocity = velocity.normalized() * speed
	var from := global_position
	move_and_slide()
	_resolve_collisions()
	_track_stuck(from)

	if global_position.y > death_y:
		visible = false
		fell_out_of_playfield.emit()


func _resolve_collisions() -> void:
	## 只处理穿透最深的那一个接触点。
	## move_and_slide 报告的所有法线都基于「本帧移动前」的速度，把它们依次 bounce 到
	## 已经反弹过的速度上是不物理的：实测会把垂直分量直接抹平，球变成纯水平速度
	## (430, 0) 并卡死在砖块面上，一帧只移动 0.5px 不到。
	var best: KinematicCollision2D = null
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_collider() == null:
			continue
		if best == null or c.get_depth() > best.get_depth():
			best = c
	if best == null:
		_clamp_direction()
		return

	var collider: Object = best.get_collider()
	velocity = velocity.bounce(best.get_normal())

	# 砖块：反弹 + 消失 + 加分，由 Main 负责加分与销毁
	if collider.has_method("hit"):
		brick_hit.emit(collider)

	# 挡板：按击中位置改变水平方向，避免死循环
	elif collider.is_in_group("paddle"):
		_deflect_from_paddle()
		paddle_hit.emit()

	# 其余接触只可能是墙体
	else:
		wall_hit.emit()

	_clamp_direction()


## 速度方向兜底：把与水平面的夹角钳进包络，再按包络角度重建速度。
## 重建后的向量长度恰好是 speed、角度恰好落在区间内，不会出现「钳制后被归一化抵消」。
func _clamp_direction() -> void:
	if velocity.length_squared() < 0.0001:
		velocity = Vector2(0.0, -1.0)
	var angle := atan2(absf(velocity.y), absf(velocity.x))
	var sign_x := 1.0 if velocity.x >= 0.0 else -1.0
	var sign_y := 1.0 if velocity.y >= 0.0 else -1.0
	angle = clampf(angle, MIN_ANGLE_FROM_HORIZONTAL, MAX_ANGLE_FROM_HORIZONTAL)
	velocity = Vector2(cos(angle) * sign_x, sin(angle) * sign_y) * speed


## 位移长期为 0 说明球被挤进了几何体内部，move_and_slide 推不出去，
## 此时速度再正常球也不会动。累计若干帧后强制脱离。
func _track_stuck(from: Vector2) -> void:
	if from.distance_to(global_position) < 0.5:
		_stuck_frames += 1
	else:
		_stuck_frames = 0
	if _stuck_frames < STUCK_FRAMES:
		return
	_stuck_frames = 0
	_unstick()


## 一律向下脱离，并且至少脱离到砖墙下方的空场（`unstick_y`，由 Main 按布局写入）：
## 砖块下方是空场，最坏情况是球落向挡板，绝不会把球顶进墙里；
## 只下移几个像素会正好挤进下一行砖块（行间距 26px），等于换个地方继续卡。
func _unstick() -> void:
	global_position.y = maxf(global_position.y + radius + 4.0, unstick_y)
	velocity = Vector2(randf_range(-0.6, 0.6), 1.0).normalized() * speed
	_clamp_direction()


## 根据击中挡板的位置重新计算反弹角度：
## 正中 = 垂直向上，边缘 = 大角度斜飞。
func _deflect_from_paddle() -> void:
	var offset := 0.0
	if is_instance_valid(_paddle):
		var half_width := maxf(float(_paddle.get("paddle_width")) * 0.5, 1.0)
		offset = clampf((global_position.x - _paddle.global_position.x) / half_width, -1.0, 1.0)

	var angle := PI * 0.5 - offset * MAX_DEFLECT_ANGLE  # PI/2 为正上方
	velocity = Vector2(cos(angle), -sin(angle))

	# 叠加一点挡板的横向速度，模拟真实的“擦球”
	if is_instance_valid(_paddle):
		velocity.x += float(_paddle.velocity.x) * 0.12


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, color)
	draw_circle(Vector2(-radius * 0.3, -radius * 0.3), radius * 0.35, Color(1, 1, 1, 0.65))
	if attached_to_paddle:
		# 吸附状态下的发射提示箭头：朝上，与发射方向一致
		draw_colored_polygon(
			PackedVector2Array([Vector2(-8, -radius - 6), Vector2(8, -radius - 6), Vector2(0, -radius - 20)]),
			Color(1, 1, 1, 0.5)
		)
