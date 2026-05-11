#!/bin/bash

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then 
    echo "Пожалуйста, запустите скрипт с правами root (sudo)"
    exit 1
fi

echo "Начинаем установку и настройку..."

# Обновление системы
apt update
apt upgrade -y

# Установка основных пакетов (адаптировано для Ubuntu 26.04)
apt install -y linux-source
apt install -y linux-image-generic
apt install -y linux-headers-generic
apt install -y linux-headers-$(uname -r) || echo "Заголовки ядра $(uname -r) не найдены"
apt install -y git
apt install -y iptables
apt install -y iptables-persistent
apt install -y build-essential
apt install -y software-properties-common
apt install -y zlib1g-dev
apt install -y libncurses-dev  # Изменено с libncurses5-dev (устаревший)
apt install -y libgdbm-dev
apt install -y libnss3-dev
apt install -y libssl-dev
apt install -y libreadline-dev
apt install -y libffi-dev  # Исправлено: libffi-d -> libffi-dev
apt install -y libsqlite3-dev
apt install -y wget
apt install -y curl
apt install -y libbz2-dev
apt install -y gnupg2
apt install -y wireguard-tools
apt install -y net-tools
apt install -y pkg-config  # Добавлен для сборки
apt install -y make  # Добавлен явно

# Определение версии ядра для исходников
KERNEL_VERSION=$(uname -r | cut -d'-' -f1)
SOURCE_FILE="/usr/src/linux-source-${KERNEL_VERSION}.tar.xz"

# Если точного совпадения нет, ищем доступный исходник
if [ ! -f "$SOURCE_FILE" ]; then
    SOURCE_FILE=$(ls /usr/src/linux-source-*.tar.xz 2>/dev/null | head -n1)
fi

if [ -n "$SOURCE_FILE" ] && [ -f "$SOURCE_FILE" ]; then
    cd /usr/src
    echo "Распаковка исходников ядра из $SOURCE_FILE"
    tar -xf "$SOURCE_FILE" || echo "Ошибка распаковки исходников ядра"
else
    echo "Исходники ядра не найдены в /usr/src/"
    echo "Пропускаем распаковку"
fi

# Перезагрузка не требуется, комментарий
# reboot

echo "Установка инструментов сборки ядра и модуля AmneziaWG"

# Клонирование модуля AmneziaWG
git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git /amneziawg-linux-kernel-module

cd /amneziawg-linux-kernel-module/src

# Поиск правильной директории с исходниками ядра
KERNEL_SOURCE_DIR=""
for dir in /usr/src/linux-*; do
    if [ -d "$dir" ] && [ -f "$dir/Makefile" ]; then
        KERNEL_SOURCE_DIR="$dir"
        break
    fi
done

if [ -n "$KERNEL_SOURCE_DIR" ]; then
    rm -f kernel
    ln -s "$KERNEL_SOURCE_DIR" kernel
    echo "Создана ссылка на $KERNEL_SOURCE_DIR"
else
    echo "Исходники ядра не найдены. Установите linux-source и linux-headers"
    exit 1
fi

# Сборка модуля
make
make install

# Загрузка модуля
modprobe amneziawg

# Добавление в автозагрузку
if ! grep -q "^amneziawg" /etc/modules 2>/dev/null; then
    echo amneziawg >> /etc/modules
fi

# Установка AmneziaWG PPA (обновлено для Ubuntu 26.04)
# Ubuntu 26.04 будет называться "Mantic" или новее, используем переменную
UBUNTU_VERSION=$(lsb_release -sc)
echo "Обнаружена версия Ubuntu: $UBUNTU_VERSION"

# Добавление PPA Amnezia (адаптировано под новую версию)
add-apt-repository -y ppa:amnezia/ppa || {
    # Если PPA не работает, используем ручное добавление
    echo "PPA не добавлен, пробуем ручной метод..."
    wget -O- https://download.amnezia.org/ubuntu/KEY.gpg | gpg --dearmor | tee /usr/share/keyrings/amnezia.gpg
    echo "deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://download.amnezia.org/ubuntu $UBUNTU_VERSION main" | tee /etc/apt/sources.list.d/amnezia.list
}

apt update
apt install -y amneziawg

# Установка WGDashboard
echo "Установка WGDashboard"
cd /
git clone https://github.com/donaldzou/WGDashboard.git
cd ./WGDashboard/src
chmod +x ./wgd.sh

# Установка зависимостей Python для WGDashboard
apt install -y python3 python3-pip python3-venv
./wgd.sh install

# Включение IP-форвардинга
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Запуск WGDashboard
./wgd.sh start

# Создание systemd-сервиса для WGDashboard
cat > /etc/systemd/system/wgdashboard.service <<EOF
[Unit]
Description=WGDashboard Service
After=network.target
After=wg-quick@wg0.service
Wants=network.target

[Service]
Type=forking
WorkingDirectory=/WGDashboard/src
ExecStart=/WGDashboard/src/wgd.sh start
ExecStop=/WGDashboard/src/wgd.sh stop
ExecReload=/WGDashboard/src/wgd.sh restart
PIDFile=/WGDashboard/src/gunicard.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wgdashboard.service
systemctl start wgdashboard.service

# Установка AdGuardHome
echo "Установка AdGuardHome"
cd /tmp
curl -sSL https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz -o AdGuardHome.tar.gz
tar -xzf AdGuardHome.tar.gz  # Добавлен флаг -z для gzip

mkdir -p /AdGuardHome
mv AdGuardHome/* /AdGuardHome/ 2>/dev/null || mv AdGuardHome/AdGuardHome /AdGuardHome/
chown -R root:root /AdGuardHome

cd /AdGuardHome
./AdGuardHome -s install

# Исправление путей в systemd сервисе
if [ -f /etc/systemd/system/AdGuardHome.service ]; then
    sed -i 's|WorkingDirectory=.*|WorkingDirectory=/AdGuardHome|g' /etc/systemd/system/AdGuardHome.service
    sed -i 's|ExecStart=.*|ExecStart=/AdGuardHome/AdGuardHome -s run|g' /etc/systemd/system/AdGuardHome.service
fi

systemctl daemon-reload
systemctl enable AdGuardHome
systemctl start AdGuardHome

# Настройка iptables для WireGuard (базовые правила)
iptables -A INPUT -p udp --dport 51820 -j ACCEPT
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Сохранение правил iptables
if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4
fi

echo "============================================"
echo "Установка завершена!"
echo "============================================"
echo "WGDashboard доступен по адресу: http://$(hostname -I | awk '{print $1}'):10086"
echo "AdGuardHome доступен по адресу: http://$(hostname -I | awk '{print $1}'):3000"
echo ""
echo "Для проверки статуса сервисов:"
echo "systemctl status wgdashboard"
echo "systemctl status AdGuardHome"
echo ""
echo "Для проверки модуля AmneziaWG:"
echo "lsmod | grep amneziawg"
echo "============================================"
