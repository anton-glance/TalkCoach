import Foundation
import OSLog
import SwiftData

enum SessionContainerFactory {

    static func makeContainer() throws -> ModelContainer {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let storeDirectory = appSupport.appendingPathComponent("TalkCoach", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )

        let storeURL = storeDirectory.appendingPathComponent("sessions.store")
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: storeURL)

        return try ModelContainer(
            for: schema,
            migrationPlan: SessionMigrationPlan.self,
            configurations: config
        )
    }
}
