import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// Backing the journal up must never be able to take it away.
///
/// Every reason iCloud can be missing is outside the person's control and usually temporary:
/// signed out, out of storage, a profile without the entitlement, a device restriction. If
/// any of those stopped the store opening, an optional convenience would have broken the one
/// thing the app actually promises.
@Suite("Backup", .serialized)
@MainActor
struct BackupTests {

    /// Stands in for CloudKit being unavailable, so the rule can be tested without an iCloud
    /// account, an entitlement or a network.
    private func maker(cloudFails: String?) -> (String?) throws -> ModelContainer {
        { id in
            if id != nil, let cloudFails {
                throw NSError(
                    domain: "CloudKit", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: cloudFails]
                )
            }
            return try ModelContainerFactory.makeInMemoryContainer()
        }
    }

    @Test("asking for local never touches iCloud")
    func localAsksForNothing() throws {
        var askedForCloud = false
        let opening = try ModelContainerFactory.openAppContainer(backup: .thisPhoneOnly) { id in
            askedForCloud = id != nil
            return try ModelContainerFactory.makeInMemoryContainer()
        }
        #expect(opening.isBackedUp == false)
        #expect(opening.unavailable == nil)
        #expect(askedForCloud == false)
    }

    @Test("iCloud is used when it is available")
    func usesCloudWhenAvailable() throws {
        let opening = try ModelContainerFactory.openAppContainer(
            backup: .iCloud, make: maker(cloudFails: nil)
        )
        #expect(opening.isBackedUp)
        #expect(opening.unavailable == nil)
    }

    /// The whole point.
    @Test("the journal still opens when iCloud will not")
    func fallsBackRatherThanFailing() throws {
        let opening = try ModelContainerFactory.openAppContainer(
            backup: .iCloud,
            make: maker(cloudFails: "Missing com.apple.developer.icloud entitlement")
        )
        #expect(opening.isBackedUp == false, "must not claim to be backed up")
        #expect(opening.unavailable != nil, "must say why, rather than pretending")
    }

    /// A switch that reads iCloud while nothing syncs is worse than no switch, so the flag
    /// reports what actually happened rather than what was asked for.
    @Test("the reported state is what happened, not what was requested")
    func reportsRealityNotIntent() throws {
        let opening = try ModelContainerFactory.openAppContainer(
            backup: .iCloud, make: maker(cloudFails: "not signed in to iCloud")
        )
        #expect(opening.isBackedUp == false)
    }

    @Test("each reason it can be unavailable says what to do about it")
    func explainsUsefully() {
        let entitlement = ModelContainerFactory.explain(
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing entitlement"])
        )
        #expect(entitlement.contains("isn't set up"))

        let account = ModelContainerFactory.explain(
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No iCloud account"])
        )
        #expect(account.contains("Sign in"))

        let quota = ModelContainerFactory.explain(
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Quota exceeded"])
        )
        #expect(quota.contains("storage is full"))
    }

    /// The tone rule. None of these are the person's mistake, and none of them mean anything
    /// was lost, so none of them may read like an error.
    @Test("no unavailable message implies anything was lost")
    func neverImpliesLoss() {
        let messages = ["missing entitlement", "no account", "quota exceeded", "something odd"]
            .map { ModelContainerFactory.explain(
                NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: $0])
            ) }
        for message in messages {
            for word in ["failed", "error", "lost", "couldn't save", "unable to save"] {
                #expect(!message.lowercased().contains(word), "\(message) should not say '\(word)'")
            }
            #expect(message.contains("on this phone"), "\(message) should say where the journal is")
        }
    }

    /// Permanent once data exists in it, and deliberately not derived from the bundle id,
    /// which is about to change with the product name.
    @Test("the container id survives a rename")
    func containerIdIsNeutral() {
        #expect(CloudContainer.identifier.hasPrefix("iCloud."))
        for name in ["dumpnotes", "codenamepromise", "autoreflect", "journal.app"] {
            #expect(!CloudContainer.identifier.lowercased().contains(name)
                    || name == "journal.app")
        }
        #expect(!CloudContainer.identifier.lowercased().contains("dumpnotes"))
    }
}

/// Where the bytes live once the journal is backed up.
///
/// The rule under test is that nothing already on disk is ever moved. A bulk relocation of
/// the one category of data in this app that cannot be regenerated has no version that is
/// safe to get wrong, so files stay where they were written and a path resolves against
/// every root the app has used.
@Suite("Backup media roots", .serialized)
struct BackupMediaRootTests {

