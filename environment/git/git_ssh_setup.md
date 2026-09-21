# Настройка SSH-ключа для Git

Git по SSH — это не «ещё одна команда», а доверенная пара: сервер узнаёт вас по ключу, а не по паролю. Этот материал проводит через всю настройку один раз. Дальше достаточно маленького скрипта в каталоге проекта.

Нужны Git и OpenSSH. Скрипт ищет файлы `.conf` рядом с собой (`environment/git/`). Если файл один — берёт его; если несколько — печатает список и просит номер. Рабочий пример для GitLab Ambiot — [git_ssh_ambiot.conf](git_ssh_ambiot.conf). Рядом лежит [git_ssh_example.conf](git_ssh_example.conf): тот же формат, но с вымышленным `gitlab.example.com`. Если `.conf` нет, setup заведёт `git_ssh.conf` и спросит host, порт и остальное. Если значение уже записано — оно появится в скобках: Enter оставляет его как есть.

Linux, WSL и macOS — [git_ssh_setup.sh](git_ssh_setup.sh). Windows — [git_ssh_setup.ps1](git_ssh_setup.ps1). Запускайте из корня проекта: тогда ключ и скрипты окажутся в `ssh-connect/` рядом с вами, а не «где-то в домашней папке».

```bash
bash environment/git/git_ssh_setup.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\environment\git\git_ssh_setup.ps1
```

Скрипт спросит имя и почту (для Git и комментария ключа), создаст ключ, если его ещё нет, и покажет **публичную** половину (файл `.pub`). Скопируйте её и вставьте в GitLab: User Settings → SSH Keys → поле Key → Add key. Пока ключ не добавлен на сервере, проверка не пройдёт — это нормально. Enter повторяет попытку, Esc или `q` выходит без записи скриптов подключения.

Успех — это ответ сервера вроде `Welcome to GitLab, @ваш_логин!`. Доступ к конкретному репозиторию (`git ls-remote`) можно проверить следом, но это уже по желанию: для настройки достаточно входа на GitLab.

Ниже — как это выглядит в терминале, если выбран [git_ssh_example.conf](git_ssh_example.conf). В скобках стоят значения из этого файла; пустой Enter их принимает. Имя и почта обязательны: пустой ввод скрипт не принимает и сразу записывает их в выбранный `.conf`.

```text
$ bash environment/git/git_ssh_setup.sh
=== Настройка Git SSH ===
Найдено несколько конфигов:
  1) git_ssh_ambiot.conf
  2) git_ssh_example.conf
Выберите номер [1-2]: 2
Конфиг: .../environment/git/git_ssh_example.conf
Каталог запуска: .../IEK_LC1_2

=== Параметры подключения ===
Enter оставляет значение в скобках (из конфига или по умолчанию).

Git host [gitlab.example.com]:
SSH port [22]:
GIT_REMOTE (пусто = не проверять репозиторий) [git@gitlab.example.com:group/project.git]:
Каталог ключа и скриптов (относительно места запуска) [ssh-connect]:
Имя файла ключа [id_ed25519]:
Тип ключа [ed25519]:
Писать Host в ~/.ssh/config (yes/no) [no]:
Имя (для Git) [Иван Петров]:
Email (для Git и SSH-ключа) [ivan.petrov@example.com]:
Записан конфиг: .../environment/git/git_ssh_example.conf

Ключ и выход: .../IEK_LC1_2/ssh-connect
Git: user.name = Иван Петров
Git: user.email = ivan.petrov@example.com

Сохранять passphrase в конфиг (yes/no) [no]:
Passphrase для нового SSH-ключа (Enter = без пароля):
Повторите passphrase:

Скопируйте публичный ключ (именно файл .pub):
  cat .../ssh-connect/id_ed25519.pub
------------------------------------------------------------------------
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePublicKey ivan.petrov@example.com
------------------------------------------------------------------------
Добавьте ключ в GitLab (gitlab.example.com):
  1. User Settings → SSH Keys: https://gitlab.example.com/-/user_settings/ssh_keys
  2. Вставьте содержимое .../ssh-connect/id_ed25519.pub в поле Key
  3. Нажмите Add key

Нажмите Enter, когда ключ добавлен в GitLab...

Проверка SSH git@gitlab.example.com:22 ...
Welcome to GitLab, @ivan.petrov!

Доступ к серверу есть.
Конфиг подключения: .../ssh-connect/config
Скрипт: .../ssh-connect/git-ssh.sh
Скрипт: .../ssh-connect/git-ssh.ps1
Git identity: .../ssh-connect/.git-user
UPDATE_USER_SSH_CONFIG=no — ~/.ssh/config не меняем.

Проверить доступ к репозиторию git@gitlab.example.com:group/project.git? (y/N) [N]:

Готово. Дальше:
  .../ssh-connect/git-ssh.sh test
  .../ssh-connect/git-ssh.sh pub
  .../ssh-connect/git-ssh.sh test-repo
  .../ssh-connect/git-ssh.sh git status
```

