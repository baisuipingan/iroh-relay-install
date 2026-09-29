#!/usr/bin/env bash
# ============================================================================
#  iroh 中继 · 一台机器的全部部署
#
#  用法（新机器上一条命令）：
#     bash -c "$(curl -sSL https://get.editor.vip/iroh/install.sh)"
#  卸载：
#     bash -c "$(curl -sSL https://get.editor.vip/iroh/install.sh)" -- remove
#
#  设计原则：一台中继 = 1 个容器 + 1 个配置文件 + 1 个证书目录。
#    没有 systemd，没有 nginx，不改动机器上任何无关服务。
#    证书续期后中继自动重读（cert_mode = "Reloading"），不需要重启。
# ============================================================================
set -euo pipefail

DIR="${RELAY_DIR:-/opt/iroh/relay}"   # RELAY_DIR 仅用于测试，正常不用管
IMG="n0computer/iroh-relay"
VER="${IROH_RELAY_VERSION:-v1.3.0}"
DEFAULT_PORT=8443
CONTAINER_NAME="${IROH_CONTAINER_NAME:-iroh-relay}"

c()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok() { c "32" "  ✓ $*"; }
wa() { c "33" "  ! $*"; }
er() { c "31" "  ✗ $*"; exit 1; }
hr() { c "90" "────────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------- 卸载
if [ "${1:-}" = "remove" ] || [ "${2:-}" = "remove" ]; then
  hr; c "1" " 卸载 iroh 中继"; hr
  [ -d "$DIR" ] || er "没找到 $DIR，这台机器没装过"
  (cd "$DIR" && docker compose down 2>/dev/null) || true
  crontab -l 2>/dev/null | grep -v "$DIR/cert-sync.sh" | crontab - 2>/dev/null || true
  for p in $(sed -n 's/^RELAY_PORT=//p' "$DIR/.env" 2>/dev/null); do
    ufw delete allow "$p/tcp" >/dev/null 2>&1 || true
  done
  rm -rf "$DIR"
  ok "已删除 $DIR、容器、cron 任务与防火墙规则"
  ok "镜像保留（$IMG:$VER），如不需要：docker rmi $IMG:$VER"
  exit 0
fi

# ---------------------------------------------------------------- 交互
# 取值规则：优先用环境变量（便于自动化/CI）；没有才交互问；非交互环境直接报错
need() {  # need <变量名> <提示> [默认值]
  local name="$1" prompt="$2" def="${3:-}" val
  eval "val=\${$name:-}"
  [ -z "$val" ] && [ -n "$def" ] && val="$def"
  if [ -z "$val" ]; then
    [ -t 0 ] || er "非交互运行：请用环境变量提供 $name"
    read -rp "  $prompt" val
  fi
  eval "$name=\$val"
}
clear 2>/dev/null || true
hr; c "1" " iroh 中继安装器"; hr
c "90" " 一台机器一个中继。装完给你一条可用的中继地址。"
echo

[ "$(id -u)" = "0" ] || er "请用 root 运行"

# 1) 域名
need DOMAIN "[1/4] 中继域名（需已解析到本机，例如 relay-3.editor.vip）: "
[ -n "$DOMAIN" ] || er "域名不能为空"
RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
MYPUB=$(curl -s --max-time 8 https://api.ipify.org || true)
if [ -n "$RESOLVED" ] && [ -n "$MYPUB" ] && [ "$RESOLVED" != "$MYPUB" ]; then
  wa "域名解析到 $RESOLVED，但本机出口 IP 是 $MYPUB —— 证书签发会失败，先改 DNS"
  read -rp "  仍要继续？[y/N] " a; [ "${a:-n}" = "y" ] || exit 1
fi

# 2) 证书来源
echo
if [ -z "${CERT_CHOICE:-}" ]; then
  c "1" "  [2/4] 证书来源"
  c "90" "   1) Cloudflare DNS 自动签发 —— 推荐：不占任何端口，全自动续期"
  c "90" "   2) 复用已有证书 —— 机器上已有 1Panel/acme.sh/certbot 签好的证书"
  need CERT_CHOICE "选择 [1]: " 1
fi

CF_TOKEN="${CF_TOKEN:-}"; CERT_SRC="${CERT_SRC:-}"
if [ "$CERT_CHOICE" = "1" ]; then
  need CF_TOKEN "Cloudflare API Token（权限 Zone.DNS 编辑）: "
  [ -n "$CF_TOKEN" ] || er "Token 不能为空"
else
  need CERT_SRC "证书目录（含 fullchain.pem + privkey.pem，或 acme.sh 的 *_ecc 目录）: "
  [ -d "$CERT_SRC" ] || er "目录不存在: $CERT_SRC"
  # 自动识别文件名
  if   [ -f "$CERT_SRC/fullchain.pem" ]; then SRC_CRT=fullchain.pem; SRC_KEY=privkey.pem
  elif [ -f "$CERT_SRC/fullchain.cer" ]; then SRC_CRT=fullchain.cer; SRC_KEY="$DOMAIN.key"
  else er "没在 $CERT_SRC 里找到 fullchain.pem 或 fullchain.cer"; fi
  ok "识别到 $SRC_CRT + $SRC_KEY"
fi

# 3) 端口
echo
need RELAY_PORT "[3/4] 对外端口" "$DEFAULT_PORT"
if ss -tln 2>/dev/null | grep -q ":$RELAY_PORT "; then
  # 如果占用者就是我们自己的中继容器（重复安装场景），允许继续；否则报错
  if docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -q "^$CONTAINER_NAME|.*iroh-relay"; then
    wa "端口 $RELAY_PORT 由本中继容器占用，将重建（等价于升级/重装）"
  else
    er "端口 $RELAY_PORT 已被其它服务占用，换一个（看看 ss -tlnp）"
  fi
fi

# 4) 确认
echo
hr
c "1" "  [4/4] 确认"
echo "   域名      : $DOMAIN"
echo "   中继地址  : https://$DOMAIN:$RELAY_PORT"
echo "   证书来源  : $([ "$CERT_CHOICE" = 1 ] && echo 'Cloudflare DNS 自动签发' || echo "$CERT_SRC")"
echo "   安装目录  : $DIR"
echo "   QAD/打洞  : 关闭（纯中继，不占任何 UDP 端口）"
hr
if [ -t 0 ]; then
  read -rp "  开始安装？[Y/n] " a; [ "${a:-y}" = "n" ] && exit 0
else
  [ "${CONFIRM:-}" = "yes" ] || er "非交互运行：确认信息无误后加环境变量 CONFIRM=yes"
fi

# ---------------------------------------------------------------- 环境
echo
command -v docker >/dev/null 2>&1 || er "没装 docker。先装：curl -fsSL https://get.docker.com | sh"
docker compose version >/dev/null 2>&1 || er "docker compose 不可用（docker 版本太老？）"
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

mkdir -p "$DIR/certs"
cd "$DIR"

# ---------------------------------------------------------------- 写文件
cat > relay.toml <<TOML
enable_relay = true
http_bind_addr = "127.0.0.1:0"           # 0 = 让系统随便给个空闲口，避免和其它服务撞
enable_quic_addr_discovery = false       # 纯中继不打洞：不占任何 UDP 端口
enable_metrics = false                   # 不用就不开，少一个绑定
access = "everyone"

[tls]
https_bind_addr = "0.0.0.0:$RELAY_PORT"
cert_mode = "Reloading"                  # 周期性重读证书 → 续期零重启
cert_dir = "/etc/iroh-relay/certs"
TOML

cat > docker-compose.yml <<'YAML'
services:
  iroh-relay:
    image: n0computer/iroh-relay:v1.3.0
    container_name: __NAME__
    network_mode: host          # 必须：否则来源 IP 被 NAT、且绕过 ufw
    restart: unless-stopped
    volumes:
      - ./relay.toml:/etc/iroh-relay/relay.toml:ro
      - ./certs:/etc/iroh-relay/certs:ro
    command: ["--config-path", "/etc/iroh-relay/relay.toml"]
YAML
sed -i -e "s|n0computer/iroh-relay:v1.3.0|$IMG:$VER|" -e "s|__NAME__|$CONTAINER_NAME|" docker-compose.yml

cat > .env <<ENV
DOMAIN=$DOMAIN
RELAY_PORT=$RELAY_PORT
CERT_MODE=$([ "$CERT_CHOICE" = 1 ] && echo cloudflare || echo reuse)
CERT_SRC=$CERT_SRC
CERT_SRC_CRT=${SRC_CRT:-fullchain.cer}
CERT_SRC_KEY=${SRC_KEY:-}
ENV
chmod 600 .env
ok "写了 relay.toml / docker-compose.yml / .env"

# ---------------------------------------------------------------- 证书
if [ "$CERT_CHOICE" = "1" ]; then
  if [ ! -x /root/.acme.sh/acme.sh ]; then
    ok "安装 acme.sh"
    curl -sS https://get.acme.sh | sh -s email="acme@$DOMAIN" >/dev/null 2>&1
  fi
  export CF_Token="$CF_TOKEN"
  ok "用 DNS-01 向 Let's Encrypt 申请证书（不占任何端口）"
  /root/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 >/dev/null \
    || er "签发失败：检查域名是否在 Cloudflare 托管、Token 是否有 Zone.DNS 编辑权限"
  SRC_CRT_DIR="/root/.acme.sh/${DOMAIN}_ecc"
  SRC_CRT="fullchain.cer"; SRC_KEY="$DOMAIN.key"
  sed -i "s|^CERT_SRC=.*|CERT_SRC=$SRC_CRT_DIR|; s|^CERT_SRC_KEY=.*|CERT_SRC_KEY=$SRC_KEY|" .env
  ok "证书已签发"
fi

cat > cert-sync.sh <<'SH'
#!/usr/bin/env bash
# 把外部签发的证书同步成中继 Reloading 期望的命名（default.crt/default.key）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/.env"
SRC="${CERT_SRC:?}"; CRT="${CERT_SRC_CRT:-fullchain.pem}"; KEY="${CERT_SRC_KEY:-privkey.pem}"
DST="$HERE/certs"
[ -r "$SRC/$CRT" ] && [ -r "$SRC/$KEY" ] || { echo "源证书缺失: $SRC/$CRT 或 $SRC/$KEY" >&2; exit 1; }
B=$(sha256sum "$DST/default.crt" 2>/dev/null | cut -d' ' -f1 || echo none)
install -m 644 "$SRC/$CRT" "$DST/default.crt"
install -m 644 "$SRC/$KEY" "$DST/default.key"
A=$(sha256sum "$DST/default.crt" | cut -d' ' -f1)
[ "$B" = "$A" ] && echo "证书无变化" || echo "证书已更新（中继会自动重读，无需重启）"
SH
chmod +x cert-sync.sh

./cert-sync.sh
[ -s "$DIR/certs/default.crt" ] || er "证书没同步成功"
ok "证书就位：$DIR/certs/default.crt"

# ---------------------------------------------------------------- 起服务
# 幂等：清掉可能残留的旧实例（否则会因端口被崩溃重启中的旧容器占着而起不来）
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker compose down --remove-orphans >/dev/null 2>&1 || true

docker compose up -d >/dev/null 2>&1

# 等健康（最多 30s），本地直连避免受 DNS 影响
for i in $(seq 1 15); do
  sleep 2
  if curl -sk --max-time 4 "https://127.0.0.1:$RELAY_PORT/healthz" 2>/dev/null | grep -q '"status":"ok"'; then
    ok "容器已运行并通过健康检查（${i}×2s）"
    break
  fi
  if [ "$i" = "15" ]; then
    echo; docker compose logs --tail 20
    er "容器 30 秒内没起来"
  fi
done

# 防火墙（只一条规则）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$RELAY_PORT/tcp" >/dev/null && ok "ufw 放行 $RELAY_PORT/tcp"
fi

# 证书自动同步（每 6 小时）
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
  wa "健康检查没通过：$HZ"
  wa "常见原因：DNS 没生效 / 云朵没关（Cloudflare 必须 DNS-only）/ 端口没放行"
fi
WS=$(curl -sS -i -m 5 -H "Connection: Upgrade" -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
      -H "Sec-WebSocket-Protocol: iroh-relay-v2" "https://$DOMAIN:$RELAY_PORT/relay" 2>/dev/null | head -1 || true)
echo "$WS" | grep -q "101" && ok "中继协议可用：$WS" || wa "WebSocket 升级异常：$WS"

echo
hr; c "32" " 装完了"; hr
echo "  中继地址（加进前端名单）："
c "36" "    https://$DOMAIN:$RELAY_PORT"
echo
echo "  常用命令："
echo "    docker compose -f $DIR/docker-compose.yml logs -f     # 看日志"
echo "    docker compose -f $DIR/docker-compose.yml restart     # 重启"
echo "    $DIR/cert-sync.sh                                     # 手动同步证书"
echo "    bash -c \"\$(curl -sSL <本脚本URL>)\" -- remove          # 卸载"
hr
