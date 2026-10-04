class_name Brick
extends StaticBody2D
## 单块砖。由 Main 在运行时批量生成，碰撞层为 Brick(第 3 层)。

@export var size := Vector2(48, 20):
	set(value):
		size = value
		if is_inside_tree():
			_apply_shape()
@export var points := 10
@export var color := Color("4cc9f0")

func _ready() -> void:
	collision_layer = 4  # 第 3 层：Brick
	collision_mask = 0   # 砖块本身不主动检测任何东西，碰撞完全由球发起
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


## 被球击中：返回应增加的分数，并立即从场景中消失。
func hit() -> int:
	queue_free()
	return points


func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	draw_rect(rect, color, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.32)), color.lightened(0.35), true)
	draw_rect(rect, color.darkened(0.35), false, 2.0)
