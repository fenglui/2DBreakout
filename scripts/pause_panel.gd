class_name PausePanel
extends CanvasLayer
## 暂停遮罩：按 P 键切换，显示“已暂停”。

@onready var panel: PanelContainer = $Panel


func _ready() -> void:
	# 暂停时依然要能显示/隐藏，所以始终处理输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	panel.visible = false


func set_paused(paused: bool) -> void:
	panel.visible = paused
