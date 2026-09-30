import Foundation
import TranquilityCore

/// Every harness on this Mac reads the rules the running app ships: checked at
/// every launch and every hour, repaired when they differ, and said out loud.
///
/// Until 30 Sep 2026 the skills half of this ran only inside the launch
/// block for a BROKEN HOOK: a Mac whose hooks were healthy never had its
/// skills checked, which is how a MacBook's agents ran August's rules for six
/// days. A reconcile that waits for something else to go wrong is an incident
/// response, not a reconcile. This one runs unconditionally, is idempotent (a
/// healthy machine is read, not written), and judges health by identity with
/// the desired copy, never by a file merely existing.
///
/// Order matters: stage the rules first, so hooks and skills are pointed at
/// the new copy rather than at the copy this run is about to replace.
@MainActor
enum RulesReconcile {

    /// The last thing said on the HUD, so an hourly run that finds the same
    /// problem does not say it again every hour.
    private static var lastNote: String?

    static func run(trigger: String, note: @escaping (String) -> Void) {
        // 1. Stage the running app's rules into the store.
        var fingerprint: String?
        if let resources = Bundle.main.resourceURL {
            switch RulesStore.stage(from: resources) {
            case .unchanged(let fp):
                fingerprint = fp
            case .switched(let from, let to):
                fingerprint = to
                Permissions.log("rules (\(trigger)): now \(to)" + (from.map { ", was \($0)" } ?? ", first staging"))
            case .unavailable(let reason):
                // A developer build run from .build/ has no bundled rules; the
                // learned fallbacks below still apply to it.
                Permissions.log("rules (\(trigger)): not staged: \(reason)")
            }
        }
        let desired = RulesStore.desired()
        if let desired, desired.fromCheckout {
            Permissions.log("rules (\(trigger)): reading the developer checkout \(desired.hooks), "
                + "which contains this build")
        }
        Track.record("rules_state", [
            "trigger": .token(trigger),
            "fingerprint": .token(desired?.fingerprint ?? fingerprint ?? "none"),
            "source": .token(desired == nil ? "learned" : (desired!.fromCheckout ? "checkout" : "store")),
        ])

        var said: [String] = []

        // 2. Hooks, every harness.
        var repairedHooks: [String] = []
        for (harness, outcome) in HookManifest.repairAll(desired: desired?.hooks) {
            switch outcome {
            case .healthy:
                Track.record("hooks_state", ["harness": .token(harness.id), "state": "healthy"])
            case .repaired(let rewired, let added):
                Permissions.log("rules (\(trigger)): \(harness.id) hooks repaired, \(rewired) rewired, \(added) added")
                Track.record("hooks_state", ["harness": .token(harness.id), "state": "repaired",
                                             "rewired": .int(rewired), "added": .int(added)])
                repairedHooks.append(harness.label)
                // Codex trusts a hook by its definition: a repointed hook is
                // skipped until approved once. Say so, rather than let it look
                // installed and do nothing.
                if let step = HookManifest.nextStep(for: harness) {
                    said.append("\(harness.label): \(step)")
                }
            case .unavailable(let reason):
                Permissions.log("rules (\(trigger)): \(harness.id) hooks NOT repaired: \(reason)")
                Track.record("hooks_state", ["harness": .token(harness.id), "state": "not_repaired",
                                             "reason": .prose(reason)])
                said.append("\(harness.label) hooks need attention: \(reason)")
            }
        }

        // 3. Skills, every harness.
        for (target, outcome) in SkillManifest.repairAll(desired: desired?.skills) {
            switch outcome {
            case .healthy:
                Track.record("skills_state", ["harness": .token(target.id), "state": "healthy"])
            case .repaired(let linked, let retired):
                Permissions.log("rules (\(trigger)): \(target.id) skills linked, \(linked) linked, "
                    + "\(retired) copies moved aside")
                Track.record("skills_state", ["harness": .token(target.id), "state": "repaired",
                                              "linked": .int(linked), "retired": .int(retired)])
            case .unavailable(let reason):
                Permissions.log("rules (\(trigger)): \(target.id) skills NOT linked: \(reason)")
                Track.record("skills_state", ["harness": .token(target.id), "state": "not_repaired",
                                              "reason": .prose(reason)])
                said.append("\(target.label) skills need attention: \(reason)")
            }
        }

        // 4. The hq commands on PATH, from the same source.
        let shimSource = desired?.skills
            ?? (try? String(contentsOf: SkillManifest.recordedDirectoryURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if let shimSource {
            switch SkillManifest.repairShims(source: shimSource) {
            case .healthy: break
            case .repaired(let linked, let retired):
                Permissions.log("rules (\(trigger)): \(linked) hq command(s) linked on PATH, \(retired) moved aside")
            case .unavailable(let reason):
                Permissions.log("rules (\(trigger)): hq commands NOT linked: \(reason)")
            }
        }

        // 5. OpenCode's rules plugin: it has no hooks, so this is how its
        //    sessions get the same rules.
        switch SkillManifest.repairOpenCodePlugin(source: desired?.openCode) {
        case .healthy: break
        case .repaired:
            Permissions.log("rules (\(trigger)): OpenCode rules plugin linked")
            Track.record("skills_state", ["harness": "opencode_rules", "state": "repaired"])
        case .unavailable(let reason):
            Permissions.log("rules (\(trigger)): OpenCode rules plugin NOT linked: \(reason)")
            Track.record("skills_state", ["harness": "opencode_rules", "state": "not_repaired",
                                          "reason": .prose(reason)])
        }

        if !repairedHooks.isEmpty {
            said.insert("Agent hooks updated for " + repairedHooks.joined(separator: " and ")
                + ". New sessions pick them up; running ones on their next message.", at: 0)
        }
        let line = said.joined(separator: " ")
        if !line.isEmpty, line != lastNote {
            note(line)
        }
        lastNote = line.isEmpty ? nil : line
    }
}
