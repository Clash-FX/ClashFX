<h1 align="center">
  ClashFX
  <br>
</h1>

<h4 align="center">A rule-based macOS proxy client with Enhanced Mode (TUN) — powered by mihomo core.</h4>

<div align="center">

[English](README.md) | [简体中文](README_zh-CN.md) | [繁體中文](README_zh-TW.md) | [日本語](README_ja.md) | [Русский](README_ru.md)

</div>

---

## ✨ Features

- **Enhanced Mode (TUN)** — Global traffic capture via TUN device, one-click setup
- HTTP/HTTPS and SOCKS protocol support
- Rule-based routing (Domain, IP-CIDR, GeoIP, Process)
- Support for VMess/VLESS/Trojan/Shadowsocks/Hysteria2 protocols
- DNS security with Fake-IP mode
- gVisor userspace network stack
- Apple Silicon native support
- macOS 10.14+ compatibility (including macOS 15 Sequoia)

## 📥 Installation

Download from the [Releases](https://github.com/Clash-FX/ClashFX/releases) page.

### 🧪 Update Channels: Stable & Lab

ClashFX ships through two update channels. You can choose either — both are first-class.

| | 🟢 Stable | 🟠 Lab |
|---|---|---|
| **Default** | ✅ | — |
| **Release cadence** | Every 2–7 days, when fixes accumulate | As soon as a fix lands — sometimes daily |
| **What you get** | Tested fixes only | Latest fixes + occasional experimental features |
| **Visual badge** | None | Small orange dot on the top-right of the Dock / Applications icon |

**Opt into Lab**: open `ClashFX → Settings → Debug → Update Channel → Lab (Experimental)` and confirm. The orange dot appears immediately. You can switch back to Stable from the same place at any time.

**Found a Lab bug?** Use `Help → Send Feedback…` to open a pre-filled GitHub issue (diagnostic info auto-attached and redacted), or `Help → Copy Diagnostic Info…` to copy the report manually.

Stable users: you're already on the recommended channel — nothing to change.

## 🔨 Build from Source

### Prerequisites

- macOS 10.14 or later
- Xcode 15.0+
- Python 3
- Golang 1.21+

### Build Steps

1. **Install Golang**
   ```bash
   brew install golang
   ```

2. **Install dependencies**
   ```bash
   bash install_dependency.sh
   ```

3. **Open and build**
   ```bash
   open ClashFX.xcworkspace
   # Build in Xcode (Cmd+R)
   ```

## ⚙️ Configuration

### Default Paths

The default configuration directory is `$HOME/.config/clashfx`

The default configuration file name is `config.yaml`. You can use custom config names and switch between them in the `Config` menu.

### Enhanced Mode

ClashFX's core feature — TUN-based global proxy that captures all TCP/UDP traffic from every application, not just browsers.

**How to enable:**
1. Menu Bar → Enhanced Mode → Enable
2. Grant administrator privileges on first use
3. All traffic is now routed through ClashFX

### URL Schemes

- **Import remote config:**
  ```
  clashfx://install-config?url=http%3A%2F%2Fexample.com&name=example
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- **Reload current config:**
  ```
  clash://update-config
  ```

## 🤝 Companion Repo: cn-apps-direct

The **"Bypass Common Chinese Apps"** toggle (added in v1.0.38, under Enhanced Mode) reads its `PROCESS-NAME` rule list from **[Clash-FX/cn-apps-direct](https://github.com/Clash-FX/cn-apps-direct)** — a small community-maintained repo of macOS executable names for high-frequency Chinese apps (WeChat, QQ, DingTalk, Feishu, Bilibili, etc.). The list updates automatically every 24 hours via `rule-provider`, decoupled from the ClashFX release cycle.

**Want to add an app or fix a wrong process name?** PRs are welcome — see [CONTRIBUTING.md](https://github.com/Clash-FX/cn-apps-direct/blob/main/CONTRIBUTING.md). Adding an entry takes about a minute:

```bash
ls /Applications/<App>.app/Contents/MacOS/   # verify the actual executable name
# append the verified name as: PROCESS-NAME,<name>,DIRECT
# open a PR
```

## 📄 License

[AGPL-3.0](LICENSE)

## 🙏 Acknowledgments

- [mihomo](https://github.com/MetaCubeX/mihomo) — Core proxy engine
- [ClashX](https://github.com/bannedbook/ClashX) — Original macOS client
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — Dashboard UI
