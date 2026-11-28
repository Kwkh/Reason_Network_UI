#Requires -Version 5.1
<#
.SYNOPSIS
    在隔离的临时用户目录里冒烟测试 Windows 后台。

.DESCRIPTION
    覆盖：二进制启动、daemon 启动、建网、team/link JSON、本机会话目录、daemon
    重启后的状态恢复。加 -JoinCheck 时再用第二个隔离目录通过邀请链接入网。

    不向真实队友发消息，也不改动当前用户的 ~/.reason。

.PARAMETER Binary
    reason-network-backend.exe 路径，默认 Engine\Bin 下的构建产物。

.PARAMETER JoinCheck
    额外验证两个本机隔离实例之间的入网。需要本机网络与中继可达，默认关闭。

.PARAMETER TimeoutSeconds
    等待 daemon 就绪的秒数。
#>
[CmdletBinding()]
param(
    [string]$Binary,

    [switch]$JoinCheck,

    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

if (-not $Binary) {
    $Binary = Join-Path $RepoRoot 'Engine\Bin\reason-network-backend.exe'
}
if (-not (Test-Path $Binary)) {
    throw "找不到后台二进制：$Binary。先运行 Engine\build-windows.ps1。"
}
$Binary = (Resolve-Path $Binary).Path

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("reason-network-smoke-" + [guid]::NewGuid().ToString('n'))
$SavedEnv = @{
    USERPROFILE                 = $env:USERPROFILE
    HOME                        = $env:HOME
    REASON_NETWORK_HOME         = $env:REASON_NETWORK_HOME
    REASON_NETWORK_NO_SERVICE   = $env:REASON_NETWORK_NO_SERVICE
    REASON_NETWORK_NO_TRAY      = $env:REASON_NETWORK_NO_TRAY
}
# 每个元素：@{ State = <REASON_NETWORK_HOME>; Process = <daemon 进程> }
# 双实例入网时 A 必须保持在线，所以不能只记一个 daemon。
$script:Daemons = @()

function Set-IsolatedHome {
    param([string]$Name)

    $Root = Join-Path $WorkDir $Name
    $State = Join-Path $Root '.reason\network'
    New-Item -ItemType Directory -Path $State -Force | Out-Null

    $env:USERPROFILE = $Root
    $env:HOME = $Root
    $env:REASON_NETWORK_HOME = $State
    $env:REASON_NETWORK_NO_SERVICE = '1'
    $env:REASON_NETWORK_NO_TRAY = '1'
    return $State
}

function Invoke-Backend {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    # stdout 只留给 JSON；stderr 单独收，避免 daemon 的诊断行污染解析。
    $ErrorFile = Join-Path $WorkDir ("stderr-" + [guid]::NewGuid().ToString('n') + ".txt")
    try {
        $Output = & $Binary @Arguments 2>$ErrorFile | Out-String
        $Code = $LASTEXITCODE
        $ErrorText = if (Test-Path $ErrorFile) { Get-Content $ErrorFile -Raw } else { "" }
        if ($Code -ne 0 -and -not $AllowFailure) {
            throw "reason-network $($Arguments -join ' ') 失败（退出码 $Code）：`n$ErrorText`n$Output"
        }
        return $Output.Trim()
    }
    finally {
        Remove-Item $ErrorFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Json {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $Text = Invoke-Backend -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "reason-network $($Arguments -join ' ') 没有输出 JSON"
    }
    return $Text | ConvertFrom-Json
}

function Start-TestDaemon {
    $State = $env:REASON_NETWORK_HOME
    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = $Binary
    $Info.Arguments = 'daemon'
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.EnvironmentVariables['USERPROFILE'] = $env:USERPROFILE
    $Info.EnvironmentVariables['HOME'] = $env:HOME
    $Info.EnvironmentVariables['REASON_NETWORK_HOME'] = $State
    $Info.EnvironmentVariables['REASON_NETWORK_NO_SERVICE'] = '1'
    $Info.EnvironmentVariables['REASON_NETWORK_NO_TRAY'] = '1'

    $Process = [System.Diagnostics.Process]::Start($Info)
    $script:Daemons += @{ State = $State; Process = $Process }
    $Lock = Join-Path $State 'daemon.lock'
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $Deadline) {
        if ($Process.HasExited) {
            throw "daemon 提前退出（退出码 $($Process.ExitCode)）。日志：$(Join-Path $State 'daemon.log')"
        }
        if (Test-Path $Lock) {
            $PidText = (Get-Content $Lock -Raw).Trim()
            if ($PidText -match '^\d+$' -and (Get-Process -Id ([int]$PidText) -ErrorAction SilentlyContinue)) {
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "daemon 在 $TimeoutSeconds 秒内未就绪。日志：$(Join-Path $State 'daemon.log')"
}

function Stop-TestDaemon {
    if (-not $env:REASON_NETWORK_HOME) { return }
    Stop-DaemonAt -State $env:REASON_NETWORK_HOME
}

function Stop-DaemonAt {
    param([string]$State)

    $Entry = $script:Daemons | Where-Object { $_.State -eq $State } | Select-Object -First 1
    if ($Entry) {
        $Process = $Entry.Process
        if ($Process) {
            if (-not $Process.HasExited) {
                $Process.Kill()
                $Process.WaitForExit(10000) | Out-Null
            }
            $Process.Dispose()
        }
        $script:Daemons = @($script:Daemons | Where-Object { $_.State -ne $State })
    }
    $Lock = Join-Path $State 'daemon.lock'
    if (Test-Path $Lock) {
        $PidText = (Get-Content $Lock -Raw).Trim()
        if ($PidText -match '^\d+$') {
            Stop-Process -Id ([int]$PidText) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "断言失败：$Message"
    }
}

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    $Version = (& $Binary --version 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $Version.Length -gt 0) "二进制 --version 可执行"
    Write-Host "后台版本：$Version"

    Write-Host '==> 实例 A：建网、team/link、会话目录'
    $StateA = Set-IsolatedHome 'a'
    Start-TestDaemon

    $Created = Invoke-Json @('init', 'SmokeNet', '--as', 'alice', '--no-setup', '--json')
    Assert-True ($null -ne $Created.team_id -and $Created.team_id.Length -eq 32) 'init 返回 32 位 team_id'
    Assert-True ($Created.team_name -eq 'SmokeNet') 'Network 名称为 SmokeNet'
    Assert-True ($Created.person -eq 'alice') '本机身份为 alice'
    $TeamA = $Created.team_id

    $Team = Invoke-Json @('team', '--json')
    Assert-True (@($Team.members).Count -ge 1) 'team 至少有一台成员机器'
    Assert-True (@($Team.members | Where-Object { $_.is_me }).Count -eq 1) 'team 标出本机'

    $Link = Invoke-Json @('link', '--json')
    Assert-True (-not [string]::IsNullOrWhiteSpace($Link.link)) 'link 返回邀请链接'
    Assert-True ($Link.invite_line -like '*Reason Network*') 'link 返回邀请行'

    $Catalog = @(Invoke-Json @('native-session-catalog'))
    Write-Host "    本机会话目录：$($Catalog.Count) 条"

    Write-Host '==> 实例 A：重启 daemon 后状态仍在'
    Stop-TestDaemon
    Start-TestDaemon
    $Again = Invoke-Json @('team', '--json')
    Assert-True ($Again.team_id -eq $TeamA) '重启后仍属于同一个 Network'
    Assert-True ($Again.person -eq 'alice') '重启后身份不变'

    if ($JoinCheck) {
        # 邀请链接入网需要创建者机器在线，所以 A 的 daemon 必须保持运行。
        Write-Host '==> 实例 B：通过邀请链接入网（A 保持在线）'
        Set-IsolatedHome 'b' | Out-Null
        Start-TestDaemon

        $Joined = Invoke-Json @('join', $Link.link, '--as', 'bob', '--no-setup', '--json')
        Assert-True ($Joined.team_id -eq $TeamA) 'B 加入的是同一个 Network'
        Assert-True ($Joined.person -eq 'bob') 'B 的身份为 bob'

        # 成员列表可能比 join 返回晚一拍，最多等 30 秒。
        $HasAlice = $false
        $Deadline = (Get-Date).AddSeconds(30)
        do {
            $TeamB = Invoke-Json @('team', '--json')
            $HasAlice = @($TeamB.members | Where-Object { $_.person -eq 'alice' }).Count -ge 1
            if (-not $HasAlice) { Start-Sleep -Milliseconds 500 }
        } while (-not $HasAlice -and (Get-Date) -lt $Deadline)
        Assert-True $HasAlice 'B 能看到 alice'
        Stop-TestDaemon
    }

    Write-Host ''
    Write-Host 'PASS: Windows 后台冒烟通过'
}
finally {
    foreach ($Entry in @($script:Daemons)) {
        Stop-DaemonAt -State $Entry.State
    }
    foreach ($Key in $SavedEnv.Keys) {
        if ($null -eq $SavedEnv[$Key]) {
            Remove-Item -Path "env:$Key" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path "env:$Key" -Value $SavedEnv[$Key]
        }
    }
    Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
}
