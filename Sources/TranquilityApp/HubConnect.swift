import AppKit
import TranquilityCore

/// Connecting this Mac, from wherever the person started it.
///
/// Two doors lead here and they are the same flow from opposite sides: the
/// Setup row's button (app first) and `tranquilitybase://connect` fired by the
/// hub's own page (web first). Both mean "begin", neither carries anything,
/// and both end with a token in the keychain and a mirror that is running.
///
/// One at a time, and the state is public, because the phrase has to be on
/// screen while the browser is asking about it. Pressing the button twice
/// should re-show the phrase that is already live rather than invent a second
/// code and leave the first one polling.
@MainActor
final class HubConnect {
    static let shared = HubConnect()

    /// The phrase this Mac is currently showing, or nil when nothing is in
    /// flight. The Setup row prints it; so does the HUD.
    private(set) var phrase: String?
    /// The last thing that happened, as a person would say it.
    private(set) var note: String?
    /// Redraw whatever is showing this.
    var onChange: (() -> Void)?

    private var inFlight = false

    /// The hub this Mac talks to. hq.json when it says, else the one built in.
    /// NEVER a link's idea of where the archive lives.
    static var base: URL {
        HubApp.baseURL ?? URL(string: "https://hq.tranquilitybase.dev")!
    }

    /// What the row says while the browser has the question.
    func begin() {
        guard !inFlight else { onChange?(); return }
        let pairing = HubPairing(base: Self.base)
        // The one moment the MACHINE talks to the hub: register the key it
        // will prove possession with, so the pairing can spend later. Made
        // now if it does not exist yet. Without it the Mac still pairs and
        // still mirrors; it simply cannot be granted spending authority.
        pairing.publicKey = ManagedCredits.deviceSigner(log: { Permissions.log($0) })?.publicJWK
        guard let session = pairing.begin() else {
            note = "could not start. The hub address is not usable"
            onChange?()
            return
        }
        inFlight = true
        phrase = session.phrase
        // Says what to DO, with the phrase first: "showing B12-C21. Approve it
        // in the browser" sent Gary looking for somewhere to type it (14 Sep).
        note = "\(session.phrase) in the browser? Then press Connect there"
        onChange?()
        Permissions.log("hub: pairing started, phrase \(session.phrase)")
        NSWorkspace.shared.open(session.url)

        Task { [weak self] in
            let outcome = await pairing.collect(session)
            await MainActor.run { self?.finish(outcome, base: pairing.base) }
        }
    }

    private func finish(_ outcome: HubPairing.Outcome, base: URL) {
        inFlight = false
        phrase = nil
        switch outcome {
        case let .connected(token, device):
            do {
                try HubPairing.adopt(token: token, base: base)
                note = "connected as \(device)"
                Permissions.log("hub: connected as \(device)")
                startMirroring()
            } catch {
                note = "connected, but the key could not be saved: \(error.localizedDescription)"
                Permissions.log("hub: adopt failed: \(error)")
            }
        case .expired:
            note = "that request expired. Press Sign in again"
        case let .refused(why):
            note = why
        case .timedOut:
            note = "nobody approved it. Press Sign in again"
        case let .failed(why):
            note = "could not reach the hub: \(why)"
        }
        if case .connected = outcome {} else {
            Permissions.log("hub: pairing ended, \(note ?? "")")
        }
        onChange?()
    }

    /// Start the mirror on the credential that just arrived, and put down the
    /// one that was running. A reconnect on the same launch would otherwise
    /// leave two sweeps against two tokens, which is exactly the leak
    /// `HubMirror.stop()` was added for.
    private func startMirroring() {
        HubMirror.shared?.stop()
        let store = (NSApp.delegate as? AppDelegate)?.store
        guard let mirror = HubMirror.fromMachine(store: store) else {
            Permissions.log("hub: connected but the mirror would not start")
            return
        }
        HubMirror.shared = mirror
        mirror.start()
        mirror.kick()
    }
}
