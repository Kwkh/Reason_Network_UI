#Requires -Version 7
<#
.SYNOPSIS
    真实 Codex 联调的准备与基础验证（登录后运行）。

.DESCRIPTION
    在临时目录里搭一套隔离环境：
      - CODEX_HOME 只复制已登录的 auth.json，不改真实 Codex 配置；
      - USERPROFILE / REASON_NETWORK_HOME 都在临时目录；
      - REASON_NETWORK_CODEX_BIN 指向实际 Codex CLI，供后台 wake/resume 使用。

    依次验证：Codex 登录可复用、Network 初始化、setup 写入 MCP 配置、
    创建一个真实线程、native-session-catalog 能识别线程。

    唤醒（resume_queued）需要 Codex 原对话保持打开，脚本只打印手工步骤。

.PARAMETER Keep
    保留临时目录（排查失败时用）。默认结束会停止临时 daemon 并删除目录。

.PARAMETER Root
    临时根目录，默认 %TEMP%\rn-codex-e2e。

.EXAMPLE
    pwsh -NoProfile -File .\Tests\codex-e2e.ps1

.NOTES
    必须先登录 Codex：
      & "<Codex CLI 路径>" login
    Microsoft Store 版内置 CLI 通常在
      C:\Program Files\WindowsApps\OpenAI.Codex_*\app\resources\codex.exe
#>
[CmdletBinding()]
param(
    [switch]$Keep,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
$Backend = Join-Path $Repo 'Engine\Bin\reason-network-backend.exe'
if (-not (Test-Path $Backend)) {
    throw "缺少后台：$Backend。请先运行 Engine\build-windows.ps1。"
}

function Find-CodexCli {
    if ($env:REASON_NETWORK_CODEX_BIN -and (Test-Path $env:REASON_NETWORK_CODEX_BIN)) {
        return $env:REASON_NETWORK_CODEX_BIN
    }
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $apps = Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter 'OpenAI.Codex_*_x64__*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    foreach ($app in $apps) {
        $exe = Join-Path $app.FullName 'app\resources\codex.exe'
        if (Test-Path $exe) { return $exe }
    }
    throw '找不到 Codex CLI。安装 OpenAI Codex，或把 REASON_NETWORK_CODEX_BIN 指向 codex.exe。'
}

