class_name Ball
extends CharacterBody2D
## 球：用 CharacterBody2D + 手动反射实现稳定可控的反弹，避免刚体带来的抖动。
## 初始吸附在挡板上，按空格（launch）发射。

signal brick_hit(brick: Node)
signal fell_out_of_playfield()

const DEFAULT_SPEED := 430.0
## 水平速度下限，避免出现几乎垂直的球长期卡在砖块下方来回弹
const MIN_HORIZONTAL_SPEED := 70.0
## 击中挡板时允许的最大偏转角（弧度）
const MAX_DEFLECT_ANGLE := 1.0

@export var radius := 9.0
@export var speed := DEFAULT_SPEED
@export var color := Color("f8f9fa")
## 吸附状态下，球心距离挡板中心的距离（Main 按布局写入）
@export var stick_offset := 24.0
## 球心 Y 超过该值即判定为掉出底部（Main 按布局写入）
@export var death_y := 780.0

var attached_to_paddle := true

var _paddle: Node2D = null


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
	move_and_slide()
	_resolve_collisions()

	if global_position.y > death_y:
		visible = false
		fell_out_of_playfield.emit()


func _resolve_collisions() -> void:
	## move_and_slide 一次可能返回多个接触点，用字典去重，避免同一次接触重复反弹/重复计分
	var handled := {}
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider: Object = collision.get_collider()
		if collider == null or handled.has(collider):
			continue
		handled[collider] = true

		var normal := collision.get_normal()
		velocity = velocity.bounce(normal)

		# 砖块：反弹 + 消失 + 加分，由 Main 负责加分与销毁
		if collider.has_method("hit"):
			brick_hit.emit(collider)

		# 挡板：按击中位置改变水平方向，避免死循环
		if collider.is_in_group("paddle"):
			_deflect_from_paddle()

	# 兜底：把过于垂直的速度掰开一点，防止球在两块砖之间来回卡住
	if absf(velocity.x) < MIN_HORIZONTAL_SPEED:
		var sign_x := 1.0 if velocity.x >= 0.0 else -1.0
		velocity.x = MIN_HORIZONTAL_SPEED * sign_x
	velocity = velocity.normalized() * speed


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
