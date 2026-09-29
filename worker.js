/**
 * Cloudflare Worker：把 GitHub 上的安装脚本用你自己的域名发出去。
 *
 * 作用：给你一个稳定、好记、国内也顺的 URL：
 *     bash -c "$(curl -sSL https://get.editor.vip/iroh/install.sh)"
 * 换脚本内容时只改 GitHub，URL 不变。
 *
 * 部署：
 *   1) 改下面的 GH_RAW 为你的 GitHub raw 地址
 *   2) 新建 Worker，粘贴本文件
 *   3) 加路由 get.editor.vip/*（该主机名需要有一条开启代理的占位 DNS 记录）
 */

const GH_RAW = 'https://raw.githubusercontent.com/<你的账号>/iroh-relay-install/main/install.sh';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (!url.pathname.endsWith('/install.sh') && url.pathname !== '/') {
      return new Response('not found\n', { status: 404 });
    }
    // 边缘缓存 5 分钟：改完 GitHub 最多 5 分钟后生效
    const cache = caches.default;
    const cacheKey = new Request(GH_RAW, { method: 'GET' });
    let res = await cache.match(cacheKey);
    if (!res) {
      res = await fetch(GH_RAW, { cf: { cacheTtl: 300 } });
      if (!res.ok) return new Response('upstream error\n', { status: 502 });
      res = new Response(res.body, res);
      res.headers.set('Cache-Control', 'public, max-age=300');
      await cache.put(cacheKey, res.clone());
    }
    return new Response(res.body, {
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=300' },
    });
  },
};
