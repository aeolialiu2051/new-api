# WarpGate API Docs

独立静态文档站，无构建依赖。入口文件为 `index.html`。

## 本地预览

```bash
python3 -m http.server 4173 --directory docs-site
```

打开 `http://localhost:4173/#/docs`。

## 部署

推送 `docs-site/` 或 `.github/workflows/docs-site.yml` 的变更到 `warpgate` 分支后，GitHub Actions 会自动将本站部署到 GitHub Pages。也可以在 Actions 页面手动运行 `Deploy docs site`。

站点使用自定义域名 <https://docs.warpgateapi.com>。首次部署前需要：

1. 在仓库 Settings → Pages 中将 Source 设置为 `GitHub Actions`。
2. 为 `docs.warpgateapi.com` 配置指向仓库 GitHub Pages 域名的 DNS `CNAME` 记录。
3. DNS 生效后，在 Pages 设置中确认自定义域名，并启用 `Enforce HTTPS`。

由于路由使用 URL hash，不需要额外配置服务端 fallback。
