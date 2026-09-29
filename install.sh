#!/usr/bin/env bash
# ============================================================================
#  iroh 中继 · 一台机器的全部部署
#
#  用法（新机器上一条命令）：
#     bash -c "$(curl -sSL https://raw.githubusercontent.com/baisuipingan/iroh-relay-install/main/install.sh)"
#  卸载：
#     bash -c "$(curl -sSL …/install.sh)" remove
#
#  设计原则：一台中继 = 1 个容器 + 1 个配置文件 + 1 个证书目录。
#    没有 systemd，没有 nginx，不占 80/443，不占任何 UDP 端口。
#    证书用 Cloudflare DNS-01 签发（不需要任何端口），续期后中继自动重读，不重启。
#
#  非交互（CI/批量）：DOMAIN=x.editor.vip CF_TOKEN=xxx CONFIRM=yes bash install.sh
# ============================================================================
set -euo pipefail

DIR="${RELAY_DIR:-/opt/iroh/relay}"   # RELAY_DIR 仅供测试
IMG="n0computer/iroh-relay"
VER="${IROH_RELAY_VERSION:-v1.3.0}"
DEFAULT_PORT=15443
ACME=/root/.acme.sh/acme.sh

c()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok() { c "32" "  ✓ $*"; }
wa() { c "33" "  ! $*"; }
er() { c "31" "  ✗ $*"; exit 1; }
hr() { c "90" "────────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------- 卸载
if [ "${1:-}" = "remove" ] || [ "${2:-}" = "remove" ]; then
  hr; c "1" " 卸载 iroh 中继"; hr
  [ -d "$DIR" ] || er "没找到 $DIR，这台机器没装过"
  D=$(sed -n 's/^DOMAIN=//p' "$DIR/.env" 2>/dev/null || true)
  P=$(sed -n 's/^RELAY_PORT=//p' "$DIR/.env" 2>/dev/null || true)
  (cd "$DIR" && docker compose down 2>/dev/null) || true
  docker rm -f iroh-relay >/dev/null 2>&1 || true
  crontab -l 2>/dev/null | grep -v "$DIR/cert-sync.sh" | crontab - 2>/dev/null || true
  if [ -n "$P" ]; then ufw delete allow "$P/tcp" >/dev/null 2>&1 || true; fi
  rm -rf "$DIR"
  ok "已删除 $DIR、容器、cron 任务与防火墙规则"
  if [ -n "$D" ]; then wa "证书目录保留，如需一并删除：rm -rf /root/.acme.sh/${D}_ecc"; fi
  exit 0
fi

# ---------------------------------------------------------------- 交互
need() {  # need <变量名> <提示> [默认值] [quiet]
  local name="$1" prompt="$2" def="${3:-}" quiet="${4:-}" val
  eval "val=\${$name:-}"
  if [ -z "$val" ] && [ -n "$def" ]; then val="$def"; fi
  if [ -z "$val" ]; then
    [ -t 0 ] || er "非交互运行：请用环境变量提供 $name"
    if [ -n "$quiet" ]; then read -rsp "  $prompt" val; echo; else read -rp "  $prompt" val; fi
  fi
  eval "$name=\$val"
}

[ "$(id -u)" = "0" ] || er "请用 root 运行"

hr; c "1" " iroh 中继安装器"; hr
c "90" " 一台机器一个中继，装完给你一条可用的中继地址。"
echo
need DOMAIN "中继域名（已在 Cloudflare 解析到本机，例如 relay-3.editor.vip）: "
[ -n "$DOMAIN" ] || er "域名不能为空"

RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
MYPUB=$(curl -s --max-time 8 https://api.ipify.org || true)
if [ -n "$RESOLVED" ] && [ -n "$MYPUB" ] && [ "$RESOLVED" != "$MYPUB" ]; then
  wa "域名解析到 $RESOLVED，本机出口 IP 是 $MYPUB —— 不一致，签发会失败"
  read -rp "  仍要继续？[y/N] " a; [ "${a:-n}" = "y" ] || exit 1
fi

# Cloudflare Token：本机已保存过就不再问
TOKEN_SAVED=0
if [ -f /root/.acme.sh/account.conf ] && grep -q '^SAVED_CF_Token=' /root/.acme.sh/account.conf; then
  TOKEN_SAVED=1
fi
if [ -z "${CF_TOKEN:-}" ]; then
  if [ "$TOKEN_SAVED" = "1" ]; then
    ok "使用本机已保存的 Cloudflare Token（要更换：删掉 /root/.acme.sh/account.conf 再跑）"
  else
    c "90" " 证书用 Cloudflare DNS-01 签发（不占任何端口），需要一枚 API Token"
    c "90" " 权限：Zone → DNS → Edit 与 Zone → Zone → Read，范围限定到你的域名"
    need CF_TOKEN "Cloudflare API Token: " "" quiet
    [ -n "$CF_TOKEN" ] || er "Token 不能为空"
  fi
fi

echo
need RELAY_PORT "对外端口" "$DEFAULT_PORT"
if ss -tln 2>/dev/null | grep -q ":$RELAY_PORT "; then
  if docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -q "^iroh-relay|.*iroh-relay"; then
    wa "端口 $RELAY_PORT 由本中继容器占用，将重建"
  else
    er "端口 $RELAY_PORT 已被其它服务占用，换一个（ss -tlnp 看看）"
  fi
fi

echo
hr; c "1" " 确认"; hr
echo "   域名      : $DOMAIN"
echo "   中继地址  : https://$DOMAIN:$RELAY_PORT"
echo "   证书      : Cloudflare DNS-01（自动续期，不占端口）"
echo "   安装目录  : $DIR"
hr
if [ -t 0 ]; then
  read -rp "  开始安装？[Y/n] " a; [ "${a:-y}" = "n" ] && exit 0
else
  [ "${CONFIRM:-}" = "yes" ] || er "非交互运行：确认后加 CONFIRM=yes"
fi

# ---------------------------------------------------------------- 环境
echo
command -v docker >/dev/null 2>&1 || er "没装 docker。先装：curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || er "docker compose 不可用（docker 版本太老？）"
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

mkdir -p "$DIR/certs"; cd "$DIR"

# ---------------------------------------------------------------- 配置文件
cat > relay.toml <<TOML
enable_relay = true
http_bind_addr = "127.0.0.1:0"           # 0 = 系统随便给个空闲口，不占 80/3340
enable_quic_addr_discovery = false       # 纯中继不打洞：不占任何 UDP 端口
enable_metrics = false                   # 不用就不开
access = "everyone"

[tls]
https_bind_addr = "0.0.0.0:$RELAY_PORT"
cert_mode = "Reloading"                  # 周期性重读证书 → 续期零重启
cert_dir = "/etc/iroh-relay/certs"
TOML

cat > docker-compose.yml <<YAML
services:
  iroh-relay:
    image: $IMG:$VER
    container_name: iroh-relay
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./relay.toml:/etc/iroh-relay/relay.toml:ro
      - ./certs:/etc/iroh-relay/certs:ro
    command: ["--config-path", "/etc/iroh-relay/relay.toml"]
YAML

# ---------------------------------------------------------------- 证书
if [ ! -x "$ACME" ]; then
  ok "安装 acme.sh"
  curl -sS https://get.acme.sh | sh -s email="acme@$DOMAIN" >/dev/null 2>&1 || er "acme.sh 安装失败"
fi

if [ -f "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" ]; then
  ok "复用已有证书"
else
  ok "用 Cloudflare DNS-01 向 Let's Encrypt 申请证书（不占任何端口，约 10~30 秒）"
  if [ -n "${CF_TOKEN:-}" ]; then export CF_Token="$CF_TOKEN"; fi
  "$ACME" --issue --dns dns_cf -d "$DOMAIN" --server letsencrypt --keylength ec-256 >/dev/null 2>&1 \
    || er "签发失败：检查域名是否在 Cloudflare 托管、Token 权限是否含 Zone:DNS:Edit 与 Zone:Zone:Read"
fi

CERT_SRC="/root/.acme.sh/${DOMAIN}_ecc"
cat > .env <<ENV
DOMAIN=$DOMAIN
RELAY_PORT=$RELAY_PORT
CERT_SRC=$CERT_SRC
CERT_SRC_CRT=fullchain.cer
CERT_SRC_KEY=$DOMAIN.key
ENV
chmod 600 .env

cat > cert-sync.sh <<'SH'
#!/usr/bin/env bash
# 把 acme.sh 的证书同步成中继 Reloading 期望的命名（default.crt/default.key）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/.env"
SRC="${CERT_SRC:?}"; CRT="${CERT_SRC_CRT:-fullchain.cer}"; KEY="${CERT_SRC_KEY:?}"
DST="$HERE/certs"
[ -r "$SRC/$CRT" ] && [ -r "$SRC/$KEY" ] || { echo "源证书缺失: $SRC/$CRT 或 $SRC/$KEY" >&2; exit 1; }
B=$(sha256sum "$DST/default.crt" 2>/dev/null | cut -d' ' -f1 || echo none)
install -m 644 "$SRC/$CRT" "$DST/default.crt"
install -m 644 "$SRC/$KEY" "$DST/default.key"
A=$(sha256sum "$DST/default.crt" | cut -d' ' -f1)
if [ "$B" = "$A" ]; then echo "证书无变化"; else echo "证书已更新（中继会自动重读，无需重启）"; fi
SH
chmod +x cert-sync.sh

./cert-sync.sh
[ -s "$DIR/certs/default.crt" ] || er "证书没同步成功"
ok "证书就位：$DIR/certs/default.crt"

# ---------------------------------------------------------------- 起服务
docker rm -f iroh-relay >/dev/null 2>&1 || true
docker compose down --remove-orphans >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1

for i in $(seq 1 15); do
  sleep 2
  if curl -sk --max-time 4 "https://127.0.0.1:$RELAY_PORT/healthz" 2>/dev/null | grep -q '"status":"ok"'; then
    ok "容器已运行并通过健康检查（${i}×2s）"; break
  fi
  if [ "$i" = "15" ]; then echo; docker compose logs --tail 20; er "容器 30 秒内没起来"; fi
done

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$RELAY_PORT/tcp" >/dev/null && ok "ufw 放行 $RELAY_PORT/tcp"
fi

if ! crontab -l 2>/dev/null | grep -q "$DIR/cert-sync.sh"; then
  (crontab -l 2>/dev/null; echo "0 */6 * * * $DIR/cert-sync.sh >> /var/log/iroh-cert-sync.log 2>&1") | crontab -
  ok "已加入 cron：每 6 小时同步证书（中继自动重读，不重启）"
fi

# ---------------------------------------------------------------- 验收
echo
hr; c "1" " 验收"; hr
HZ=$(curl -sS --max-time 10 "https://$DOMAIN:$RELAY_PORT/healthz" 2>&1 || true)
if echo "$HZ" | grep -q '"status":"ok"'; then
  ok "HTTPS + 证书：$HZ"
else
  wa "健康检查没通过：$HZ（DNS 没生效？云朵没关？）"
fi
WS=$(curl -sS -i -m 5 -H "Connection: Upgrade" -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     -H "Sec-WebSocket-Protocol: iroh-relay-v2" "https://$DOMAIN:$RELAY_PORT/relay" 2>/dev/null | head -1 || true)
if echo "$WS" | grep -q "101"; then ok "中继协议可用：$WS"; else wa "WebSocket 升级异常：$WS"; fi

echo
hr; c "32" " 装完了"; hr
echo "  中继地址（加进前端名单）："
c "36" "    https://$DOMAIN:$RELAY_PORT"
echo
echo "  常用命令："
echo "    cd $DIR && docker compose logs -f            # 日志"
echo "    cd $DIR && docker compose restart            # 重启"
echo "    $DIR/cert-sync.sh                            # 手动同步证书"
echo "    bash -c \"\$(curl -sSL <脚本URL>)\" remove      # 卸载"
hr
