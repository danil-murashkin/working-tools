#!/bin/bash
# install-sublime.sh
# nano install-sublime.sh
# chmod +x install-sublime.sh && ./install-sublime.sh

set -e

echo "Установка Sublime Text и Sublime Merge на Ubuntu 20.04"

# 1. Удаляем ВСЕ старые файлы Sublime (на всякий случай)
sudo rm -f /etc/apt/sources.list.d/sublime-text.*
sudo rm -f /etc/apt/sources.list.d/sublime-merge.*

# 2. Устанавливаем зависимости
sudo apt update
sudo apt install -y wget gnupg ca-certificates

# 3. Добавляем ОДИН общий репозиторий для обоих продуктов
echo "deb https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-all.list

# 4. Импортируем GPG-ключ как БИНАРНЫЙ файл (.gpg) — критично для Ubuntu 20.04
wget -qO- https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/sublimehq.gpg > /dev/null

# 5. Обновляем кэш пакетов
sudo apt update

# 6. Устанавливаем оба приложения
sudo apt install -y sublime-text sublime-merge

echo ""
echo "✅ Sublime Text и Sublime Merge успешно установлены!"
echo "Запуск:"
echo "  Sublime Text: subl"
echo "  Sublime Merge: smerge"