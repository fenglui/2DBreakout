class_name Brick
extends StaticBody2D
## 单块砖。由 Main 在运行时批量生成，碰撞层为 Brick(第 3 层)。
## 支持多耐久：max_hits > 1 的砖需要多次击打才会消失，每次击打都计分并显示裂纹。
##
## kind 区分 6 种特殊砖（普通砖为 NORMAL）。砖本身只负责「我是什么」——
## 怎么加耐久、发几分、击破后炸什么，全部由 Main 按 kind 分派，
## 这样爆炸连锁与多球逻辑不会渗进一个只该画方块的节点里。

## 砖的种类。数值同时被 Main 的 BRICK_LAYOUT 布局表使用，
## 所以顺序一旦确定就不能重排——布局表里写的是字面数字。
enum Kind {
	NORMAL,     ## 普通砖
	ARMORED,    ## 加固砖：耐久高于本关标准
	LIFE,       ## 生命砖：击破 +1 生命
	BONUS,      ## 分数砖：分数倍率最高
	EXPLOSIVE,  ## 爆破砖：击破清掉半径内的邻居，可连锁
	SPLIT,      ## 分裂砖：击破多弹出一颗球
	SLOW,       ## 减速砖：击破后全场球速打折若干秒
}

## 每种砖的中文名，供结算面板的图例行与调试输出使用。
## 索引与 Kind 对齐；NORMAL 之外的六种都会被面板显示，
## 因此这几个字必须留在内嵌字体的子集里（见 README 的「字体」一节）。
const KIND_NAMES := ["普通", "加固", "生命", "分数", "爆破", "分裂", "减速"]

@export var size := Vector2(48, 20):
	set(value):
		size = value
		if is_inside_tree():
			_apply_shape()
@export var points := 10
## 砖色带 setter：换肤流程会直接改这个字段。
@export var color := Color("4cc9f0"):
	set(value):
		color = value
		if is_inside_tree():
			queue_redraw()
## 砖的种类。带 setter 是因为 Main 生成砖墙后仍可能改写它（换关重建、测试改布局）。
@export var kind: Kind = Kind.NORMAL:
	set(value):
		kind = value
		if is_inside_tree():
			queue_redraw()
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


## 不是普通砖。Main 用它把「这层墙有特殊砖」与「整墙都是普通砖」区分开。
func is_special() -> bool:
	return kind != Kind.NORMAL


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


## 本砖实际绘制用的底色：受损越深越暗。
func _base_color() -> Color:
	var damage := maxi(0, max_hits - hits_left)
	if damage <= 0:
		return color
	return color.darkened(0.16 * damage)


func _draw() -> void:
	var rect := Rect2(-size * 0.5, size)
	var base := _base_color()

	draw_rect(rect, base, true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.32)), base.lightened(0.35), true)
	draw_rect(rect, base.darkened(0.35), false, 2.0)

	# 受过伤的砖块描一圈暗红警示边：光靠变暗不够醒目，
	# 玩家在高速下要能一眼分出「这块还没碎」和「这块快碎了」。
	if _base_color() != color:
		draw_rect(rect.grow(-3.0), base.darkened(0.45), false, 1.5)

	# 裂纹：每承受一次击打多一条
	for i in maxi(0, max_hits - hits_left):
		var t := 0.22 + 0.26 * i
		var top := Vector2(rect.position.x + rect.size.x * t, rect.position.y + rect.size.y * 0.12)
		var bottom := Vector2(rect.position.x + rect.size.x * (t + 0.16), rect.position.y + rect.size.y * 0.88)
		draw_line(top, bottom, Color(0, 0, 0, 0.5), 2.0)
		draw_line(top, Vector2(rect.position.x + rect.size.x * (t - 0.12), rect.position.y + rect.size.y * 0.8),
			Color(0, 0, 0, 0.3), 1.0)

	# 特殊砖标记画在裂纹之上：它是「这是什么砖」的唯一常驻提示，
	# 不能被损伤纹理盖掉半截。
	if kind != Kind.NORMAL:
		_draw_kind_marker(rect, base)


## 特殊砖的形状标记。
## 只靠颜色区分特殊砖是不够的：换肤会换掉整墙砖色，玩家没法把
## 「这一行本来就是绿的」和「这一行是加固砖」对上号。
## 所以每种砖额外画一个固定形状，颜色按底色亮度在近白/近黑之间二选一，
## 保证在任何一行的砖色上都有对比度。
func _draw_kind_marker(rect: Rect2, base: Color) -> void:
	var ink := _marker_color(base)
	var center := rect.get_center()
	match kind:
		Kind.ARMORED:
			# 四角护角：一眼看出「这块更硬」
			var arm := 5.0
			var corners := [
				rect.position, Vector2(rect.end.x, rect.position.y),
				Vector2(rect.position.x, rect.end.y), rect.end,
			]
			for corner: Vector2 in corners:
				var sx := 1.0 if is_equal_approx(corner.x, rect.position.x) else -1.0
				var sy := 1.0 if is_equal_approx(corner.y, rect.position.y) else -1.0
				draw_line(corner, corner + Vector2(arm * sx, 0.0), ink, 2.0)
				draw_line(corner, corner + Vector2(0.0, arm * sy), ink, 2.0)
		Kind.LIFE:
			draw_rect(Rect2(center + Vector2(-6.0, -1.5), Vector2(12.0, 3.0)), ink, true)
			draw_rect(Rect2(center + Vector2(-1.5, -6.0), Vector2(3.0, 12.0)), ink, true)
		Kind.BONUS:
			var radius := 5.0
			draw_colored_polygon(PackedVector2Array([
				center + Vector2(0.0, -radius), center + Vector2(radius, 0.0),
				center + Vector2(0.0, radius), center + Vector2(-radius, 0.0)]), ink)
		Kind.EXPLOSIVE:
			draw_circle(center, 3.6, ink)
			# 四根引线：把「炸弹」这个隐喻画出来，比光一个圆点好认
			for i in 4:
				var angle := TAU * float(i) / 4.0 + PI * 0.25
				var ray := Vector2(cos(angle), sin(angle))
				draw_line(center + ray * 5.0, center + ray * 8.5, ink, 1.5)
		Kind.SPLIT:
			draw_circle(center + Vector2(-4.0, 0.0), 3.0, ink)
			draw_circle(center + Vector2(4.0, 0.0), 3.0, ink)
		Kind.SLOW:
			# 双层倒 V：视觉上「往下压」
			for offset_y: float in [-2.0, 3.0]:
				draw_line(center + Vector2(-5.0, offset_y - 3.0),
					center + Vector2(0.0, offset_y), ink, 2.0)
				draw_line(center + Vector2(5.0, offset_y - 3.0),
					center + Vector2(0.0, offset_y), ink, 2.0)


## 标记色：按底色亮度在近白与近黑之间二选一。
## 直接用白色会在 f9c74f 这类亮黄砖上糊成一片，用黑色又会在 4cc9f0 上看不见。
func _marker_color(base: Color) -> Color:
	if base.get_luminance() > 0.45:
		return Color(0.05, 0.06, 0.09, 0.85)
	return Color(1, 1, 1, 0.9)
