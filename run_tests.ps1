<#
.SYNOPSIS
    一键验证：--check-only 静态门禁 + 无头冒烟测试。

.DESCRIPTION
    串起两步，任一步失败即以非零码退出，可直接用于本地提交前检查或 CI：
      1) 对 scripts/ 与 tests/ 下每个 .gd 逐个跑 --check-only，出现 SCRIPT ERROR 即失败
         （GDScript warning 默认只提示不失败，加 -Strict 后同样视为失败）
      2) 跑 res://tests/headless_smoke_test.gd，其退出码即测试结果

.PARAMETER Strict
    把 GDScript 的 warning 也当作失败。

.PARAMETER SkipSmoke
    只做静态检查，跳过冒烟测试。

.PARAMETER Detailed
    打印 Godot 的完整输出（默认只显示摘要与失败详情）。

.EXAMPLE
    .\run_tests.ps1

.EXAMPLE
    .\run_tests.ps1 -Strict -Detailed

.NOTES
    Godot 可执行文件的查找顺序：
      1) 环境变量 GODOT_PATH
      2) PATH 中的 godot / godot4 / godot-console
      3) 项目目录及其上两级目录、%LOCALAPPDATA%\Programs、%USERPROFILE%\Downloads、
         Program Files 下递归两层的 Godot*console*.exe（优先 console 版，无头运行更稳）
    找不到时退出码为 2。
#>
[CmdletBinding()]
param(
	[switch]$Strict,
	[switch]$SkipSmoke,
	[switch]$Detailed
)

Set-StrictMode -Version Latest
# 注意：Godot 会把 warning / SCRIPT ERROR 写到 stderr。PowerShell 在 Stop 模式下
# 会把原生命令的 stderr 包装成终止性错误并中断脚本，因此这里必须用 Continue，
# 静态检查的捕获改由 cmd /c 在原生层合并两个流。
$ErrorActionPreference = 'Continue'

# Godot 的中文输出是 UTF-8，控制台默认代码页会把它显示成乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = $PSScriptRoot

function Find-Godot {
	$candidates = [System.Collections.Generic.List[string]]::new()

	if ($env:GODOT_PATH) { $candidates.Add($env:GODOT_PATH) }
	foreach ($name in 'godot', 'godot4', 'godot-console') {
		$cmd = Get-Command $name -ErrorAction SilentlyContinue
		if ($cmd) { $candidates.Add($cmd.Source) }
	}

	$roots = @(
		$root,
		(Join-Path $root '..'),
		(Join-Path $root '..\..'),
		(Join-Path $env:LOCALAPPDATA 'Programs'),
		(Join-Path $env:USERPROFILE 'Downloads'),
		'C:\Program Files',
		'C:\Program Files (x86)'
	)
	foreach ($dir in $roots) {
		if (-not (Test-Path -LiteralPath $dir)) { continue }
		# console 版在无头/CI 场景下输出可直接捕获，优先选它
		$hit = Get-ChildItem -Path $dir -Filter 'Godot*console*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
			Sort-Object FullName | Select-Object -First 1
		if (-not $hit) {
			$hit = Get-ChildItem -Path $dir -Filter 'Godot*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
				Sort-Object FullName | Select-Object -First 1
		}
		if ($hit) { $candidates.Add($hit.FullName) }
	}

	foreach ($c in $candidates) {
		if ($c -and (Test-Path -LiteralPath $c)) { return $c }
	}
	return $null
}

function ResPath([string]$absolutePath) {
	$rel = $absolutePath.Substring($root.Length).TrimStart('\', '/')
	return 'res://' + ($rel -replace '\\', '/')
}

Write-Host "2DBreakout 一键验证" -ForegroundColor Cyan
Write-Host "项目目录: $root"

$godot = Find-Godot
if (-not $godot) {
	Write-Host ""
	Write-Host "未找到 Godot 可执行文件。" -ForegroundColor Red
	Write-Host "请安装 Godot 4.7，或设置环境变量 GODOT_PATH 指向 Godot 可执行文件后重试。"
	exit 2
}
Write-Host "Godot:     $godot"
Write-Host ""

# ---------- 1. 静态门禁 ----------
Write-Host "== 1/2 静态检查（--check-only）==" -ForegroundColor Cyan
$targets = @()
foreach ($dir in 'scripts', 'tests') {
	$dirPath = Join-Path $root $dir
	if (Test-Path -LiteralPath $dirPath) {
		$targets += @(Get-ChildItem -Path $dirPath -Filter '*.gd' -File | Sort-Object Name)
	}
}

$errors = 0
$warnings = 0
foreach ($file in $targets) {
	$resPath = ResPath $file.FullName
	$out = (@(cmd /c "`"$godot`" --headless --path `"$root`" --check-only --script $resPath 2>&1")) -join "`n"
	$hasError = $out -match 'SCRIPT ERROR'
	$hasWarn = $out -match '(?m)^WARNING:'

	if ($hasError) {
		$errors++
		Write-Host ("  FAIL  {0}" -f $file.Name) -ForegroundColor Red
		($out -split "`n" | Where-Object { $_ -match 'SCRIPT ERROR|at:|Parse' }) | ForEach-Object { "        $_".TrimEnd() } | ForEach-Object { Write-Host $_ }
	} elseif ($hasWarn) {
		$warnings++
		$color = if ($Strict) { 'Red' } else { 'Yellow' }
		Write-Host ("  WARN  {0}" -f $file.Name) -ForegroundColor $color
		($out -split "`n" | Where-Object { $_ -match 'WARNING|at:' }) | ForEach-Object { "        $_".TrimEnd() } | ForEach-Object { Write-Host $_ }
	} else {
		Write-Host ("  OK    {0}" -f $file.Name) -ForegroundColor Green
	}
	if ($Detailed -and -not $hasError) { Write-Host $out.Trim() }
}

$staticFailed = ($errors -gt 0) -or ($Strict -and $warnings -gt 0)
Write-Host ("  共 {0} 个脚本：{1} 个错误，{2} 个警告{3}" -f `
	$targets.Count, $errors, $warnings, $(if ($Strict) { "（-Strict：警告计为失败）" } else { "" }))
Write-Host ""

if ($staticFailed) {
	Write-Host "静态门禁未通过，已跳过冒烟测试。" -ForegroundColor Red
	exit 1
}
Write-Host "静态门禁通过。" -ForegroundColor Green
Write-Host ""

# ---------- 2. 冒烟测试 ----------
if ($SkipSmoke) {
	Write-Host "已按 -SkipSmoke 跳过冒烟测试。"
	exit 0
}

Write-Host "== 2/2 无头冒烟测试 ==" -ForegroundColor Cyan
& $godot --headless --path $root --script res://tests/headless_smoke_test.gd
$smokeExit = $LASTEXITCODE
Write-Host ""

if ($smokeExit -eq 0) {
	Write-Host "全部通过。" -ForegroundColor Green
	exit 0
}

Write-Host "冒烟测试失败（Godot 退出码 $smokeExit）。" -ForegroundColor Red
exit 1
