## ClashFX 1.0.1

### Bug Fixes & Improvements

- **Fix status bar speed overflow** — Network speed text (e.g. "4.22MB/s") no longer intrudes into the vertical separator line. The status item now dynamically resizes based on actual text width
- **Fix auto-update system** — All appcast download URLs were pointing to the wrong repository (`ClashX-Pro/ClashX`) with the wrong filename (`ClashX.dmg`). Corrected to `Clash-FX/ClashFX` with `ClashFX.dmg`. Auto-update should now work properly
- **Fix update script** — `update_appcast.sh` now requires EdDSA signature (mandatory for Sparkle 2.x), preserves version history instead of overwriting, and uses correct URLs
- **Fix prelease channel** — The "Prelease" update channel was pointing to the same feed as "Stable". It now uses a separate `appcast-prerelease.xml` feed
- **Code cleanup** — Renamed `AutoUpgardeManager` → `AutoUpgradeManager` (typo fix)

### Documentation

- Added README translations: 繁體中文, 日本語, Русский
- Updated language switcher across all README files (5 languages)
- Fixed stale `ClashX.xcworkspace` reference → `ClashFX.xcworkspace`

---

### 修复与改进

- **修复状态栏网速溢出** — 高速率文本（如 "4.22MB/s"）不再侵入竖线分隔符。状态栏项现在根据实际文本宽度动态调整大小
- **修复自动更新系统** — appcast.xml 中所有下载 URL 指向了错误仓库（`ClashX-Pro/ClashX`）和错误文件名（`ClashX.dmg`）。已修正为 `Clash-FX/ClashFX` 和 `ClashFX.dmg`
- **修复更新脚本** — `update_appcast.sh` 现在强制要求 EdDSA 签名（Sparkle 2.x 必需），保留版本历史而非覆盖，使用正确的 URL
- **修复预发布频道** — "Prelease" 更新频道之前指向与 "Stable" 相同的 feed，现在使用独立的 `appcast-prerelease.xml`
- **代码清理** — 修正 `AutoUpgardeManager` → `AutoUpgradeManager` 拼写错误

### 文档

- 新增 README 翻译：繁體中文、日本語、Русский
- 更新所有 README 语言切换器（5 种语言）
- 修正 `ClashX.xcworkspace` → `ClashFX.xcworkspace` 引用
