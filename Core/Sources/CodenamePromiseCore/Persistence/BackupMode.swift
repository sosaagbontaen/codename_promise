import Foundation
import SwiftData

/// Whether the journal is backed up to the person's own iCloud.
///
/// The whole feature is a second copy of something irreplaceable, so the governing rule is
/// the project's first tenet rather than anything about sync: **backup may never be able to
/// break the journal.** Every decision below follows from that.
public enum BackupMode: String, Codable, Sendable, CaseIterable {
    /// Everything stays in the app's own container. Still covered by the iPhone's own
    /// backup, which is worth saying out loud because people assume otherwise.
    case thisPhoneOnly
    /// Synced through the person's private iCloud database. Not our servers: we never hold
    /// a copy and could not read one if we wanted to.
    case iCloud

    public var label: String {
        switch self {
        case .thisPhoneOnly: "This phone only"
        case .iCloud: "iCloud"
        }
    }
}

/// The CloudKit container the journal lives in.
///
/// Deliberately not derived from the bundle identifier, which is what Xcode offers by
/// default. The product name is unsettled and the bundle id will change with it; a container
/// named after either would either have to be abandoned, taking the data with it, or would
/// carry a dead product name forever. This one is named after the person and says nothing
/// about what the app is called, so a rename never touches it.
///
/// Permanent once data has been written to it. Do not change this string.
public enum CloudContainer {
    public static let identifier = "iCloud.com.osaagbontaen.journal"
}

/// What happened when the store was opened, and what the UI is allowed to claim.
public struct StoreOpening {
    public let container: ModelContainer
    /// True only when the store is genuinely CloudKit-backed. The settings screen reads this
    /// rather than the requested mode, because a switch that says iCloud while nothing is
    /// syncing is worse than no switch.
    public let isBackedUp: Bool
    /// Why iCloud was asked for and not used. Nil when nothing was wrong.
    public let unavailable: String?

    public init(container: ModelContainer, isBackedUp: Bool, unavailable: String? = nil) {
        self.container = container
        self.isBackedUp = isBackedUp
        self.unavailable = unavailable
    }
}

extension ModelContainerFactory {

    /// Opens the store, preferring iCloud when asked, and falling back to local rather than
    /// failing.
    ///
    /// The fallback is the point. Turning on a backup switch must never be able to stop
    /// somebody reading their journal, and every reason iCloud can be missing is outside
    /// their control and usually temporary: signed out, out of storage, a provisioning
    /// profile without the entitlement, a device restriction. Refusing to open the store in
    /// any of those cases would trade the thing the app promises for the thing it merely
    /// offers.
    ///
    /// The caller is told what happened so the UI can say so. Silently running local while
    /// the switch reads iCloud would be the same lie in the other direction.
    public static func openAppContainer(
        backup: BackupMode,
        cloudContainerId: String = CloudContainer.identifier,
        /// Takes the CloudKit container id, or nil for a purely local store. Deliberately
        /// a `String?` rather than SwiftData's own type: that one is a struct of static
        /// factories rather than an enum, so a test cannot look at it and say which was
        /// asked for. The seam is only useful if a test can see through it.
        make: (String?) throws -> ModelContainer = { id in
            try makeAppContainer(
                cloudKitDatabase: id.map { .private($0) } ?? .none
            )
        }
    ) throws -> StoreOpening {
        guard backup == .iCloud else {
            return StoreOpening(container: try make(nil), isBackedUp: false)
        }

        do {
            return StoreOpening(container: try make(cloudContainerId), isBackedUp: true)
        } catch {
            // Local still has to open. If this throws too there is no journal to show and
            // the error belongs to the caller.
            return StoreOpening(
                container: try make(nil),
                isBackedUp: false,
                unavailable: Self.explain(error)
            )
        }
    }

    /// Turns a CloudKit failure into something worth reading.
    ///
    /// Deliberately never says "failed". None of these are the person's mistake and none of
    /// them mean anything was lost, so the sentence says what is true and what to do, in
    /// that order.
    static func explain(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription.lowercased()
        if text.contains("entitle") || text.contains("permission") {
            return "This build isn't set up for iCloud yet. Your journal is on this phone."
        }
        if text.contains("account") || text.contains("signed") {
            return "Sign in to iCloud to back up. Your journal is on this phone either way."
        }
        if text.contains("quota") || text.contains("storage") || text.contains("space") {
            return "Your iCloud storage is full. Your journal is on this phone."
        }
        return "iCloud isn't available right now. Your journal is on this phone."
    }
}
