# 安装/卸载前结束 Reason Network daemon，避免后台占用文件或留在已删除的路径。
# 只处理 %USERPROFILE%\.reason 下主工作区和各工作区的 daemon.lock。
$ErrorActionPreference = 'SilentlyContinue'

$reason = Join-Path $env:USERPROFILE '.reason'
$roots = @(Join-Path $reason 'network')
$workspaces = Join-Path $reason 'workspaces'
if (Test-Path $workspaces) {
    Get-ChildItem $workspaces -Directory | ForEach-Object { $roots += $_.FullName }
}

foreach ($root in $roots) {
    $lock = Join-Path $root 'daemon.lock'
    if (-not (Test-Path $lock)) { continue }
    $text = (Get-Content $lock -Raw).Trim()
    if ($text -match '^\d+$') {
        Stop-Process -Id ([int]$text) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 200
    }
}
