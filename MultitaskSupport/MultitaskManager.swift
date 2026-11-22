//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    
    @objc class func registerMultitaskContainer(container: String) {
        usingMultitaskContainers.append(container)
        postRunningAppsChangedNotification()
    }

    @objc class func unregisterMultitaskContainer(container: String) {
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
        postRunningAppsChangedNotification()
    }

    private class func postRunningAppsChangedNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.MultitaskRunningAppsChanged, object: nil)
            // PROBE P1（2026-11-22）：refresh 接线暂撤，定位启动闪退中。
        }
    }

    /// Terminate the multitask session using the given container, in whichever
    /// multitask mode it is running. Returns false when the container is not
    /// running in this LiveContainer instance.
    @objc class func terminateApp(container: String) -> Bool {
        guard isUsing(container: container) else {
            return false
        }
        // Virtual window mode: the dock tracks every running window.
        if #available(iOS 16.0, *) {
            if let app = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == container }),
               let view = app.view,
               let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                // Red-X close: no curl-up exit animation.
                decoratedVC.closeWindowWithoutAnimation()
                return true
            }
        }
        // Native window mode: ask the SwiftUI window hosting this container to close.
        if #available(iOS 16.1, *) {
            if MultitaskWindowManager.appDict[container] != nil {
                NotificationCenter.default.post(
                    name: NSNotification.MultitaskCloseWindowRequested,
                    object: nil,
                    userInfo: ["dataUUID": container]
                )
                return true
            }
        }
        return false
    }
    
    @objc class func isUsing(container: String) -> Bool {
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        return usingMultitaskContainers.count > 0
    }
}
