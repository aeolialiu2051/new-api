# WarpGate API Docs

独立静态文档站，无构建依赖。入口文件为 `index.html`。

## 本地预览

```bash
python3 -m http.server 4173 --directory docs-site
```

打开 `http://localhost:4173/#/docs`。

## 部署

将 `docs-site/` 内的文件上传到 `docs.warpgateapi.com` 的站点根目录即可。由于路由使用 URL hash，不需要额外配置服务端 fallback。

建议为域名启用 HTTPS、Brotli/Gzip 和静态资源缓存；`index.html` 使用短缓存，CSS/JS 可使用版本化 URL 后配置长缓存。
