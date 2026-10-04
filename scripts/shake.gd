class_name ShakeBus
extends Node
## 屏幕震动（Autoload 名：Shake，类型：ShakeBus）
##
## 用 trauma 模型驱动：每次调用 shake() 累加创伤值，随后按时间衰减，
## 位移量取创伤值的平方，使轻微碰撞只有细微抖动、重击才有明显震动。
## 实现方式是偏移场景中当前的 Camera2D，不移动任何游戏节点，因此不影响碰撞与坐标。
##
## 用法：`@onready var shake: ShakeBus = ShakeBus.instance(self)`，然后 `shake.shake(0.2)`。
## 用 get_node 而不是全局名，理由同 SfxBus：`--check-only` 不实例化 autoload。

## 单次震动的最大位移（像素）
const MAX_OFFSET := 14.0
## 创伤值每秒衰减量
const DECAY_PER_SECOND := 1.9

var _trauma := 0.0


## 取得 autoload 单例。找不到时返回 null，调用方需判空。
static func instance(node: Node) -> ShakeBus:
	return node.get_node_or_null("/root/Shake") as ShakeBus


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## 触发一次震动。amount 建议取 0.10（撞墙）到 0.9（掉命/通关）。
func shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## 立即停止震动并归零相机偏移。
func reset() -> void:
	_trauma = 0.0
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		camera.offset = Vector2.ZERO


## 当前创伤值，供测试与调试读取。
func get_trauma() -> float:
	return _trauma


func _process(delta: float) -> void:
	if _trauma <= 0.0:
		return

	_trauma = maxf(0.0, _trauma - delta * DECAY_PER_SECOND)
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		_trauma = 0.0
		return

	if _trauma <= 0.0:
		camera.offset = Vector2.ZERO
		return

	var magnitude := _trauma * _trauma * MAX_OFFSET
	camera.offset = Vector2(randf_range(-magnitude, magnitude), randf_range(-magnitude, magnitude))
