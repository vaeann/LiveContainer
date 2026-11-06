# LiveContainer 自建构建

> **本仓库是 [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) 的修改版本。**
> 自 2026-11-06 起由 [@vaeann](https://github.com/vaeann) 维护，与上游的差异见文末
> [本仓库的改动](#本仓库的改动)。按 **AGPL-3.0** 分发，完整许可证见 [LICENSE](LICENSE)。

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

> **Runner 用的是 `macos-26-intel`，不是 `macos-latest`。** macOS arm64 runner 容量紧张，
> 排队 15 分钟拿不到机器就会被系统直接放弃（注解原文：`The job was not acquired by
> Runner of type hosted even after multiple attempts`）。Intel 镜像实测 10 秒内分配。
> 交叉编译 iOS arm64 与宿主架构无关，产物一致。

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

## 开发时注意

### 引入第三方库

AGPL-3.0 对许可证兼容性很严格，引入不兼容的库会导致整个项目不能合法分发。

| 许可证 | 能否引入 |
|---|---|
| MIT / BSD-2 / BSD-3 / ISC | 可以 |
| Apache-2.0 | 可以（与 AGPL-3.0 兼容）|
| MPL-2.0 | 可以（文件级 copyleft）|
| LGPL-2.1 / LGPL-3.0 | 谨慎，动态链接一般可以，静态链接有问题 |
| GPL-2.0-only | **不行**，与 AGPL-3.0 不兼容 |
| 任何「非商业」「仅个人使用」许可 | **不行**，那不是开源许可 |

加库之前先看它的 LICENSE。SPM 项目可以用 `swift package show-dependencies` 列出全部依赖。

### 改动放在哪里

新功能尽量放在独立目录（比如 `MyFeature/`），不要改 `main.m`、`LiveContainerSwiftUI/`
这些上游高频变动的文件，否则每次同步上游都要解冲突。

`.gitattributes` 只保护列出的那些文件。**新建目录不会自动受保护**——如果上游恰好也起了同名路径，照样冲突。

### 每次 push 会自动检查

`guard.yml` 会拦下这些情况：

- `LICENSE` 内容被改动（sha256 比对）
- 仓库里出现 `.p12` / `.p8` / `.mobileprovision` / `.ipa` / `.env` 等
- `xcconfigs/Global.xcconfig` 的 bundle id 或 Release 后缀被改
- 关键文件被删除，或 workflow 被改名
- `.gitmodules` 少了 submodule
- README 丢了上游链接或 AGPL 声明

红了就看 Guard 的日志，它会指出具体是哪一条。

---

## 已移除的上游文件

| 文件 | 原因 |
|---|---|
| `.github/workflows/build.yml` | 已被本仓库版本覆盖（上游是 `on: push` 全自动，会白白消耗构建时间并自动发 nightly release） |
| `.github/workflows/update_source.yml` | 用于更新上游自己的 AltStore 源，本仓库不需要 |

---

## 本仓库的改动

AGPL-3.0 第 5(a) 条要求标注修改并给出日期。以下是相对上游的全部差异：

| 日期 | 文件 | 改动 |
|---|---|---|
| 2026-11-06 | `.github/workflows/build.yml` | 替换上游 `on: push` 全自动构建为手动触发；构建前注入递增的 `CFBundleVersion`；runner 改为 `macos-26-intel`；Release 描述附对应源码链接 |
| 2026-11-06 | `.github/workflows/check-upstream.yml` | 新增。每日比对上游 main 的 commit 时间，有更新则开 issue 提醒 |
| 2026-11-06 | `.github/workflows/guard.yml` | 新增。静态检查合规与安全基线（LICENSE 哈希、敏感文件、bundle id、关键文件） |
| 2026-11-06 | `scripts/make-ipa.sh` | 新增。把 `.xcarchive` 打成未签名 IPA |
| 2026-11-06 | `.github/workflows/update_source.yml` | 删除。该文件用于更新上游自己的 AltStore 源，本仓库不需要 |
| 2026-11-06 | `.gitignore` | 追加签名材料与凭证的忽略规则 |
| 2026-11-06 | `.gitattributes` | 新增。标记本仓库自有文件为 `merge=ours`，同步上游时不被覆盖 |
| 2026-11-06 | `README.md` / `NOTICE.md` | 重写为面向本仓库的说明与署名 |

**App 自身的业务代码（`LiveContainer/`、`LiveContainerSwiftUI/` 等）未做任何修改。**
构建产物与上游 Release 一致：未签名、Bundle ID 为 `com.kdt.livecontainer`。

---

## 许可

本项目是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 的衍生作品，
遵循 **GNU Affero General Public License v3.0**，完整许可证见 [LICENSE](LICENSE)。

分发本仓库构建的二进制时，必须同时提供对应源码（即本仓库本身），并保留原始版权声明。
上游另有声明：不认可任何闭源的第三方构建，因为 LiveContainer 内的所有 App 数据
（含 keychain 与登录凭证）对宿主完全可见。

第三方组件署名见 [NOTICE.md](NOTICE.md)。
