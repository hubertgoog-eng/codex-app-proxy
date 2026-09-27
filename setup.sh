#!/usr/bin/env bash
set -euo pipefail
umask 077

server_ip="${1:-}"
resume_mode="${2:-}"
if [[ $EUID -ne 0 ]]; then
  echo '请以 root 身份运行。' >&2
  exit 1
fi
if [[ ! $server_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '用法: bash setup-vless-reality.sh <VPS公网IPv4>' >&2
  exit 1
fi
if [[ -e /usr/local/bin/xray || -e /usr/local/etc/xray/config.json ]]; then
  if [[ $resume_mode != --resume ]]; then
    echo '检测到现有 Xray。若要接续之前失败的安装，请在命令末尾加 --resume。' >&2
    exit 1
  fi
fi
if ss -H -ltn | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
  ssh_ports=/etc/ssh/sshd_config.d/ports.conf
  if ss -H -ltnp | grep -E '(:|\])443[[:space:]]' | grep -q 'sshd' &&
     [[ -f $ssh_ports ]] && grep -qx 'Port 443' "$ssh_ports"; then
    echo 'SSH 当前占用 TCP 443；VLESS 服务需要此端口。'
    read -r -p '移除之前临时添加的 SSH 443，保留其他 SSH 端口？[y/N] ' answer
    if [[ $answer != y && $answer != Y ]]; then
      echo '未修改 SSH；安装已停止。' >&2
      exit 1
    fi
    backup=$(mktemp)
    cp "$ssh_ports" "$backup"
    sed -i '/^Port 443$/d' "$ssh_ports"
    if ! sshd -t || ! systemctl restart ssh.service; then
      cp "$backup" "$ssh_ports"
      systemctl restart ssh.service || true
      echo 'SSH 调整失败，原配置已恢复。' >&2
      exit 1
    fi
    rm -f "$backup"
  fi
fi
if ss -H -ltn | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
  echo 'TCP 443 仍被占用。请先确认占用该端口的服务。' >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
if [[ $resume_mode != --resume ]]; then
  apt-get update
  apt-get install -y ca-certificates curl openssl
fi

if [[ ! -x /usr/local/bin/xray ]]; then
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl -fsSL 'https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh' -o "$installer"
  bash "$installer" install
fi

xray=/usr/local/bin/xray
config=/usr/local/etc/xray/config.json
uuid=$(cat /proc/sys/kernel/random/uuid)
key_output=$($xray x25519)
mapfile -t keys < <(printf '%s\n' "$key_output" | grep -oE '[A-Za-z0-9_-]{43}' | head -n 2)
private_key=${keys[0]:-}
public_key=${keys[1]:-}
short_id=$(openssl rand -hex 8)
if [[ -z $uuid || -z $private_key || -z $public_key || -z $short_id ]]; then
  echo '生成连接参数失败；没有修改 Xray 配置。' >&2
  printf '%s\n' "$key_output" | awk -F: 'NF>1 {print "Xray field: " $1} NF==1 {print "Xray field: (unlabeled)"}' >&2
  exit 1
fi

new_config=$(mktemp --suffix=.json "${config}.new.XXXXXX")
trap 'rm -f "$new_config"' EXIT
cat > "$new_config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
service_user=$(systemctl show -p User --value xray)
service_user=${service_user:-root}
service_group=$(id -gn "$service_user")
chown "root:$service_group" "$new_config"
chmod 640 "$new_config"

$xray run -test -config "$new_config"
if [[ -f $config ]]; then
  backup="${config}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$config" "$backup"
  echo "原配置已备份到 $backup"
fi
mv -f "$new_config" "$config"
if ! systemctl enable --now xray || ! systemctl restart xray || ! systemctl is-active --quiet xray; then
  if [[ -n ${backup:-} ]]; then
    cp -a "$backup" "$config"
    systemctl restart xray || true
  fi
  echo 'Xray 未能启动；已尝试恢复原配置。请运行 journalctl -u xray -n 40 --no-pager 查看错误。' >&2
  exit 1
fi
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 443/tcp
fi

connection_file=/root/vless-reality-connection.txt
cat > "$connection_file" <<EOF
服务端: $server_ip:443
协议: VLESS + REALITY + Vision (TCP)
UUID: $uuid
SNI: www.microsoft.com
Public key: $public_key
Short ID: $short_id
Fingerprint: chrome
Flow: xtls-rprx-vision

vless://$uuid@$server_ip:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#VPS-Reality
EOF
chmod 600 "$connection_file"

echo
echo '服务端安装完成；Xray 正在运行。'
echo '请确认 VPS 服务商的防火墙也允许入站 TCP 443。'
echo "连接参数已保存到 $connection_file"
