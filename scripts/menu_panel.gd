class_name MenuPanel
extends CanvasLayer
## 玩法菜单：经典 / 无尽挑战 / 每日挑战三选一，外加退出。
##
## 它是启动后的第一个界面。理由不是「菜单更完整」，而是复玩性这件事
## 只有在**开局前**就能选才成立：每日挑战要玩家看到今天的种子才愿意点进去，
## 无尽挑战要玩家知道自己拿到的是哪一副牌。
## 把入口藏在暂停面板里会让两个模式变成「没人找得到的功能」。
##
## 面板自己读 MetaProgress 与 GameMode，不接受外部注入：这些数据都是
## 全局单例级的静态档案，没有任何一局的状态在里面，注入只会多一层无意义的耦合。

signal mode_chosen(mode: int)
signal quit_requested()

@onready var panel: PanelContainer = $Panel
@onready var classic_button: Button = $Panel/Margin/VBox/ClassicButton
@onready var run_button: Button = $Panel/Margin/VBox/RunButton
@onready var daily_button: Button = $Panel/Margin/VBox/DailyButton
@onready var daily_info_label: Label = $Panel/Margin/VBox/DailyInfoLabel
@onready var run_info_label: Label = $Panel/Margin/VBox/RunInfoLabel
@onready var quit_button: Button = $Panel/Margin/VBox/QuitButton
@onready var sfx: SfxBus = SfxBus.instance(self)


func _ready() -> void:
	# 菜单是全程界面，必须在暂停/结算时也能响应按钮
	process_mode = Node.PROCESS_MODE_ALWAYS
	classic_button.pressed.connect(_on_mode_button.bind(GameMode.Mode.CLASSIC))
	run_button.pressed.connect(_on_mode_button.bind(GameMode.Mode.RUN))
	daily_button.pressed.connect(_on_mode_button.bind(GameMode.Mode.DAILY))
	quit_button.pressed.connect(_on_quit_pressed)
	panel.visible = false


## 显示菜单，并刷新种子与历史成绩（每次进菜单都重读，
## 这样刚打完一局返回菜单时，当日最佳与连击天数是更新过的）。
func present() -> void:
	refresh_info()
	panel.visible = true
	classic_button.grab_focus()


func hide_menu() -> void:
	panel.visible = false


func is_open() -> bool:
	return panel.visible


func refresh_info() -> void:
	daily_info_label.text = "今日种子 %s · 今日最佳 %d · 连续 %d 天" % [
		GameMode.seed_text(GameMode.daily_seed()),
		MetaProgress.daily_best(),
		MetaProgress.daily_streak(),
	]
	run_info_label.text = "无尽最佳 %d · 上局种子 %s" % [
		MetaProgress.run_best(),
		GameMode.seed_text(int(MetaProgress.data()[MetaProgress.KEY_RUN_SEED])),
	]


func _on_mode_button(mode: int) -> void:
	if sfx != null:
		sfx.play("ui")
	mode_chosen.emit(mode)


func _on_quit_pressed() -> void:
	if sfx != null:
		sfx.play("ui")
	quit_requested.emit()