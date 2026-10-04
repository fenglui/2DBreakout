class_name SparkBurst
extends CPUParticles2D
## 一次性碎屑粒子：不依赖任何贴图（无 texture 时 CPUParticles2D 绘制方块），
## 由 Main 在砖块被击破处生成，播放完毕自动销毁。


var _elapsed := 0.0
var _max_age := 2.0


## 按指定颜色播发一次碎屑。
## 参数名用 tint，避免与 CPUParticles2D 自身的 color 属性同名遮蔽。
func launch(tint: Color, count: int = 18, power: float = 1.0) -> void:
	one_shot = true
	explosiveness = 1.0
	amount = count
	lifetime = 0.55
	direction = Vector2.UP
	spread = 180.0
	gravity = Vector2(0.0, 1150.0)
	initial_velocity_min = 120.0 * power
	initial_velocity_max = 300.0 * power
	angular_velocity_min = -220.0
	angular_velocity_max = 220.0
	scale_amount_min = 0.6
	scale_amount_max = 1.4
	color = Color(tint.r, tint.g, tint.b, 1.0)
	# 粒子随寿命淡出：color_ramp 是 Gradient，两个端点分别对应当量 0 与 1
	var ramp := Gradient.new()
	ramp.set_offset(0, 0.0)
	ramp.set_offset(1, 1.0)
	ramp.set_color(0, Color(tint.r, tint.g, tint.b, 1.0))
	ramp.set_color(1, Color(tint.r, tint.g, tint.b, 0.0))
	color_ramp = ramp
	finished.connect(queue_free)
	_max_age = lifetime + 1.5
	set_emitting(true)


## 兜底自毁：若因暂停/无头等原因收不到 finished，也要能离开场景，不累积泄漏。
func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _max_age:
		queue_free()
