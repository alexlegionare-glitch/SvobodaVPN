#!/bin/bash
# ============================================================
#  Свобода VPN — авто-настройка сервера
#  Запусти на СВЕЖЕМ VPS (Ubuntu 22/24) от root одной командой:
#    bash <(curl -fsSL https://raw.githubusercontent.com/alexlegionare-glitch/SvobodaVPN/main/setup.sh)
#  В конце получишь ссылку — вставь её в приложение «Свобода VPN».
# ============================================================
set -e
GREEN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
say(){ echo -e "${GREEN}>>> $1${NC}"; }

[ "$(id -u)" = "0" ] || { echo "Запусти от root (sudo -i)"; exit 1; }

say "1/6 Обновление и зависимости..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl tar openssl ca-certificates >/dev/null 2>&1 || true

say "2/6 Определяю архитектуру и качаю sing-box..."
case "$(uname -m)" in
  x86_64|amd64) A=amd64 ;;
  aarch64|arm64) A=arm64 ;;
  *) echo "Неизвестная архитектура $(uname -m)"; exit 1 ;;
esac
VER=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+' | head -1)
[ -n "$VER" ] || VER="1.10.7"
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${A}.tar.gz" -o /tmp/sb.tgz
tar xzf /tmp/sb.tgz -C /tmp
install -m755 "/tmp/sing-box-${VER}-linux-${A}/sing-box" /usr/local/bin/sing-box
rm -rf /tmp/sb.tgz "/tmp/sing-box-${VER}-linux-${A}"

say "3/6 Генерирую ключ и сертификат..."
UUID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /etc/sing-box/cert
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/sing-box/cert/key.pem -out /etc/sing-box/cert/cert.pem \
  -subj "/CN=www.samsung.com" -days 3650 >/dev/null 2>&1

say "4/6 Пишу конфиг (VLESS + TLS, без SNI — обход ТСПУ)..."
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": 443,
    "users": [{ "uuid": "${UUID}" }],
    "tls": {
      "enabled": true,
      "certificate_path": "/etc/sing-box/cert/cert.pem",
      "key_path": "/etc/sing-box/cert/key.pem"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
/usr/local/bin/sing-box check -c /etc/sing-box/config.json

say "5/6 Сервис + автозапуск..."
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sing-box >/dev/null 2>&1
# фаервол (если есть ufw)
if command -v ufw >/dev/null 2>&1; then ufw allow 22/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1; fi

say "6/6 Готово!"
IP=$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null)
LINK="vless://${UUID}@${IP}:443?type=tcp&security=tls&allowInsecure=1#Мой сервер"
echo ""
echo -e "${YEL}=================================================================${NC}"
echo -e "${GREEN}  ВСЁ ГОТОВО! Скопируй ссылку ниже и вставь в «Свобода VPN»:${NC}"
echo -e "${YEL}=================================================================${NC}"
echo ""
echo "$LINK"
echo ""
echo -e "${YEL}=================================================================${NC}"
echo "  (Приложение: кнопка «Серверы» -> вставить ссылку -> Добавить)"
echo "  Проверка сервера: systemctl status sing-box"
echo -e "${YEL}=================================================================${NC}"
