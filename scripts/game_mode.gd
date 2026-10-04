class_name GameMode
extends RefCounted
## 玩法模式与种子推导（纯静态工具类，无实例状态）。
##
## 三种模式，复玩性的三个来源正好各占一条：
## - CLASSIC 经典：3 关固定关卡，种子恒为 CLASSIC_SEED(0)。
##   种子 0 是 LevelGenerator 的「原样返回模板」开关，因此经典模式的砖墙
##   逐位等于 Main.BRICK_LAYOUT——老玩家的肌肉记忆、冒烟测试的锚点断言
##   全都不受新系统影响。
## - RUN 无尽挑战：开局随机一个种子，关卡无上限，每过一关抽一次「三选一」卡牌。
## - DAILY 每日挑战：种子由 UTC 日期推导，当天全服同一份砖墙与同一份卡序，
##   同样抽卡。用来给玩家一个「今天得打个分」的理由。
##
## 种子哈希自己实现 FNV-1a 而不用内置 hash()：内置 hash 只保证「同一版本内一致」，
## 引擎升级就可能变。每日挑战的种子必须跨版本稳定，否则昨天能分享的种子
## 今天长出另一堵墙，「同一天所有人同一局」这个承诺就废了。

enum Mode { CLASSIC, RUN, DAILY }

## MODE_NAMES 索引与 Mode 对齐
const MODE_NAMES := ["经典", "无尽挑战", "每日挑战"]
## 模式总数。写成字面量而不是 MODE_NAMES.size()：
## 后者不是常量表达式（const 不接受函数调用），而这份表与 Mode 枚举必须手写对齐。
## 冒烟测试有一条断言守着「Mode 的条目数 == MODE_NAMES.size() == MODE_COUNT」。
const MODE_COUNT := 3

## 经典模式的种子。0 保留给「不改模板」这个语义，因此合法种子一律避开 0。
const CLASSIC_SEED := 0
## 种子码长度（分享/抄写用）
const SEED_TEXT_LENGTH := 6
## 种子码字符表。刻意去掉 0/O/1/I 这几个手抄容易混淆的字符。
const SEED_ALPHABET := "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
## 种子可能取到的最大值（取正数区间，省掉负数种子）
const SEED_MASK := 0x7FFFFFFF
## 传入种子被规整成保留值 0 时改用这个偏移，避免「非经典模式拿到 0」
const FALLBACK_SEED_OFFSET := 1


## 模式的中文名；越界时回落到经典模式名。
static func mode_name(mode: int) -> String:
	if mode < 0 or mode >= MODE_NAMES.size():
		return String(MODE_NAMES[Mode.CLASSIC])
	return String(MODE_NAMES[mode])


## 该模式是否没有最后一关（无尽）。无尽模式没有 WON 态，永远是「打一关 → 抽卡 → 下一关」。
static func is_endless(mode: int) -> bool:
	return mode == Mode.RUN or mode == Mode.DAILY


## 该模式是否在关卡之间抽卡。经典模式保持 P0/P1 的原样流程（直接进下一关），
## 让「不打卡牌」始终是一个完整可玩的选择，而不是被砍掉的功能。
static func has_cards(mode: int) -> bool:
	return is_endless(mode)


## 该模式每次结算是否记账到长期档案（无尽/每日才记，经典不记）。
static func tracks_progress(mode: int) -> bool:
	return is_endless(mode)


## 稳定字符串哈希（FNV-1a 32 位）。
## 逐字符取 unicode 而不是字节：中文日期串与 ASCII 行为一致，且不依赖编码设置。
static func stable_hash(text: String) -> int:
	var h := 2166136261
	for i in text.length():
		h = (h ^ text.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h


## 今日的 UTC 日期（"2026-10-04"）。
##
## 刻意用 UTC 而不是本地时区：每日挑战要的是「全服同一天同一个局」，
## UTC 的日界是全球统一定义；本地时区的话 UTC+13 的玩家会比 UTC-11 的玩家
## 多玩一整天，这就不是「每日」而是「按你的时区自己给自己加了个班」。
static func daily_date_text() -> String:
	var part := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()))
	return "%04d-%02d-%02d" % [int(part["year"]), int(part["month"]), int(part["day"])]


## 今日种子。相同日期在任何设备、任何时刻调用都必须得到同一个值。
static func daily_seed() -> int:
	return stable_hash("daily:" + daily_date_text()) & SEED_MASK


## 今日 UTC 天的序号（天）。用于连续打卡天数：只比「天数」不比日期字符串，
## 于是跨月跨年也只是一次整数相减，不需要额外的日历运算。
static func daily_day_index() -> int:
	var part := Time.get_datetime_dict_from_unix_time(int(Time.get_unix_time_from_system()))
	var midnight := Time.get_unix_time_from_datetime_dict({
		"year": int(part["year"]), "month": int(part["month"]), "day": int(part["day"]),
	})
	return int(midnight) / 86400


## 随机种子（无尽挑战开局用）。刻意生成后由界面显示出来：
## 「这局是这副牌」比「重开一次换副牌」更能让玩家想把它打完并分享出去。
static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi() & SEED_MASK


## 把整数种子编码成可抄写的种子码。
static func seed_text(seed_value: int) -> String:
	var v := seed_value & SEED_MASK
	var out := ""
	for i in SEED_TEXT_LENGTH:
		out += String(SEED_ALPHABET)[v % SEED_ALPHABET.length()]
		v /= SEED_ALPHABET.length()
	return out


## 某个模式该用的种子。经典模式固定 0，其余按传入的种子走。
##
## 非经典模式不接受 0：0 是 CLASSIC_SEED 的保留值，LevelGenerator 见到它就
## 原样返回模板。拿到 0 的无尽/每日局会和经典模式长得一模一样，
## 玩家会以为「程序化关卡没生效」——所以这里把 0 换成一个确定性的非 0 值。
static func seed_for_mode(mode: int, chosen: int) -> int:
	if mode == Mode.CLASSIC:
		return CLASSIC_SEED
	var value := chosen & SEED_MASK
	if value != CLASSIC_SEED:
		return value
	return (value + FALLBACK_SEED_OFFSET) & SEED_MASK


## 新开一局时该分配的种子。经典恒为 0；每日按当天日期重算
## （即使进程跨过 UTC 零点、或玩家在菜单里停了十分钟，也拿到当天的局）。
static func begin_seed(mode: int) -> int:
	match mode:
		Mode.CLASSIC:
			return CLASSIC_SEED
		Mode.DAILY:
			return daily_seed()
		_:
			return random_seed()