На Windows диалог тот же, только запускается `.ps1`. Если ключ ещё не успели добавить в GitLab, вместо приветствия будет отказ — тогда Enter, и скрипт проверит снова.

Домашний `~/.ssh/config` скрипт не трогает, пока в конфиге явно не стоит `UPDATE_USER_SSH_CONFIG=yes`.

После удачной проверки в `ssh-connect/` появятся ключ, `config`, `.git-user` и два помощника: `git-ssh.sh` и `git-ssh.ps1`. Ими удобно пользоваться каждый день. Повторная проверка сервера выглядит так:

```text
$ ./ssh-connect/git-ssh.sh test
Checking SSH to git@gitlab.example.com:22 ...
Welcome to GitLab, @ivan.petrov!

SSH authentication succeeded.
```

```bash
./ssh-connect/git-ssh.sh pub
./ssh-connect/git-ssh.sh git status
```

```powershell
powershell -ExecutionPolicy Bypass -File .\ssh-connect\git-ssh.ps1 test
powershell -ExecutionPolicy Bypass -File .\ssh-connect\git-ssh.ps1 pub
powershell -ExecutionPolicy Bypass -File .\ssh-connect\git-ssh.ps1 git status
```

Приватный ключ, `known_hosts`, `config` и `.git-user` в git не попадают — их бережёт `.gitignore`. В репозиторий уходит только эта инструкция и сами setup-скрипты.

## Как всё сделать вручную

Те же шаги, что делает setup-скрипт, можно выполнить руками. Команды ниже — из корня проекта. Host, порт и путь к ключу возьмите из выбранного `.conf` (здесь — значения из [git_ssh_example.conf](git_ssh_example.conf); для GitLab Ambiot это `gitlab.ambiot.io` и порт `22210`).

### 1. Сгенерируйте SSH-ключ в каталоге `ssh-connect`

При запросе `passphrase` укажите надёжный пароль:

```bash
mkdir -p ssh-connect && ssh-keygen -t ed25519 -C "ivan.petrov@example.com" -f ssh-connect/id_ed25519
```

```powershell
New-Item -ItemType Directory -Force -Path ssh-connect | Out-Null
ssh-keygen -t ed25519 -C "ivan.petrov@example.com" -f ssh-connect/id_ed25519
```

### 2. Скопируйте публичный ключ (именно `.pub`)

```bash
cat ssh-connect/id_ed25519.pub
```

```powershell
Get-Content .\ssh-connect\id_ed25519.pub
```

Скопируйте строку целиком (`ssh-ed25519 AAAA... почта`).

### 3. Добавьте ключ в GitLab

- Зайдите в **User Settings → SSH Keys** на [https://gitlab.example.com/-/user_settings/ssh_keys](https://gitlab.example.com/-/user_settings/ssh_keys) (для Ambiot: [https://gitlab.ambiot.io/-/user_settings/ssh_keys](https://gitlab.ambiot.io/-/user_settings/ssh_keys))
- Вставьте содержимое `ssh-connect/id_ed25519.pub` в поле **Key**
- Нажмите **Add key**

### 4. Добавьте ключ в `ssh-agent`

При запросе введите тот же `passphrase`, что указали выше.

*(При каждом новом терминальном сеансе эту команду нужно будет выполнить снова, если ключ не в агенте.)*

```bash
eval "$(ssh-agent -s)" && ssh-add ssh-connect/id_ed25519
```

```powershell
Get-Service ssh-agent | Start-Service
ssh-add .\ssh-connect\id_ed25519
```

### 5. Проверьте подключение

```bash
ssh -T -p 22 -i ssh-connect/id_ed25519 -o IdentitiesOnly=yes git@gitlab.example.com
```

Для GitLab Ambiot:

```bash
ssh -T -p 22210 -i ssh-connect/id_ed25519 -o IdentitiesOnly=yes git@gitlab.ambiot.io
```

```powershell
ssh -T -p 22210 -i .\ssh-connect\id_ed25519 -o IdentitiesOnly=yes git@gitlab.ambiot.io
```

Если всё настроено правильно, вы увидите сообщение вроде:

```text
Welcome to GitLab, @ваш_логин!
```

> Чтобы не указывать путь к ключу вручную при каждом подключении, добавьте запись в `~/.ssh/config`. Благодаря `AddKeysToAgent yes` ключ будет попадать в агент при подключении. Setup-скрипт делает это только если в `.conf` стоит `UPDATE_USER_SSH_CONFIG=yes`.
>
> ```text
> Host gitlab.example.com
>     HostName gitlab.example.com
>     User git
>     Port 22
>     IdentityFile /полный/путь/к/проекту/ssh-connect/id_ed25519
>     IdentitiesOnly yes
>     AddKeysToAgent yes
> ```
>
> Для Ambiot: `Host`/`HostName` = `gitlab.ambiot.io`, `Port` = `22210`.
