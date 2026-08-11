import AVFoundation
import Foundation

/// Which macOS voice the fallback should use.
///
/// `SystemSpeechProvider` has always accepted a `voiceIdentifier` and nothing ever
/// passed one, so every announcement got `AVSpeechSynthesizer`'s locale default —
/// compact Samantha, the lowest-quality voice macOS ships. Meanwhile this machine
/// already had `Ava (Premium)` installed, plus enhanced Alex, Allison, Ava, Evan and
/// the Siri voice Nicky. The good voices were present and unreachable.
///
/// Worth recording how that stayed hidden: `say -v '?'` lists only the legacy
/// SpeechSynthesis voices, so it reported "Samantha and 40 novelty voices" and made
/// the machine look bare. `AVSpeechSynthesisVoice.speechVoices()` — what the app
/// actually speaks through — reports the premium and enhanced ones. Probing with the
/// wrong API produced a confident wrong answer about the hardware.
public enum SystemVoiceCatalog {

    /// UserDefaults key for an explicit choice. Absent means "pick the best".
    static let preferenceKey = "systemVoiceIdentifier"

    /// Quality first, because that is the whole point; then a stable name order so
    /// the choice does not wander between launches for no reason.
    ///
    /// `AVSpeechSynthesisVoiceQuality` is not `Comparable`, so the rank is explicit
    /// rather than inferred from the raw value — the enum's numbering is Apple's to
    /// change and this ordering is a decision of ours.
    public static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Every installed voice for a language, best first.
    public static func voices(matching language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted {
                let (a, b) = (rank($0.quality), rank($1.quality))
                return a == b ? $0.name < $1.name : a > b
            }
    }

