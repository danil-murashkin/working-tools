#!/bin/bash
# network_script_host.sh — Управление сетью на хост-устройстве
# Режимы: 1) Статическая настройка для прямого подключения к target
#         2) Сброс к DHCP для подключения к роутеру

echo "=== УПРАВЛЕНИЕ СЕТЬЮ НА ХОСТ-УСТРОЙСТВЕ ==="
echo ""
echo "Выберите режим работы:"
echo "  1) Статическая настройка (192.168.2.1) — для прямого подключения к target"
echo "  2) Сброс к DHCP — для подключения к роутеру"
echo "  3) Выход"
echo ""
read -p "Ваш выбор [1-3]: " MODE

case $MODE in
  1)
    echo ""
    echo ">>> РЕЖИМ: Статическая настройка для target"
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
# Проверка прав суперпользователя
# ==============================================================================
if [ "$EUID" -ne 0 ]; then 
  echo "[ОШИБКА] Пожалуйста, запускайте скрипт через sudo:"
  echo "  sudo ./network_script_host.sh"
  exit 1
fi

# ==============================================================================
# Определение интерфейса
# ==============================================================================
echo "[1/8] Ищем проводной Ethernet‑интерфейс..."
INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | \
    grep -Ev 'lo|wlan|wlo|wifi|docker|veth|br-|can|sit|tun|tap|ppp' | \
    head -1)

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | \
        grep -E '^en[ops]|^eth' | head -1)
fi

if [ -z "$INTERFACE" ]; then
  echo "  [ВНИМАНИЕ] Не удалось автоматически найти интерфейс."
  ip -o link show | awk -F': ' '{print $2}'
  read -p "Введите имя интерфейса вручную: " INTERFACE
fi
echo "  ✓ Интерфейс: $INTERFACE"

# ==============================================================================
# РЕЖИМ 1: Статическая настройка (192.168.2.1)
# ==============================================================================
if [ "$SETUP_MODE" -eq 1 ]; then

  # Отключение NetworkManager
  echo "[2/8] Отключаем NetworkManager для $INTERFACE..."
  if command -v nmcli &> /dev/null; then
      nmcli device set "$INTERFACE" managed no 2>/dev/null || true
      nmcli device disconnect "$INTERFACE" 2>/dev/null || true
      echo "  ✓ NetworkManager отключён"
  fi
  sleep 2

  # Настройка IP
  echo "[3/8] Настраиваем IP 192.168.2.1/24..."
  ip addr flush dev "$INTERFACE"
  ip addr add 192.168.2.1/24 dev "$INTERFACE"
  ip link set "$INTERFACE" up
  sleep 2
  echo "  ✓ IP настроен"

  # IP-форвардинг
  echo "[4/8] Включаем IP‑форвардинг..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  echo "  ✓ Форвардинг включён"

  # Очистка старых правил
  echo "[5/8] Очищаем старые правила NAT..."
  iptables -t nat -D POSTROUTING -o wlo1 -j MASQUERADE 2>/dev/null || true
  iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$INTERFACE" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  echo "  ✓ Правила очищены"

  # Настройка NAT
  echo "[6/8] Настраиваем NAT..."
  WAN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
  
  # ============================================================================
  # УЛУЧШЕННАЯ ПРОВЕРКА ИНТЕРНЕТ-СОЕДИНЕНИЯ
  # ============================================================================
  if [ -z "$WAN_INTERFACE" ]; then
      echo "  ⚠ ПРЕДУПРЕЖДЕНИЕ: Интернет-интерфейс не найден!"
      echo ""
      echo "  Возможные причины:"
      echo "    • WiFi выключен или не подключён к сети"
      echo "    • Ethernet-кабель не подключён к роутеру/интернету"
      echo "    • Нет активного соединения с Интернетом"
      echo ""
      echo "  Доступные интерфейсы:"
      ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | sed 's/^/    /'
      echo ""
      echo "  Что делать:"
      echo "    • Включите WiFi и подключитесь к сети"
      echo "    • ИЛИ подключите Ethernet-кабель к роутеру с Интернетом"
      echo "    • ИЛИ запустите: nmcli device wifi connect <SSID> password <PASS>"
      echo ""
      echo "  ⚡ Связь host↔target будет работать, но доступа в Интернет у target НЕ будет!"
      echo ""
      read -p "Продолжить без NAT? [y/N]: " CONTINUE
      if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
          echo "Настройка прервана."
          exit 0
      fi
  else
      echo "  ✓ Интернет-интерфейс (WAN): $WAN_INTERFACE"
      iptables -t nat -A POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE
      iptables -A FORWARD -i "$INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
      iptables -A FORWARD -i "$WAN_INTERFACE" -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
      echo "  ✓ NAT настроен через $WAN_INTERFACE"
  fi

  # Проверка
  echo "[7/8] Проверка..."
  ip -br addr show "$INTERFACE" | sed 's/^/  /'
  echo "  Форвардинг: $(cat /proc/sys/net/ipv4/ip_forward)"

  echo "[8/8] Готово!"
  echo "============================================"
  echo "На target настройте: IP 192.168.2.2, шлюз 192.168.2.1"
  echo "Проверка: ping 192.168.2.2"
  if [ -z "$WAN_INTERFACE" ]; then
      echo "⚠ ВНИМАНИЕ: Интернета у target не будет (нет WAN на host)"
  fi
  echo "============================================"

# ==============================================================================
# РЕЖИМ 0: Сброс к DHCP
# ==============================================================================
else

  echo "[2/6] Отключаем IP‑форвардинг..."
  echo 0 > /proc/sys/net/ipv4/ip_forward
  echo "  ✓ Форвардинг отключён"

  echo "[3/6] Очищаем правила NAT..."
  iptables -t nat -F 2>/dev/null || true
  iptables -F FORWARD 2>/dev/null || true
  echo "  ✓ Правила очищены"

  echo "[4/6] Очищаем статический IP..."
  ip addr flush dev "$INTERFACE"
  echo "  ✓ IP очищен"

  echo "[5/6] Возвращаем NetworkManager..."
  if command -v nmcli &> /dev/null; then
      nmcli device set "$INTERFACE" managed yes 2>/dev/null || true
      nmcli device connect "$INTERFACE" 2>/dev/null || true
      echo "  ✓ NetworkManager управляет интерфейсом"
  fi

  echo "[6/6] Запускаем DHCP..."
  if command -v dhclient &> /dev/null; then
      dhclient -r "$INTERFACE" 2>/dev/null || true
      dhclient "$INTERFACE"
      echo "  ✓ DHCP запущен"
  fi
  sleep 5

  echo "Готово!"
  echo "============================================"
  echo "Подключите $INTERFACE к роутеру"
  echo "Проверка: ip addr show $INTERFACE"
  echo "============================================"

fi

echo ""
echo "=== ЗАВЕРШЕНО ==="