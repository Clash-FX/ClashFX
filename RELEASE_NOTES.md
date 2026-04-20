## ClashFX 1.0.12

### Improvements

- **Fixed subscription downloads from mihomo/SS-2022 providers** — Remote subscription requests now send a `mihomo` User-Agent instead of the default Alamofire client identity. This avoids certain providers misclassifying ClashFX as a legacy Dreamacro/clash client and returning empty or dummy configs instead of real nodes.
- **Fixed Appearance tab height not adapting to content** — The Appearance settings window now resizes correctly when switching tabs, eliminating clipped or awkward spacing in the UI.

---

### 改进

- **修复 mihomo / SS-2022 订阅兼容性** — 托管订阅请求现在会以 `mihomo` 的 User-Agent 拉取配置，避免部分机场把 ClashFX 误判成旧版 Dreamacro/clash 客户端，从而返回空配置或占位节点，而不是真实节点列表。
- **修复外观标签页高度不随内容变化** — 外观设置窗口在切换标签页时现在会正确自适应高度，避免内容被裁切或留白不自然。

---

### Contributors

Thanks to everyone who contributed to this release:

- @ayangweb — Appearance tab adaptive height fix (#25)

[![Download ClashFX](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/clashfx/files/1.0.12/)
