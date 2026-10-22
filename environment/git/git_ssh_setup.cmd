@echo off
setlocal EnableExtensions
set "GIT_SSH_SETUP_SELF=%~f0"
set "GIT_SSH_SETUP_PS1=%TEMP%\git_ssh_setup_%RANDOM%%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$utf8=New-Object System.Text.UTF8Encoding $true; $raw=[System.IO.File]::ReadAllText($env:GIT_SSH_SETUP_SELF, (New-Object System.Text.UTF8Encoding $false)); $m=[regex]::Match($raw, '(?m)^# >>> POWERSHELL\s*$'); if(-not $m.Success){ throw 'POWERSHELL marker not found in '+$env:GIT_SSH_SETUP_SELF }; [System.IO.File]::WriteAllText($env:GIT_SSH_SETUP_PS1, $raw.Substring($m.Index+$m.Length), $utf8)"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell -NoProfile -ExecutionPolicy Bypass -File "%GIT_SSH_SETUP_PS1%" %*
set "ERR=%ERRORLEVEL%"
del /f /q "%GIT_SSH_SETUP_PS1%" >nul 2>&1
endlocal & exit /b %ERR%

# >>> POWERSHELL
# git_ssh_setup.cmd - Windows PowerShell 5+ / 7+ (hybrid .cmd)
# Parameters: *.conf next to this script (if several, pick by number).
# Output: KEY_DIR relative to the launch directory.
#
#   .\environment\git\git_ssh_setup.cmd

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Нужен PowerShell 5.1 или новее.'
}

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GIT_SSH_SETUP_SELF) -or -not (Test-Path -LiteralPath $env:GIT_SSH_SETUP_SELF)) {
    throw 'Не задан путь к скрипту (GIT_SSH_SETUP_SELF). Запускайте git_ssh_setup.cmd.'
}
$ScriptFile = $env:GIT_SSH_SETUP_SELF
$ScriptDir = Split-Path -Parent $ScriptFile
$LaunchDir = (Get-Location).Path
$ConfFile = ''
$SshGitLogin = 'git'

$DefaultHost = 'gitlab.example.com'
$DefaultPort = '22'
$DefaultRemote = 'git@gitlab.example.com:group/project.git'
$DefaultKeyDir = 'ssh-connect'
$DefaultKeyFile = 'id_ed25519'
$DefaultKeyType = 'ed25519'

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Die {
    param([string]$Message)
    Write-Log $Message
    exit 1
}

function Test-FlagYes {
    param([string]$Value)
    $v = "$Value".ToLowerInvariant()
    return $v -in @('yes', 'true', '1', 'да', 'y')
}

function Read-PromptDefault {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    if ($Default) {
        $reply = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    }
    else {
        $reply = Read-Host $Prompt
    }
    if ([string]::IsNullOrWhiteSpace($reply)) {
        return $Default
    }
    return $reply.Trim()
}

function Expand-LaunchPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return (Join-Path $LaunchDir $DefaultKeyDir)
    }
    if ($Path -eq '~') {
        return $env:USERPROFILE
    }
    if ($Path.StartsWith('~/')) {
        $rest = $Path.Substring(2) -replace '/', '\'
        return (Join-Path $env:USERPROFILE $rest)
    }
    if ($Path -match '%USERPROFILE%') {
        return [Environment]::ExpandEnvironmentVariables($Path)
    }
    if ($Path -match '^[A-Za-z]:[\\/]' -or $Path.StartsWith('\\')) {
        return $Path
    }
    if ($Path.StartsWith('/')) {
        return $Path
    }
    return (Join-Path $LaunchDir ($Path -replace '/', '\'))
}

function Read-PromptRequired {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    while ($true) {
        $reply = Read-PromptDefault $Prompt $Default
        if (-not [string]::IsNullOrWhiteSpace($reply)) {
            return $reply.Trim()
        }
        Write-Log 'Значение не должно быть пустым.'
    }
}

function Write-ConfFile {
    $remoteLine = $script:GitRemote
    $passOut = ''
    if (Test-FlagYes $script:SavePassphrase) {
        $passOut = $script:KeyPassphrase
    }
    $text = @"
# Настройки Git SSH
GIT_HOST=$($script:GitHost)
GIT_PORT=$($script:GitPort)

# Опциональная проверка доступа к репозиторию (git ls-remote / test-repo). Пусто = не проверять.
GIT_REMOTE=$remoteLine

# Ключ и выход setup - каталог относительно места запуска скрипта
KEY_DIR=$($script:KeyDirRel)
KEY_FILE=$($script:KeyFile)
KEY_TYPE=$($script:KeyType)

# Имя и почта Git (обязательны, сохраняются при setup).
GIT_USER_NAME=$($script:GitName)
GIT_USER_EMAIL=$($script:GitEmail)

# Писать Host-блок в ~/.ssh/config (да/yes/true/1)
UPDATE_USER_SSH_CONFIG=$($script:UpdateUserSshConfig)

# Сохранять passphrase ключа в этот файл (да/yes/true/1). По умолчанию no.
SAVE_PASSPHRASE=$($script:SavePassphrase)
KEY_PASSPHRASE=$passOut
"@
    [System.IO.File]::WriteAllText($ConfFile, $text, (New-Object System.Text.UTF8Encoding $true))
}

function Get-ConfMap {
    $known = @(
        'GIT_HOST', 'GIT_PORT', 'GIT_REMOTE',
        'KEY_DIR', 'KEY_FILE', 'KEY_TYPE',
        'GIT_USER_NAME', 'GIT_USER_EMAIL',
        'UPDATE_USER_SSH_CONFIG', 'SAVE_PASSPHRASE', 'KEY_PASSPHRASE',
        'GITLAB_HOST', 'GITLAB_PORT', 'SSH_HOST_ALIAS'
    )
    $map = @{}
    # UTF-8 explicitly: Windows PowerShell 5.1 defaults to ANSI and garbles Cyrillic in .conf
    $lines = [System.IO.File]::ReadAllLines($ConfFile, (New-Object System.Text.UTF8Encoding $false))
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash).Trim() }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim().Trim('"')
        if ($known -contains $key) {
            $map[$key] = $val
        }
    }
    return $map
}

