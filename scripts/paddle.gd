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
@export var color := Color("f9c74f"):
	set(value):
		color = value
		if is_inside_tree():
			queue_redraw()
## 蓄力比例 0~1，由 Main 写入；0 时不画蓄力条
var charge_ratio := 0.0
## 蓄力条与蓄满时的高亮色，跟随当前关卡调色板
@export var charge_color := Color("ffd166"):
	set(value):
		charge_color = value
		if is_inside_tree():
			queue_redraw()
@export var input_enabled := true

## 扳挡状态：反弹角左右镜像。由 AbilitySystem 通过 Main 写入。
## 挡板只负责「把自己长什么样」——高光条移到下沿。
## 反弹算术在 Ball._deflect_from_paddle() 里，挡板不参与球的方向计算。
@export var flipped := false:
	set(value):
		if flipped == value:
			return
		flipped = value
		queue_redraw()

## 热度条比例 0~1，0 时不画。由 Main 在热度换档时写入。
## 画在挡板下沿而不是上沿：上沿已经有蓄力条，两条都在那儿会互相干扰，
## 而蓄力的时间尺度（0.45s）与热度的（跨整关）本来就完全不同。
var heat_ratio := 0.0:
	set(value):
		var clamped := clampf(value, 0.0, 1.0)
		if is_equal_approx(clamped, heat_ratio):
			return
		heat_ratio = clamped
		queue_redraw()

## 热度条颜色。跟随当前调色板的强调色——它是「你正在拿精度换分数」的提示，
## 和蓄力条同色系才读得出这两条是同一件事的两面。
@export var heat_color := Color("fb8500"):
	set(value):
		heat_color = value
		queue_redraw()

## 蓄力条几何：贴在挡板上沿，宽度与挡板一致
const CHARGE_BAR_HEIGHT := 5.0
const CHARGE_BAR_GAP := 5.0
## 热度条几何：贴在挡板下沿，比蓄力条细（它不要求精确读数，只要求一眼看出在涨）
const HEAT_BAR_HEIGHT := 3.0
const HEAT_BAR_GAP := 4.0

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


## 设置蓄力比例（0~1）。Main 在蓄力期间每帧写入。
## 蓄力条画在挡板本体上（见 _draw）：蓄力、瞄准、发射是同一个动作，
## 指示器必须贴在动作发起的地方，不能拆到别处让玩家来回找。
func set_charge(ratio: float) -> void:
	var clamped := clampf(ratio, 0.0, 1.0)
	if is_equal_approx(clamped, charge_ratio):
		return
	charge_ratio = clamped
	queue_redraw()


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
	# 高光条在上沿还是下沿就是扳挡状态的读数：
	# 球在板面上方弹开，高光在上沿时读作「球会往我按下的那一侧偏」，
	# 高光翻到下沿则读作「会往反侧偏」。用位置而不是加一个图标来说明方向，
		# 是因为图标要玩家去查对照表，而位置是直接可读的。
	var highlight := Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.35))
	if flipped:
		highlight.position.y = rect.position.y + rect.size.y * 0.65
	draw_rect(highlight, color.lightened(0.4), true)
	draw_rect(rect, color.darkened(0.4), false, 2.0)

	if charge_ratio > 0.0:
		# 蓄力条：底槽 + 填充。底槽常驻是必要的，
		# 否则玩家只能靠「条出现了」判断已经按上，没有参照物就看不出还剩多少。
		var bar_top := rect.position.y - CHARGE_BAR_GAP - CHARGE_BAR_HEIGHT
		var bar := Rect2(rect.position.x, bar_top, rect.size.x, CHARGE_BAR_HEIGHT)
		draw_rect(bar, Color(0, 0, 0, 0.45), true)
		var fill := Rect2(bar.position, Vector2(bar.size.x * charge_ratio, bar.size.y))
		draw_rect(fill, charge_color, true)
		draw_rect(bar, charge_color.darkened(0.3), false, 1.0)

	if heat_ratio <= 0.0:
		return
	var heat_bar := Rect2(rect.position.x,
		rect.position.y + rect.size.y + HEAT_BAR_GAP,
		rect.size.x * heat_ratio, HEAT_BAR_HEIGHT)
	draw_rect(heat_bar, heat_color, true)
