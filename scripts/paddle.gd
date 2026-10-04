class_name Paddle
extends CharacterBody2D
## 底部挡板：A/D 或左右方向键移动，横向位置被夹在游戏区内，不会移出屏幕。
## 自带的 Area2D(Sensor) 用来检测“球停在板面上等待发射”的状态。
## 宽度会随剩余生命收窄（由 Main 调用 set_width），是主要的难度曲线之一。

signal ball_on_paddle(ball: Node2D)

const SPEED := 640.0
const MIN_WIDTH := 48.0
const MAX_WIDTH := 160.0

## 宽度是「改了就必须同步碰撞形状」的字段，因此带 setter：
## 任何赋值（Inspector、set()、未来的道具代码）都会走 _refresh_shapes()，
## 不会出现「绘制宽度与碰撞宽度不一致、球在可见挡板外侧反弹」。
@export var paddle_width := 108.0:
	set(value):
		paddle_width = clampf(value, MIN_WIDTH, MAX_WIDTH)
		if is_inside_tree():
			_refresh_shapes()
@export var paddle_height := 20.0
## 挡板中心的合法 X 范围（由 Main 根据墙体位置写入）
@export var left_bound := 20.0
@export var right_bound := 460.0
@export var color := Color("f9c74f")
@export var input_enabled := true

@onready var sensor: Area2D = $Sensor


func _ready() -> void:
	add_to_group("paddle")
	collision_layer = 2  # 第 2 层：Paddle
	collision_mask = 0   # 挡板不与其他物理体发生阻挡，只作为球的目标
	sensor.collision_mask = 8   # 只检测 Ball（第 4 层）
	sensor.collision_layer = 0
	sensor.body_entered.connect(_on_sensor_body_entered)
	queue_redraw()


func _physics_process(_delta: float) -> void:
	var direction := 0.0
	if input_enabled:
		direction = Input.get_axis("move_left", "move_right")  # A/D 与左右方向键
	velocity = Vector2(direction * SPEED, 0.0)
	move_and_slide()
	# 硬性夹紧，保证挡板不会移出屏幕
	global_position.x = clampf(global_position.x, left_bound, right_bound)


## 改变挡板宽度：赋值即触发 setter 同步替换碰撞形状与传感器形状并重绘。
## 调用方需要重新计算 left_bound / right_bound。
func set_width(width: float) -> void:
	paddle_width = width


## 按当前宽度重建本体与传感器的碰撞形状。
## 用新建的 shape 覆盖，不会改动场景里共享的 SubResource。
func _refresh_shapes() -> void:
	var body_shape := RectangleShape2D.new()
	body_shape.size = Vector2(paddle_width, paddle_height)
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision != null:
		collision.shape = body_shape

	var sensor_shape := RectangleShape2D.new()
	sensor_shape.size = Vector2(paddle_width * 0.85, paddle_height * 1.5)
	var sensor_collision := sensor.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if sensor_collision != null:
		sensor_collision.shape = sensor_shape

	queue_redraw()


func _on_sensor_body_entered(body: Node2D) -> void:
	# 球带有 attached_to_paddle 标记时，说明它正停在板面上等待发射
	if bool(body.get("attached_to_paddle")):
		ball_on_paddle.emit(body)


func _draw() -> void:
	var rect := Rect2(-Vector2(paddle_width, paddle_height) * 0.5, Vector2(paddle_width, paddle_height))
	draw_rect(rect, color, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.35)), color.lightened(0.4), true)
	draw_rect(rect, color.darkened(0.4), false, 2.0)
