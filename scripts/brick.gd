class_name Brick
extends StaticBody2D
## 单块砖。由 Main 在运行时批量生成，碰撞层为 Brick(第 3 层)。
## 支持多耐久：max_hits > 1 的砖需要多次击打才会消失，每次击打都计分并显示裂纹。

@export var size := Vector2(48, 20):
	set(value):
		size = value
		if is_inside_tree():
			_apply_shape()
@export var points := 10
@export var color := Color("4cc9f0")
## 击破所需次数（至少 1）
@export var max_hits := 1:
	set(value):
		max_hits = maxi(1, value)
		if hits_left == 0:
			hits_left = max_hits
## 当前剩余耐久，归零即消失
var hits_left := 1


func _ready() -> void:
	collision_layer = 4  # 第 3 层：Brick
	collision_mask = 0   # 砖块本身不主动检测任何东西，碰撞完全由球发起
	hits_left = max_hits
	_apply_shape()
	queue_redraw()


## 在运行时创建/更新碰撞形状，这样 Main 只需 add_child(Brick.new()) 即可生成砖墙。
func _apply_shape() -> void:
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = size

	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision == null:
		collision = CollisionShape2D.new()
		collision.name = "CollisionShape2D"
		add_child(collision)
	collision.shape = rect_shape


## 被球击中一次：返回本次应增加的分数。耐久耗尽时立即从场景中消失。
## 调用方可通过 is_destroyed() 判断本次击打是否真正清除了这块砖。
func hit() -> int:
	hits_left = maxi(0, hits_left - 1)
	if hits_left <= 0:
		queue_free()
	queue_redraw()
	return points


func is_destroyed() -> bool:
	return hits_left <= 0


func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	var base := color
	var damage := maxi(0, max_hits - hits_left)
	if damage > 0:
		# 越打越暗，直观暴露剩余耐久
		base = color.darkened(0.16 * damage)

	draw_rect(rect, base, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.32)), base.lightened(0.35), true)
	draw_rect(rect, base.darkened(0.35), false, 2.0)

	# 裂纹：每承受一次击打多一条
	for i in damage:
		var t := 0.22 + 0.26 * i
		var top := Vector2(rect.position.x + rect.size.x * t, rect.position.y + rect.size.y * 0.12)
		var bottom := Vector2(rect.position.x + rect.size.x * (t + 0.16), rect.position.y + rect.size.y * 0.88)
		draw_line(top, bottom, Color(0, 0, 0, 0.5), 2.0)
		draw_line(top, Vector2(rect.position.x + rect.size.x * (t - 0.12), rect.position.y + rect.size.y * 0.8),
			Color(0, 0, 0, 0.3), 1.0)
