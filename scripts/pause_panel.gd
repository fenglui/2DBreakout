class_name PausePanel
extends CanvasLayer
## 暂停遮罩：按 P 键切换，显示“已暂停”，并提供继续与退出按钮。
## 面板始终处理输入，因此暂停状态下按钮依然可点。

signal resume_requested()
signal quit_requested()

@onready var panel: PanelContainer = $Panel
@onready var resume_button: Button = $Panel/Margin/VBox/ResumeButton
@onready var quit_button: Button = $Panel/Margin/VBox/QuitButton
@onready var sfx: SfxBus = SfxBus.instance(self)


func _ready() -> void:
	# 暂停时依然要能显示/隐藏并响应按钮，所以始终处理输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	resume_button.pressed.connect(_on_resume_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	panel.visible = false


func set_paused(paused: bool) -> void:
	panel.visible = paused
	if paused:
		resume_button.grab_focus()


func _on_resume_pressed() -> void:
	if sfx != null:
		sfx.play("ui")
	resume_requested.emit()


func _on_quit_pressed() -> void:
	if sfx != null:
		sfx.play("ui")
	quit_requested.emit()
