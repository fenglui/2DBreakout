class_name Paddle
extends CharacterBody2D
## 底部挡板：A/D 或左右方向键移动，横向位置被夹在游戏区内，不会移出屏幕。
## 自带的 Area2D(Sensor) 用来检测“球停在板面上等待发射”的状态。

signal ball_on_paddle(ball: Node2D)

const SPEED := 640.0

@export var paddle_width := 108.0
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


func _on_sensor_body_entered(body: Node2D) -> void:
	# 球带有 attached_to_paddle 标记时，说明它正停在板面上等待发射
	if bool(body.get("attached_to_paddle")):
		ball_on_paddle.emit(body)


func _draw() -> void:
	var rect := Rect2(-Vector2(paddle_width, paddle_height) * 0.5, Vector2(paddle_width, paddle_height))
	draw_rect(rect, color, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.35)), color.lightened(0.4), true)
	draw_rect(rect, color.darkened(0.4), false, 2.0)
