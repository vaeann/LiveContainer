# 来源与第三方署名

## 上游

本仓库是以下项目的衍生构建：

- **LiveContainer** — https://github.com/LiveContainer/LiveContainer
  许可证：GNU Affero General Public License v3.0
  Copyright (c) LiveContainer contributors

本仓库不修改任何业务逻辑，只调整构建流水线（版本号注入、产物打包、上游同步机制）。
构建产物与上游 Release 使用相同的 Bundle ID `com.kdt.livecontainer`。

## 第三方组件

以下组件由上游引入，本仓库原样沿用：

| 组件 | 来源 | 许可证 |
|---|---|---|
| litehook | https://github.com/opa334/litehook | MIT |
| CFastFind | https://github.com/pinauten/PatchfinderUtils | MIT |
| ZSign | https://github.com/zhlynn/zsign ，Feather 改版 https://github.com/khcrysalis/Feather | MIT |
| FrontBoardAppLauncher | https://github.com/khanhduytran0/FrontBoardAppLauncher | 见原仓库 |
| OpenSSL | https://github.com/krzyzanowskim/OpenSSL | Apache-2.0 |
| fishhook | https://github.com/LiveContainer/fishhook | BSD-3-Clause |
| xpn 的 dyld 内存加载研究 | https://blog.xpnsec.com/restoring-dyld-memory-loading/ | 见原文 |

## 说明

本仓库**不提供任何签名证书**，也不绕过苹果的签名校验机制。产物是未签名 IPA，
须由使用者用自己的 Apple 开发者证书签名后安装。

本项目仅用于在自己拥有的设备上安装自行编译或合法获取的应用。
