class_name MetaProgress
extends RefCounted
## 长期档案：每日挑战的当日最佳/连续天数、无尽模式最佳、当前持有的卡牌计数。
##
## 与 HighScore 分开存档，理由是生命周期不同：最高分是「跨全部模式的单值」，
## 而这里全是「按模式/按日期分桶」的结构化数据，挤进同一个 ConfigFile
## 只会让两边互相迁就。
##
## 全部是静态函数 + 一份内存缓存：这些数据一局之内读多写少，
## 每次 set 都落盘（Web 的 IndexedDB 写入并不便宜），而且 MetaProgress
## 随时可能被菜单、结算面板与存档面板三处同时调用，没有实例可挂。

## 存档路径。与 HighScore.SAVE_PATH 分开，避免互相覆盖。
const SAVE_PATH := "user://2d_breakout_meta.cfg"
const SECTION := "meta"
const KEY_DAILY_BEST := "daily_best"
const KEY_DAILY_DATE := "daily_date"
const KEY_DAILY_DAY := "daily_day"
const KEY_DAILY_STREAK := "daily_streak"
const KEY_RUN_BEST := "run_best"
const KEY_RUN_SEED := "run_seed"
const KEY_CARDS := "cards"

## 内存缓存。null = 还没读过盘。
static var _cache: Variant = null


## 读档并返回整份档案。读不到文件时返回一份默认值（不是空字典）。
static func data() -> Dictionary:
	if _cache != null:
		return _cache as Dictionary
	var defaults := {
		KEY_DAILY_BEST: 0,
		KEY_DAILY_DATE: "",
		KEY_DAILY_DAY: -1,
		KEY_DAILY_STREAK: 0,
		KEY_RUN_BEST: 0,
		KEY_RUN_SEED: 0,
		KEY_CARDS: {},
	}
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		_cache = defaults
		return _cache
	for key in defaults:
		if not config.has_section_key(SECTION, key):
			continue
		# 字典单独转换：ConfigFile 读回来的是 Variant，直接当 Dictionary 用
		# 在没有类型断言的路径上会报运行时错。
		if key == KEY_CARDS:
			defaults[key] = _to_dict(config.get_value(SECTION, key, {}))
		else:
			defaults[key] = config.get_value(SECTION, key, defaults[key])
	_cache = defaults
	return _cache


## 落盘。返回是否成功（Web 导出在隐私模式下会写失败）。
static func save() -> bool:
	var config := ConfigFile.new()
	var current := data()
	for key in current:
		config.set_value(SECTION, key, current[key])
	return config.save(SAVE_PATH) == OK


static func daily_best() -> int:
	return int(data()[KEY_DAILY_BEST])


static func daily_streak() -> int:
	return int(data()[KEY_DAILY_STREAK])


static func run_best() -> int:
	return int(data()[KEY_RUN_BEST])


## 已持有的卡牌计数 {id: 次数}。
static func cards() -> Dictionary:
	return _to_dict(data()[KEY_CARDS])


## 记一次无尽/每日模式的结算，返回更新后的档案副本。
##
## 连续打卡天数按 UTC 天序号算：今天就是上次那天的后一天则 +1，
## 不是（隔了至少两天）则重置成 1。今天已经打过则原样保留，
## 免得同一天反复结算把连击天数刷成天文数字。
static func record_run(mode: int, run_seed: int, score: int) -> Dictionary:
	var current := data()
	var today := GameMode.daily_day_index()
	if mode == GameMode.Mode.DAILY:
		if score > int(current[KEY_DAILY_BEST]):
			current[KEY_DAILY_BEST] = score
		var last_day := int(current[KEY_DAILY_DAY])
		if last_day >= 0 and today == last_day:
			pass
		elif last_day >= 0 and today == last_day + 1:
			current[KEY_DAILY_STREAK] = int(current[KEY_DAILY_STREAK]) + 1
		else:
			current[KEY_DAILY_STREAK] = 1
		current[KEY_DAILY_DAY] = today
		current[KEY_DAILY_DATE] = GameMode.daily_date_text()
	elif mode == GameMode.Mode.RUN:
		if score > int(current[KEY_RUN_BEST]):
			current[KEY_RUN_BEST] = score
		current[KEY_RUN_SEED] = run_seed
	save()
	return current.duplicate(true)


## 把一张卡记进档案（跨局保留「抽到过几次」，用于菜单展示收藏进度）。
static func record_card(card_id: String) -> void:
	var current := data()
	var owned := _to_dict(current[KEY_CARDS])
	owned[card_id] = int(owned.get(card_id, 0)) + 1
	current[KEY_CARDS] = owned
	save()


## 丢掉内存缓存（只给测试与「手动重置档案」用）。
static func forget_cache() -> void:
	_cache = null


# —— 内部实现 ——

static func _to_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value as Dictionary
	return {}