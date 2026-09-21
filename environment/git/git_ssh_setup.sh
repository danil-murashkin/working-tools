#!/usr/bin/env bash
# git_ssh_setup.sh — Linux/WSL/macOS
# Параметры: *.conf рядом со скриптом (если несколько — выбор по номеру).
# Выход: KEY_DIR относительно каталога запуска.
#
#   bash environment/git/git_ssh_setup.sh
#   chmod +x git_ssh_setup.sh && ./git_ssh_setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_DIR="$(pwd)"
CONF_FILE=""
SSH_GIT_LOGIN=git

DEFAULT_HOST="gitlab.example.com"
DEFAULT_PORT="22"
DEFAULT_REMOTE="git@gitlab.example.com:group/project.git"
DEFAULT_KEY_DIR="ssh-connect"
DEFAULT_KEY_FILE="id_ed25519"
DEFAULT_KEY_TYPE="ed25519"

KNOWN_KEYS=(
  GIT_HOST GIT_PORT GIT_REMOTE
  KEY_DIR KEY_FILE KEY_TYPE
  GIT_USER_NAME GIT_USER_EMAIL
  UPDATE_USER_SSH_CONFIG SAVE_PASSPHRASE KEY_PASSPHRASE
  GITLAB_HOST GITLAB_PORT SSH_HOST_ALIAS
)

log() { printf '%s\n' "$*"; }
die() { log "$*" >&2; exit 1; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_known_key() {
  local name="$1" k
  for k in "${KNOWN_KEYS[@]}"; do
    [[ "$k" == "$name" ]] && return 0
  done
  return 1
}

flag_yes() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "yes" || "$v" == "true" || "$v" == "1" || "$v" == "да" || "$v" == "y" ]]
}

