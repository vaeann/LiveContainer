//
//  LCBundledSideStoreTranslator.swift
//  LiveContainerSwiftUI
//
//  内置 SideStore 翻译插件（dompling 的 SideStoreTranslator.dylib）
//  的部署。二合一包里以 base64 形式携带——散装 dylib 会被装机重签
//  改坏加载命令，和 CZFKeepAlive 同样的教训——LC 启动时解码、写
//  进全局插件目录的 SideStoreTranslator 子文件夹并签名。子文件
//  夹不会被 TweakLoader 自动加载（它只加载根目录和各 App 自选
//  的文件夹），LCBootstrap 在内置 SideStore 启动时单独 dlopen
//  它，所以这个插件只进 SideStore，不进其他 App。独立版没有
//  base64 资源，本部署自动跳过。
//

import CryptoKit
import Foundation

enum LCBundledSideStoreTranslator {
    private static let folderName = "SideStoreTranslator"
    private static let dylibName = "SideStoreTranslator.dylib"
    private static let signedDigestKey = "LCSideStoreTranslatorSignedDigest"

    static func sync() {
        guard let b64URL = Bundle.main.url(forResource: "SideStoreTranslator.dylib", withExtension: "b64"),
              let b64Data = try? Data(contentsOf: b64URL),
              let data = Data(base64Encoded: b64Data, options: .ignoreUnknownCharacters) else {
            return
        }
        let fm = FileManager.default
        // 签名纪律与 CZFKeepAlive 部署一致：内容变了才重签；已签
        // 摘要存标准 defaults（重装会清掉），对不上时也重签一次。
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let alreadySigned = UserDefaults.standard.string(forKey: signedDigestKey) == digest
        var foldersToSign: [URL] = []
        for root in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            let folder = root.appendingPathComponent(folderName)
            // 用户把 dylib 改名成 .disabled 就是要关掉它：尊重这个
            // 状态，不再重新部署这个文件夹。
            if fm.fileExists(atPath: folder.appendingPathComponent(dylibName + ".disabled").path) {
                continue
            }
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(dylibName)
            let existing = try? Data(contentsOf: dest)
            var updated = false
            if existing != data {
                // 先写临时文件再换位，写失败时旧文件原样保留。
                let tmp = dest.appendingPathExtension("tmp")
                try? fm.removeItem(at: tmp)
                if (try? data.write(to: tmp)) != nil {
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: tmp, to: dest)
                    updated = true
                }
            }
            if updated || !alreadySigned {
                foldersToSign.append(folder)
            }
        }
        guard !foldersToSign.isEmpty else { return }
        // 两个文件夹的签名在一个 Task 里串行做：LCUtils 的签名机
        // 器不是并发安全的（CZFKeepAlive 部署的既有教训）。
        Task {
            for folder in foldersToSign {
                do {
                    try await LCUtils.signTweaks(tweakFolderUrl: folder, force: true)
                } catch {
                    NSLog("[SideStoreTranslator] sign failed for %@: %@", folder.path, error.localizedDescription)
                    return
                }
            }
            UserDefaults.standard.set(digest, forKey: signedDigestKey)
        }
    }
}
