class_name BallTrail
extends Node2D
## 球拖尾：记录最近若干帧的球心位置，画成由粗到细、由透明到实的渐隐色带。
##
## 拖尾同时承担两件事：一是让高速球的运动有连续感（圆点逐帧跳看起来很廉价），
## 二是把连击状态可视化——颜色由 Main 按当前调色板/连击数设置。

const MAX_POINTS := 14
## 位移小于这个值就不记点：球吸附在挡板上时位置不变，
## 否则会在同一个点上堆满 MAX_POINTS 段，退化成一块方块。
const MIN_STEP := 2.0

## 拖尾线宽下限 / 上限。Main 按连击数在这两个值之间插值，
## 做成常量而不是写死在 Main 里，宽度范围就只有一个事实来源。
const MIN_WIDTH := 5.0
const MAX_WIDTH := 13.0
## 连击增粗时的目标色。越接近满连击越往这个色靠，
## 颜色是「本关拖尾色 lerp 向这个色」，所以换肤后拖尾依然认得出属于哪一关。
const GLOW_COLOR := Color("ffd166")

## 换肤专用：只由 Main._apply_palette_colors() 通过 tween 写入。
## 单独存一份而不是直接改 color，是为了让 Main 每帧算连击强度时
## 有稳定的「本关基色」可插值——否则换肤 tween 会被逐帧赋值立刻盖回去，
## palette.trail 永远看不见。
var base_color := Color("4cc9f0"):
	set(value):
		base_color = value
		_derive_color(0.0)

## 实际绘制色。Main 每帧按连击数算一次强度（0~1）写进来，
## 0 = 本关基色，1 = 满连击的 GLOW_COLOR。
var color := Color("4cc9f0"):
	set(value):
		color = value
		queue_redraw()
## 线宽由 Main 按连击数调整（见 MIN_WIDTH / MAX_WIDTH）
var line_width := MIN_WIDTH:
	set(value):
		line_width = maxf(1.0, value)
		queue_redraw()

var _points: PackedVector2Array = PackedVector2Array()


## 写入连击强度（0~1）：越接近 1，拖尾越亮、越偏暖色。
## 做成独立方法而不是让 Main 直接写 color，是为了把「基色 → 实际色」
## 这条派生关系收在本节点内，Main 那边只剩一行调用。
func set_intensity(intensity: float) -> void:
	var t := clampf(intensity, 0.0, 1.0)
	_derive_color(t)
	queue_redraw()


func _derive_color(t: float) -> void:
	color = base_color.lerp(GLOW_COLOR, t)


## 追加一个拖尾采样点。
func push_point(at: Vector2) -> void:
	if _points.size() > 0 and _points[_points.size() - 1].distance_to(at) < MIN_STEP:
		return
	_points.append(at)
	while _points.size() > MAX_POINTS:
		_points.remove_at(0)
	queue_redraw()


func clear_trail() -> void:
	if _points.is_empty():
		return
	_points = PackedVector2Array()
	queue_redraw()


## 当前采样点数量，供测试与调试读取。
func get_point_count() -> int:
	return _points.size()


func _draw() -> void:
	if _points.size() < 2:
		return
	var last := _points.size() - 1
	for i in last:
		# t 从 0 走到 1，越靠头部越不透明、越粗
		var t := float(i + 1) / float(last)
		var shade := Color(color.r, color.g, color.b, color.a * t * t)
		draw_line(_points[i], _points[i + 1], shade, maxf(1.0, line_width * t), true)
