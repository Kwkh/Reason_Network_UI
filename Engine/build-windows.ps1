#Requires -Version 5.1
<#
.SYNOPSIS
    从固定的上游提交重建 Windows x64 兼容后台。

.DESCRIPTION
    按 Engine/build.sh 的补丁顺序应用 macOS 兼容补丁，再追加 Windows 多工作区
    命名管道补丁，最后产出 Engine\Bin\reason-network-backend.exe。

    需要：Git、Rust（rustup）、Visual Studio 的 C++ MSVC 生成工具、Windows SDK。

.PARAMETER Target
    目标三元组，默认 x86_64-pc-windows-msvc。

.PARAMETER SkipTests
    跳过与 macOS 构建相同的四个 Rust 测试。

.PARAMETER KeepWork
    保留临时构建目录，便于排查失败原因。
#>
[CmdletBinding()]
param(
    [ValidateSet('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')]
    [string]$Target = 'x86_64-pc-windows-msvc',

    [switch]$SkipTests,

    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$EngineDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $EngineDir
$OutDir = Join-Path $EngineDir 'Bin'
$OutFile = Join-Path $OutDir 'reason-network-backend.exe'
$Upstream = 'https://github.com/reason-machines/reason-network.git'
$Commit = '5872711927788b0d43a8a940ea45f993bc2926bc'

# 与 Engine/build.sh 完全一致，最后追加 Windows 命名管道工作区分发。
$PatchOrder = @(
    'session-participation',
    'receive-mode',
    'codex-wake',
    'connection-recovery',
    'native-thread-guard',
    'network-workspaces',
    'codex-resume-server',
    'founder-admin',
    'departure-notices',
    'multi-agent-workspaces',
    'native-agent-wake',
    'app-integrations',
    'dsh-session-identity',
    'native-titles',
    'harness-presence',
    'agent-session-join',
    'session-join-diagnostics',
    'agent-join-setup',
    'dsh-presence',
    'compact-replies',
    'windows-workspaces',
    'windows-codex-resume',
    'windows-codex-uds'
)

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') 失败（退出码 $LASTEXITCODE）"
    }
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "缺少 $Name。$Hint"
    }
}

Assert-Command git '请安装 Git for Windows。'
Assert-Command cargo '请安装 Rust（https://rustup.rs），并选择 MSVC 工具链。'
Assert-Command rustup '请安装 rustup。'

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("reason-network-build-" + [guid]::NewGuid().ToString('n'))
$SourceDir = Join-Path $WorkDir 'src'

Write-Host "==> 拉取上游 v0.12.17（$Commit）"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
try {
    Invoke-Checked 'git' @('clone', '--quiet', '--branch', 'v0.12.17', '--depth', '1', $Upstream, $SourceDir)

    $Head = (& git -C $SourceDir rev-parse HEAD).Trim()
    if ($Head -ne $Commit) {
        throw "上游提交不匹配：期望 $Commit，实际 $Head"
    }
    Write-Host "    提交校验通过"

    Write-Host "==> 应用补丁（共 $($PatchOrder.Count) 个）"
    foreach ($Name in $PatchOrder) {
        $Patch = Join-Path $EngineDir "$Name.patch"
        if (-not (Test-Path $Patch)) {
            throw "缺少补丁：$Patch"
        }
        Invoke-Checked 'git' @('-C', $SourceDir, 'apply', '--whitespace=nowarn', $Patch)
        Write-Host "    $Name"
    }

    Write-Host "==> 确保 Rust 目标 $Target"
    Invoke-Checked 'rustup' @('target', 'add', $Target)

    Push-Location $SourceDir
    try {
        if (-not $SkipTests) {
            Write-Host '==> 运行与 macOS 构建相同的测试'
            $Tests = @(
                'native_rename_after_long_records_and_compression',
                'founder_management_is_scoped_and_terminal',
                'paused_session_rejects_hooks_and_mcp_until_explicitly_resumed',
                'dropping_an_unpublished_connection_closes_its_peer'
            )
            foreach ($Test in $Tests) {
                Invoke-Checked 'cargo' @('test', '--locked', '--release', $Test)
            }
        }

        Write-Host "==> 构建 $Target"
        Invoke-Checked 'cargo' @('build', '--locked', '--release', '--target', $Target)

        $Built = Join-Path $SourceDir "target\$Target\release\reason-network.exe"
        if (-not (Test-Path $Built)) {
            throw "构建产物不存在：$Built"
        }
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        Copy-Item -Path $Built -Destination $OutFile -Force
    }
    finally {
        Pop-Location
    }

    $Version = (& $OutFile --version) 2>&1 | Out-String
    Write-Host ''
    Write-Host "完成：$OutFile"
    Write-Host "版本：$($Version.Trim())"
    Write-Host '下一步：Tests\windows-smoke.ps1 做本机冒烟；Mac ↔ Windows 联调见 WINDOWS.md。'
}
finally {
    if ($KeepWork) {
        Write-Host "临时目录保留：$WorkDir"
    }
    else {
        Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
    }
}
