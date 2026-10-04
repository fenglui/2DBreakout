class_name CardDraftPanel
extends CanvasLayer
## 三选一卡牌面板：关卡通过后弹出，玩家从三张牌里挑一张带进下一关。
##
## 卡面节点是运行时生成的（Cards 容器下每张牌一个 Card0/Card1/Card2 子树），
## 而不是写死在场景里。原因很实际：卡表是数据（CardPool.CARDS），
## 牌的条数、宽度、配色都跟着稀有度变——写死三份场景节点就等于
## 「卡表」和「场景」两份必须手工对齐的事实来源，正是这个项目一路在消灭的东西。
##
## 键盘由 Main 处理（1/2/3 选牌、R 跳过）：放在这里会和 Main 的
## _unhandled_input 抢同一个事件，而 Godot 的 unhandled 输入顺序
## （子节点先于父节点）会让「谁先收到」变成一个隐含前提。
## 面板只负责鼠标与焦点，焦点落在第一张牌上，回车即可确认。

signal card_chosen(index: int)
signal draft_skipped()

const CARD_MIN_WIDTH := 112.0
const RARITY_COLORS := [
	Color(0.788235, 0.85098, 0.921569),
	Color(0.478431, 0.831373, 0.929412),
	Color(0.976471, 0.780392, 0.298039),
]

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/Margin/VBox/TitleLabel
@onready var sub_label: Label = $Panel/Margin/VBox/SubLabel
@onready var cards_root: HBoxContainer = $Panel/Margin/VBox/Cards
@onready var skip_button: Button = $Panel/Margin/VBox/SkipButton
@onready var hint_label: Label = $Panel/Margin/VBox/HintLabel
@onready var sfx: SfxBus = SfxBus.instance(self)

## 本次展示的牌（卡面字典数组）。测试与 Main 都读它来核对「发了几张、是哪几张」。
var offered: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	skip_button.pressed.connect(_on_skip_pressed)
	panel.visible = false


## 发牌并显示。cards 传空数组时面板自动跳过（牌池见底），
## 调用方不必自己判断「有没有牌可发」。
func present(cards: Array, level: int, taken: int, palette: Palette) -> void:
	# 先无条件收起：本次是空牌时必须把上一轮残留的界面关掉，
	# 否则「牌池见底 -> 自动跳过」之后面板仍停在屏幕上，
	# 玩家看到的是一张没有牌的空壳。
	panel.visible = false
	offered = []
	if cards.is_empty():
		draft_skipped.emit()
		return
	offered = cards
	title_label.text = "选择一张卡牌"
	sub_label.text = "第 %d 关通过 · 本局已选 %d 张" % [level, taken]
	_build(cards, palette)
	panel.visible = true
	var first := _button_at(0)
	if first != null:
		first.grab_focus()


func hide_panel() -> void:
	panel.visible = false
	offered = []


func is_open() -> bool:
	return panel.visible


## 第 i 张牌的「选择」按钮。测试用它模拟点击，避免依赖屏幕坐标。
func _button_at(index: int) -> Button:
	if index < 0 or index >= cards_root.get_child_count():
		return null
	var slot: Node = cards_root.get_child(index)
	return slot.get_node_or_null("VBox/ChooseButton") as Button


## 按下第 index 张牌的「选择」（对外给 Main 的键盘分支用）。
func choose(index: int) -> void:
	if not panel.visible:
		return
	if index < 0 or index >= offered.size():
		_on_skip_pressed()
		return
	if sfx != null:
		sfx.play("ui")
	card_chosen.emit(index)


func _on_skip_pressed() -> void:
	if not panel.visible:
		return
	if sfx != null:
		sfx.play("ui")
	draft_skipped.emit()


# —— 卡面构建 ——

func _build(cards: Array, palette: Palette) -> void:
	# 先 remove_child 再 queue_free：queue_free 要到帧末才生效，
	# 同一帧内 get_child_count() 仍会算上旧卡，新卡就会被接在旧卡后面，
	# 下一次发牌就会多出几张残影。先摘出子树则立刻腾空容器。
	for child in cards_root.get_children():
		cards_root.remove_child(child)
		child.queue_free()

	var accent: Color = palette.accent if palette != null else Color("f9c74f")
	for i in cards.size():
		cards_root.add_child(_make_slot(cards[i], i, accent))


func _make_slot(card: Dictionary, index: int, accent: Color) -> Control:
	var rarity := clampi(int(card["rarity"]), 0, RARITY_COLORS.size() - 1)
	var slot := PanelContainer.new()
	slot.name = "Card%d" % index
	slot.custom_minimum_size = Vector2(CARD_MIN_WIDTH, 0.0)

	var box := VBoxContainer.new()
	box.name = "VBox"
	box.add_theme_constant_override("separation", 6)
	slot.add_child(box)

	var name_label := Label.new()
	name_label.name = "NameLabel"
	name_label.text = String(card["name"])
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.custom_minimum_size = Vector2(CARD_MIN_WIDTH - 16.0, 0.0)
	box.add_child(name_label)

	var desc_label := Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = String(card["desc"])
	desc_label.add_theme_font_size_override("font_size", 13)
	desc_label.add_theme_color_override("font_color", RARITY_COLORS[rarity])
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.custom_minimum_size = Vector2(CARD_MIN_WIDTH - 16.0, 0.0)
	box.add_child(desc_label)

	var rarity_label := Label.new()
	rarity_label.name = "RarityLabel"
	rarity_label.text = CardPool.rarity_name(rarity)
	rarity_label.add_theme_font_size_override("font_size", 12)
	rarity_label.add_theme_color_override("font_color", accent)
	rarity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(rarity_label)

	var button := Button.new()
	button.name = "ChooseButton"
	button.text = "选择"
	button.pressed.connect(choose.bind(index))
	box.add_child(button)

	return slot