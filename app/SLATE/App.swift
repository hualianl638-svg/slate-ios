import SwiftUI
import UIKit

/// 全局方向控制：App 平时锁竖屏，只有全屏预览时放开横屏，
/// 避免编辑器（竖屏定高布局）在横屏下被挤压溢出。
final class OrientationController {
    static let shared = OrientationController()
    var allowLandscape = false

    /// 请求系统重新评估方向（iOS 16+）。
    static func refresh() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:
            shared.allowLandscape ? .allButUpsideDown : .portrait))
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.shared.allowLandscape ? .allButUpsideDown : .portrait
    }
}

@main
struct SLATEApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ShellView()
                .preferredColorScheme(.dark)
        }
    }
}
