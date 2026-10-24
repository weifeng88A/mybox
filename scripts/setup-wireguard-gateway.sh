#!/usr/bin/env bash
set -euo pipefail

WG_NAME="mybox-wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_NAME}.conf"
WG_KEY="${WG_DIR}/${WG_NAME}.key"
WG_PUB="${WG_DIR}/${WG_NAME}.pub"
WG_PORT="${WG_PORT:-51820}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.66.0.1/24}"
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-10.66.0.2/32}"
WG_CLIENT_PUBLIC_KEY="${WG_CLIENT_PUBLIC_KEY:-}"
WG_INTERFACE="${WG_INTERFACE:-}"

usage() {
  cat <<'EOF'
用法:
  setup-wireguard-gateway.sh --client-public-key <客户端公钥>

可选环境变量:
  WG_PORT=51820
  WG_INTERFACE=eth0       # 不设置时自动识别 IPv4 默认出口网卡
  WG_SERVER_ADDR=10.66.0.1/24
  WG_CLIENT_ADDR=10.66.0.2/32
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --client-public-key)
      WG_CLIENT_PUBLIC_KEY="${2:-}"
      shift 2
      ;;
    --interface)
      WG_INTERFACE="${2:-}"
      shift 2
      ;;
    --port)
      WG_PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行此脚本。" >&2
  exit 1
fi
if [ -z "${WG_CLIENT_PUBLIC_KEY}" ]; then
  echo "缺少 --client-public-key。请先在 IPv6-only VPS 的 mybox 中生成客户端配置。" >&2
  exit 1
fi
if ! printf '%s' "${WG_CLIENT_PUBLIC_KEY}" | grep -Eq '^[A-Za-z0-9+/]{43}={0,1}$'; then
  echo "客户端公钥格式不正确。" >&2
  exit 1
fi

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iptables
  else
    echo "未找到 apt-get、dnf 或 yum。" >&2
    exit 1
  fi
}

command -v wg >/dev/null 2>&1 || install_deps
command -v wg-quick >/dev/null 2>&1 || install_deps
command -v iptables >/dev/null 2>&1 || install_deps

if [ -z "${WG_INTERFACE}" ]; then
  WG_INTERFACE="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
if [ -z "${WG_INTERFACE}" ] || ! ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
  echo "无法自动识别 IPv4 公网出口网卡，请使用 --interface eth0 重试。" >&2
  exit 1
fi

install -d -m 0700 "${WG_DIR}"
if [ ! -s "${WG_KEY}" ]; then
  umask 077
  wg genkey > "${WG_KEY}"
fi
wg pubkey < "${WG_KEY}" > "${WG_PUB}"
chmod 600 "${WG_KEY}"
chmod 644 "${WG_PUB}"

cat > "${WG_CONF}" <<EOF
# Managed by mybox
[Interface]
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${WG_KEY}")
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.66.0.0/24 -o ${WG_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.66.0.0/24 -o ${WG_INTERFACE} -j MASQUERADE

[Peer]
PublicKey = ${WG_CLIENT_PUBLIC_KEY}
AllowedIPs = ${WG_CLIENT_ADDR}
EOF
chmod 600 "${WG_CONF}"

cat > /etc/sysctl.d/99-mybox-wireguard-gateway.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "${WG_PORT}/udp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${WG_PORT}/udp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

systemctl enable --now "wg-quick@${WG_NAME}"
sleep 2

SERVER_PUBLIC_KEY="$(cat "${WG_PUB}")"
echo
echo "双栈 VPS WireGuard 网关已配置完成。"
echo "公网出口网卡: ${WG_INTERFACE}"
echo "WireGuard 配置: ${WG_CONF}"
echo "WireGuard 公钥: ${SERVER_PUBLIC_KEY}"
echo
echo "请回到 IPv6-only VPS，把上面的公钥填入客户端 Peer.PublicKey，然后启动："
echo "  systemctl enable --now wg-quick@${WG_NAME}"
echo "验证 IPv4 出口："
echo "  curl -4 https://api.ipify.org; echo"