function CfgValue {
    param(
        [hashtable]$Map,
        [string]$Name
    )
    if ($Map.ContainsKey($Name)) {
        return [string]$Map[$Name]
    }
    return ''
}

function Select-ConfFile {
    $candidates = @(
        Get-ChildItem -LiteralPath $ScriptDir -Filter '*.conf' -File -ErrorAction SilentlyContinue |
            Sort-Object Name
    )
    if ($candidates.Count -eq 0) {
        $script:ConfFile = Join-Path $ScriptDir 'git_ssh.conf'
        return
    }
    if ($candidates.Count -eq 1) {
        $script:ConfFile = $candidates[0].FullName
        return
    }

    Write-Log 'Найдено несколько конфигов:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Log ('  {0}) {1}' -f ($i + 1), $candidates[$i].Name)
    }
    while ($true) {
        $choice = "$(Read-Host ('Выберите номер [1-{0}]' -f $candidates.Count))".Trim()
        if ($choice -match '^[1-9][0-9]*$') {
            $num = [int]$choice
            if ($num -ge 1 -and $num -le $candidates.Count) {
                $script:ConfFile = $candidates[$num - 1].FullName
                return
            }
        }
        Write-Log ('Введите число от 1 до {0}.' -f $candidates.Count)
    }
}

function Load-OrInitConfig {
    $hostName = $DefaultHost
    $port = $DefaultPort
    $remote = $DefaultRemote
    $keyDir = $DefaultKeyDir
    $keyFile = $DefaultKeyFile
    $keyType = $DefaultKeyType
    $updateCfg = 'no'
    $savePass = 'no'
    $keyPass = ''
    $userName = ''
    $userEmail = ''

    if (Test-Path -LiteralPath $ConfFile) {
        $map = Get-ConfMap
        $hostName = CfgValue $map 'GIT_HOST'
        $port = CfgValue $map 'GIT_PORT'
        $remote = CfgValue $map 'GIT_REMOTE'
        $keyDir = CfgValue $map 'KEY_DIR'
        $keyFile = CfgValue $map 'KEY_FILE'
        $keyType = CfgValue $map 'KEY_TYPE'
        $updateCfg = CfgValue $map 'UPDATE_USER_SSH_CONFIG'
        $savePass = CfgValue $map 'SAVE_PASSPHRASE'
        $keyPass = CfgValue $map 'KEY_PASSPHRASE'
        $userName = CfgValue $map 'GIT_USER_NAME'
        $userEmail = CfgValue $map 'GIT_USER_EMAIL'
        if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = CfgValue $map 'GITLAB_HOST' }
        if ([string]::IsNullOrWhiteSpace($port)) { $port = CfgValue $map 'GITLAB_PORT' }
    }
    else {
        Write-Log ("Конфиг не найден: {0}" -f $ConfFile)
        Write-Log 'Создадим файл. Enter - значение по умолчанию.'
    }

    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $DefaultHost }
    if ([string]::IsNullOrWhiteSpace($port)) { $port = $DefaultPort }
    if ([string]::IsNullOrWhiteSpace($keyDir)) { $keyDir = $DefaultKeyDir }
    if ([string]::IsNullOrWhiteSpace($keyFile)) { $keyFile = $DefaultKeyFile }
    if ([string]::IsNullOrWhiteSpace($keyType)) { $keyType = $DefaultKeyType }
    if ([string]::IsNullOrWhiteSpace($updateCfg)) { $updateCfg = 'no' }
    if ([string]::IsNullOrWhiteSpace($savePass)) { $savePass = 'no' }
    if ([string]::IsNullOrWhiteSpace($remote) -and -not (Test-Path -LiteralPath $ConfFile)) {
        $remote = $DefaultRemote
    }

    $script:GitHost = $hostName
    $script:GitPort = $port
    $script:GitRemote = $remote
    $script:KeyDirRel = $keyDir
    $script:KeyFile = $keyFile
    $script:KeyType = $keyType
    $script:UpdateUserSshConfig = $updateCfg
    $script:SavePassphrase = $savePass
    $script:KeyPassphrase = $keyPass
    $script:GitUserName = $userName
    $script:GitUserEmail = $userEmail
}

