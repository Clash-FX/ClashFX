### Bug Fixes

- **System Proxy Toggle Restored** — The privileged helper now accepts ad-hoc signed clients again, so toggling system proxy from the menu bar works and the helper install dialog no longer loops. Regression introduced in v1.0.30 by the strict XPC code-signature check; bundle-ID validation is preserved. Thanks @agentforhuan for the detailed report. (#65, #68)
- **GEOIP Database Update Fixed** — `Debug → Update GEOIP Database` now succeeds. The default download URL was pointing to mihomo's proprietary metadb format which the verifier rejected, causing every update to fail with "Database verify fail" and silently fall back to the bundled database. Thanks @qgdsdfq8xv-a11y. (#66, #67)

---
### 修复

- **修复系统代理开关失效** — 特权助手恢复了对 ad-hoc 签名客户端的接受，菜单栏的系统代理切换重新可用，助手安装弹窗不再死循环。该问题是 v1.0.30 引入的 XPC 代码签名严格校验导致；本次仍保留 bundle ID 校验。感谢 @agentforhuan 的详细报告。（#65, #68）
- **修复 GEOIP 数据库更新** — `调试 → 更新 GEOIP 数据库` 现在能成功。默认下载地址原本指向 mihomo 的私有 metadb 格式，验证器无法识别，每次更新都报 "Database verify fail" 并悄悄回退到内置数据库。感谢 @qgdsdfq8xv-a11y。（#66, #67）
