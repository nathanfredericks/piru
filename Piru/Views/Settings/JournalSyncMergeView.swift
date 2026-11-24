import SwiftData
import SwiftUI

struct JournalSyncMergeView: View {
    let reference: String
    let profileID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.profileDirectory) private var directory
    @State private var detail: SyncMergeDetail?
    @State private var finished = false

    var body: some View {
        JournalSyncList(title: "Merge Details") {
            if directory.activeProfileID == profileID, let detail {
                Section {
                    LabeledContent("Record ID", value: detail.key.recordID)
                    if detail.result == nil {
                        Label("Record deleted", systemImage: "trash")
                    } else {
                        Label("Edits merged automatically", systemImage: "arrow.triangle.merge")
                    }
                }
                ForEach(changedFields(detail), id: \.self) { field in
                    JournalSyncMergedField(field: field, detail: detail)
                }
            } else if finished {
                ContentUnavailableView("Merge details unavailable", systemImage: "clock.arrow.circlepath")
            } else {
                ProgressView()
            }
        }
        .privacySensitive()
        .task(id: reference) {
            defer { finished = true }
            guard directory.activeProfileID == profileID, context.container === directory.activeContainer else { return }
            detail = try? ProfileSyncJournal.mergeDetail(for: reference, in: context)
        }
    }

    private func changedFields(_ detail: SyncMergeDetail) -> [String] {
        let versions = detail.versions + [detail.result]
        let fields = Set(versions.compactMap(\.self).flatMap(\.keys)).union(detail.conflicts.keys)
        return fields.filter { field in
            Set(versions.map { $0?[field] }).count > 1 || !(detail.conflicts[field] ?? []).isEmpty
        }.sorted()
    }
}

private struct JournalSyncMergedField: View {
    let field: String
    let detail: SyncMergeDetail

    var body: some View {
        Section {
            ForEach(Array(detail.versions.enumerated()), id: \.offset) { index, version in
                LabeledContent {
                    value(in: version)
                } label: { Text("Version \(index + 1)") }
            }
            let seen = Set(detail.versions.compactMap { $0?[field] })
            ForEach(Set(detail.conflicts[field] ?? []).subtracting(seen).sorted(), id: \.self) { candidate in
                LabeledContent("Concurrent edit") { JournalSyncFieldValue(field: field, raw: candidate) }
            }
            LabeledContent("Merged result") { value(in: detail.result) }
        } header: {
            switch field {
            case "dose": Text("Dose")
            case "notes", "note", "text": Text("Notes")
            case "tags": Text("Tags")
            default: Text(verbatim: field)
            }
        }
    }

    @ViewBuilder
    private func value(in version: SyncFields?) -> some View {
        if let raw = version?[field] {
            JournalSyncFieldValue(field: field, raw: raw)
        } else if version == nil {
            Text("Record deleted")
        } else {
            Text("Not set")
        }
    }
}

private struct JournalSyncFieldValue: View {
    let field: String
    let raw: String

    var body: some View {
        let data = Data(raw.utf8)
        if field == "dose", let dose = try? JSONDecoder().decode(Dose.self, from: data) {
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(verbatim: dose.substance)
                if dose.isUnknownDose == true {
                    Text("Unknown dose")
                } else {
                    Text(verbatim: "\(dose.amount.doseFormatted) \(dose.unit)")
                }
                if let route = RouteOfAdministration(rawValue: dose.route) {
                    Text(route.localizedName)
                } else {
                    Text(verbatim: dose.route)
                }
                DisclosureGroup("All dose fields") { Text(verbatim: raw).font(.caption.monospaced()) }
            }
        } else if raw == "null" {
            Text("Not set")
        } else if let text = try? JSONDecoder().decode(String.self, from: data) {
            Text(verbatim: text)
        } else if let values = try? JSONDecoder().decode([String].self, from: data) {
            Text(verbatim: values.formatted(.list(type: .and)))
        } else {
            Text(verbatim: raw)
        }
    }

    private struct Dose: Decodable {
        let substance: String
        let amount: Double
        let unit: String
        let route: String
        let isUnknownDose: Bool?
    }
}
