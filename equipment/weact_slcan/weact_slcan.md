# WeAct USB2CANFD V1 — SLCAN на хосте

Адаптер **WeAct Studio USB2CANFD V1** на хосте виден как USB CDC (виртуальный COM-порт). Для управления есть скрипты:

| Платформа | Скрипт |
| --------- | ------ |
| Linux     | `equipment/weact_slcan.sh` |
| Windows 11 | `equipment/weact_slcan.ps1` или `equipment/weact_slcan.cmd` |

| Параметр          | Значение                                                  |
| ----------------- | --------------------------------------------------------- |
| Устройство (Linux) | `/dev/ttyACM*` или `usb-WeAct_*` (номер может отличаться) |
| Устройство (Windows) | **COM12** (по умолчанию; смотрите Диспетчер устройств) |
| USB ID            | `0483:5740` STMicroelectronics Virtual COM Port           |
| Протокол          | **SLCAN** (текстовые команды, окончание `\r`)             |
| Скорость UART     | **115200** 8N1                                            |
| Прошивка (пример) | `WeAct Studio V1.0.0.3_bb264e71`                          |

---

## Windows 11

### 1. Проверка адаптера

1. Подключите WeAct USB2CAN к ПК.
2. Откройте **Диспетчер устройств** → **Порты (COM и LPT)**.
3. Найдите **USB Serial Device** или **STMicroelectronics Virtual COM Port** — запомните номер (например, **COM12**).
4. Если порт другой, укажите его через `-d` или переменную `WEACT_DEV`.

Проверка в PowerShell:

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

### 2. Запуск `weact_slcan.ps1`

Из каталога `equipment`:

```powershell
cd equipment

# Версия прошивки
.\weact_slcan.ps1 v
# или через .cmd (удобно из cmd.exe):
weact_slcan.cmd v

# Явный порт (если не COM12)
.\weact_slcan.ps1 -d COM12 v
$env:WEACT_DEV = "COM12"
.\weact_slcan.ps1 v
```

| Команда | Назначение |
| ------- | ---------- |
| `.\weact_slcan.ps1` или `.\weact_slcan.ps1 -Interactive` | Интерактивная консоль |
| `.\weact_slcan.ps1 v` | Версия прошивки (`V`) |
| `.\weact_slcan.ps1 init 100000` | Открыть канал: `C` + `S3` + `M0` + `O` + `E` |
| `.\weact_slcan.ps1 send t002133` | Отправить один кадр (**auto-init**, bitrate 100000) |
| `.\weact_slcan.ps1 send 100000 t002133` | То же с явным bitrate |
| `.\weact_slcan.ps1 listen 100000` | **Приём** с шины (init + decode до Ctrl+C) |
| `.\weact_slcan.ps1 tx 100000 1` | **Постоянная отправка** кадра `test` (ID 0x100) |
| `.\weact_slcan.ps1 monitor` | Сырой приём (канал уже открыт) |
| `.\weact_slcan.ps1 reset` | Закрыть канал (`C`) |

Опции:

- `-d COM12` — явный COM-порт WeAct
- `WEACT_DEV`, `WEACT_BAUD`, `WEACT_BITRATE`, `WEACT_READ_MS` — переменные окружения

### Примеры (Windows, COM12)

```powershell
.\weact_slcan.ps1 v
.\weact_slcan.ps1 send t002133
.\weact_slcan.ps1 listen 100000
.\weact_slcan.ps1 -d COM12 tx 100000 1
.\weact_slcan.ps1 -Interactive
```

Вывод при приёме:

```text
RX ID=0x100 len=4 data=74 65 73 74 ascii="test"
```

Ответ `\x07` при отправке — ошибка шины / нет ACK.

### 3. Проверка CAN на Windows

На Windows нет `candump`/`cansend` из can-utils. Используйте скрипт:

```powershell
# Терминал 1 — приём
.\weact_slcan.ps1 listen 100000

# Терминал 2 — отправка кадра ID 0x123, data 0x21 0x33
.\weact_slcan.ps1 send 100000 t12322133
```

Формат кадра SLCAN: `t` + 3 hex цифры ID + длина (0–8) + данные hex.

**Bitrate на плате NC-2 (`ip link … bitrate`) и на WeAct (`Sx`) должны совпадать.**

