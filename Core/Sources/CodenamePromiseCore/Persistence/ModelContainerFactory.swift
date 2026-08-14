import Foundation
import SwiftData

public enum ModelContainerFactory {
    /// The on-disk container the app uses.
    ///
    /// `allowsSave` is on and autosave is deliberately *not* relied upon — see
    /// `DraftStore` for why the save discipline is explicit.
    public static func makeAppContainer(
        url: URL? = nil,
        cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .none
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(
                schema: CodenamePromiseSchema.current,
                url: url,
                cloudKitDatabase: cloudKitDatabase
            )
        } else {
            configuration = ModelConfiguration(
                schema: CodenamePromiseSchema.current,
                cloudKitDatabase: cloudKitDatabase
            )
        }
        return try ModelContainer(
            for: CodenamePromiseSchema.current,
            migrationPlan: CodenamePromiseMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// In-memory container for tests. The durability guarantees this app makes are only
    /// credible if they're tested, and they can only be tested cheaply if the store is
    /// disposable. See ADR-025.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: CodenamePromiseSchema.current,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: CodenamePromiseSchema.current,
            migrationPlan: CodenamePromiseMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
