import Foundation
import TranquilityCore

/// Which account this Mac is connected as, and tickets for its window.
///
/// Remembered locally so the app can tell, the moment its Hub window signs in,
/// whether that is the Mac's own account or a different one (in which case
/// the Mac follows the window: one account, never two).
enum HubAccount {
    static let key = "hub.account"

    /// The account's hub sign-in id, or nil when not known yet.
    static var remembered: String? { UserDefaults.standard.string(forKey: key) }

    static func remember(_ user: String?) {
        if let user { UserDefaults.standard.set(user, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A ticket for this Mac's account, or nil when it is not connected or the
    /// hub refuses. Learns the account id as a side effect.
    static func ticket(next: String) async -> HubWebSession.Ticket? {
        let token = Secrets.read(.hubToken)
        guard let token, !token.isEmpty, let signer = try? DeviceKeyStore.resolve().signer else { return nil }
        do {
            let ticket = try await HubWebSession.ticket(hub: HubApp.hub, next: next,
                                                        deviceToken: token, signer: signer)
            remember(ticket.user)
            return ticket
        } catch {
            Permissions.log("hub: no sign-in ticket for the Hub window: \(error)")
            return nil
        }
    }
}
