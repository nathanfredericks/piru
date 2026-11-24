import Foundation
import SwiftData

extension SyncProjection {
    static let tables: [any SyncModelTable] = [
        doseEntry,
        session,
        sessionNote,
        dailyDoseItem,
        doseRoutine,
        routineOccurrence,
        favoriteSubstance,
        substanceColor,
        quickLogDose,
        inventoryItem,
        customSubstanceRecord,
        customUnitPreset,
        customDrinkPreset,
        userProfileRecord,
        notificationPreferences,
        labMeasurement,
    ]

    static let doseEntry = SyncTable<DoseEntry>(
        kind: "dose",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { _ in DoseEntry(substance: "", amount: 0) },
        columns: [
            .group("dose", [
                .init("substance", \.substance),
                .init("amount", \.amount),
                .init("unit", \.unit),
                .init("route", \.route),
                .init("saltForm", \.saltForm),
                .init("isomer", \.isomer),
                .init("releaseForm", \.releaseForm),
                .init("substanceUID", \.substanceUID),
                .init("productName", \.productName),
                .init("displayNameSnapshot", \.displayNameSnapshot),
                .init("isApproximate", \.isApproximate),
                .init("isUnknownDose", \.isUnknownDose),
                .init("volumeML", \.volumeML),
                .init("abv", \.abv),
                .init("drinkName", \.drinkName),
                .init("combinationName", \.combinationName),
                .init("injectionSiteRaw", \.injectionSiteRaw),
            ], required: ["substance", "amount", "unit", "route"], defaults: ["isApproximate": "false", "isUnknownDose": "false"]),
            .init("timestamp", \.timestamp),
            .init("timeZoneIdentifier", \.timeZoneIdentifier),
            .init("medSlotMinutes", \.medSlotMinutes),
            .init("notes", \.notes),
            .init("tags", \.tags),
            .init("isBackgroundMed", \.isBackgroundMed),
            .init("hadGrapefruit", \.hadGrapefruit),
            .init("mealRaw", \.mealRaw),
            sessionLink(\.session, pending: \.pendingSyncSessionID),
        ],
        afterWrite: { row, _ in row.session?.refreshDoseBounds() },
    )

    static let session = SyncTable<Session>(
        kind: "session",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { id in Session(id: id, startDate: .distantPast) },
        columns: [
            .init("startDate", \.startDate),
            .init("title", \.title),
            .init("note", \.note),
            .group("checkIns", [
                .init("checkInIntervalMinutes", \.checkInIntervalMinutes),
                .init("checkInOffsetMinutes", \.checkInOffsetMinutes),
                .init("checkInFollowsDoses", \.checkInFollowsDoses),
            ], required: ["checkInOffsetMinutes", "checkInFollowsDoses"]),
            .init("checkInOffered", \.checkInOffered),
        ],
        afterWrite: { try attachWaitingChildren($0, in: $1) },
        beforeDelete: { detachSession($0) },
    )

    static let sessionNote = SyncTable<SessionNote>(
        kind: "sessionNote",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { id in SessionNote(id: id) },
        columns: [
            .init("timestamp", \.timestamp),
            .init("text", \.text),
            .init("shulgin", \.shulgin),
            .init("mood", \.mood),
            .init("energy", \.energy),
            .init("social", \.social),
            .init("worked", \.worked),
            .init("descriptors", \.descriptors),
            .init("kindRaw", \.kindRaw),
            sessionLink(\.session, pending: \.pendingSyncSessionID),
        ],
    )

    static let dailyDoseItem = SyncTable<DailyDoseItem>(
        kind: "dailyDoseItem",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { try [$0.identityKey, $0.route.rawValue, $0.category, $0.productName ?? "", SyncJSON.encode($0.startDate), SyncJSON.encode($0.reminderTimesMinutes)] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in DailyDoseItem(substance: "", amount: 0) },
        columns: [
            .group("dose", [
                .init("substance", \.substance),
                .init("amount", \.amount),
                .init("unit", \.unit),
                .init("route", \.route),
                .init("substanceUID", \.substanceUID),
                .init("isomer", \.isomer),
                .init("releaseForm", \.releaseForm),
                .init("saltForm", \.saltForm),
                .init("productName", \.productName),
            ], required: ["substance", "amount", "unit", "route"]),
            .init("sortOrder", \.sortOrder),
            .group("schedule", [
                .init("category", \.category),
                .init("isBackgroundMed", \.isBackgroundMed),
                .init("reminderTimesMinutes", \.reminderTimesMinutes),
                .init("remind", \.remind),
                .init("askAgainOverrideMinutes", \.askAgainOverrideMinutes),
                .init("isQuiet", \.isQuiet),
                .init("isAsNeeded", \.isAsNeeded),
                .init("maxPerDay", \.maxPerDay),
                .init("frequencyRaw", \.frequencyRaw),
                .init("frequencyDays", \.frequencyDays),
                .init("frequencyIntervalDays", \.frequencyIntervalDays),
                .init("startDate", \.startDate),
            ], required: ["category", "remind", "frequencyRaw", "frequencyDays", "frequencyIntervalDays", "startDate", "reminderTimesMinutes"], defaults: ["isBackgroundMed": "false", "isQuiet": "false", "isAsNeeded": "false"]),
        ],
    )

