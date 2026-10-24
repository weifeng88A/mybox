#!/usr/bin/env bash
set -euo pipefail
key="${1:-}"
if [ -z "$key" ]; then
  echo "用法: bash wg.sh <IPv6-only VPS 的 WireGuard 客户端公钥>" >&2
  exit 1
fi
exec bash <(curl -fsSL --retry 3 --connect-timeout 10 \
  https://cdn.jsdelivr.net/gh/weifeng88A/mybox@main/scripts/setup-wireguard-gateway.sh) \
  --client-public-key "$key"