function Stop-TempDaemons {
    param([string[]]$Homes)
    foreach ($home in $Homes) {
        $lock = Join-Path $home 'daemon.lock'
        if (-not (Test-Path $lock)) { continue }
        $pidText = (Get-Content $lock -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($pidText -match '^\d+$') {
            Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue
        }
    }
}

$Codex = Find-CodexCli
$version = (& $Codex --version 2>&1 | Out-String).Trim()
Write-Host "Codex：$version"

if (-not $Root) { $Root = Join-Path ([System.IO.Path]::GetTempPath()) 'rn-codex-e2e' }
$codexHome = Join-Path $Root 'codex-home'
$profileDir = Join-Path $Root 'profile'
$workDir = Join-Path $Root 'work'
$localAppData = Join-Path $profileDir 'AppData\Local'
$reasonHome = Join-Path $profileDir '.reason\network'

# 只看登录凭据文件是否存在，不读取内容；真实的 config.toml 不复制。
$realCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$auth = Join-Path $realCodexHome 'auth.json'
if (-not (Test-Path $auth)) {
    Write-Host 'Codex 还没有登录。请先在对话框运行：'
    Write-Host ('  & "{0}" login' -f $Codex)
    Write-Host '登录后重新运行本脚本。'
    exit 2
}

if (Test-Path $Root) { Remove-Item -Recurse -Force $Root }
foreach ($dir in @($codexHome, $profileDir, $workDir, $localAppData, $reasonHome)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
Copy-Item $auth (Join-Path $codexHome 'auth.json') -Force

$env:USERPROFILE = $profileDir
$env:CODEX_HOME = $codexHome
$env:LOCALAPPDATA = $localAppData
$env:REASON_NETWORK_HOME = $reasonHome
$env:REASON_NETWORK_CODEX_BIN = $Codex
$env:REASON_NETWORK_NO_SERVICE = '1'
$env:REASON_NETWORK_NO_UPDATE = '1'
$env:REASON_NETWORK_NO_TRAY = '1'

$status = (& $Codex login status 2>&1 | Out-String).Trim()
if ($status -notmatch 'Logged in') {
    Write-Host "临时 CODEX_HOME 无法复用登录：$status"
    Write-Host "真实凭据：$auth"
    exit 2
}
Write-Host '登录复用：OK'

try {
    Push-Location $reasonHome
    try {
        & $Backend init CodexE2E --as tester --no-setup --json *> $null
        if ($LASTEXITCODE -ne 0) { throw '初始化 Network 失败' }
    } finally {
        Pop-Location
    }
    Write-Host 'Network 初始化：OK'

    $dryRun = (& $Backend setup --dry-run 2>&1 | Out-String).Trim()
    Write-Host "setup --dry-run：`n$dryRun"
    & $Backend setup --no-service *> $null
    if ($LASTEXITCODE -ne 0) { throw 'setup --no-service 失败' }

    $configToml = Join-Path $codexHome 'config.toml'
    if (-not (Test-Path $configToml) -or -not (Select-String -Path $configToml -Pattern 'reason' -Quiet)) {
        throw "setup 没有把 Reason Network 写进 $configToml"
    }
    Write-Host 'MCP 配置写入：OK'

    # 真实线程：非交互跑一句话，要求模型只回 OK，不执行命令。
    $prompt = 'Reply with exactly OK. Do not run any commands.'
    $json = (& $Codex exec --json --skip-git-repo-check -C $workDir $prompt 2>&1 | Out-String)
    $thread = ([regex]::Match($json, '"thread_id"\s*:\s*"([^"]+)"')).Groups[1].Value
    if (-not $thread -and $json -match '"id"\s*:\s*"(01[0-9A-Za-z-]{20,})"') {
        $thread = $Matches[1]
    }
    if (-not $thread) {
        $rollout = Get-ChildItem (Join-Path $codexHome 'sessions') -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($rollout) {
            $first = Get-Content $rollout.FullName -TotalCount 1
            if ($first -match '"id"\s*:\s*"([^"]+)"') { $thread = $Matches[1] }
        }
    }
    if (-not $thread) {
        Write-Host '没有从 codex exec 输出里解析到线程 id，下面是原始输出：'
        Write-Host $json
        throw '线程创建结果解析失败'
    }
    Write-Host "真实线程：$thread"

    $catalog = (& $Backend native-session-catalog 2>&1 | Out-String)
    if ($catalog -match [regex]::Escape($thread)) {
        Write-Host 'native-session-catalog 识别线程：OK'
    } else {
        Write-Host 'native-session-catalog 没有列出该线程，下面是输出：'
        Write-Host $catalog
        throw '目录未识别真实线程'
    }

    Write-Host ''
    Write-Host '基础链路通过。真实唤醒（resume_queued）需要 Codex 原对话保持打开，手工步骤：'
    Write-Host '  1. 保留本脚本 -Keep 生成的临时目录，按输出的 CODEX_HOME/REASON_NETWORK_HOME 启动 Codex；'
    Write-Host '  2. 在 Codex 原对话里让模型调用 reason-network 的 list_team，确认会话已登记；'
    Write-Host '  3. 用另一个本机身份发消息（或另一台机器），观察 Codex 空闲线程是否被唤醒并收到消息；'
    Write-Host '  4. 再测工作区：把该会话接入工作区后重复发送，确认跨工作区地址与唤醒。'
    Write-Host ''
    Write-Host "临时目录：$Root"
} finally {
    if (-not $Keep) {
        Stop-TempDaemons -Homes @($reasonHome)
        Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
        Write-Host '临时目录已清理（-Keep 可保留）。'
    } else {
        Write-Host '已保留临时目录（-Keep）。'
    }
}