### Замечания Windows

- Скрипт использует встроенный .NET `System.IO.Ports` — Python не нужен.
- Если порт занят другой программой (терминал, другой скрипт) — закройте её перед запуском.
- При ошибке доступа к порту запустите PowerShell от имени администратора или проверьте, что COM-порт не используется.

---

## Linux

### 1. Проверка адаптера

```bash
ls -l /dev/ttyACM*
ls -l /dev/serial/by-id/usb-WeAct_*
lsusb | grep -i '0483:5740\|STM'
```

Проверка портов:

```bash
ls -l /dev/serial/by-id/
# usb-WeAct_*  -> ttyACM0 (или другой ttyACM*)
# usb-1a86_*   -> ttyACM1 (NC1 консоль или другое устройство)
```

Группа `dialout` для доступа без root: `groups`.

### 2. `weact_slcan.sh` — все режимы

```bash
cd equipment
chmod +x weact_slcan.sh
```

| Команда | Назначение |
| ------- | ---------- |
| `./weact_slcan.sh -i` | Интерактивная консоль (по умолчанию без аргументов) |
| `./weact_slcan.sh v` | Версия прошивки (`V`) |
| `./weact_slcan.sh init 100000` | Открыть канал: `C` + `S3` + `M0` + `O` + `E` |
| `./weact_slcan.sh send t002133` | Отправить один кадр (**auto-init**, bitrate 100000) |
| `./weact_slcan.sh send 100000 t002133` | То же с явным bitrate |
| `./weact_slcan.sh listen 100000` | **Приём** с шины (init + decode до Ctrl+C) |
| `./weact_slcan.sh tx 100000 1` | **Постоянная отправка** кадра `test` (ID 0x100) |
| `./weact_slcan.sh monitor` | Сырой приём (канал уже открыт) |
| `./weact_slcan.sh test` | Автотест NC1 + WeAct (`nc1_can_host_test.py`) |

Опции:

- `-d /dev/ttyACM2` — явный serial-порт WeAct
- `WEACT_DEV`, `WEACT_BAUD`, `WEACT_BITRATE`, `WEACT_READ_MS` — переменные окружения

### Примеры (Linux)

```bash
./weact_slcan.sh v
./weact_slcan.sh send t002133
./weact_slcan.sh listen 100000
./weact_slcan.sh -d /dev/ttyACM2 tx 100000 1
./weact_slcan.sh -i
```

### 4. Ручная проверка CAN (Linux, can-utils)

#### Внутренняя проверка CAN (loopback)

```bash
ip link set can0 down
ip link set can0 type can bitrate 100000 loopback on listen-only off
ip link set can0 up
sleep 0.5
rm -f /tmp/can-lb.rx
candump -n 1 -T 3000 can0 > /tmp/can-lb.rx 2>&1 &
sleep 0.4
cansend can0 123#DEADBEEF
wait
cat /tmp/can-lb.rx
```

Ожидается:

```text
can0  123   [4]  DE AD BE EF
```

#### Проверка шины CAN наружу

```bash
ip link set can0 down
ip link set can0 type can bitrate 100000 loopback off listen-only off
ip link set can0 up

cansend can0 123#DEADBEEF
candump -ta can0
```

---

## Справочник SLCAN (общий)

Каждая команда заканчивается `\r` (Enter).

| Команда   | Ответ (пример)                   | Назначение                     |
| --------- | -------------------------------- | ------------------------------ |
| `V`       | `WeAct Studio V1.0.0.3_bb264e71` | Версия прошивки                |
| `C`       | пусто                            | Закрыть CAN-канал              |
| `M0`      | пусто                            | Normal mode (нужен для ACK)    |
| `M1`      | пусто                            | Silent / listen-only (без ACK) |
| `O`       | пусто                            | Открыть CAN-канал              |
| `S3`      | пусто                            | **100 kbit/s**                 |
| `S6`      | пусто                            | **500 kbit/s**                 |
| `S8`      | пусто                            | **1 Mbit/s**                   |
| `E`       | `CANable Error Register: 0`      | Регистр ошибок                 |
| `t002133` | пусто или `\x07`                 | Стандартный кадр ID 0x002, 1 байт 0x33 |

**Bitrate на целевом устройстве и на WeAct (`Sx`) должны совпадать.**
