<h1 align="center">
  ClashFX
  <br>
</h1>

<h4 align="center">具備增強模式 (TUN) 的 macOS 規則代理客戶端 — 基於 mihomo 核心</h4>

<div align="center">

[English](README.md) | [简体中文](README_zh-CN.md) | [繁體中文](README_zh-TW.md) | [日本語](README_ja.md) | [Русский](README_ru.md)

</div>

---

## ✨ 功能特性

- **增強模式 (TUN)** — 透過 TUN 虛擬網卡全域流量擷取，一鍵開啟
- 支援 HTTP/HTTPS 和 SOCKS 協定
- 規則路由（網域、IP-CIDR、GeoIP、程序匹配）
- 支援 VMess/VLESS/Trojan/Shadowsocks/Hysteria2 協定
- DNS 安全（Fake-IP 模式）
- gVisor 使用者態網路堆疊
- Apple Silicon 原生支援
- 支援 macOS 10.14+（包含 macOS 15 Sequoia）

## 📥 安裝

從 [Releases](https://github.com/Clash-FX/ClashFX/releases) 頁面下載。

### 🧪 更新通道:正式版與實驗室版

ClashFX 提供兩條更新通道,你可以自由選擇。

| | 🟢 正式版 (Stable) | 🟠 實驗室版 (Lab) |
|---|---|---|
| **預設** | ✅ | — |
| **更新頻率** | 通常每 2–7 天累積一批修復後發布 | 修復一落地就推送,可能每天都有 |
| **包含內容** | 經過測試的修復 | 最新修復 + 偶有實驗性功能 |
| **視覺標識** | 無 | Dock / 應用程式裡的 app 圖示右上角有橘色小圓點 |

**加入實驗室版**:開啟 `ClashFX → 設定 → 調試 → 更新通道 → 實驗室版 (Lab)` 並確認。橘色小圓點會立刻出現。任何時候都可以從同樣的路徑切回正式版。

**實驗室版遇到問題?** 在 `說明 → 回饋問題…` 中打開預填好的 GitHub Issue(診斷資訊自動附上並脫敏),或 `說明 → 複製診斷資訊…` 手動複製報告。

正式版使用者:你已經在推薦的通道上,無需任何操作。

## 🔨 從原始碼建置

### 環境需求

- macOS 10.14 或更高版本
- Xcode 15.0+
- Python 3
- Golang 1.21+

### 建置步驟

1. **安裝 Golang**
   ```bash
   brew install golang
   ```

2. **安裝依賴**
   ```bash
   bash install_dependency.sh
   ```

3. **開啟並建置**
   ```bash
   open ClashFX.xcworkspace
   # 在 Xcode 中建置 (Cmd+R)
   ```

## ⚙️ 設定

### 預設路徑

預設設定目錄為 `$HOME/.config/clashfx`

預設設定檔名為 `config.yaml`。您可以使用自訂設定名稱，並在「設定」選單中切換。

### 增強模式

ClashFX 的核心功能 — 基於 TUN 的全域代理，擷取所有應用程式的 TCP/UDP 流量，不僅限於瀏覽器。

**啟用方法：**
1. 選單列 → 增強模式 → 啟用
2. 首次使用需授予管理員權限
3. 所有流量現在都透過 ClashFX 路由

### URL Schemes

- **匯入遠端設定：**
  ```
  clashfx://install-config?url=http%3A%2F%2Fexample.com&name=example
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- **重新載入目前設定：**
  ```
  clash://update-config
  ```

## 🤝 配套儲存庫：cn-apps-direct

v1.0.38 新增的 **「Bypass Common Chinese Apps」（增強模式 → 國內 App 直連）** 開關會從 **[Clash-FX/cn-apps-direct](https://github.com/Clash-FX/cn-apps-direct)** 拉取 `PROCESS-NAME` 規則清單，這是社群共同維護的國內高頻 macOS 客戶端可執行檔名列表（微信、QQ、釘釘、飛書、嗶哩嗶哩等）。清單透過 `rule-provider` 每 24 小時自動更新，與 ClashFX 發版週期解耦。

**想新增 App 或修正錯誤的程序名？** 歡迎提 PR——參考 [CONTRIBUTING.md](https://github.com/Clash-FX/cn-apps-direct/blob/main/CONTRIBUTING.md)。新增一筆大約一分鐘：

```bash
ls /Applications/<App>.app/Contents/MacOS/   # 驗證實際可執行檔名
# 把驗證後的名字追加為: PROCESS-NAME,<name>,DIRECT
# 開 PR
```

## 📄 授權條款

[AGPL-3.0](LICENSE)

## 🙏 致謝

- [mihomo](https://github.com/MetaCubeX/mihomo) — 代理引擎核心
- [ClashX](https://github.com/bannedbook/ClashX) — 原始 macOS 客戶端
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — Dashboard 面板
