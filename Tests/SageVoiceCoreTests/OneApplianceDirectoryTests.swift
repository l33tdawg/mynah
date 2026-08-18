import XCTest
@testable import SageVoiceCore

/// One appliance, one directory — on both platforms, checked from both.
///
/// **What was wrong.** Four files had been routed through
/// `ApplianceSupportDirectory` and about thirty had not. The rest spelled
/// `homeDirectory/"Library/Application Support/SAGE Voice Bridge"` by hand, and
/// every one of them is reachable off Darwin — so a Linux appliance kept its
/// pause flag and its service settings in `~/.local/share` while putting the
/// owner's conversations, provider keys, Google refresh token, notes, WhatsApp
/// token, voice notes and Mynah's own key in a `~/Library` folder that nothing
/// on the system understands, that no uninstaller knows about, and that no
/// backup covers because nothing else on a Linux box has ever created one.
///
/// `SQLiteMemoryStore` was worse than misplaced: it was split against itself.
/// The ciphertext went to `~/Library/Application Support/QuietType` and the AES
/// key that opens it went to `FileManager.applicationSupportDirectory` —
/// `$XDG_DATA_HOME` under swift-corelibs-foundation. Two roots for one secret,
/// and the failure mode is the quiet one: copy the store, lose the key, and
/// every memory is gone while the file still looks intact.
///
/// **Why this file has no `#if`.** The bug lived off Darwin and the suite is run
/// on a Mac before a release, so a guard that only compiles on Linux is a guard
/// that reddens after shipping. Every assertion here names its layout, which
/// means a Mac run proves the Linux paths and a Linux run proves the Mac ones.
/// The Mac literals below are the load-bearing half: an owner upgrading from
/// 2.3.0 must find their conversations, their keys and their identity in exactly
/// the files they are in today, so those paths are pinned as strings rather than
/// derived — a derived expectation moves when the code moves, which is the one
/// thing this must not tolerate.
final class OneApplianceDirectoryTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/home/owner", isDirectory: true)

    // MARK: - The table

    /// Everything that belongs in the appliance directory, by the name a
    /// failure message should say.
    ///
    /// A dictionary rather than a list of assertions so a file added to the
    /// product has one place to be added here, and so every property below —
    /// the Mac paths, the XDG paths, the litter check, the shared-parent check
    /// — is asking about the same set rather than its own subset.
    private func applianceFiles(
        layout: ApplianceSupportDirectory.Layout,
        environment: [String: String] = [:]
    ) -> [String: URL] {
        [
            "conversations": ConversationStore.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "notes": NotesToolSource.defaultDirectory(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "provider keys": ProviderKeyStore.defaultURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "google token": GoogleTokenStore.defaultURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "window key": MynahIdentity.keyURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "appliance key (legacy)": MynahIdentity.legacyApplianceKeyURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "whatsapp token": URL(fileURLWithPath: WhatsAppChannel.defaultTokenPath(
                homeDirectory: home, layout: layout, environment: environment
            )),
            "voice notes": VoiceNote.directory(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "voice preferences": VoicePreferences.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "appliance status": ApplianceStatus.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "calendar preferences": CalendarPreferences.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "calendar ledger": CalendarLedger.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "kokoro voices": KokoroAssets.directory(
                homeDirectory: home, layout: layout, environment: environment
            ),
            "where we are": WhereWeAre.defaultFileURL(
                homeDirectory: home, layout: layout, environment: environment
            ),
        ]
    }

    // MARK: - The Mac must not notice any of this

    /// **2.3.0 is shipping with these files at these exact paths.** Every one of
    /// them holds something an owner cannot get back by reinstalling: months of
    /// conversation, an API key they pasted once, a Google refresh token, the
    /// notes they dictated, and the Ed25519 seed that *is* Mynah's identity in
    /// SAGE. A build that moved any of them would come up looking factory-fresh
    /// — no history, no keys, and a new agent id with none of the owner's
    /// memories attached to it — during an update they asked for.
    func testEveryMacPathIsExactlyWhereItAlreadyIs() {
        let support = "/home/owner/Library/Application Support/SAGE Voice Bridge"
        let expected = [
            "conversations": support + "/conversations.json",
            "notes": support + "/Notes",
            "provider keys": support + "/provider-keys.json",
            "google token": support + "/google-oauth.json",
            "window key": support + "/agent.key",
            "appliance key (legacy)": support + "/appliance-agent.key",
            "whatsapp token": support + "/WhatsApp/api-token",
            "voice notes": support + "/VoiceNotes",
            "voice preferences": support + "/voice-preferences.json",
            "appliance status": support + "/appliance-status.json",
            "calendar preferences": support + "/calendar-preferences.json",
            "calendar ledger": support + "/calendar-ledger.json",
            "kokoro voices": support + "/Kokoro",
            "where we are": support + "/where-we-are.json",
        ]

        for (name, url) in applianceFiles(layout: .darwin) {
            XCTAssertEqual(
                url.path,
                expected[name],
                "\(name) moved on macOS — an upgrading owner would lose it"
            )
        }
        XCTAssertEqual(
            Set(applianceFiles(layout: .darwin).keys),
            Set(expected.keys),
            "a file joined or left the appliance directory without its Mac path being pinned"
        )
    }

    /// The memory store keeps the name it has always had on a Mac.
    ///
    /// `QuietType` is not this product's name and it stays anyway: this
    /// appliance grew out of QuietType and the store never moved, so every
    /// shipped install's memories are in that folder. Renaming it would read as
    /// an appliance that had forgotten everything.
    func testTheMacMemoryStoreKeepsItsOriginalFolder() {
        XCTAssertEqual(
            SQLiteMemoryStore.persistentDirectory(homeDirectory: home, layout: .darwin).path,
            "/home/owner/Library/Application Support/QuietType"
        )
    }

    // MARK: - Off Darwin

    /// `~/Library` is a Mac idea. Creating one on a Linux box leaves a folder
    /// the desktop does not show, the packaging does not own and the owner's
    /// backup does not cover — holding, in this case, every secret the appliance
    /// has.
    func testOffDarwinEveryOneOfThemIsUnderTheXDGDataDirectory() {
        let support = "/home/owner/.local/share/SAGE Voice Bridge"
        let expected = [
            "conversations": support + "/conversations.json",
            "notes": support + "/Notes",
            "provider keys": support + "/provider-keys.json",
            "google token": support + "/google-oauth.json",
            "window key": support + "/agent.key",
            "appliance key (legacy)": support + "/appliance-agent.key",
            "whatsapp token": support + "/WhatsApp/api-token",
            "voice notes": support + "/VoiceNotes",
            "voice preferences": support + "/voice-preferences.json",
            "appliance status": support + "/appliance-status.json",
            "calendar preferences": support + "/calendar-preferences.json",
            "calendar ledger": support + "/calendar-ledger.json",
            "kokoro voices": support + "/Kokoro",
            "where we are": support + "/where-we-are.json",
        ]

        for (name, url) in applianceFiles(layout: .xdg) {
            XCTAssertEqual(url.path, expected[name], "\(name) is not in the XDG data directory")
        }
        XCTAssertEqual(
            SQLiteMemoryStore.persistentDirectory(homeDirectory: home, layout: .xdg).path,
            support,
            "the memory store still imports a second product's folder off Darwin"
        )
    }

    /// The litter check, stated as the thing an owner would see.
    ///
    /// Deliberately a substring test rather than a path comparison: it catches
    /// a `Library` that arrives via any route — a hardcoded component, an
    /// `.applicationSupportDirectory` lookup, a helper that appends one — which
    /// a fixed expectation for each file would not.
    func testNothingOffDarwinCreatesALibraryFolderInTheOwnersHome() {
        var everything = Array(applianceFiles(layout: .xdg).map { ($0.key, $0.value.path) })
        everything.append(
            ("memory store", SQLiteMemoryStore.persistentDirectory(homeDirectory: home, layout: .xdg).path)
        )
        everything.append(
            ("memory key", SQLiteMemoryStore.keyFileURL(homeDirectory: home, layout: .xdg).path)
        )

        for (name, path) in everything {
            XCTAssertFalse(
                path.contains("/Library/"),
                "\(name) would create a stray ~/Library on Linux: \(path)"
            )
        }
    }

    /// An owner who moved their data directory moved it for everything. An
    /// appliance that read `$XDG_DATA_HOME` for four files and ignored it for
    /// thirty would scatter one appliance across two roots on exactly the
    /// machines whose owner was being careful.
    func testXDGDataHomeMovesAllOfThemTogether() {
        let files = applianceFiles(layout: .xdg, environment: ["XDG_DATA_HOME": "/srv/state"])
        for (name, url) in files {
            XCTAssertTrue(
                url.path.hasPrefix("/srv/state/SAGE Voice Bridge/"),
                "\(name) ignored XDG_DATA_HOME and stayed at \(url.path)"
            )
        }
        XCTAssertEqual(
            SQLiteMemoryStore.persistentDirectory(
                homeDirectory: home, layout: .xdg, environment: ["XDG_DATA_HOME": "/srv/state"]
            ).path,
            "/srv/state/SAGE Voice Bridge"
        )
    }

    /// An empty variable is unset, not the filesystem root. `XDG_DATA_HOME=`
    /// appears in shell profiles by accident, and honouring it literally would
    /// send the owner's keys to `/SAGE Voice Bridge`, which they cannot write —
    /// so every save would fail on a machine that looks fine.
    func testAnEmptyXDGDataHomeFallsBackRatherThanWritingToTheRoot() {
        for (name, url) in applianceFiles(layout: .xdg, environment: ["XDG_DATA_HOME": ""]) {
            XCTAssertTrue(
                url.path.hasPrefix("/home/owner/.local/share/SAGE Voice Bridge/"),
                "\(name) took an empty XDG_DATA_HOME literally: \(url.path)"
            )
        }
    }

    // MARK: - One directory

    /// The property the whole change is for: every one of these files resolves
    /// under the *same* directory as the four that were already routed, on both
    /// layouts.
    ///
    /// Checked against `ApplianceSupportDirectory` rather than against a
    /// literal, because the failure being guarded is drift between two spellings
    /// of one directory — and two literals cannot drift apart in a test that
    /// writes them both.
    func testEveryOneOfThemSharesTheDirectoryTheSettingsFilesUse() {
        for layout in [ApplianceSupportDirectory.Layout.darwin, .xdg] {
            let root = ApplianceSupportDirectory.directory(
                layout: layout, homeDirectory: home, environment: [:]
            ).path

            // The four that were already routed, as the anchor.
            for settings in [
                PauseState.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
                ProactivePreferences.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
                ServicePreferences.defaultFileURL(homeDirectory: home, layout: layout, environment: [:]),
            ] {
                XCTAssertEqual(settings.deletingLastPathComponent().path, root)
            }

            for (name, url) in applianceFiles(layout: layout) {
                XCTAssertTrue(
                    url.path.hasPrefix(root + "/"),
                    "\(name) is outside the appliance directory under \(layout): \(url.path)"
                )
            }
        }
    }

    /// **The split, closed.** One secret in two roots is a memory store that
    /// looks fine and opens to nothing: back up the ciphertext, miss the key
    /// under a different root, restore, and every memory the owner ever gave
    /// Mynah is unreadable — with no error, because a missing key is
    /// indistinguishable from a first run and mints a fresh one.
    ///
    /// Asserted on both layouts although the key file is only ever written off
    /// Darwin, where there is no Keychain. That is deliberate: the halves
    /// disagreed for as long as they did because only one of them existed on the
    /// machine the suite was run on.
    func testTheEncryptedStoreAndTheKeyThatOpensItShareOneDirectory() {
        for layout in [ApplianceSupportDirectory.Layout.darwin, .xdg] {
            let store = SQLiteMemoryStore.persistentDirectory(homeDirectory: home, layout: layout)
            let key = SQLiteMemoryStore.keyFileURL(homeDirectory: home, layout: layout)
            XCTAssertEqual(
                key.deletingLastPathComponent().path,
                store.path,
                "the memory key is not in the directory the store it opens is in, under \(layout)"
            )
        }
    }

    /// The two platforms name one secret one way — which was a comment above two
    /// separate literals until it was this.
    func testTheMemoryKeyHasOneNameOnBothPlatforms() {
        XCTAssertEqual(
            SQLiteMemoryStore.keyFileURL(homeDirectory: home, layout: .xdg).lastPathComponent,
            "quiettype-local-memory-aes-gcm-key"
        )
        #if canImport(Security)
        XCTAssertEqual(
            SQLiteMemoryStore.keychainAccount,
            SQLiteMemoryStore.keyFileName,
            "the Keychain item and the Linux key file are two different secrets now"
        )
        #endif
    }

    // MARK: - The running build

    /// Every default argument resolves through the shared directory on whichever
    /// platform this is.
    ///
    /// The other tests all name a layout, which proves the *mapping* is right
    /// and would keep passing if a function stopped consulting the layout at
    /// all. This one calls each of them the way production does — no arguments
    /// — and checks the answer against `ApplianceSupportDirectory` under the
    /// real home and the real environment.
    func testTheRunningBuildsDefaultsGoThroughTheSharedDirectory() {
        let root = ApplianceSupportDirectory.directory().path

        let defaults: [String: String] = [
            "conversations": ConversationStore.defaultFileURL().path,
            "notes": NotesToolSource.defaultDirectory().path,
            "provider keys": ProviderKeyStore.defaultURL().path,
            "google token": GoogleTokenStore.defaultURL().path,
            "window key": MynahIdentity.keyURL().path,
            "appliance key (legacy)": MynahIdentity.legacyApplianceKeyURL().path,
            "whatsapp token": WhatsAppChannel.defaultTokenPath(),
            "voice notes": VoiceNote.directory().path,
            "voice preferences": VoicePreferences.defaultFileURL().path,
            "appliance status": ApplianceStatus.defaultFileURL().path,
            "calendar preferences": CalendarPreferences.defaultFileURL().path,
            "calendar ledger": CalendarLedger.defaultFileURL().path,
            "kokoro voices": KokoroAssets.directory().path,
            "where we are": WhereWeAre.defaultFileURL().path,
        ]

        for (name, path) in defaults {
            XCTAssertTrue(
                path.hasPrefix(root + "/"),
                "\(name) does not use this platform's appliance directory: \(path) is not under \(root)"
            )
        }

        #if os(macOS)
        XCTAssertEqual(ApplianceSupportDirectory.current, .darwin)
        #else
        XCTAssertEqual(ApplianceSupportDirectory.current, .xdg)
        #endif
    }

    // MARK: - Nothing spells it by hand any more

    /// Directories the manifest keeps out of an off-Darwin build entirely.
    ///
    /// Not an opinion — `Package.swift` declares `MynahMac` and `Mynah` only
    /// `if isDarwin`, and appends `Call` to `coreExclusions` when it is not, so
    /// nothing in these three directories is compiled on Linux and a
    /// `~/Library` spelled inside them cannot reach a Linux owner.
    /// `testTheExemptDirectoriesAreStillTheOnesTheManifestExcludes` re-reads the
    /// manifest and fails if that ever stops being true, because an exemption
    /// nobody rechecks is how the last fixed list went stale.
    private static let notBuiltOffDarwin = [
        "Sources/Mynah/",
        "Sources/MynahMac/",
        "Sources/SageVoiceCore/Call/",
    ]

    /// Conditions under which a region is Darwin-only, so a hand-spelled Mac
    /// path inside it is unreachable off Darwin and therefore fine.
    ///
    /// Deliberately short. Every entry here is a hole in the guard, so the bar
    /// is "swift-corelibs cannot provide this at all" — not "this is usually a
    /// Mac". `SingleInstance.defaultLockURL` is the one site that relies on it
    /// today, and it is why this list exists rather than a second ledger entry.
    private static let darwinOnlyConditions = [
        "os(macOS)",
        "canImport(Darwin)",
        "canImport(AppKit)",
    ]

    /// A file that writes `Library/Application Support` out in code, and why it
    /// is allowed to for now.
    private struct HandSpelling {
        let path: String
        let occurrences: Int
        /// What the file puts in the wrong place off Darwin, or — for a settled
        /// one — why it is not the wrong place.
        let note: String
    }

    /// Spelled by hand on purpose, and staying that way.
    ///
    /// Two, and both have a reason that is about a *different* directory from
    /// the appliance one — which is exactly why they cannot simply be routed.
    private static let settledSpellings = [
        HandSpelling(
            path: "Sources/SageVoiceCore/ServicePreferences.swift",
            occurrences: 1,
            note: "ApplianceSupportDirectory itself. Somewhere has to say the words."
        ),
        HandSpelling(
            path: "Sources/SageVoiceCore/MemoryStore.swift",
            occurrences: 1,
            note: """
            the Mac-only QuietType folder an installed base already lives in, \
            behind the layout switch and pinned by \
            testTheMemoryStoreSpellsItExactlyOnceAndOnlyForTheMac
            """
        ),
    ]

    /// **Defect C, as it actually stands.** Eleven files, thirteen sites.
    ///
    /// Every one of these compiles into `SageVoiceCore` on Linux and resolves
    /// into a `~/Library` folder that nothing on that system understands. They
    /// are written down rather than skipped so the number is a number somebody
    /// can watch go to zero, and so the *shape* of the omission is guarded
    /// everywhere else in the tree while they are open.
    ///
    /// **This list may only shrink.** A file that is not on it and spells the
    /// directory fails; a file on it that spells it more times than recorded
    /// fails; and a file on it that has been fixed also fails, saying so, so the
    /// entry is deleted in the same commit as the fix rather than rotting into
    /// a permanent exemption. That last rule is the whole difference between
    /// this and the fixed list of seven filenames it replaces — which passed,
    /// green, while thirteen files were wrong.
    private static let openSpellings = [
        HandSpelling(path: "Sources/SageVoiceCore/Brain/AgentSendJournal.swift",
                     occurrences: 1, note: "agent-sends.json"),
        HandSpelling(path: "Sources/SageVoiceCore/Brain/PromisedAnswer.swift",
                     occurrences: 1, note: "outstanding-promise.json"),
        HandSpelling(path: "Sources/SageVoiceCore/Brain/RecallScope.swift",
                     occurrences: 1, note: "readable-domains.json"),
        HandSpelling(path: "Sources/SageVoiceCore/Brain/SageRitual.swift",
                     occurrences: 2, note: "said-replies-<surface>.json and display-name"),
        HandSpelling(path: "Sources/SageVoiceCore/Proactive/OwnTaskEdits.swift",
                     occurrences: 1, note: "own-task-edit"),
        HandSpelling(path: "Sources/SageVoiceCore/Proactive/ProactiveWatch.swift",
                     occurrences: 1, note: "proactive-ledger.json"),
        HandSpelling(path: "Sources/SageVoiceCore/Setup/EnvironmentProbe.swift",
                     occurrences: 2, note: "the managed-runtime and Ollama-models roots it matches paths against"),
        HandSpelling(path: "Sources/SageVoiceCore/Setup/LocalBrainInstaller.swift",
                     occurrences: 1, note: "the whole local-brain runtime, which is gigabytes"),
        HandSpelling(path: "Sources/SageVoiceCore/Setup/UpdateCheck.swift",
                     occurrences: 1, note: "update-preferences.json"),
        HandSpelling(path: "Sources/SageVoiceCore/WhisperKitServerSupervisor.swift",
                     occurrences: 1, note: "a QuietType/WhisperKit model candidate that can never match off Darwin"),
    ]

    /// The guard that survives the next edit — and, this time, the next file.
    ///
    /// **The version of this test that shipped read seven named files.** Four
    /// more were wrong the whole time it was green: `ApplianceStatus`, whose
    /// `publish` runs unguarded at every daemon start and so created the stray
    /// `~/Library` before the owner had done anything at all; both calendar
    /// files; and the 354 MB of Kokoro weights. A guard that is handed the list
    /// of places to look cannot find the place nobody thought of, which is the
    /// only kind of omission there is.
    ///
    /// So this enumerates `Sources/` instead. Every `.swift` file in the product
    /// is read; any that spells `Library/Application Support` in code — comments
    /// excluded by `SwiftSourceScan`, so the prose above these functions can
    /// keep explaining the Mac layout — has to be accounted for by name, with
    /// its count, in one of the two ledgers above.
    func testNothingCompiledOffDarwinSpellsTheApplianceDirectoryByHand() throws {
        var found: [String: [Int]] = [:]

        for path in try productSourceFiles() {
            if Self.notBuiltOffDarwin.contains(where: { path.hasPrefix($0) }) { continue }
            let scan = SwiftSourceScan(try read(path))
            let darwinOnly = darwinOnlyLines(in: scan)
            let lines = scan.indices(of: "Library/Application Support")
                .map { scan.line(of: $0) }
                .filter { !darwinOnly.contains($0) }
            if !lines.isEmpty { found[path] = lines }
        }

        var recorded: [String: HandSpelling] = [:]
        for spelling in Self.settledSpellings + Self.openSpellings {
            recorded[spelling.path] = spelling
        }

        for (path, lines) in found.sorted(by: { $0.key < $1.key }) {
            guard let known = recorded[path] else {
                XCTFail(
                    "\(path):\(lines) spells the appliance directory by hand instead of asking "
                        + "ApplianceSupportDirectory — which is how it got scattered. Route it "
                        + "through ApplianceSupportDirectory.url(for:layout:homeDirectory:environment:) "
                        + "and add its Mac path to applianceFiles above, so an upgrading owner keeps it."
                )
                continue
            }
            XCTAssertLessThanOrEqual(
                lines.count,
                known.occurrences,
                "\(path) spelled the appliance directory by hand \(lines.count) times at \(lines), "
                    + "up from \(known.occurrences). The ledger in this file may only shrink: route "
                    + "the new one through ApplianceSupportDirectory rather than raising the number."
            )
            XCTAssertGreaterThanOrEqual(
                lines.count,
                known.occurrences,
                "\(path) is down to \(lines.count) hand-spellings from \(known.occurrences) — that is "
                    + "the fix landing. Change its `occurrences` to \(lines.count) in this file "
                    + "(or delete the entry when it reaches 0) in the same commit."
            )
        }

        for (path, known) in recorded.sorted(by: { $0.key < $1.key }) where found[path] == nil {
            XCTFail(
                "\(path) no longer spells the appliance directory by hand — \(known.note) is fixed. "
                    + "Delete its entry from this file, so the ledger cannot rot into a permanent "
                    + "exemption that hides the next reintroduction."
            )
        }

        XCTAssertEqual(
            Self.openSpellings.reduce(0) { $0 + $1.occurrences },
            // 13 -> 12 on 18 Aug 2026: PendingDelivery's pending-deliveries.json
            // now goes through ApplianceSupportDirectory, so its entry above was
            // deleted rather than left as a standing exemption.
            12,
            "Defect C's remainder changed size. That is fine and expected — write the new number "
                + "here deliberately, so it is a number somebody watched go down rather than one "
                + "that drifted."
        )
    }

    /// The exemptions are the manifest's, not this test's.
    ///
    /// `Sources/MynahMac`, `Sources/Mynah` and `Sources/SageVoiceCore/Call` are
    /// skipped above because `Package.swift` does not compile them off Darwin.
    /// If that ever changes — the call feature gets ported, the app target gets
    /// declared unconditionally — the skip becomes a hole covering five files
    /// that all spell the directory by hand, and this fails rather than letting
    /// it open quietly.
    func testTheExemptDirectoriesAreStillTheOnesTheManifestExcludes() throws {
        let manifest = SwiftSourceScan(try read("Package.swift"))
        XCTAssertTrue(
            manifest.contains("coreExclusions.append(\"Call\")"),
            "Package.swift no longer excludes Call/ off Darwin, so its four hand-spelled "
                + "~/Library paths now compile on Linux — remove it from notBuiltOffDarwin"
        )
        XCTAssertTrue(
            manifest.contains("let macOnlyTargets: [Target] = isDarwin ?"),
            "Package.swift no longer declares the Mac targets only on Darwin, so Sources/MynahMac "
                + "and Sources/Mynah may build on Linux — remove them from notBuiltOffDarwin"
        )
        for directory in Self.notBuiltOffDarwin {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(directory).path
                ),
                "\(directory) is exempted from the hand-spelling guard and does not exist — "
                    + "a skip that matches nothing is a skip nobody will notice is wrong"
            )
        }
    }

    // MARK: - Reading the tree

    /// Every `.swift` file under `Sources/`, by repository-relative path.
    ///
    /// The count is asserted because the failure this whole file guards against
    /// is work that reports success without doing it — and an enumeration that
    /// silently returned nothing would make the guard above pass on an empty
    /// set, which is the most convincing green there is.
    private func productSourceFiles() throws -> [String] {
        let sources = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .map { "Sources/" + $0 }
            .sorted()
        XCTAssertGreaterThan(
            files.count, 150,
            "only \(files.count) Swift files found under Sources/ — the enumeration is broken, "
                + "and every guard reading it is passing on nothing"
        )
        return files
    }

    /// Line numbers, 1-based, that a non-Darwin compiler never sees.
    ///
    /// A hand-spelled Mac path inside `#if os(macOS)` is not the bug: it cannot
    /// reach a Linux owner. Tracked as a stack so a nested `#if` inside a Darwin
    /// block stays covered, and cleared by `#else` so the Linux half of a
    /// platform fork is *not* — which is precisely where a wrong path would do
    /// its damage.
    ///
    /// Read from `SwiftSourceScan`'s blanked text rather than the raw file, so
    /// an `#if os(macOS)` written inside a comment cannot grant cover.
    private func darwinOnlyLines(in scan: SwiftSourceScan) -> Set<Int> {
        var covered: Set<Int> = []
        var stack: [(condition: String, isElse: Bool)] = []
        var number = 0

        for line in String(scan.characters).split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#if ") {
                stack.append((String(text.dropFirst(4)), false))
            } else if text.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1] = (String(text.dropFirst(8)), false) }
            } else if text.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1].isElse = true }
            } else if text.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            }

            let isDarwinOnly = stack.contains { frame in
                guard !frame.isElse else { return false }
                return Self.darwinOnlyConditions.contains { frame.condition.contains($0) }
            }
            if isDarwinOnly { covered.insert(number) }
        }
        return covered
    }

    /// `MemoryStore` keeps exactly one, and it is the Mac-only `QuietType`
    /// folder that an installed base already lives in. One, not zero, because
    /// that folder is genuinely different from the appliance directory on a Mac;
    /// one, not two, because two is what the split was.
    func testTheMemoryStoreSpellsItExactlyOnceAndOnlyForTheMac() throws {
        let scan = SwiftSourceScan(try read("Sources/SageVoiceCore/MemoryStore.swift"))
        let hits = scan.indices(of: "Library/Application Support")
        XCTAssertEqual(
            hits.count, 1,
            "expected the one Mac QuietType path, found \(hits.count) at lines "
                + "\(hits.map { scan.line(of: $0) })"
        )
        for hit in hits {
            XCTAssertTrue(
                scan.text(in: hit..<min(hit + 40, scan.characters.count)).contains("QuietType"),
                "a second directory is spelled by hand in MemoryStore.swift at line \(scan.line(of: hit))"
            )
        }
        XCTAssertTrue(
            scan.indices(of: "applicationSupportDirectory").isEmpty,
            "the memory key is back on FileManager's own lookup, which is a different root "
                + "from the store on every platform where the store is not"
        )
    }

    /// The checkout this test file is in, found from `#filePath` rather than
    /// the working directory — which under `swift test` is wherever the caller
    /// happened to be standing.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
