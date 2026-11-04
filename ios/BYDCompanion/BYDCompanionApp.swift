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
    let trips: TripStore
    let autoUnlock: AutoUnlock
    let autoLock: AutoLock
    let tripLogger: TripLogger

    private init() {
        let ble = BleCarLink()
        let trips = TripStore()
        // Neither walk-up/walk-away feature acts while another phone is driving the car.
        let autoUnlock = AutoUnlock(link: ble, otherPhoneLeads: { trips.otherPhoneLeads })
        self.ble = ble
        self.trips = trips
        self.autoUnlock = autoUnlock
        autoLock = AutoLock(link: ble, api: CarAPI(), cachedStatus: StatusCache.load, otherPhoneLeads: { trips.otherPhoneLeads })
        tripLogger = TripLogger(link: ble, store: trips, carLocation: { autoUnlock.carLocation })
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppServices.shared
        return true
    }
}
