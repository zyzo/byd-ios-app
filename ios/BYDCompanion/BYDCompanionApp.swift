import SwiftUI
import UIKit
import UserNotifications

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

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = AppServices.shared
        UNUserNotificationCenter.current().delegate = self
        CarNotifications.registerActions()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppServices.shared.ble.note("App went to the background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        AppServices.shared.ble.note("App came to the foreground")
    }

    /// The Lock button on a left-unlocked notification: lock through the cloud, then say how it went.
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == CarNotifications.lockAction else { return }
        let link = AppServices.shared.ble
        link.note("Lock tapped on the left-unlocked notification")
        do {
            let confirmed = try await CarAPI().run(.lock)
            link.note("Cloud lock \(confirmed ? "confirmed" : "sent, not confirmed")")
            CarNotifications.post(confirmed ? "Locked." : "Sent lock, but BYD didn't confirm it. Check the car.")
        } catch {
            link.note("Cloud lock failed: \(error.localizedDescription)")
            CarNotifications.post("Couldn't lock the car: \(error.localizedDescription)")
        }
    }
}