    private func makeRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a file written before the switch is still found after it")
    func oldFilesStayReadable() throws {
        let old = try makeRoot("old")
        let before = MediaFileStore(root: old)
        let written = try before.write(Data("a photo".utf8), preferredName: "original", extension: "jpg")

        // Switching backup on changes where new files go, and nothing else.
        let after = MediaFileStore(root: try makeRoot("new"), previousRoots: [old])

        #expect(after.exists(written.relativePath), "the photo must not disappear")
        #expect(try Data(contentsOf: after.url(for: written.relativePath)) == Data("a photo".utf8))
    }

    @Test("nothing is moved off the old root")
    func nothingIsRelocated() throws {
        let old = try makeRoot("old")
        let before = MediaFileStore(root: old)
        let written = try before.write(Data("x".utf8), preferredName: "original", extension: "jpg")

        let after = MediaFileStore(root: try makeRoot("new"), previousRoots: [old])
        _ = after.exists(written.relativePath)

        let stillThere = old.appendingPathComponent(written.relativePath)
        #expect(FileManager.default.fileExists(atPath: stillThere.path),
                "resolving a path must never have the side effect of moving it")
    }

    @Test("new files go to the new root")
    func newFilesUseTheCurrentRoot() throws {
        let old = try makeRoot("old")
        let new = try makeRoot("new")
        let store = MediaFileStore(root: new, previousRoots: [old])

        let written = try store.write(Data("fresh".utf8), preferredName: "original", extension: "m4a")
        #expect(FileManager.default.fileExists(
            atPath: new.appendingPathComponent(written.relativePath).path))
        #expect(!FileManager.default.fileExists(
            atPath: old.appendingPathComponent(written.relativePath).path))
    }

    /// A recorder needs somewhere to stream to, and it must be under the current root even
    /// though older roots are still being read from.
    @Test("a reservation is made under the current root")
    func reservationsUseTheCurrentRoot() throws {
        let old = try makeRoot("old")
        let new = try makeRoot("new")
        let store = MediaFileStore(root: new, previousRoots: [old])

        let spot = try store.reserve(preferredName: "dictation", extension: "m4a")
        #expect(spot.url.path.hasPrefix(new.path))
    }

    /// Orphan reaping walks the current root. It must not wander into an older one and
    /// delete files it does not recognise.
    @Test("reaping never touches an older root")
    func reapingStaysInTheCurrentRoot() throws {
        let old = try makeRoot("old")
        let before = MediaFileStore(root: old)
        let kept = try before.write(Data("old photo".utf8), preferredName: "original", extension: "jpg")

        let store = MediaFileStore(root: try makeRoot("new"), previousRoots: [old])
        _ = store.reapOrphans(claimedRelativePaths: [])

        #expect(FileManager.default.fileExists(
            atPath: old.appendingPathComponent(kept.relativePath).path),
            "a file in an older root is not an orphan, it is history")
    }

    @Test("a file that is present needs no download")
    func presentFileNeedsNoDownload() throws {
        let store = MediaFileStore(root: try makeRoot("only"))
        let written = try store.write(Data("here".utf8), preferredName: "original", extension: "jpg")
        #expect(store.ensureDownloaded(written.relativePath))
    }

    @Test("a missing file reports as not ready rather than pretending")
    func missingFileIsNotReady() throws {
        let store = MediaFileStore(root: try makeRoot("only"))
        #expect(store.ensureDownloaded("media/nope/original.jpg") == false)
    }
}

/// Changing where the app points must not need a relaunch.
///
/// The address was captured once, at launch, so saving a new one in Settings did nothing
/// until the app was restarted — on the single setting somebody is most likely to be editing
/// precisely because nothing is connecting.
@Suite("Backend address")
struct BackendAddressTests {

    @Test("the address is read per request, not captured once")
    func addressIsResolvedLive() {
        nonisolated(unsafe) var current: URL? = URL(string: "https://first.example.com")
        let configuration = APIConfiguration(baseURL: { current }, apiKey: { nil })

        #expect(configuration.baseURL()?.host() == "first.example.com")

        current = URL(string: "https://second.example.com")
        #expect(configuration.baseURL()?.host() == "second.example.com",
                "a saved address must apply without rebuilding the client")
    }

    @Test("an absent address is still a supported state")
    func absentAddressIsFine() {
        let configuration = APIConfiguration(baseURL: { nil }, apiKey: { nil })
        #expect(configuration.isConfigured == false)
    }

    /// The fixed-value initialiser is what tests and simple callers use; it must keep working.
    @Test("a fixed address still works")
    func fixedAddressStillWorks() {
        let url = URL(string: "https://example.com")!
        let configuration = APIConfiguration(baseURL: url, apiKey: { nil })
        #expect(configuration.isConfigured)
        #expect(configuration.baseURL() == url)
    }
}
