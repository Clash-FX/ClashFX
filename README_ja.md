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

### 🧪 アップデートチャンネル: 安定版と Lab 版

ClashFX は 2 種類のアップデートチャンネルを提供します。お好みで選べます。

| | 🟢 安定版 | 🟠 Lab (実験版) |
|---|---|---|
| **デフォルト** | ✅ | — |
| **リリース頻度** | 通常 2–7 日ごとに修正をまとめてリリース | 修正がマージされた直後 — 毎日のこともあります |
| **内容** | テスト済みの修正のみ | 最新の修正 + 時々実験的機能 |
| **見分けるマーク** | なし | Dock /「アプリケーション」フォルダのアイコン右上にオレンジの小さな丸 |

**Lab に切り替える**: `ClashFX → 設定 → デバッグ → 更新チャネル → ラボ版 (実験的)` を選んで確認します。オレンジの丸はすぐに表示されます。同じ場所からいつでも安定版に戻せます。

**Lab で不具合に遭遇したら?** `ヘルプ → 問題を報告…` で診断情報入りの GitHub Issue を開けます(IP・ホスト名等は自動でマスク済み)。手動でコピーしたい場合は `ヘルプ → 診断情報をコピー…` を選んでください。

安定版ユーザー: すでに推奨のチャンネルにいます。何もする必要はありません。

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

デフォルトの設定ディレクトリは `$HOME/.config/clashfx` です。

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

## 🤝 関連リポジトリ：cn-apps-direct

v1.0.38 で追加された **「Bypass Common Chinese Apps」（拡張モード → 中国系アプリの直接接続）** トグルは、**[Clash-FX/cn-apps-direct](https://github.com/Clash-FX/cn-apps-direct)** から `PROCESS-NAME` ルールリストを取得します。これは中国でよく使われる macOS クライアント（WeChat、QQ、DingTalk、Feishu、Bilibili など）の実行ファイル名を集めたコミュニティ管理のリストです。リストは `rule-provider` 経由で 24 時間ごとに自動更新され、ClashFX のリリースサイクルから独立しています。

**アプリを追加したい・プロセス名の誤りを修正したい？** PR を歓迎します —— [CONTRIBUTING.md](https://github.com/Clash-FX/cn-apps-direct/blob/main/CONTRIBUTING.md) を参照してください。エントリの追加は約 1 分で完了します：

```bash
ls /Applications/<App>.app/Contents/MacOS/   # 実際の実行ファイル名を確認
# 確認した名前を以下の形式で追加: PROCESS-NAME,<name>,DIRECT
# PR を開く
```

## 📄 ライセンス

[AGPL-3.0](LICENSE)

## 🙏 謝辞

- [mihomo](https://github.com/MetaCubeX/mihomo) — プロキシエンジンコア
- [ClashX](https://github.com/bannedbook/ClashX) — オリジナル macOS クライアント
- [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) — ダッシュボード UI
