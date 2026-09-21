#!/bin/bash
# network_script_target.sh — Управление сетью на target
# Подход: Маскировка DHCP + сервис в конце загрузки + цикл ожидания линка

echo "=== УПРАВЛЕНИЕ СЕТЬЮ НА TARGET ==="
echo ""
echo "Выберите режим работы:"
echo "  1) Статическая настройка (192.168.2.2) — для прямого подключения к host"
echo "  2) Сброс к DHCP — для подключения к роутеру"
echo "  3) Выход"
echo ""
read -p "Ваш выбор [1-3]: " MODE
case $MODE in
1)
echo ""
echo ">>> РЕЖИМ: Статическая настройка для host"
echo ""
SETUP_MODE=1
;;
2)
echo ""
echo ">>> РЕЖИМ: Сброс к DHCP для роутера"
echo ""
SETUP_MODE=0
;;
3)
echo "Выход."
exit 0
;;
*)
echo "[ОШИБКА] Неверный выбор."
exit 1
;;
esac

# ==============================================================================
# Проверка прав
# ==============================================================================
if [ "$EUID" -ne 0 ]; then
echo "[ОШИБКА] Запускайте через sudo:"
echo "  sudo ./network_script_target.sh"
exit 1
fi

# ==============================================================================
# Определение интерфейса
# ==============================================================================
echo "[1/6] Ищем Ethernet‑интерфейс..."
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | \
grep -Ev 'lo|wlan|wlo|wifi|docker|veth|br-|can|sit|tun|tap|ppp' | \
head -1)
[ -z "$INTERFACE" ] && INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^en[ops]|^eth' | head -1)
if [ -z "$INTERFACE" ]; then
echo "  [ВНИМАНИЕ] Не удалось найти интерфейс."
ip -o link show | awk -F': ' '{print $2}'
read -p "Введите имя интерфейса: " INTERFACE
fi
echo "  ✓ Интерфейс: $INTERFACE"

# ==============================================================================
# РЕЖИМ 1: Статика + ПЕРСИСТЕНТНОСТЬ
# ==============================================================================
if [ "$SETUP_MODE" -eq 1 ]; then
# 1. Применяем настройки вручную (ваш проверенный код)
echo "[2/6] Настраиваем IP 192.168.2.2/24..."
ip addr flush dev "$INTERFACE"
ip addr add 192.168.2.2/24 dev "$INTERFACE"
ip link set "$INTERFACE" up
sleep 2

echo "[3/6] Устанавливаем шлюз 192.168.2.1..."
ip route replace default via 192.168.2.1 2>/dev/null || true
ip route add default via 192.168.2.1 dev "$INTERFACE" 2>/dev/null || true

echo "[4/6] Настраиваем DNS..."
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf

echo "[5/6] Проверка связи..."
if ping -c 2 -W 1 192.168.2.1 > /dev/null 2>&1; then
echo "  ✓ Host доступен"
else
echo "  ✗ Host недоступен"
fi

# 6. СОЗДАЁМ ПЕРСИСТЕНТНОСТЬ (НОВЫЙ ПОДХОД)
echo "[6/6] Настройка сохранения после перезагрузки..."

# Монтируем корень в RW, если нужно
mount | grep -q 'on / .*ro,' && mount -o remount,rw / 2>/dev/null || true

# Создаём скрипт, который будет вызываться при загрузке
cat > /usr/local/bin/target-restore-net.sh << 'RESTORE_EOF'
#!/bin/sh
IFACE="${1:-eth0}"
TARGET_IP="192.168.2.2/24"
GW="192.168.2.1"

# Ждём появления интерфейса и линка (до 40 сек)
for i in $(seq 1 40); do
    if [ -f "/sys/class/net/$IFACE/operstate" ] && [ "$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)" = "up" ]; then
        break
    fi
    sleep 1
done

# Проверяем, не сбил ли кто-то IP
CURRENT_IP=$(ip -o addr show dev "$IFACE" 2>/dev/null | awk '/inet / {print $4}' | head -1)
if [ "$CURRENT_IP" != "$TARGET_IP" ]; then
    ip link set "$IFACE" down 2>/dev/null
    sleep 1
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add "$TARGET_IP" dev "$IFACE"
    ip link set "$IFACE" up
    sleep 2
    ip route replace default via "$GW" 2>/dev/null || true
    ip route add default via "$GW" dev "$IFACE" 2>/dev/null || true
    printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf 2>/dev/null
fi
exit 0
RESTORE_EOF
chmod +x /usr/local/bin/target-restore-net.sh