    /// The identifier the fallback provider should speak with, or nil to leave
    /// `AVSpeechSynthesizer` to its own default.
    ///
    /// Nil is a real answer, not a failure: a machine with only compact voices has
    /// nothing better to offer, and passing the compact identifier explicitly would
    /// be the same voice with more ceremony.
    public static func preferredIdentifier(language: String = "en-US") -> String? {
        if let chosen = UserDefaults.standard.string(forKey: preferenceKey) {
            // Honour an explicit choice only while it is still installed — a voice can
            // be removed in Settings, and a stale identifier makes AVSpeechSynthesizer
            // fall back silently, which would look like this fix had regressed.
            if AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.identifier == chosen }) {
                return chosen
            }
        }
        guard let best = voices(matching: language).first,
              rank(best.quality) > 1
        else { return nil }
        return best.identifier
    }

    /// Set or clear the explicit choice. Clearing returns to "best installed".
    public static func choose(_ identifier: String?) {
        if let identifier {
            UserDefaults.standard.set(identifier, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
    }

    /// Whether the machine has anything better than the compact default, so the app
    /// can say "there are better voices available in Settings" rather than leaving a
    /// user to conclude this is how it sounds.
    public static func hasBetterVoiceAvailable(language: String = "en-US") -> Bool {
        voices(matching: language).contains { rank($0.quality) > 1 }
    }

    // MARK: - Recommendations, for a machine that has none of them


    /// Voices macOS offers for download, read from its own asset manifests.
    ///
    /// This is the answer to "can we detect what is NOT installed": there is no public
    /// API for it — `speechVoices()` returns only what is present — but macOS ships
    /// the catalogues on disk and they are readable:
    ///
    ///   VoiceServices_CombinedVocalizerVoices — the good ones (Allison, Ava, Susan,
    ///     Tom for en-US) with `_DownloadSize`
    ///   MacinTalkVoiceAssets — the legacy set: Alex, plus every novelty voice
    ///
    /// Reading the manifest rather than hardcoding a list is what lets this keep up:
    /// when Apple ships a new voice the manifest gains an entry and it appears here
    /// with no code change. A hardcoded list would have frozen on the day it was
    /// written, which is exactly what the previous `recommended` constant did.
    ///
    /// Novelty voices are excluded by construction: the MacinTalk entries carry a
    /// `VoiceRelativeDesirability` and Bubbles, Boing, Zarvox and friends simply have
    /// none. Apple's own ranking does the filtering, so the app is not maintaining a
    /// blocklist of joke voices.
    public static func downloadable(language: String = "en-US") -> [(name: String, megabytes: Double)] {
        var found: [(name: String, megabytes: Double)] = []

        func assets(_ catalogue: String) -> [[String: Any]] {
            let dir = "/System/Library/AssetsV2/com_apple_MobileAsset_\(catalogue)"
            let url = URL(fileURLWithPath: dir).appendingPathComponent("com_apple_MobileAsset_\(catalogue).xml")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil) as? [String: Any],
                  let list = plist["Assets"] as? [[String: Any]]
            else { return [] }
            return list
        }

        for asset in assets("VoiceServices_CombinedVocalizerVoices") {
            guard let langs = asset["Languages"] as? [String], langs.contains(language),
                  let name = asset["Name"] as? String else { continue }
            let bytes = (asset["_DownloadSize"] as? NSNumber)?.doubleValue ?? 0
            found.append((name, bytes / 1_000_000))
        }
        for asset in assets("MacinTalkVoiceAssets") {
            guard let name = asset["Name"] as? String else { continue }
            let bytes = (asset["_DownloadSize"] as? NSNumber)?.doubleValue ?? 0
            // Size is the filter, because size is what a good voice costs. Measured
            // across both catalogues:
            //
            //   Alex 885M   Ava 479M   Tom 411M   Susan 132M   Allison 99M
            //   Vicki 28M   Bruce 2M   Agnes 1M   every novelty voice 0M
            //
            // A concatenative voice carries recorded speech; a formant voice carries a
            // few kilobytes of rules and sounds like 1994. The megabytes ARE the
            // quality, so the threshold reads directly on the thing being judged.
            //
            // This replaces a `VoiceRelativeDesirability >= 10000` test that only
            // worked by accident: Ava — the best voice on the machine — carries no
            // desirability score at all, because the Vocalizer catalogue does not use
            // that field. The rank existed in one catalogue and the good voices live
            // in the other.
            guard bytes >= 50_000_000 else { continue }
            found.append((name, bytes / 1_000_000))
        }
        // Biggest first, which is best first — and it stays true for voices Apple has
        // not shipped yet, unlike any ordering we could hardcode.
        return found.sorted { $0.megabytes > $1.megabytes }
    }

    /// What is here, and what is a download away.
    ///
    /// Matched on NAME, and on a PREFIX at that: installed voices are listed as
    /// "Ava (Premium)" and "Ava (Enhanced)" while the manifest calls the asset "Ava".
    /// Comparing whole strings would report Ava as missing on a machine that has two
    /// copies of it. Identifier matching is worse still — premium voices moved from
    /// `com.apple.ttsbundle.*` to `com.apple.voice.premium.*`, so an identifier
    /// allowlist reports everything missing after an OS upgrade.
    public static func recommendationStatus(language: String = "en-US")
        -> (installed: [String], missing: [(name: String, note: String)]) {
        let present = voices(matching: language).map(\.name)
        func isInstalled(_ assetName: String) -> Bool {
            present.contains { $0 == assetName || $0.hasPrefix(assetName + " (") }
        }
        var installed: [String] = []
        var missing: [(name: String, note: String)] = []
        for entry in downloadable(language: language) {
            if isInstalled(entry.name) {
                installed.append(entry.name)
            } else {
                let size = entry.megabytes >= 1
                    ? String(format: "%.0f MB", entry.megabytes) : "small"
                missing.append((entry.name, size))
            }
        }
        return (installed, missing)
    }

    /// Lands on Read & Speak, one surface deeper than the Accessibility pane.
    ///
    /// VERIFIED by opening each candidate and reading the resulting window title, with
    /// System Settings quit between attempts — without that a failed anchor inherits
    /// whatever pane was last shown and looks like it worked. Of six candidates only
    /// this one resolves:
    ///
    ///     (no anchor)            → Accessibility
    ///     ?Spoken_Content        → Accessibility
    ///     ?Speech                → Accessibility
    ///     ?ReadAndSpeak          → Accessibility
    ///     ?SpokenContent         → Read & Speak     ✓
    ///     ?Speech_Spoken_Content → Accessibility
    ///
    /// Note the near-miss: `Spoken_Content` and `SpokenContent` differ by an
    /// underscore and only one works. A plausible-looking anchor that silently lands
    /// on the parent is worse than no anchor, because it reads as a broken button
    /// rather than a missing feature.
    public static let settingsURL =
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"

    /// The clicks the deep link cannot skip, so the app can spell them out rather than
    /// implying the button finishes the job. "System voice" and the voice sheet are
    /// controls inside the pane, not panes, so no URL can reach them.
    public static let remainingSteps = "System voice → Voice → ↓"

    /// The free voices as catalogue entries, so the picker can list them beside the
    /// paid ones instead of showing an empty pane.
    ///
    /// Without this the Voices face read "15 of 0 on roster" on a machine with no
    /// ElevenLabs key: `VoiceCatalog.cached()` is ElevenLabs-only and returns nothing,
    /// while a stale roster of 15 ids survived from a previous session. Zero available
    /// voices was never true — the machine had forty-odd installed and the app could
    /// not see any of them.
    ///
    /// Category carries quality, because "free" alone does not tell you that Ava
    /// (Premium) and compact Samantha are not the same offer.
    /// Only the voices worth offering.
    ///
    /// Of 34 en-US voices installed here, 28 are unusable for this purpose: 20 legacy
    /// novelty voices (Bubbles, Boing, Bells, Bad News — literal sound effects) and 8
    /// Eloquence voices, which are the robotic ones. Listing them made the picker
    /// open on "Albert, Bad News, Bahh, Bells, Boing, Bubbles", because the bench
    /// sorts by (category, name) and "Compact" precedes "Enhanced" alphabetically —
    /// so the worst voices macOS ships were the first thing the app showed.
    ///
    /// Filtered by QUALITY, not by identifier family: Alex is `com.apple.speech.
    /// synthesis.voice.Alex`, the same family as the novelty voices, and is one of
    /// the best. Quality is the thing actually being judged.
    /// Id prefix marking a row that is NOT installed. Selecting it cannot play
    /// anything, so the picker turns it into the button that opens Settings — the
    /// download IS the action, and a row you can act on beats a sentence telling you
    /// to go somewhere else.
    public static let downloadPrefix = "download:"

    public static func isDownloadRow(_ id: String) -> Bool { id.hasPrefix(downloadPrefix) }

    /// Voices worth having that are not installed, as rows.
    ///
    /// Listing them is the whole point: a picker that shows only what you have cannot
    /// tell you what you are missing, and the missing ones are the good ones. Big
    /// only — a download row for a 1MB voice from 1994 is not an offer.
    public static func downloadRows(language: String = "en-US") -> [Voice] {
        recommendationStatus(language: language).missing.compactMap { entry in
            let mb = Double(entry.note.replacingOccurrences(of: " MB", with: "")) ?? 0
            guard mb >= 100 else { return nil }
            // Name stays the name — `VoiceRowView.concise` strips anything after a
            // separator, so "Susan — 132 MB" rendered as "Susan" and the size, the
            // one fact that mattered, disappeared.
            return Voice(id: downloadPrefix + entry.name,
                         name: entry.name,
                         category: entry.note)
        }
    }


    /// Megabytes for a voice by name, from the manifest, for installed voices as well
    /// as absent ones. The picker shows size instead of repeating a tier the name
    /// already carries: "Ava (Premium)" does not need a column saying Premium.
    public static func sizeMB(named voiceName: String) -> Double? {
        // "Ava (Premium)" and "Ava (Enhanced)" are both the "Ava" asset.
        let base = voiceName.split(separator: " ").first.map(String.init) ?? voiceName
        return downloadable().first { $0.name == base }?.megabytes
    }

    public static func asCatalogueVoices(language: String = "en-US") -> [Voice] {
        let good = voices(matching: language).filter { rank($0.quality) > 1 }
        // A stock Mac has none of these. Rather than an empty pane, show what it will
        // actually speak with, so the list always explains the sound coming out.
        let shown = good.isEmpty
            ? voices(matching: language).filter { $0.identifier.contains(".voice.compact.") }
            : good
        return shown.map { v in
            // Size, not tier. The tier is already in the name — a column repeating
            // "Enhanced" beside "Allison (Enhanced)" is noise, and "Free" beside a
            // list of free voices says nothing at all.
            let size = sizeMB(named: v.name).map { String(format: "%.0f MB", $0) } ?? ""
            return Voice(id: v.identifier, name: v.name, category: size)
        }
    }

    /// Whether an id belongs to a macOS voice rather than an ElevenLabs one.
    ///
    /// The picker holds both, and they are spoken by different providers — passing a
    /// system identifier to the ElevenLabs path is why every preview played the same
    /// voice: the chain did not recognise it, fell through to the one system provider,
    /// and that provider spoke in its own configured voice every time.
    public static func isSystemVoice(_ id: String) -> Bool { id.hasPrefix("com.apple.") }
}
