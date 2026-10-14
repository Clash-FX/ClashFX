## ClashFX 1.1.11.12 (Lab)

### Improvements

- **Install the Helper After Applying a Lab or Custom Icon** — Finder icon metadata could make strict validation of the staged app fail, blocking the helper update and Enhanced Mode startup in 1.1.11.11. Both installer staging paths now remove only FinderInfo and ResourceFork from the private copy before verification; the original app icon is preserved.
- **Keep Signature and Core Trust Checks Intact** — Full app signature verification, client CDHash, helper/core hashes, root ownership and symlink containment checks remain required. Altered executable or signed-resource bytes are still rejected.
- **Exercise Installation Before Publishing** — Add metadata-decorated signed-bundle regressions to source and release CI, and verify the production administrator installer plus helper-managed core startup in a disposable hosted guest. Installation gates run before any release tag is published.

Validation: source CI, metadata cleanup/tamper regressions and hosted installation/startup acceptance must pass before tagging. The GitHub Actions release pipeline rebuilds the app and universal cores, checks the packaged architectures/minimum versions, signs the DMG with Sparkle and produces the Lab update feed. Full GUI authorization-dialog interaction and macOS 10.14 runtime testing are outside demonstrated coverage. Subscription YAML handling is unchanged.

---

### 改进

- **设置 Lab／自定义图标后仍可安装辅助程序** — Finder 图标元数据会导致暂存 App 的严格签名检查失败，从而阻止 1.1.11.11 的 helper 更新和增强模式启动。两个安装暂存路径现在仅清除副本中的 FinderInfo 与 ResourceFork，再执行验证；原 App 图标保留。
- **保留完整签名与核心信任校验** — App 完整签名、客户端 CDHash、helper／核心哈希、root 归属与链接范围仍必须通过检查；被修改的可执行文件或签名资源仍会被拒绝。
- **发布前验证安装流程** — 源码与发布 CI 增加带图标元数据的签名 App 回归检查，并在一次性托管环境验证生产管理员安装脚本和 helper 管理的核心启动；通过安装门槛后才打发布标签。

验证：源码 CI、元数据清理／篡改拒绝测试和托管环境安装／启动验收通过后才发布。GitHub Actions 重新构建 App 与通用核心，检查最终包架构及最低系统版本，执行 Sparkle 签名并生成 Lab 更新订阅。未覆盖 GUI 授权弹窗交互和 macOS 10.14 实机运行。订阅 YAML 处理未改动。
