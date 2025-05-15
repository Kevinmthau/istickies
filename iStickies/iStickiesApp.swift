//
//  iStickiesApp.swift
//  iStickies
//
//  Created by Kevin Thau on 5/15/25.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct iStickiesApp: App {
    var body: some Scene {
        DocumentGroup(editing: .itemDocument, migrationPlan: iStickiesMigrationPlan.self) {
            ContentView()
        }
    }
}

extension UTType {
    static var itemDocument: UTType {
        UTType(importedAs: "com.example.item-document")
    }
}

struct iStickiesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [VersionedSchema.Type] = [
        iStickiesVersionedSchema.self,
    ]

    static var stages: [MigrationStage] = [
        // Stages of migration between VersionedSchema, if required.
    ]
}

struct iStickiesVersionedSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] = [
        Item.self,
    ]
}