    static let doseRoutine = SyncTable<DoseRoutine>(
        kind: "doseRoutine",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.name] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in DoseRoutine(name: "") },
        columns: [
            .init("name", \.name),
            .init("sortOrder", \.sortOrder),
            .group("schedule", [
                .init("timeMinutes", \.timeMinutes),
                .init("remind", \.remind),
                .init("followUpMinutes", \.followUpMinutes),
            ], required: ["remind", "followUpMinutes"]),
        ],
        naturalMatch: { fields, context in
            guard let json = fields["name"] else { return nil }
            let value = try SyncJSON.decode(String.self, from: json)
            var request = FetchDescriptor<DoseRoutine>(predicate: #Predicate { $0.name == value })
            request.fetchLimit = 1
            return try context.fetch(request).first
        },
    )

    static let routineOccurrence = SyncTable<RoutineOccurrence>(
        kind: "routineOccurrence",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { try [$0.routineName, $0.substanceUID ?? $0.substance.lowercased(), $0.routeRaw, SyncJSON.encode($0.dueDay), SyncJSON.encode($0.slotMinutes)] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in RoutineOccurrence(substance: "", route: .oral, dueDay: .distantPast) },
        columns: [
            .init("routineName", \.routineName),
            .init("substance", \.substance),
            .init("substanceUID", \.substanceUID),
            .init("routeRaw", \.routeRaw),
            .init("dueDay", \.dueDay),
            .init("slotMinutes", \.slotMinutes),
            .init("stateRaw", \.stateRaw),
            reference("satisfyingEntryID", \.satisfyingEntryID),
        ],
    )

    static let favoriteSubstance = SyncTable<FavoriteSubstance>(
        kind: "favorite",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.substance] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in FavoriteSubstance(substance: "") },
        columns: [
            .init("substance", \.substance),
            .init("createdAt", \.createdAt),
            .init("sortOrder", \.sortOrder),
            .init("substanceUID", \.substanceUID),
            .init("isomer", \.isomer),
            .init("releaseForm", \.releaseForm),
            .init("saltForm", \.saltForm),
            .init("productName", \.productName),
        ],
        naturalMatch: { fields, context in
            guard let json = fields["substance"] else { return nil }
            let value = try SyncJSON.decode(String.self, from: json)
            var request = FetchDescriptor<FavoriteSubstance>(predicate: #Predicate { $0.substance == value })
            request.fetchLimit = 1
            return try context.fetch(request).first
        },
    )

    static let substanceColor = SyncTable<SubstanceColor>(
        kind: "substanceColor",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.substance] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in SubstanceColor(substance: "", tint: .neutral, usesDefault: true) },
        columns: [
            .init("substance", \.substance),
            colorChoice,
        ],
        naturalMatch: { fields, context in
            guard let json = fields["substance"] else { return nil }
            let value = try SyncJSON.decode(String.self, from: json)
            var request = FetchDescriptor<SubstanceColor>(predicate: #Predicate { $0.substance == value })
            request.fetchLimit = 1
            return try context.fetch(request).first
        },
        visible: { !$0.usesDefault || $0.isLegacy },
    )

    static let quickLogDose = SyncTable<QuickLogDose>(
        kind: "quickLogDose",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.key] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in QuickLogDose(substance: "", route: .oral, amount: 0, unit: "", sortOrder: 0) },
        columns: [
            .group("dose", [
                .init("substance", \.substance),
                .init("route", \.route),
                .init("amount", \.amount),
                .init("unit", \.unit),
                .init("volumeML", \.volumeML),
                .init("abv", \.abv),
                .init("drinkName", \.drinkName),
                .init("substanceUID", \.substanceUID),
                .init("isomer", \.isomer),
                .init("releaseForm", \.releaseForm),
                .init("saltForm", \.saltForm),
                .init("productName", \.productName),
            ], required: ["substance", "amount", "unit", "route"]),
            .init("sortOrder", \.sortOrder),
            .init("lastUsedAt", \.lastUsedAt),
            .init("emoji", \.emoji),
        ],
    )

    static let inventoryItem = SyncTable<InventoryItem>(
        kind: "inventoryItem",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { id in InventoryItem(id: id) },
        columns: [
            .init("substance", \.substance),
            .init("saltForm", \.saltForm),
            .init("isomer", \.isomer),
            .init("productName", \.productName),
            .init("displayNameSnapshot", \.displayNameSnapshot),
            .group("stock", [
                .init("unit", \.unit),
                .init("lowStockThreshold", \.lowStockThreshold),
                .init("baselineQuantity", \.baselineQuantity),
                .init("doseSize", \.doseSize),
                .init("unitStrengthMG", \.unitStrengthMG),
            ], required: ["unit"]),
            .init("trackingStart", \.trackingStart),
            .init("createdAt", \.createdAt),
            .init("sortOrder", \.sortOrder),
        ],
        projectExtras: { try inventoryEvents($0) },
        prepareExtras: { try prepareInventoryEvents($0) },
    )

    static let customSubstanceRecord = SyncTable<CustomSubstanceRecord>(
        kind: "customSubstance",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { id in CustomSubstanceRecord(id: id) },
        columns: [
            .init("name", \.name),
            .init("displayName", \.displayName),
            .init("categoryRaw", \.categoryRaw),
            .init("defaultRouteRaw", \.defaultRouteRaw),
            .init("unit", \.unit),
            .init("notes", \.notes),
            .init("halfLifeMinutes", \.halfLifeMinutes),
            .init("createdAt", \.createdAt),
            blob("doses", \.dosesData, as: DoseRange.self),
            blob("duration", \.durationData, as: DurationProfile.self),
            blob("components", \.componentsData, as: [CombinationComponent].self),
        ],
    )

    static let customUnitPreset = SyncTable<CustomUnitPreset>(
        kind: "customUnit",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.substanceName, $0.label] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in CustomUnitPreset(substanceName: "", label: "", amountPerUnit: 0) },
        columns: [
            .init("substanceName", \.substanceName),
            .init("label", \.label),
            .group("conversion", [
                .init("amountPerUnit", \.amountPerUnit),
                .init("unit", \.unit),
            ], required: ["amountPerUnit", "unit"]),
            .init("sortOrder", \.sortOrder),
            .init("createdAt", \.createdAt),
        ],
    )

    static let customDrinkPreset = SyncTable<CustomDrinkPreset>(
        kind: "customDrink",
        tombstonePath: \.syncID,
        identify: { $0.syncID }, assign: { $0.syncID = $1 },
        seed: { [$0.substanceName, $0.name] },
        predicate: { id in #Predicate { $0.syncID == id } },
        create: { _ in CustomDrinkPreset(name: "", strengthABV: 0) },
        columns: [
            .init("name", \.name),
            .init("emoji", \.emoji),
            .group("measure", [
                .init("strengthABV", \.strengthABV),
                .init("volumeML", \.volumeML),
            ], required: ["strengthABV"]),
            .init("substanceName", \.substanceName),
            .init("sortOrder", \.sortOrder),
            .init("createdAt", \.createdAt),
        ],
    )

    static let userProfileRecord = SyncTable<UserProfileRecord>(
        kind: "userProfile",
        tombstonePath: nil,
        identify: { _ in singletonID }, assign: { _, _ in },
        seed: nil,
        predicate: { _ in nil },
        create: { _ in UserProfileRecord() },
        columns: [
            .init("disclosureTierRaw", \.disclosureTierRaw),
            .init("grapefruitLoggingEnabled", \.grapefruitLoggingEnabled),
            .init("aldh2Deficient", \.aldh2Deficient),
            manualWeight,
        ],
    )

    static let notificationPreferences = SyncTable<NotificationPreferences>(
        kind: "notificationPreferences",
        tombstonePath: nil,
        identify: { _ in singletonID }, assign: { _, _ in },
        seed: nil,
        predicate: { _ in nil },
        create: { _ in NotificationPreferences() },
        columns: [
            .init("masterEnabled", \.masterEnabled),
            .init("hydrationEnabled", \.hydrationEnabled),
            .init("sleepEnabled", \.sleepEnabled),
            .init("phaseEnabled", \.phaseEnabled),
            .init("cumulativeEnabled", \.cumulativeEnabled),
            .init("routineEnabled", \.routineEnabled),
            .init("routineFollowUpEnabled", \.routineFollowUpEnabled),
            .init("inventoryEnabled", \.inventoryEnabled),
            .init("checkInEnabled", \.checkInEnabled),
            .init("quietHoursEnabled", \.quietHoursEnabled),
            .init("quietHoursStartMinutes", \.quietHoursStartMinutes),
            .init("quietHoursEndMinutes", \.quietHoursEndMinutes),
            .init("routineTimeSensitive", \.routineTimeSensitive),
            .init("routineFollowUpTimeSensitive", \.routineFollowUpTimeSensitive),
            .init("cumulativeTimeSensitive", \.cumulativeTimeSensitive),
            askAgainCadence,
        ],
    )

    static let labMeasurement = SyncTable<LabMeasurement>(
        kind: "labMeasurement",
        tombstonePath: \.id,
        identify: { $0.id }, assign: { $0.id = $1 },
        seed: nil,
        predicate: { id in #Predicate { $0.id == id } },
        create: { id in LabMeasurement(id: id) },
        columns: [
            .init("date", \.date),
            .group("measurement", [
                .init("analyteKey", \.analyteKey),
                .init("value", \.value),
                .init("inputUnit", \.inputUnit),
                .init("esterID", \.esterID),
            ], required: ["analyteKey", "value", "inputUnit"]),
            .init("excludedFromCalibration", \.excludedFromCalibration),
            .init("note", \.note),
            .init("createdAt", \.createdAt),
        ],
    )
}
