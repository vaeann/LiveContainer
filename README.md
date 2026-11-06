# LiveContainer 自建构建

基于 [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) 的私人构建仓库。

只做一件事：把官方源码编译成**未签名**的 `LiveContainer.ipa`，由你自己签名安装。
不构建 `LiveContainer+SideStore.ipa`（二合一版），只出单版本。

---

## 为什么不改 Bundle ID

`xcconfigs/Global.xcconfig` 里这两行是关键：

```
DEVELOPMENT_TEAM_SUFFIX[config=Release] =
LIVECONTAINER_BUNDLE_IDENTIFIER = com.kdt.livecontainer$(DEVELOPMENT_TEAM_SUFFIX)
```

Release 构建时 `DEVELOPMENT_TEAM_SUFFIX` 是**空的**，所以产出的 bundle id 固定为
`com.kdt.livecontainer`，和官方 Release 完全一致。

同时 Release 配置里 `CODE_SIGNING_REQUIRED = NO`，`DEVELOPMENT_TEAM = AAAAA11111`
只是个占位符。也就是说，**这个 IPA 出厂时没有签名身份**，等你签名的那一刻才注入你自己的 team id。

`entitlements.xml` 里所有 keychain 组也是变量：

```
$(AppIdentifierPrefix)com.kdt.livecontainer.shared.0  ...  .127
```

`AppIdentifierPrefix` 由你的签名证书决定。

**结论：只要用同一个 Apple ID 签官方版和本仓库的包，bundle id 与 keychain 组完全一致，
iOS 会把它当作同一个应用覆盖安装，容器数据（已装的 App、设置、容器）全部保留。**

### 必须满足的两个条件

1. **同一个 Apple ID 签名。** 之前用 A 账号签的，就必须继续用 A 账号。换证书 = 换应用，数据读不出来。
2. **`CFBundleVersion` 递增。** 已由工作流自动处理，见下节。

---

## 版本号策略

上游 `LiveContainer/Info.plist` 把 `CFBundleVersion` 硬编码成和 `CFBundleShortVersionString`
一样的值。如果每次构建都用同一个 build number，AltStore / SideStore 会认为"没有更新"，
直接拒绝覆盖安装。

构建时自动改写：

```
CFBundleShortVersionString = 3.8.11        （保持上游原值，显示用）
CFBundleVersion            = 30811.42      （固定宽度版本号 . GitHub RunNumber）
```

格式是「固定宽度的版本号 . 运行序号」——主版本 1 位、次版本补 2 位、修订号补 2 位：

- 同一版本重复构建时递增 → 能覆盖安装
- 上游升版本时自然跃升（`3.8.11 → 30811`，`3.9.0 → 30900`）→ 依然能覆盖

不能直接去掉小数点：那样 `3.9.0` 会变成 `390`，反而小于 `3.8.11` 的 `3811`，
系统会判定为降级并拒绝安装。

---

## 构建

`Actions` → `Build IPA` → `Run workflow`

| 输入 | 说明 |
|---|---|
| `upstream_ref` | 留空 = 直接构建当前代码；填 `main` = 先合并上游 main 再构建 |
| `create_release` | 构建完成后发 GitHub Release（默认开） |
| `strip_symbols` | 对产物 strip 瘦身，默认**关**（会丢崩溃符号，包会小一点） |

产物：
- Actions artifact：`LiveContainer-<版本>-<构建号>`，保留 30 天
- Release 附件：`LiveContainer.ipa`

跑一次大约 8-12 分钟。公开仓库的 macOS runner 免费，不占额度。

---

## 同步上游

**日常路径**：`Check upstream commit` 每天跑一次，发现上游 main 有比上次构建更新的 commit
就开一个 issue。看到 issue 后去 `Build IPA`，`upstream_ref` 填 `main`。

> 官方的 Release tag 只有固定的 `1.0` 和 `nightly`，按 tag 没法判断版本新旧，
> 所以检测逻辑比的是 **commit 时间**。

**手动路径**：直接在 `upstream_ref` 里填 `main`。

**合并结果会推回仓库**：workflow 里 merge 完会 `git push` 回当前分支，这样 Release
附件对应的源码在仓库里能查到（AGPL 要求）。推送失败只会 warning，不影响构建。

**冲突处理**：如果上游改动了本仓库也改过的文件，merge 会在 `Merge upstream` 步骤失败
并打印冲突文件名。这时需要本地解决：

```bash
git remote add upstream https://github.com/LiveContainer/LiveContainer.git
git config merge.ours.driver true          # 让 .gitattributes 的 merge=ours 生效
git fetch upstream --tags
git merge upstream/main
# 解决冲突后
git push
```

`.gitattributes` 已经把本仓库自己的文件标记成 `merge=ours`，所以
`build.yml`、`README.md`、`scripts/make-ipa.sh` 不会被上游覆盖，正常不会冲突。

---

## 签名

本仓库**不签名**，产物是裸 IPA。签名方式二选一：

- **AltStore / SideStore**：添加本仓库的 Release 链接作为源，或直接下载 IPA 用它们安装
- **Sideloadly**：Windows / macOS 都能用，拖进去输入 Apple ID 即可

免费 Apple ID 签名 7 天到期，付费开发者账号 1 年。

> 不要用企业证书对外分发。Enterprise Program 明确禁止面向公众发布，证书会被永久吊销。

---

## 已移除的上游文件

| 文件 | 原因 |
|---|---|
| `.github/workflows/build.yml` | 已被本仓库版本覆盖（上游是 `on: push` 全自动，会白白消耗构建时间并自动发 nightly release） |
| `.github/workflows/update_source.yml` | 用于更新上游自己的 AltStore 源，本仓库不需要 |

---

## 许可

本项目是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的衍生作品，
遵循 **GNU Affero General Public License v3.0**，完整许可证见 [LICENSE](LICENSE)。

分发本仓库构建的二进制时，必须同时提供对应源码（即本仓库本身），并保留原始版权声明。
上游另有声明：不认可任何闭源的第三方构建，因为 LiveContainer 内的所有 App 数据
（含 keychain 与登录凭证）对宿主完全可见。

第三方组件署名见 [NOTICE.md](NOTICE.md)。
