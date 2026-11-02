import SwiftUI
import UIKit

@main
struct BYDCompanionApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Long-lived services, created at launch so a background relaunch by iOS
/// (Bluetooth restore, geofence) finds them ready even with no screen shown.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let ble: BleCarLink
    let autoUnlock: AutoUnlock

    private init() {
        ble = BleCarLink()
        autoUnlock = AutoUnlock(link: ble)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppServices.shared
        return true
    }
}