prompt_default() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " reply || true
  else
    read -r -p "${prompt}: " reply || true
  fi
  reply="$(trim "${reply:-}")"
  if [[ -z "$reply" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$reply"
  fi
}

expand_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf '%s' "${LAUNCH_DIR}/${DEFAULT_KEY_DIR}"
    return
  fi
  if [[ "$p" == "~" ]]; then
    printf '%s' "$HOME"
    return
  fi
  if [[ "$p" == "~/"* ]]; then
    printf '%s' "${HOME}/${p#~/}"
    return
  fi
  if [[ "$p" == /* || "$p" =~ ^[A-Za-z]:[\\/] ]]; then
    printf '%s' "$p"
    return
  fi
  printf '%s' "${LAUNCH_DIR}/${p}"
}

prompt_required() {
  local prompt="$1" default="${2:-}" reply
  while true; do
    reply="$(prompt_default "$prompt" "$default")"
    if [[ -n "$reply" ]]; then
      printf '%s' "$reply"
      return
    fi
    log "Значение не должно быть пустым."
  done
}

write_conf() {
  local pass_out=""
  if flag_yes "${SAVE_PASSPHRASE:-no}"; then
    pass_out="${KEY_PASSPHRASE:-}"
  fi
  {
    cat <<EOF
# Настройки Git SSH
GIT_HOST=${GIT_HOST}
GIT_PORT=${GIT_PORT}

# Опциональная проверка доступа к репозиторию (git ls-remote / test-repo). Пусто = не проверять.
GIT_REMOTE=${GIT_REMOTE}

# Ключ и выход setup — каталог относительно места запуска скрипта
KEY_DIR=${KEY_DIR}
KEY_FILE=${KEY_FILE}
KEY_TYPE=${KEY_TYPE}

# Имя и почта Git (обязательны, сохраняются при setup).
GIT_USER_NAME=${GIT_NAME}
GIT_USER_EMAIL=${GIT_EMAIL}

# Писать Host-блок в ~/.ssh/config (да/yes/true/1)
UPDATE_USER_SSH_CONFIG=${UPDATE_USER_SSH_CONFIG}

# Сохранять passphrase ключа в этот файл (да/yes/true/1). По умолчанию no.
SAVE_PASSPHRASE=${SAVE_PASSPHRASE}
EOF
    printf 'KEY_PASSPHRASE=%s\n' "$pass_out"
  } >"$CONF_FILE"
}

load_config_file() {
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || continue
    key="$(trim "${line%%=*}")"
    val="$(trim "${line#*=}")"
    val="${val#\"}"
    val="${val%\"}"
    is_known_key "$key" || continue
    printf -v "$key" '%s' "$val"
  done < "$CONF_FILE"
}

apply_aliases() {
  if [[ -z "${GIT_HOST:-}" && -n "${GITLAB_HOST:-}" ]]; then
    GIT_HOST="$GITLAB_HOST"
  fi
  if [[ -z "${GIT_PORT:-}" && -n "${GITLAB_PORT:-}" ]]; then
    GIT_PORT="$GITLAB_PORT"
  fi
}

select_conf_file() {
  local files=() sorted=() f i n choice
  shopt -s nullglob
  files=("$SCRIPT_DIR"/*.conf)
  shopt -u nullglob
  n=${#files[@]}

  if [[ "$n" -eq 0 ]]; then
    CONF_FILE="${SCRIPT_DIR}/git_ssh.conf"
    return
  fi
  if [[ "$n" -eq 1 ]]; then
    CONF_FILE="${files[0]}"
    return
  fi

  while IFS= read -r f; do
    sorted+=("$f")
  done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
  files=("${sorted[@]}")
  n=${#files[@]}

  log "Найдено несколько конфигов:"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    printf '  %s) %s\n' "$((i + 1))" "$(basename "${files[$i]}")"
    i=$((i + 1))
  done
  while true; do
    read -r -p "Выберите номер [1-${n}]: " choice || true
    choice="$(trim "${choice:-}")"
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice >= 1 && choice <= n)); then
      CONF_FILE="${files[$((choice - 1))]}"
      return
    fi
    log "Введите число от 1 до ${n}."
  done
}

load_or_init_config() {
  GIT_HOST=""
  GIT_PORT=""
  GIT_REMOTE=""
  KEY_DIR=""
  KEY_FILE=""
  KEY_TYPE=""
  GIT_USER_NAME=""
  GIT_USER_EMAIL=""
  UPDATE_USER_SSH_CONFIG=""
  SAVE_PASSPHRASE=""
  KEY_PASSPHRASE=""
  GITLAB_HOST=""
  GITLAB_PORT=""
  SSH_HOST_ALIAS=""
  CONF_EXISTS=0

  if [[ -f "$CONF_FILE" ]]; then
    CONF_EXISTS=1
    load_config_file
    apply_aliases
  else
    log "Конфиг не найден: $CONF_FILE"
    log "Создадим файл. Enter — значение по умолчанию."
  fi

  : "${GIT_HOST:=$DEFAULT_HOST}"
  : "${GIT_PORT:=$DEFAULT_PORT}"
  if [[ "$CONF_EXISTS" -eq 0 ]]; then
    : "${GIT_REMOTE:=$DEFAULT_REMOTE}"
  fi
  : "${KEY_DIR:=$DEFAULT_KEY_DIR}"
  : "${KEY_FILE:=$DEFAULT_KEY_FILE}"
  : "${KEY_TYPE:=$DEFAULT_KEY_TYPE}"
  : "${UPDATE_USER_SSH_CONFIG:=no}"
  : "${SAVE_PASSPHRASE:=no}"
}

prompt_parameters() {
  echo
  log "=== Параметры подключения ==="
  log "Enter оставляет значение в скобках (из конфига или по умолчанию)."
  echo
  GIT_HOST="$(prompt_default "Git host" "$GIT_HOST")"
  GIT_PORT="$(prompt_default "SSH port" "$GIT_PORT")"
  GIT_REMOTE="$(prompt_default "GIT_REMOTE (пусто = не проверять репозиторий)" "$GIT_REMOTE")"
  KEY_DIR="$(prompt_default "Каталог ключа и скриптов (относительно места запуска)" "$KEY_DIR")"
  KEY_FILE="$(prompt_default "Имя файла ключа" "$KEY_FILE")"
  KEY_TYPE="$(prompt_default "Тип ключа" "$KEY_TYPE")"
  UPDATE_USER_SSH_CONFIG="$(prompt_default "Писать Host в ~/.ssh/config (yes/no)" "$UPDATE_USER_SSH_CONFIG")"

  [[ -n "$GIT_HOST" ]] || die "GIT_HOST пуст."
  [[ -n "$GIT_PORT" ]] || die "GIT_PORT пуст."
  [[ -n "$KEY_DIR" ]] || KEY_DIR="$DEFAULT_KEY_DIR"
  [[ -n "$KEY_FILE" ]] || KEY_FILE="$DEFAULT_KEY_FILE"
  [[ -n "$KEY_TYPE" ]] || KEY_TYPE="$DEFAULT_KEY_TYPE"
  [[ -n "$UPDATE_USER_SSH_CONFIG" ]] || UPDATE_USER_SSH_CONFIG="no"

  GIT_NAME="$(prompt_required "Имя (для Git)" "${GIT_USER_NAME:-}")"
  GIT_EMAIL="$(prompt_required "Email (для Git и SSH-ключа)" "${GIT_USER_EMAIL:-}")"

  write_conf
  log "Записан конфиг: $CONF_FILE"

  SSH_DIR="$(expand_path "$KEY_DIR")"
  KEY_PATH="${SSH_DIR}/${KEY_FILE}"
  KNOWN_HOSTS="${SSH_DIR}/known_hosts"
  PROJECT_SSH_CONFIG="${SSH_DIR}/config"
  OUT_GIT_USER="${SSH_DIR}/.git-user"
  HOME_SSH_CONFIG="${HOME}/.ssh/config"
  GITLAB_SSH_KEYS_URL="https://${GIT_HOST}/-/user_settings/ssh_keys"
}

ssh_host_block() {
  cat <<EOF
Host ${GIT_HOST}
  HostName ${GIT_HOST}
  User ${SSH_GIT_LOGIN}
  Port ${GIT_PORT}
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
  AddKeysToAgent yes
  UserKnownHostsFile ${KNOWN_HOSTS}
  StrictHostKeyChecking accept-new
EOF
}

require_commands() {
  local missing=() cmd
  for cmd in git ssh ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Не найдены команды: ${missing[*]}. Установите git и openssh-client."
  fi
}

show_public_key_instructions() {
  echo
  log "Скопируйте публичный ключ (именно файл .pub):"
  log "  cat ${KEY_PATH}.pub"
  echo "------------------------------------------------------------------------"
  cat "${KEY_PATH}.pub"
  echo "------------------------------------------------------------------------"
  echo
  log "Добавьте ключ в GitLab (${GIT_HOST}):"
  log "  1. User Settings → SSH Keys: ${GITLAB_SSH_KEYS_URL}"
  log "  2. Вставьте содержимое ${KEY_PATH}.pub в поле Key"
  log "  3. Нажмите Add key"
  echo
  read -r -p "Нажмите Enter, когда ключ добавлен в GitLab..." || true
}

unlock_ssh_key() {
  if ! flag_yes "${SAVE_PASSPHRASE:-no}" || [[ -z "${KEY_PASSPHRASE:-}" ]]; then
    return 0
  fi
  command -v ssh-add >/dev/null 2>&1 || return 0
  command -v ssh-agent >/dev/null 2>&1 || return 0
  eval "$(ssh-agent -s)" >/dev/null

  local askpass
  askpass="$(mktemp "${TMPDIR:-/tmp}/git-ssh-askpass.XXXXXX")"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'printf %%s %q\n' "$KEY_PASSPHRASE"
  } >"$askpass"
  chmod 700 "$askpass"
  DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
    ssh-add "$KEY_PATH" </dev/null >/dev/null 2>&1 || true
  rm -f "$askpass"
}

test_server() {
  log "Проверка SSH ${SSH_GIT_LOGIN}@${GIT_HOST}:${GIT_PORT} ..."
  local output askpass=""
  if flag_yes "${SAVE_PASSPHRASE:-no}" && [[ -n "${KEY_PASSPHRASE:-}" ]]; then
    askpass="$(mktemp "${TMPDIR:-/tmp}/git-ssh-askpass.XXXXXX")"
    {
      printf '%s\n' '#!/bin/sh'
      printf 'printf %%s %q\n' "$KEY_PASSPHRASE"
    } >"$askpass"
    chmod 700 "$askpass"
  fi
  output="$(
    if [[ -n "$askpass" ]]; then
      DISPLAY="${DISPLAY:-:0}" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
        ssh -i "$KEY_PATH" -p "$GIT_PORT" \
          -o IdentitiesOnly=yes \
          -o UserKnownHostsFile="$KNOWN_HOSTS" \
          -o StrictHostKeyChecking=accept-new \
          -o PreferredAuthentications=publickey \
          -o NumberOfPasswordPrompts=0 \
          -T "${SSH_GIT_LOGIN}@${GIT_HOST}" </dev/null 2>&1 || true
    else
      ssh -i "$KEY_PATH" -p "$GIT_PORT" \
        -o IdentitiesOnly=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=publickey \
        -o NumberOfPasswordPrompts=0 \
        -o BatchMode=yes \
        -T "${SSH_GIT_LOGIN}@${GIT_HOST}" 2>&1 || true
    fi
  )"
  [[ -n "$askpass" ]] && rm -f "$askpass"
  printf '%s\n' "$output"
  echo
  if echo "$output" | grep -qiE 'welcome|successfully authenticated'; then
    log "Доступ к серверу есть."
    return 0
  fi
  log "Подключение не удалось."
  log "Пароль учётной записи GitLab для SSH не нужен — только ключ."
  log "Проверьте, что в GitLab вставлен текущий файл:"
  log "  ${KEY_PATH}.pub"
  log "Страница ключей: ${GITLAB_SSH_KEYS_URL}"
  return 1
}

test_repo() {
  if [[ -z "${GIT_REMOTE:-}" ]]; then
    log "GIT_REMOTE пуст — проверка репозитория пропущена."
    return 0
  fi
  log "Проверка репозитория: ${GIT_REMOTE}"
  export GIT_SSH_COMMAND="ssh -F \"${PROJECT_SSH_CONFIG}\""
  if git ls-remote "$GIT_REMOTE" HEAD; then
    log "Доступ к репозиторию есть."
    return 0
  fi
  log "Предупреждение: git ls-remote не удался. Доступ к серверу уже проверен."
  return 1
}

prompt_retry_or_quit() {
  local key
  echo
  read -r -s -n1 -p "Enter = проверить снова, Esc/q = выход без записи скриптов: " key || true
  echo
  if [[ "$key" == $'\e' || "$key" == "q" || "$key" == "Q" ]]; then
    return 1
  fi
  return 0
}

ensure_user_ssh_config() {
  if ! flag_yes "$UPDATE_USER_SSH_CONFIG"; then
    log "UPDATE_USER_SSH_CONFIG=no — ${HOME_SSH_CONFIG} не меняем."
    return
  fi
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh" 2>/dev/null || true
  touch "$HOME_SSH_CONFIG"
  chmod 600 "$HOME_SSH_CONFIG" 2>/dev/null || true
  if grep -Eq "^[[:space:]]*Host[[:space:]]+${GIT_HOST}([[:space:]]|$)" "$HOME_SSH_CONFIG" 2>/dev/null; then
    log "Запись для ${GIT_HOST} уже есть в ${HOME_SSH_CONFIG}"
    return
  fi
  {
    echo ""
    ssh_host_block
  } >>"$HOME_SSH_CONFIG"
  log "Добавлена запись в ${HOME_SSH_CONFIG}"
}

write_connect_sh() {
  local dest="$1"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
# Generated by git_ssh_setup. Values from git_ssh_ambiot.conf at generation time.
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
GIT_HOST="${GIT_HOST}"
GIT_PORT="${GIT_PORT}"
KEY_FILE="${KEY_FILE}"
GIT_REMOTE="${GIT_REMOTE}"
KEY_PATH="\$SCRIPT_DIR/\$KEY_FILE"
PUB_PATH="\${KEY_PATH}.pub"
KNOWN_HOSTS="\$SCRIPT_DIR/known_hosts"
SSH_CONFIG="\$SCRIPT_DIR/config"
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

die() { echo "ERROR: \$*" >&2; exit 1; }

export_git_ssh() {
  [[ -f "\$KEY_PATH" ]] || die "Нет ключа: \$KEY_PATH"
  if [[ -f "\$SSH_CONFIG" ]]; then
    export GIT_SSH_COMMAND="ssh -F \\"\$SSH_CONFIG\\""
  else
    export GIT_SSH_COMMAND="ssh -i \\"\$KEY_PATH\\" -p \$GIT_PORT -o IdentitiesOnly=yes -o UserKnownHostsFile=\\"\$KNOWN_HOSTS\\" -o StrictHostKeyChecking=accept-new"
  fi
}

cmd_pub() {
  [[ -f "\$PUB_PATH" ]] || die "Нет публичного ключа: \$PUB_PATH"
  echo "Public SSH key (\$PUB_PATH):"
  echo "------------------------------------------------------------------------"
  cat "\$PUB_PATH"
  echo "------------------------------------------------------------------------"
}

cmd_test() {
  [[ -f "\$KEY_PATH" ]] || die "Нет ключа: \$KEY_PATH"
  echo "Checking SSH to \${SSH_USER}@\${GIT_HOST}:\${GIT_PORT} ..."
  local output
  if [[ -f "\$SSH_CONFIG" ]]; then
    output="\$(ssh -F "\$SSH_CONFIG" -T "\${SSH_USER}@\${GIT_HOST}" 2>&1 || true)"
  else
    output="\$(ssh -i "\$KEY_PATH" -p "\$GIT_PORT" -o IdentitiesOnly=yes -o UserKnownHostsFile="\$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -T "\${SSH_USER}@\${GIT_HOST}" 2>&1 || true)"
  fi
  printf '%s\\n' "\$output"
  echo
  if echo "\$output" | grep -qiE 'welcome|successfully authenticated'; then
    echo "SSH authentication succeeded."
    return 0
  fi
  echo "Authentication did not succeed. Add the public key in GitLab and retry."
  return 1
}

cmd_test_repo() {
  [[ -n "\$GIT_REMOTE" ]] || die "GIT_REMOTE пуст — нечего проверять."
  export_git_ssh
  echo "Checking repository: \$GIT_REMOTE"
  git ls-remote "\$GIT_REMOTE" HEAD
}

cmd="\${1:-}"
shift || true
case "\$cmd" in
  test) cmd_test ;;
  test-repo) cmd_test_repo ;;
  pub) cmd_pub ;;
  git)
    [[ \$# -gt 0 ]] || die "Нужны аргументы git. Пример: \$0 git status"
    export_git_ssh
    git "\$@"
    ;;
  -h|--help|help|"") usage; [[ -n "\$cmd" ]] ;;
  *) usage; die "Unknown command: \$cmd" ;;
esac
EOF
  chmod +x "$dest" 2>/dev/null || true
}

write_connect_ps1() {
  local dest="$1"
  {
    printf '\xEF\xBB\xBF'
    cat <<EOF
# Generated by git_ssh_setup. Values from git_ssh_ambiot.conf at generation time.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]\$Command = "",
    [Parameter(ValueFromRemainingArguments = \$true)]
    [string[]]\$Rest
)

\$ErrorActionPreference = "Stop"
\$ScriptDir = Split-Path -Parent \$MyInvocation.MyCommand.Path
\$GitHost = "${GIT_HOST}"
\$GitPort = "${GIT_PORT}"
\$KeyFile = "${KEY_FILE}"
\$GitRemote = "${GIT_REMOTE}"
\$KeyPath = Join-Path \$ScriptDir \$KeyFile
\$PubPath = \$KeyPath + ".pub"
\$KnownHosts = Join-Path \$ScriptDir "known_hosts"
\$SshConfig = Join-Path \$ScriptDir "config"
\$SshUser = "git"

function Show-Usage {
    @"
Usage: git-ssh.ps1 <command> [args]
  test         ssh -T to the Git server
  test-repo    git ls-remote to GIT_REMOTE (optional)
  pub          print the public key
  git <args>   run git with this key
"@
}

function Die([string]\$Message) {
    Write-Host ("ERROR: " + \$Message) -ForegroundColor Red
    exit 1
}

function Set-GitSshEnvironment {
    if (-not (Test-Path -LiteralPath \$KeyPath)) {
        Die ("Нет ключа: {0}" -f \$KeyPath)
    }
    if (Test-Path -LiteralPath \$SshConfig) {
        \$cfgPosix = \$SshConfig.Replace('\', '/')
        \$env:GIT_SSH_COMMAND = 'ssh -F "{0}"' -f \$cfgPosix
    }
    else {
        \$keyPosix = \$KeyPath.Replace('\', '/')
        \$knownPosix = \$KnownHosts.Replace('\', '/')
        \$env:GIT_SSH_COMMAND = 'ssh -i "{0}" -p {1} -o IdentitiesOnly=yes -o UserKnownHostsFile="{2}" -o StrictHostKeyChecking=accept-new' -f \$keyPosix, \$GitPort, \$knownPosix
    }
}

switch (\$Command.ToLowerInvariant()) {
    "test" {
        if (-not (Test-Path -LiteralPath \$KeyPath)) { Die ("Нет ключа: {0}" -f \$KeyPath) }
        Write-Host ("Checking SSH to {0}@{1}:{2} ..." -f \$SshUser, \$GitHost, \$GitPort)
        if (Test-Path -LiteralPath \$SshConfig) {
            \$output = & ssh -F \$SshConfig -T ("{0}@{1}" -f \$SshUser, \$GitHost) 2>&1 | Out-String
        }
        else {
            \$output = & ssh -i \$KeyPath -p \$GitPort -o IdentitiesOnly=yes -o ("UserKnownHostsFile={0}" -f \$KnownHosts) -o StrictHostKeyChecking=accept-new -T ("{0}@{1}" -f \$SshUser, \$GitHost) 2>&1 | Out-String
        }
        Write-Host \$output.TrimEnd()
        Write-Host ""
        if (\$output -match "(?i)welcome|successfully authenticated") {
            Write-Host "SSH authentication succeeded." -ForegroundColor Green
        }
        else {
            Write-Host "Authentication did not succeed. Add the public key in GitLab and retry." -ForegroundColor Yellow
            exit 1
        }
    }
    "test-repo" {
        if ([string]::IsNullOrWhiteSpace(\$GitRemote)) { Die "GIT_REMOTE пуст - нечего проверять." }
        Set-GitSshEnvironment
        Write-Host ("Checking repository: {0}" -f \$GitRemote)
        & git ls-remote \$GitRemote HEAD
        exit \$LASTEXITCODE
    }
    "pub" {
        if (-not (Test-Path -LiteralPath \$PubPath)) { Die ("Нет публичного ключа: {0}" -f \$PubPath) }
        Write-Host ("Public SSH key ({0}):" -f \$PubPath)
        Write-Host "------------------------------------------------------------------------"
        Get-Content -LiteralPath \$PubPath
        Write-Host "------------------------------------------------------------------------"
    }
    "git" {
        if (\$null -eq \$Rest -or \$Rest.Count -eq 0) { Die "Нужны аргументы git. Пример: git-ssh.ps1 git status" }
        Set-GitSshEnvironment
        & git @Rest
        exit \$LASTEXITCODE
    }
    { \$_ -in @("", "-h", "--help", "help") } {
        Show-Usage
        if (\$Command -eq "") { exit 1 }
    }
    default {
        Show-Usage
        Die "Unknown command: \$Command"
    }
}
EOF
  } >"$dest"
}

write_generated_outputs() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR" 2>/dev/null || true

  {
    echo "# Generated by environment/git/git_ssh_setup. Source: git_ssh_ambiot.conf"
    ssh_host_block
  } >"$PROJECT_SSH_CONFIG"
  chmod 600 "$PROJECT_SSH_CONFIG" 2>/dev/null || true
  log "Конфиг подключения: ${PROJECT_SSH_CONFIG}"

  write_connect_sh "${SSH_DIR}/git-ssh.sh"
  log "Скрипт: ${SSH_DIR}/git-ssh.sh"
  write_connect_ps1 "${SSH_DIR}/git-ssh.ps1"
  log "Скрипт: ${SSH_DIR}/git-ssh.ps1"

  cat >"$OUT_GIT_USER" <<EOF
[user]
	name = ${GIT_NAME}
	email = ${GIT_EMAIL}
EOF
  chmod 600 "$OUT_GIT_USER" 2>/dev/null || true
  log "Git identity: ${OUT_GIT_USER}"
}

# --- main ---
echo "=== Настройка Git SSH ==="
require_commands
select_conf_file
load_or_init_config

log "Конфиг: ${CONF_FILE}"
log "Каталог запуска: ${LAUNCH_DIR}"
prompt_parameters

echo
log "Ключ и выход: ${SSH_DIR}"
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
log "Git: user.name = ${GIT_NAME}"
log "Git: user.email = ${GIT_EMAIL}"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true

if [[ -f "$KEY_PATH" ]]; then
  echo
  log "Ключ уже есть: ${KEY_PATH}"
else
  echo
  SAVE_PASSPHRASE="$(prompt_default "Сохранять passphrase в конфиг (yes/no)" "${SAVE_PASSPHRASE:-no}")"
  [[ -n "$SAVE_PASSPHRASE" ]] || SAVE_PASSPHRASE="no"

  local_pass=""
  local_pass2=""
  if flag_yes "$SAVE_PASSPHRASE" && [[ -n "${KEY_PASSPHRASE:-}" ]]; then
    read -s -p "Passphrase для нового SSH-ключа (Enter = из конфига): " local_pass || true
    echo
    if [[ -z "$local_pass" ]]; then
      local_pass="$KEY_PASSPHRASE"
    else
      read -s -p "Повторите passphrase: " local_pass2 || true
      echo
      [[ "$local_pass" == "$local_pass2" ]] || die "Passphrase не совпадают."
    fi
  else
    read -s -p "Passphrase для нового SSH-ключа (Enter = без пароля): " local_pass || true
    echo
    read -s -p "Повторите passphrase: " local_pass2 || true
    echo
    [[ "$local_pass" == "$local_pass2" ]] || die "Passphrase не совпадают."
  fi

  if flag_yes "$SAVE_PASSPHRASE"; then
    KEY_PASSPHRASE="$local_pass"
  else
    KEY_PASSPHRASE=""
  fi
  write_conf
  log "Записан конфиг: $CONF_FILE"

  ssh-keygen -t "$KEY_TYPE" -C "$GIT_EMAIL" -f "$KEY_PATH" -N "$local_pass"
fi

chmod 600 "$KEY_PATH" 2>/dev/null || true
[[ -f "${KEY_PATH}.pub" ]] && chmod 644 "${KEY_PATH}.pub" 2>/dev/null || true

show_public_key_instructions

echo
unlock_ssh_key
until test_server; do
  if ! prompt_retry_or_quit; then
    die "Выход. Скрипт запуска, config и .git-user не записаны (ключ уже в ${SSH_DIR})."
  fi
done

write_generated_outputs
ensure_user_ssh_config

if [[ -n "${GIT_REMOTE:-}" ]]; then
  echo
  repo_ans="$(prompt_default "Проверить доступ к репозиторию ${GIT_REMOTE}? (y/N)" "N")"
  if flag_yes "$repo_ans"; then
    test_repo || true
  else
    log "Проверка репозитория пропущена. Позже: ${SSH_DIR}/git-ssh.sh test-repo"
  fi
fi

echo
log "Готово. Дальше:"
log "  ${SSH_DIR}/git-ssh.sh test"
log "  ${SSH_DIR}/git-ssh.sh pub"
if [[ -n "${GIT_REMOTE:-}" ]]; then
  log "  ${SSH_DIR}/git-ssh.sh test-repo"
fi
log "  ${SSH_DIR}/git-ssh.sh git status"
log "  ssh -F ${PROJECT_SSH_CONFIG} -T ${SSH_GIT_LOGIN}@${GIT_HOST}"