# Маскируем DHCP-клиенты, чтобы они не конфликтовали
# Важно: udhcpc@*.service в shell НЕ раскрывается в имена unit'ов — только явный инстанс.
UDHCPC_UNIT="udhcpc@${INTERFACE}.service"
systemctl mask "$UDHCPC_UNIT" 2>/dev/null || true
systemctl mask dhcpcd.service 2>/dev/null || true
systemctl disable --now "$UDHCPC_UNIT" dhcpcd.service 2>/dev/null || true
# Старые имена с прошлых версий скрипта
systemctl disable --now nc2-persist-net.service 2>/dev/null || true
rm -f /etc/systemd/system/nc2-persist-net.service
rm -f /usr/local/bin/nc2-restore-net.sh

# Создаём сервис, который стартует ПОСЛЕ всего
cat > /etc/systemd/system/target-persist-net.service << EOF
[Unit]
Description=Restore static target network after all managers
After=multi-user.target network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/bin/target-restore-net.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c 'sleep 3'
ExecStart=/usr/local/bin/target-restore-net.sh $INTERFACE
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now target-persist-net.service 2>/dev/null || true

echo "  ✓ Сервис сохранения активирован"
echo "  ✓ DHCP-клиенты замаскированы"
echo "============================================"
echo "✅ Настройки сохранены. После reboot IP останется 192.168.2.2"
echo "   Проверить: systemctl status target-persist-net.service"
echo "============================================"

# ==============================================================================
# РЕЖИМ 0/2: Сброс к DHCP + ОЧИСТКА
# ==============================================================================
else
echo "[2/5] Разблокируем DHCP-клиенты..."
UDHCPC_UNIT="udhcpc@${INTERFACE}.service"
systemctl unmask "$UDHCPC_UNIT" 2>/dev/null || true
# На старых образах могли замаскировать буквально udhcpc@*.service — снимаем и его.
systemctl unmask 'udhcpc@*.service' 2>/dev/null || true
systemctl unmask dhcpcd.service 2>/dev/null || true
systemctl disable --now target-persist-net.service 2>/dev/null || true
rm -f /etc/systemd/system/target-persist-net.service
rm -f /usr/local/bin/target-restore-net.sh
# Старые имена с прошлых версий скрипта
systemctl disable --now nc2-persist-net.service 2>/dev/null || true
rm -f /etc/systemd/system/nc2-persist-net.service
rm -f /usr/local/bin/nc2-restore-net.sh
systemctl daemon-reload
systemctl reset-failed "$UDHCPC_UNIT" dhcpcd.service 2>/dev/null || true
echo "  ✓ Сервис и маски удалены"

echo "[3/5] Очищаем статический IP..."
ip addr flush dev "$INTERFACE"
ip link set "$INTERFACE" up
echo "  ✓ IP очищен, интерфейс поднят"

echo "[4/5] Удаляем статический маршрут..."
ip route del default via 192.168.2.1 2>/dev/null || true
ip route del default dev "$INTERFACE" 2>/dev/null || true
echo "  ✓ Маршрут удалён"

echo "[5/5] Восстанавливаем DNS и запускаем DHCP..."
if [ -f /etc/resolv.conf.bak ]; then
    cp /etc/resolv.conf.bak /etc/resolv.conf
fi
DHCP_STARTED=0
# Предпочтительно: штатный systemd unit (как в Yocto с udhcpc@.service)
if systemctl cat "$UDHCPC_UNIT" &>/dev/null; then
    killall udhcpc 2>/dev/null || true
    systemctl enable --now "$UDHCPC_UNIT" 2>/dev/null && DHCP_STARTED=1
fi
if [ "$DHCP_STARTED" -eq 0 ] && systemctl cat dhcpcd.service &>/dev/null; then
    killall udhcpc 2>/dev/null || true
    systemctl enable --now dhcpcd.service 2>/dev/null && DHCP_STARTED=1
fi
if [ "$DHCP_STARTED" -eq 0 ]; then
    if command -v udhcpc &> /dev/null; then
        killall udhcpc 2>/dev/null || true
        udhcpc -i "$INTERFACE" -b &
    elif command -v dhclient &> /dev/null; then
        dhclient -r "$INTERFACE" 2>/dev/null || true
        dhclient "$INTERFACE" &
    fi
fi
sleep 4
echo "✅ Готово. Интерфейс ждёт DHCP от роутера."
echo "============================================"
fi

echo ""
echo "=== ЗАВЕРШЕНО ==="