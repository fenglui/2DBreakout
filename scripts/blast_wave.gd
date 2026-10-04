class_name BlastWave
extends Node2D
## 爆破砖的冲击波：向外扩张并淡出的圆环，播完自毁。
##
## 单独一个节点而不是往 SparkBurst 里加参数：碎屑是「往外溅颗粒」，
## 冲击波是「一次范围判定」，两者的时间曲线完全不同（一个 0.55s 一次性，
## 一个随半径线性扩张）。混在一个节点里只能二选一。
##
## 没有它的话爆破只剩一堆碎屑，玩家看不出「炸到了几块」——
## 而范围正是爆破砖唯一的卖点。

## 扩张时长（秒）。太短看不见范围，太长会盖住后续的球路。
const DURATION := 0.38
## 起始半径与终止半径。终点取 66 = Main.BLAST_RADIUS，
## 让波纹边缘正好停在真实爆炸范围上，玩家的直觉不会骗自己。
const START_RADIUS := 8.0
const END_RADIUS := 66.0
## 线宽随扩张变粗一点，收尾时才不至于细到看不见
const MIN_WIDTH := 2.0
const MAX_WIDTH := 5.0

var color := Color("fff3d6")

var _elapsed := 0.0


## 按指定颜色播发一次冲击波。参数名用 tint，避免与 color 属性同名遮蔽。
## 参数必须在入树前配置好（与 Main._spawn_sparks 同理）。
func launch(tint: Color) -> void:
	color = tint


func _process(delta: float) -> void:
	_elapsed += delta
	# 兜底自毁：暂停/无头等情况下若 _process 停了，也要有离开场景的路径，
	# 不能让节点在 Fx 下越积越多（冒烟测试有一条「碎屑不累积泄漏」的断言）。
	if _elapsed >= DURATION:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := clampf(_elapsed / DURATION, 0.0, 1.0)
	# 半径线性扩张、透明度按平方淡出：先快速亮起再收尾，读起来像「炸开」而不是「淡入」
	var radius := lerpf(START_RADIUS, END_RADIUS, t)
	var shade := Color(color.r, color.g, color.b, (1.0 - t) * (1.0 - t))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, shade,
		lerpf(MIN_WIDTH, MAX_WIDTH, t), true)