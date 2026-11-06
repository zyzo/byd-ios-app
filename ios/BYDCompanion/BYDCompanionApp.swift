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
/// (Bluetooth restore, background refresh) finds them ready even with no screen shown.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let ble: BleCarLink
    let trips: TripStore
    let autoUnlock: AutoUnlock
    let autoLock: AutoLock
    let tripLogger: TripLogger

    private init() {
        let ble = BleCarLink()
        let trips = TripStore()
        self.ble = ble
        self.trips = trips
        // Neither walk-up/walk-away feature acts while another phone is driving the car.
        autoUnlock = AutoUnlock(link: ble, otherPhoneLeads: { trips.otherPhoneLeads })
        autoLock = AutoLock(link: ble, api: CarAPI(), cachedStatus: StatusCache.load, otherPhoneLeads: { trips.otherPhoneLeads })
        tripLogger = TripLogger(link: ble, store: trips)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppServices.shared
        return true
    }
}
