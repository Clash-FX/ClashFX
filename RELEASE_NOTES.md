## ClashFX 1.0.18

### Bug Fixes / 问题修复

- **Fixed subscription links with VMess/Trojan/VLESS/Hysteria protocols** — Subscription URLs that return share-link lists (vmess://, trojan://, vless://, hysteria://, hysteria2://) are now automatically converted to Clash-compatible YAML configs. Previously only Shadowsocks (ss://) links were supported; all other protocols silently failed with a "yaml unmarshal" error. Fixes #45.
- **Fixed raw (non-base64) share-link subscriptions** — Subscription URLs that return plain-text share links without base64 encoding are now handled correctly.

### Improvements / 改进

- **Full transport layer support for converted share links** — Auto-generated configs from share links now support WebSocket, gRPC, HTTP/2, and HTTP obfuscation transport layers, as well as TLS, ALPN, fingerprint, and Reality options.

---

### 问题修复

- **修复 VMess/Trojan/VLESS/Hysteria 协议的订阅链接** — 返回分享链接列表（vmess://、trojan://、vless://、hysteria://、hysteria2://）的订阅 URL 现在会自动转换为 Clash 兼容的 YAML 配置。此前仅支持 Shadowsocks (ss://) 链接，其他协议会静默失败并报「yaml unmarshal」错误。修复 #45。
- **修复未经 base64 编码的原始分享链接订阅** — 订阅 URL 直接返回明文分享链接（未经 base64 编码）的情况现在也能正确处理。

### 改进

- **分享链接转换支持完整传输层** — 从分享链接自动生成的配置现在支持 WebSocket、gRPC、HTTP/2 和 HTTP 混淆传输层，以及 TLS、ALPN、指纹和 Reality 选项。

---

### Contributors / 贡献者

- **@B_White** — reported issue #45

[![Download ClashFX](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/clashfx/files/1.0.18/)
