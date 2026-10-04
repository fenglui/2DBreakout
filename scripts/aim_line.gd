class_name AimLine
extends Node2D
## 发射预测线：从球心沿当前发射方向做多次镜面反射的射线预测，画成由近及远逐渐变淡的虚线。
##
## 为什么用 PhysicsDirectSpaceState2D.intersect_ray 而不是 RayCast2D 节点：
## RayCast2D 是节点，每条预测线都要在场景树上多挂几个节点；一旦上多球或加道具，
## 节点数会跟着涨，而且每次查询都要走一遍节点的生命周期开销。
## 直接打物理服务器查询是 O(1) 的，代价只是几条射线。
##
## 本节点摆在砖块与球之下（z_index 更低）：射线止于碰撞体表面，
## 预测线本来就不会画进砖块内部，这条顺序真正的用处是保证线也盖不住球——
## 玩家全程盯着的是球，不是线。

const MAX_SEGMENTS := 4
## 单条射线最大长度，够从场地底部打到顶再反弹一次
const RAY_LENGTH := 900.0
## 反射后沿法线挪开的距离。不挪开的话射线起点仍然贴在砖块表面，
## 下一段会立刻再命中同一块砖，预测线在一个点上反复打转。
const SKIN := 0.5
const DASH_LENGTH := 9.0
const GAP_LENGTH := 7.0
## 越远的段衰减得越厉害，让玩家一眼看出「近处才是确定的」
const SEGMENT_FADE := 0.55

var color := Color("4cc9f0"):
	set(value):
		color = value
		queue_redraw()
var line_width := 2.5

var _points: PackedVector2Array = PackedVector2Array()
var _bounces: PackedVector2Array = PackedVector2Array()
var _alpha := 1.0


## 清空预测线（不发射时调用）。
func clear_path() -> void:
	if _points.is_empty() and _bounces.is_empty():
		return
	_points = PackedVector2Array()
	_bounces = PackedVector2Array()
	queue_redraw()


## 已画出的折线顶点数（偶数，每两个点构成一段）。给冒烟测试判断「线真的画出来了」。
func get_point_count() -> int:
	return _points.size()


## 真实反射次数：只有射线真的打到了东西才计数。
## 必须和 get_point_count() 一起看——线「一直飞出去没撞到任何东西」时点数也是 2，
## 但那是 0 次反弹，只断言点数会把「没反弹」当成「预测成功」。
func get_bounce_count() -> int:
	return _bounces.size()


## 已画出的线段数（每段两个点）。_draw() 是按段号算衰减的，
## 所以段数才是衰减的索引单位，点数不是。
func get_segment_count() -> int:
	return _points.size() / 2


## 从 from 沿 dir 预测 bounces 次反射，画出折线。
## collision_mask 必须只包含墙与砖：把挡板或球自己算进去，
## 预测线会在发射瞬间就撞上挡板，画出一段毫无意义的短线。
## 每一段都以「真的撞到了东西」结束或以 RAY_LENGTH 收尾，
## 所以段数恒等于「反弹次数」或「反弹次数 + 1」（最后那段打空了）。
## from / dir 使用世界坐标——本节点固定摆在原点，局部坐标即世界坐标。
func predict(from: Vector2, dir: Vector2, bounces: int, collision_mask: int, alpha: float) -> void:
	_points = PackedVector2Array()
	_bounces = PackedVector2Array()
	_alpha = alpha

	if dir.length_squared() < 0.0001 or collision_mask == 0:
		queue_redraw()
		return

	var space := get_world_2d().direct_space_state
	if space == null:
		queue_redraw()
		return

	var current := from
	var direction := dir.normalized()
	var limit := clampi(bounces, 0, MAX_SEGMENTS)

	for i in limit:
		var query := PhysicsRayQueryParameters2D.create(
			current, current + direction * RAY_LENGTH, collision_mask)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var hit: Dictionary = space.intersect_ray(query)

		var endpoint: Vector2 = current + direction * RAY_LENGTH
		if not hit.is_empty():
			endpoint = hit["position"]

		_points.append(current)
		_points.append(endpoint)

		if hit.is_empty():
			break

		var normal: Vector2 = hit["normal"]
		_bounces.append(endpoint)
		current = endpoint + normal * SKIN
		direction = direction.bounce(normal)

	queue_redraw()


func _draw() -> void:
	if _points.size() < 2:
		return

	# 每段用一对点（s*2, s*2+1）。predict() 每反弹一次就追加「当前点 + 终点」，
	# 所以段数是点数的一半；按点下标循环会把相邻两段的首尾错接起来，
	# 衰减也会退化成 SEGMENT_FADE²（0.3），第三段基本看不见。
	var segments := _points.size() / 2
	for s in segments:
		var from := _points[s * 2]
		var to := _points[s * 2 + 1]
		var length := from.distance_to(to)
		if length <= 0.01:
			continue
		var step_dir := (to - from) / length
		var fade := pow(SEGMENT_FADE, float(s))
		var shade := Color(color.r, color.g, color.b, _alpha * fade)
		var width := maxf(1.0, line_width * fade)
		_draw_dashed(from, step_dir, length, shade, width)

	# 反射点画一个空心圈：玩家能直观看到「球会在哪拐弯」
	for i in _bounces.size():
		var fade := pow(SEGMENT_FADE, float(i))
		var shade := Color(color.r, color.g, color.b, _alpha * fade * 0.9)
		draw_arc(_bounces[i], 4.0, 0.0, TAU, 12, shade, 1.5, true)


## 沿单段画虚线。用「相位」判断当前落在 dash 还是 gap 上，
## 这样跨段时相位可以自然延续，不会每段都从实线开头。
func _draw_dashed(from: Vector2, dir: Vector2, length: float, shade: Color, width: float) -> void:
	var period := DASH_LENGTH + GAP_LENGTH
	var travelled := 0.0
	while travelled < length:
		var phase := fmod(travelled, period)
		if phase < DASH_LENGTH:
			var dash_left := DASH_LENGTH - phase
			var step := minf(dash_left, length - travelled)
			draw_line(from + dir * travelled, from + dir * (travelled + step), shade, width, true)
			travelled += step
		else:
			travelled += minf(period - phase, length - travelled)