function Read-Parameters {
    Write-Host ''
    Write-Log '=== Параметры подключения ==='
    Write-Log 'Enter оставляет значение в скобках (из конфига или по умолчанию).'
    Write-Host ''

    $script:GitHost = Read-PromptDefault 'Git host' $script:GitHost
    $script:GitPort = Read-PromptDefault 'SSH port' $script:GitPort
    $script:GitRemote = Read-PromptDefault 'GIT_REMOTE (пусто = не проверять репозиторий)' $script:GitRemote
    $script:KeyDirRel = Read-PromptDefault 'Каталог ключа и скриптов (относительно места запуска)' $script:KeyDirRel
    $script:KeyFile = Read-PromptDefault 'Имя файла ключа' $script:KeyFile
    $script:KeyType = Read-PromptDefault 'Тип ключа' $script:KeyType
    $script:UpdateUserSshConfig = Read-PromptDefault 'Писать Host в ~/.ssh/config (yes/no)' $script:UpdateUserSshConfig

    if ([string]::IsNullOrWhiteSpace($script:GitHost)) { Die 'GIT_HOST пуст.' }
    if ([string]::IsNullOrWhiteSpace($script:GitPort)) { Die 'GIT_PORT пуст.' }
    if ([string]::IsNullOrWhiteSpace($script:KeyDirRel)) { $script:KeyDirRel = $DefaultKeyDir }
    if ([string]::IsNullOrWhiteSpace($script:KeyFile)) { $script:KeyFile = $DefaultKeyFile }
    if ([string]::IsNullOrWhiteSpace($script:KeyType)) { $script:KeyType = $DefaultKeyType }
    if ([string]::IsNullOrWhiteSpace($script:UpdateUserSshConfig)) { $script:UpdateUserSshConfig = 'no' }

    $script:GitName = Read-PromptRequired 'Имя (для Git)' $script:GitUserName
    $script:GitEmail = Read-PromptRequired 'Email (для Git и SSH-ключа)' $script:GitUserEmail
    $script:GitUserName = $script:GitName
    $script:GitUserEmail = $script:GitEmail

    Write-ConfFile
    Write-Log ("Записан конфиг: {0}" -f $ConfFile)
    Write-Host ''

    $sshDir = Expand-LaunchPath $script:KeyDirRel
    $script:SshDir = $sshDir
    $script:KeyPath = Join-Path $sshDir $script:KeyFile
    $script:KnownHosts = Join-Path $sshDir 'known_hosts'
    $script:ProjectSshConfig = Join-Path $sshDir 'config'
    $script:OutGitUser = Join-Path $sshDir '.git-user'
    $script:HomeSshConfig = Join-Path $env:USERPROFILE '.ssh\config'
    $script:GitLabSshKeysUrl = 'https://{0}/-/user_settings/ssh_keys' -f $script:GitHost
}

