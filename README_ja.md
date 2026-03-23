<h1 align="center">
  ClashFX
  <br>
</h1>

<h4 align="center">拡張モード (TUN) 搭載の macOS 用ルールベースプロキシクライアント — mihomo コアを使用</h4>

<div align="center">

[English](README.md) | [简体中文](README_zh-CN.md) | [繁體中文](README_zh-TW.md) | [日本語](README_ja.md) | [Русский](README_ru.md)

</div>

---

## ✨ 機能

- **拡張モード (TUN)** — TUN デバイスによるグローバルトラフィックキャプチャ、ワンクリックで設定
- HTTP/HTTPS および SOCKS プロトコル対応
- ルールベースルーティング（ドメイン、IP-CIDR、GeoIP、プロセス）
- VMess/VLESS/Trojan/Shadowsocks/Hysteria2 プロトコル対応
- Fake-IP モードによる DNS セキュリティ
- gVisor ユーザースペースネットワークスタック
- Apple Silicon ネイティブ対応
- macOS 10.14+ 対応（macOS 15 Sequoia を含む）

## 📥 インストール

[Releases](https://github.com/Clash-FX/ClashFX/releases) ページからダウンロードしてください。

## 🔨 ソースからビルド

### 前提条件

- macOS 10.14 以降
- Xcode 15.0+
- Python 3
- Golang 1.21+

### ビルド手順

1. **Golang のインストール**
   ```bash
   brew install golang
   ```

2. **依存関係のインストール**
   ```bash
   bash install_dependency.sh
   ```

3. **プロジェクトを開いてビルド**
   ```bash
   open ClashFX.xcworkspace
   # Xcode でビルド (Cmd+R)
   ```

## ⚙️ 設定

### デフォルトパス

デフォルトの設定ディレクトリは `$HOME/.config/clash` です。

デフォルトの設定ファイル名は `config.yaml` です。カスタム設定名を使用し、「設定」メニューで切り替えることができます。

### 拡張モード

ClashFX のコア機能 — TUN ベースのグローバルプロキシで、ブラウザだけでなく全アプリケーションの TCP/UDP トラフィックをキャプチャします。

**有効化方法：**
1. メニューバー → 拡張モード → 有効化
2. 初回使用時に管理者権限を付与
3. すべてのトラフィックが ClashFX 経由でルーティングされます

### URL スキーム

- **リモート設定のインポート：**
  ```
  clashfx://install-config?url=http%3A%2F%2Fexample.com&name=example
  clash://install-config?url=http%3A%2F%2Fexample.com&name=example
  ```

- **現在の設定を再読み込み：**
  ```
  clash://update-config
  ```

## 📄 ライセンス

[AGPL-3.0](LICENSE)

## 🙏 謝辞

- [mihomo](https://github.com/MetaCubeX/mihomo) — プロキシエンジンコア
- [ClashX](https://github.com/bannedbook/ClashX) — オリジナル macOS クライアント
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — ダッシュボード UI