function Get-SshHostBlock {
    return @(
        ('Host {0}' -f $script:GitHost),
        ('  HostName {0}' -f $script:GitHost),
        ('  User {0}' -f $SshGitLogin),
        ('  Port {0}' -f $script:GitPort),
        ('  IdentityFile {0}' -f ($script:KeyPath.Replace('\', '/'))),
        '  IdentitiesOnly yes',
        '  AddKeysToAgent yes',
        ('  UserKnownHostsFile {0}' -f ($script:KnownHosts.Replace('\', '/'))),
        '  StrictHostKeyChecking accept-new'
    ) -join "`n"
}

function Test-RequiredCommands {
    $missing = @()
    foreach ($cmd in @('git', 'ssh', 'ssh-keygen')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missing += $cmd
        }
    }
    if ($missing.Count -gt 0) {
        Die ("Не найдены команды: {0}. Установите Git for Windows (вместе с OpenSSH) или OpenSSH Client." -f ($missing -join ', '))
    }
}

function Show-PublicKeyInstructions {
    $pubPath = $script:KeyPath + '.pub'
    Write-Host ''
    Write-Log 'Скопируйте публичный ключ (именно файл .pub):'
    Write-Log ("  Get-Content {0}" -f $pubPath)
    Write-Host '------------------------------------------------------------------------'
    Get-Content -LiteralPath $pubPath
    Write-Host '------------------------------------------------------------------------'
    Write-Host ''
    Write-Log ("Добавьте ключ в GitLab ({0}):" -f $script:GitHost)
    Write-Log ("  1. User Settings → SSH Keys: {0}" -f $script:GitLabSshKeysUrl)
    Write-Log ("  2. Вставьте содержимое {0} в поле Key" -f $pubPath)
    Write-Log '  3. Нажмите Add key'
    Write-Host ''
    Read-Host 'Нажмите Enter, когда ключ добавлен в GitLab' | Out-Null
}

function ConvertTo-PlainText {
    param([Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Protect-PrivateKey {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "${env:USERNAME}:R" | Out-Null
}

function ConvertTo-CommandLineArgument {
    param([string]$Value)

    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
        }
        elseif ($ch -eq '"') {
            [void]$sb.Append('\', ($slashes * 2 + 1))
            [void]$sb.Append('"')
            $slashes = 0
        }
        else {
            if ($slashes -gt 0) {
                [void]$sb.Append('\', $slashes)
                $slashes = 0
            }
            [void]$sb.Append($ch)
        }
    }
    if ($slashes -gt 0) { [void]$sb.Append('\', ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-SshKeygen {
    param([string[]]$ArgumentList)

    $sshKeygen = (Get-Command ssh-keygen -ErrorAction Stop).Source
    $parts = foreach ($arg in $ArgumentList) { ConvertTo-CommandLineArgument $arg }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $sshKeygen
    $psi.Arguments = ($parts -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{
        Code = $proc.ExitCode
        Out = $stdout
        Err = $stderr
    }
}

function New-UnlockedKeyCopy {
    param(
        [string]$KeyPath,
        [string]$Passphrase
    )

    # SSH_ASKPASS здесь не подходит: .cmd OpenSSH не запускает, а свой askpass.exe
    # блокирует политика управления приложениями (CreateProcessW error 4551).
    # Временная копия без passphrase позволяет вызвать ssh. Исходный ключ не меняется.
    $dir = Join-Path $env:TEMP ('git-ssh-unlock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $copy = Join-Path $dir (Split-Path -Leaf $KeyPath)
    Copy-Item -LiteralPath $KeyPath -Destination $copy -Force
    $changed = Invoke-SshKeygen @('-p', '-f', $copy, '-P', $Passphrase, '-N', '')
    if ($changed.Code -ne 0) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        $detail = ($changed.Err + $changed.Out)
        if ($detail -match 'incorrect passphrase') {
            Die 'Сохранённая passphrase не подошла к ключу. Проверьте KEY_PASSPHRASE в конфиге.'
        }
        Die 'Не удалось подготовить ключ для SSH.'
    }
    Protect-PrivateKey -Path $copy
    return @{ Dir = $dir; Key = $copy }
}

function Unlock-SshKey {
    if (-not (Test-FlagYes $script:SavePassphrase) -or [string]::IsNullOrEmpty($script:KeyPassphrase)) {
        return
    }
    if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) {
        return
    }

    $service = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        try {
            Start-Service -Name ssh-agent -ErrorAction Stop
        }
        catch {
            Write-Log 'Служба ssh-agent не запущена — passphrase ключа не разблокирован автоматически.'
            return
        }
    }

    $unlock = $null
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $unlock = New-UnlockedKeyCopy -KeyPath $script:KeyPath -Passphrase $script:KeyPassphrase
        & ssh-add $unlock.Key | Out-Null
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $unlock) {
            Remove-Item -LiteralPath $unlock.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-ServerConnection {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $unlock = $null
    try {
        Write-Log ("Проверка SSH {0}@{1}:{2} ..." -f $SshGitLogin, $script:GitHost, $script:GitPort)
        $keyForSsh = $script:KeyPath
        if ((Test-FlagYes $script:SavePassphrase) -and -not [string]::IsNullOrEmpty($script:KeyPassphrase)) {
            $unlock = New-UnlockedKeyCopy -KeyPath $script:KeyPath -Passphrase $script:KeyPassphrase
            $keyForSsh = $unlock.Key
        }
        $target = '{0}@{1}' -f $SshGitLogin, $script:GitHost
        $sshArgs = @(
            '-o', 'BatchMode=yes'
            '-i', $keyForSsh
            '-p', $script:GitPort
            '-o', 'IdentitiesOnly=yes'
            '-o', ('UserKnownHostsFile={0}' -f $script:KnownHosts)
            '-o', 'StrictHostKeyChecking=accept-new'
            '-o', 'PreferredAuthentications=publickey'
            '-o', 'NumberOfPasswordPrompts=0'
            '-T', $target
        )
        $output = & ssh @sshArgs 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $_.Exception.Message
                }
                else {
                    $_.ToString()
                }
            }
        $text = ($output -join [Environment]::NewLine)
        if ($text) {
            Write-Host $text
        }
        Write-Host ''
        if ($text -match '(?i)welcome|successfully authenticated') {
            Write-Log 'Доступ к серверу есть.'
            return $true
        }
        Write-Log 'Подключение не удалось.'
        Write-Log 'Пароль учётной записи GitLab для SSH не нужен — только ключ.'
        Write-Log 'Проверьте, что в GitLab вставлен текущий файл:'
        Write-Log ('  {0}' -f ($script:KeyPath + '.pub'))
        Write-Log ("Страница ключей: {0}" -f $script:GitLabSshKeysUrl)
        return $false
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $unlock) {
            Remove-Item -LiteralPath $unlock.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-RepoAccess {
    if ([string]::IsNullOrWhiteSpace($script:GitRemote)) {
        Write-Log 'GIT_REMOTE пуст - проверка репозитория пропущена.'
        return
    }
    Write-Log ("Проверка репозитория: {0}" -f $script:GitRemote)
    $cfgPosix = $script:ProjectSshConfig.Replace('\', '/')
    $env:GIT_SSH_COMMAND = 'ssh -F "{0}"' -f $cfgPosix
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git ls-remote $script:GitRemote HEAD
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Доступ к репозиторию есть.'
            return
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    Write-Log 'Предупреждение: git ls-remote не удался. Доступ к серверу уже проверен.'
}

function Read-RetryOrQuit {
    Write-Host ''
    Write-Host 'Enter = проверить снова, Esc/Q = выход без записи скриптов: ' -NoNewline
    try {
        $key = [Console]::ReadKey($true)
        Write-Host ''
        if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') {
            return $false
        }
        return $true
    }
    catch {
        Write-Host ''
        $reply = Read-Host 'Enter = повтор, q = выход'
        if ($reply -match '^[qQ]') {
            return $false
        }
        return $true
    }
}

function Ensure-UserSshConfig {
    if (-not (Test-FlagYes $script:UpdateUserSshConfig)) {
        Write-Log ("UPDATE_USER_SSH_CONFIG=no - {0} не меняем." -f $script:HomeSshConfig)
        return
    }

    $sshHome = Join-Path $env:USERPROFILE '.ssh'
    if (-not (Test-Path -LiteralPath $sshHome)) {
        New-Item -ItemType Directory -Path $sshHome -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:HomeSshConfig)) {
        New-Item -ItemType File -Path $script:HomeSshConfig -Force | Out-Null
    }

    $bytes = [System.IO.File]::ReadAllBytes($script:HomeSshConfig)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        [System.IO.File]::WriteAllBytes($script:HomeSshConfig, $bytes[3..($bytes.Length - 1)])
    }

    $configText = Get-Content -LiteralPath $script:HomeSshConfig -Raw -ErrorAction SilentlyContinue
    $hostPattern = '(?m)^Host\s+' + [regex]::Escape($script:GitHost) + '\s*$'
    if ($configText -and $configText -match $hostPattern) {
        Write-Log ("Запись для {0} уже есть в {1}" -f $script:GitHost, $script:HomeSshConfig)
        return
    }

    $entry = "`r`n" + ((Get-SshHostBlock) -replace "`n", "`r`n")
    [System.IO.File]::AppendAllText($script:HomeSshConfig, $entry, (New-Object System.Text.UTF8Encoding $false))
    Write-Log ("Добавлена запись в {0}" -f $script:HomeSshConfig)
}

function Get-ConnectShTemplate {
    return @'
#!/usr/bin/env bash
# Generated by git_ssh_setup. Values from git_ssh_ambiot.conf at generation time.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_HOST="__GIT_HOST__"
GIT_PORT="__GIT_PORT__"
KEY_FILE="__KEY_FILE__"
GIT_REMOTE="__GIT_REMOTE__"
KEY_PATH="$SCRIPT_DIR/$KEY_FILE"
PUB_PATH="${KEY_PATH}.pub"
KNOWN_HOSTS="$SCRIPT_DIR/known_hosts"
SSH_CONFIG="$SCRIPT_DIR/config"
SSH_USER=git

usage() {
  cat <<'HELP'
Usage: git-ssh.sh <command> [args]
  test         ssh -T to the Git server
  test-repo    git ls-remote to GIT_REMOTE (optional)
  pub          print the public key
  git <args>   run git with this key
HELP
}

die() { echo "ERROR: $*" >&2; exit 1; }

export_git_ssh() {
  [[ -f "$KEY_PATH" ]] || die "Нет ключа: $KEY_PATH"
  if [[ -f "$SSH_CONFIG" ]]; then
    export GIT_SSH_COMMAND="ssh -F \"$SSH_CONFIG\""
  else
    export GIT_SSH_COMMAND="ssh -i \"$KEY_PATH\" -p $GIT_PORT -o IdentitiesOnly=yes -o UserKnownHostsFile=\"$KNOWN_HOSTS\" -o StrictHostKeyChecking=accept-new"
  fi
}

cmd_pub() {
  [[ -f "$PUB_PATH" ]] || die "Нет публичного ключа: $PUB_PATH"
  echo "Public SSH key ($PUB_PATH):"
  echo "------------------------------------------------------------------------"
  cat "$PUB_PATH"
  echo "------------------------------------------------------------------------"
}

cmd_test() {
  [[ -f "$KEY_PATH" ]] || die "Нет ключа: $KEY_PATH"
  echo "Checking SSH to ${SSH_USER}@${GIT_HOST}:${GIT_PORT} ..."
  local output
  if [[ -f "$SSH_CONFIG" ]]; then
    output="$(ssh -F "$SSH_CONFIG" -T "${SSH_USER}@${GIT_HOST}" 2>&1 || true)"
  else
    output="$(ssh -i "$KEY_PATH" -p "$GIT_PORT" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -T "${SSH_USER}@${GIT_HOST}" 2>&1 || true)"
  fi
  printf '%s\n' "$output"
  echo
  if echo "$output" | grep -qiE 'welcome|successfully authenticated'; then
    echo "SSH authentication succeeded."
    return 0
  fi
  echo "Authentication did not succeed. Add the public key in GitLab and retry."
  return 1
}

cmd_test_repo() {
  [[ -n "$GIT_REMOTE" ]] || die "GIT_REMOTE пуст - нечего проверять."
  export_git_ssh
  echo "Checking repository: $GIT_REMOTE"
  git ls-remote "$GIT_REMOTE" HEAD
}

cmd="${1:-}"
shift || true
case "$cmd" in
  test) cmd_test ;;
  test-repo) cmd_test_repo ;;
  pub) cmd_pub ;;
  git)
    [[ $# -gt 0 ]] || die "Нужны аргументы git. Пример: $0 git status"
    export_git_ssh
    git "$@"
    ;;
  -h|--help|help|"") usage; [[ -n "$cmd" ]] ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
'@
}

function Get-ConnectPs1Template {
    return @'
# Generated by git_ssh_setup. Values from git_ssh_ambiot.conf at generation time.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($env:GIT_SSH_SETUP_SELF) -or -not (Test-Path -LiteralPath $env:GIT_SSH_SETUP_SELF)) {
    Write-Host "ERROR: Не задан путь к скрипту. Запускайте git-ssh.cmd." -ForegroundColor Red
    exit 1
}
$ScriptDir = Split-Path -Parent $env:GIT_SSH_SETUP_SELF
$GitHost = "__GIT_HOST__"
$GitPort = "__GIT_PORT__"
$KeyFile = "__KEY_FILE__"
$GitRemote = "__GIT_REMOTE__"
$ConfFile = "__CONF_FILE__"
$KeyPath = Join-Path $ScriptDir $KeyFile
$PubPath = $KeyPath + ".pub"
$KnownHosts = Join-Path $ScriptDir "known_hosts"
$SshConfig = Join-Path $ScriptDir "config"
$SshUser = "git"

function Show-Usage {
    @"
Usage: git-ssh.cmd <command> [args]
  test         ssh -T to the Git server
  test-repo    git ls-remote to GIT_REMOTE (optional)
  pub          print the public key
  git <args>   run git with this key
"@
}

function Die([string]$Message) {
    Write-Host ("ERROR: " + $Message) -ForegroundColor Red
    exit 1
}

function ConvertTo-CommandLineArgument {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++ }
        elseif ($ch -eq '"') {
            [void]$sb.Append('\', ($slashes * 2 + 1))
            [void]$sb.Append('"')
            $slashes = 0
        }
        else {
            if ($slashes -gt 0) { [void]$sb.Append('\', $slashes); $slashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($slashes -gt 0) { [void]$sb.Append('\', ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-SavedPassphrase {
    if ([string]::IsNullOrWhiteSpace($ConfFile) -or -not (Test-Path -LiteralPath $ConfFile)) { return '' }
    $save = ''
    $pass = ''
    foreach ($raw in [System.IO.File]::ReadAllLines($ConfFile)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $name = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim().Trim('"')
        if ($name -eq 'SAVE_PASSPHRASE') { $save = $val }
        elseif ($name -eq 'KEY_PASSPHRASE') { $pass = $val }
    }
    if ($save.ToLowerInvariant() -in @('yes', 'true', '1', 'да', 'y')) { return $pass }
    return ''
}

function New-UnlockedKeyCopy {
    param([string]$SourcePath, [string]$Passphrase)
    $dir = Join-Path $env:TEMP ('git-ssh-unlock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $copy = Join-Path $dir (Split-Path -Leaf $SourcePath)
    Copy-Item -LiteralPath $SourcePath -Destination $copy -Force
    $sshKeygen = (Get-Command ssh-keygen -ErrorAction Stop).Source
    $argLine = @(
        (ConvertTo-CommandLineArgument '-p'),
        (ConvertTo-CommandLineArgument '-f'),
        (ConvertTo-CommandLineArgument $copy),
        (ConvertTo-CommandLineArgument '-P'),
        (ConvertTo-CommandLineArgument $Passphrase),
        (ConvertTo-CommandLineArgument '-N'),
        (ConvertTo-CommandLineArgument '')
    ) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $sshKeygen
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        if (($stderr + $stdout) -match 'incorrect passphrase') {
            Die 'Сохранённая passphrase не подошла к ключу. Проверьте KEY_PASSPHRASE в конфиге.'
        }
        Die 'Не удалось подготовить ключ для SSH.'
    }
    return @{ Dir = $dir; Key = $copy }
}

function Invoke-WithUnlockedKey {
    param([scriptblock]$Action)
    $pass = Get-SavedPassphrase
    $unlock = $null
    $identity = $KeyPath
    try {
        if (-not [string]::IsNullOrEmpty($pass)) {
            $unlock = New-UnlockedKeyCopy -SourcePath $KeyPath -Passphrase $pass
            $identity = $unlock.Key
        }
        & $Action $identity
    }
    finally {
        if ($null -ne $unlock) {
            Remove-Item -LiteralPath $unlock.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-GitSshEnvironment {
    param([string]$IdentityPath)
    if (-not (Test-Path -LiteralPath $IdentityPath)) {
        Die ("Нет ключа: {0}" -f $IdentityPath)
    }
    $keyPosix = $IdentityPath.Replace('\', '/')
    $knownPosix = $KnownHosts.Replace('\', '/')
    $env:GIT_SSH_COMMAND = 'ssh -i "{0}" -p {1} -o IdentitiesOnly=yes -o UserKnownHostsFile="{2}" -o StrictHostKeyChecking=accept-new' -f $keyPosix, $GitPort, $knownPosix
}

switch ($Command.ToLowerInvariant()) {
    "test" {
        if (-not (Test-Path -LiteralPath $KeyPath)) { Die ("Нет ключа: {0}" -f $KeyPath) }
        Write-Host ("Checking SSH to {0}@{1}:{2} ..." -f $SshUser, $GitHost, $GitPort)
        Invoke-WithUnlockedKey {
            param($IdentityPath)
            $script:SshOutput = & ssh -i $IdentityPath -p $GitPort -o IdentitiesOnly=yes -o BatchMode=yes -o ("UserKnownHostsFile={0}" -f $KnownHosts) -o StrictHostKeyChecking=accept-new -T ("{0}@{1}" -f $SshUser, $GitHost) 2>&1 | Out-String
        }
        $output = $script:SshOutput
        Write-Host $output.TrimEnd()
        Write-Host ""
        if ($output -match "(?i)welcome|successfully authenticated") {
            Write-Host "SSH authentication succeeded." -ForegroundColor Green
        }
        else {
            Write-Host "Authentication did not succeed. Add the public key in GitLab and retry." -ForegroundColor Yellow
            exit 1
        }
    }
    "test-repo" {
        if ([string]::IsNullOrWhiteSpace($GitRemote)) { Die "GIT_REMOTE пуст - нечего проверять." }
        Write-Host ("Checking repository: {0}" -f $GitRemote)
        Invoke-WithUnlockedKey {
            param($IdentityPath)
            Set-GitSshEnvironment -IdentityPath $IdentityPath
            & git ls-remote $GitRemote HEAD
            $script:GitExit = $LASTEXITCODE
        }
        exit $script:GitExit
    }
    "pub" {
        if (-not (Test-Path -LiteralPath $PubPath)) { Die ("Нет публичного ключа: {0}" -f $PubPath) }
        Write-Host ("Public SSH key ({0}):" -f $PubPath)
        Write-Host "------------------------------------------------------------------------"
        Get-Content -LiteralPath $PubPath
        Write-Host "------------------------------------------------------------------------"
    }
    "git" {
        if ($null -eq $Rest -or $Rest.Count -eq 0) { Die "Нужны аргументы git. Пример: git-ssh.cmd git status" }
        Invoke-WithUnlockedKey {
            param($IdentityPath)
            Set-GitSshEnvironment -IdentityPath $IdentityPath
            & git @Rest
            $script:GitExit = $LASTEXITCODE
        }
        exit $script:GitExit
    }
    { $_ -in @("", "-h", "--help", "help") } {
        Show-Usage
        if ($Command -eq "") { exit 1 }
    }
    default {
        Show-Usage
        Die "Unknown command: $Command"
    }
}
'@
}

function Expand-ConnectTemplate {
    param([string]$Template)
    return $Template.
        Replace('__GIT_HOST__', $script:GitHost).
        Replace('__GIT_PORT__', $script:GitPort).
        Replace('__KEY_FILE__', $script:KeyFile).
        Replace('__GIT_REMOTE__', $script:GitRemote).
        Replace('__CONF_FILE__', $script:ConfFile)
}

function Get-HybridCmdPrefix {
    $extract = @(
        '$utf8=New-Object System.Text.UTF8Encoding $true'
        '$raw=[System.IO.File]::ReadAllText($env:GIT_SSH_SETUP_SELF, (New-Object System.Text.UTF8Encoding $false))'
        '$m=[regex]::Match($raw, ''(?m)^# >>> POWERSHELL\s*$'')'
        'if(-not $m.Success){ throw ''POWERSHELL marker not found in ''+$env:GIT_SSH_SETUP_SELF }'
        '[System.IO.File]::WriteAllText($env:GIT_SSH_SETUP_PS1, $raw.Substring($m.Index+$m.Length), $utf8)'
    ) -join '; '
    return @(
        '@echo off'
        'setlocal EnableExtensions'
        'set "GIT_SSH_SETUP_SELF=%~f0"'
        'set "GIT_SSH_SETUP_PS1=%TEMP%\git_ssh_setup_%RANDOM%%RANDOM%.ps1"'
        ('powershell -NoProfile -ExecutionPolicy Bypass -Command "{0}"' -f $extract)
        'if errorlevel 1 exit /b %ERRORLEVEL%'
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%GIT_SSH_SETUP_PS1%" %*'
        'set "ERR=%ERRORLEVEL%"'
        'del /f /q "%GIT_SSH_SETUP_PS1%" >nul 2>&1'
        'endlocal & exit /b %ERR%'
        ''
        '# >>> POWERSHELL'
        ''
    ) -join "`r`n"
}

function Write-GeneratedOutputs {
    if (-not (Test-Path -LiteralPath $script:SshDir)) {
        New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null
    }

    $header = "# Generated by environment/git/git_ssh_setup. Source: git_ssh_ambiot.conf`n"
    $text = $header + (Get-SshHostBlock) + "`n"
    [System.IO.File]::WriteAllText($script:ProjectSshConfig, $text, (New-Object System.Text.UTF8Encoding $false))
    Write-Log ("Конфиг подключения: {0}" -f $script:ProjectSshConfig)

    $shPath = Join-Path $script:SshDir 'git-ssh.sh'
    $cmdPath = Join-Path $script:SshDir 'git-ssh.cmd'
    [System.IO.File]::WriteAllText($shPath, (Expand-ConnectTemplate (Get-ConnectShTemplate)), (New-Object System.Text.UTF8Encoding $false))
    $cmdBody = (Expand-ConnectTemplate (Get-ConnectPs1Template)).TrimStart([char]0xFEFF)
    $cmdText = (Get-HybridCmdPrefix) + $cmdBody
    if (-not $cmdText.EndsWith("`r`n") -and -not $cmdText.EndsWith("`n")) { $cmdText += "`r`n" }
    [System.IO.File]::WriteAllText($cmdPath, $cmdText, (New-Object System.Text.UTF8Encoding $false))
    Write-Log ("Скрипт: {0}" -f $shPath)
    Write-Log ("Скрипт: {0}" -f $cmdPath)

    $gitUserText = "[user]`n`tname = {0}`n`temail = {1}`n" -f $script:GitName, $script:GitEmail
    [System.IO.File]::WriteAllText($script:OutGitUser, $gitUserText, (New-Object System.Text.UTF8Encoding $false))
    Write-Log ("Git identity: {0}" -f $script:OutGitUser)
}

Write-Host '=== Настройка Git SSH ==='
Test-RequiredCommands
Select-ConfFile
Load-OrInitConfig

Write-Log ("Конфиг: {0}" -f $ConfFile)
Write-Log ("Каталог запуска: {0}" -f $LaunchDir)
Read-Parameters

Write-Host ''
Write-Log ("Ключ и выход: {0}" -f $script:SshDir)
git config --global user.name $script:GitName
git config --global user.email $script:GitEmail
Write-Log ("Git: user.name = {0}" -f $script:GitName)
Write-Log ("Git: user.email = {0}" -f $script:GitEmail)

if (-not (Test-Path -LiteralPath $script:SshDir)) {
    New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null
}

if (Test-Path -LiteralPath $script:KeyPath) {
    Write-Host ''
    Write-Log ("Ключ уже есть: {0}" -f $script:KeyPath)
}
else {
    Write-Host ''
    $script:SavePassphrase = Read-PromptDefault 'Сохранять passphrase в конфиг (yes/no)' $script:SavePassphrase
    if ([string]::IsNullOrWhiteSpace($script:SavePassphrase)) { $script:SavePassphrase = 'no' }

    $savedPass = ''
    if (Test-FlagYes $script:SavePassphrase) {
        $savedPass = $script:KeyPassphrase
    }
    if ($savedPass) {
        $pass1 = ConvertTo-PlainText -SecureString (Read-Host 'Passphrase для нового SSH-ключа (Enter = из конфига)' -AsSecureString)
        if ([string]::IsNullOrEmpty($pass1)) {
            $pass1 = $savedPass
        }
        else {
            $pass2 = ConvertTo-PlainText -SecureString (Read-Host 'Повторите passphrase' -AsSecureString)
            if ($pass1 -ne $pass2) {
                Die 'Passphrase не совпадают.'
            }
        }
    }
    else {
        $pass1 = ConvertTo-PlainText -SecureString (Read-Host 'Passphrase для нового SSH-ключа (Enter = без пароля)' -AsSecureString)
        $pass2 = ConvertTo-PlainText -SecureString (Read-Host 'Повторите passphrase' -AsSecureString)
        if ($pass1 -ne $pass2) {
            Die 'Passphrase не совпадают.'
        }
    }

    if (Test-FlagYes $script:SavePassphrase) {
        $script:KeyPassphrase = $pass1
    }
    else {
        $script:KeyPassphrase = ''
    }
    Write-ConfFile
    Write-Log ("Записан конфиг: {0}" -f $ConfFile)

    $created = Invoke-SshKeygen @(
        '-t', $script:KeyType,
        '-C', $script:GitEmail,
        '-f', $script:KeyPath,
        '-N', $pass1
    )
    if ($created.Code -ne 0) {
        Die 'ssh-keygen не удался.'
    }
}

Protect-PrivateKey -Path $script:KeyPath
Show-PublicKeyInstructions

Write-Host ''
Unlock-SshKey
while (-not (Test-ServerConnection)) {
    if (-not (Read-RetryOrQuit)) {
        Die ("Выход. Скрипт запуска, config и .git-user не записаны (ключ уже в {0})." -f $script:SshDir)
    }
}

Write-GeneratedOutputs
Ensure-UserSshConfig

if (-not [string]::IsNullOrWhiteSpace($script:GitRemote)) {
    Write-Host ''
    $repoAns = Read-PromptDefault ("Проверить доступ к репозиторию {0}? (y/N)" -f $script:GitRemote) 'N'
    if (Test-FlagYes $repoAns) {
        Test-RepoAccess
    }
    else {
        Write-Log ("Проверка репозитория пропущена. Позже: {0}" -f (Join-Path $script:SshDir 'git-ssh.cmd test-repo'))
    }
}

Write-Host ''
Write-Log 'Готово. Дальше:'
Write-Log ("  {0}" -f (Join-Path $script:SshDir 'git-ssh.cmd test'))
Write-Log ("  {0}" -f (Join-Path $script:SshDir 'git-ssh.cmd pub'))
if (-not [string]::IsNullOrWhiteSpace($script:GitRemote)) {
    Write-Log ("  {0}" -f (Join-Path $script:SshDir 'git-ssh.cmd test-repo'))
}
Write-Log ("  {0}" -f (Join-Path $script:SshDir 'git-ssh.cmd git status'))
Write-Log ("  ssh -F {0} -T {1}@{2}" -f $script:ProjectSshConfig, $SshGitLogin, $script:GitHost)
Write-Host ''
Read-Host 'Нажмите Enter для выхода' | Out-Null
