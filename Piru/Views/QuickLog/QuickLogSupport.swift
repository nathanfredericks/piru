import SwiftUI
import UIKit

struct QuickLogDetails: View {
    @Bindable var tray: DoseTrayModel
    let content: QuickLogContentModel
    let onFindLocation: () -> Void

    @AppStorage(DoseTimeDefaults.choicesKey, store: UserDefaults(suiteName: DoseTimeDefaults.suite))
    private var timePresets = DoseTimeDefaults.defaultRaw

    var body: some View {
        Section("Details") {
            Menu {
                Button("Now") { tray.time = .now }
                ForEach(DoseTimeDefaults.parse(timePresets), id: \.self) { minutes in
                    Button(TrayTime.offsetLabel(minutes: minutes)) { tray.time = .offset(minutes: minutes) }
                }
                Button("Pick date & time…") { tray.time = .custom(tray.time.resolved) }
            } label: {
                LabeledContent("When", value: tray.time.chipLabel)
            }
            if case let .custom(date) = tray.time {
                // Keep the original selection available for editing even when
                // an older launch URL supplied a future timestamp.
                DatePicker(
                    "Date and Time",
                    selection: Binding(
                        get: { if case let .custom(current) = tray.time { current } else { date } },
                        set: { tray.time = .custom($0) },
                    ),
                    in: ...max(Date.now, date),
                )
            }
            TrayRecipientRow(model: tray)
            if tray.staged.contains(where: { $0.route == .oral }) {
                Picker("Stomach", selection: $tray.meal) {
                    Text("Unknown").tag(MealState?.none)
                    ForEach(MealState.allCases, id: \.self) { meal in
                        Text(meal.label).tag(Optional(meal))
                    }
                }
            }
            NavigationLink {
                QuickLogTagsPage(tray: tray, suggestions: content.cachedTagSuggestions)
            } label: {
                LabeledContent("Tags", value: tray.tags.sorted().formatted(.list(type: .and)))
            }
            Button(action: onFindLocation) {
                LabeledContent("Location", value: tray.location?.name ?? String(localized: "None"))
            }
            if tray.location != nil {
                Button("Remove location") { tray.location = nil }
            }
        }
    }
}

private struct QuickLogTagsPage: View {
    @Bindable var tray: DoseTrayModel
    let suggestions: [String]
    @State private var newTag = ""

    private var tag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    var body: some View {
        Form {
            Section {
                TextField("New tag", text: $newTag)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(add)
                Button("Add", action: add).disabled(tag.isEmpty)
            }
            Section("Tags") {
                ForEach(Set(suggestions).union(tray.tags).sorted(), id: \.self) { tag in
                    Toggle(isOn: Binding(
                        get: { tray.tags.contains(tag) },
                        set: { selected in
                            if selected { tray.tags.insert(tag) } else { tray.tags.remove(tag) }
                        },
                    )) {
                        Text(verbatim: tag)
                    }
                }
            }
        }
        .navigationTitle("Tags")
    }

    private func add() {
        guard !tag.isEmpty else { return }
        tray.tags.insert(tag)
        newTag = ""
    }
}

struct QuickLogLocationPage: View {
    let recents: [PickedLocation]
    let onPick: (PickedLocation) -> Void

    @Environment(\.openURL) private var openURL
    @State private var model = LocationSearchModel()
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        if let place = await model.requestCurrentLocation() { onPick(place) }
                    }
                } label: {
                    Label("Current Location", systemImage: "location.fill")
                }
                .disabled(model.isLocating)
                if model.isLocating { ProgressView() }
                if model.authDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                }
            }
            if query.isEmpty {
                Section("Recents") {
                    ForEach(recents.uniqued(by: \.name), id: \.name) { place in
                        Button(place.name) { onPick(place) }
                    }
                }
            } else {
                Section("Results") {
                    ForEach(model.suggestions) { suggestion in
                        Button {
                            Task {
                                if let place = await model.resolve(suggestion) { onPick(place) }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: suggestion.title)
                                if !suggestion.subtitle.isEmpty {
                                    Text(verbatim: suggestion.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Location")
        .searchable(text: $query, prompt: "Search for a place or address")
        .onChange(of: query) { model.query = query }
    }
}

struct QuickLogBrowsePage: View {
    let onSelect: (QuickLogStagePayload) -> Void

    var body: some View {
        List(LibraryFamily.browsable) { family in
            NavigationLink {
                List {
                    QuickLogSearchResults(
                        results: substances(in: family).map { .custom($0) },
                        onAdd: onSelect,
                        onAddCombination: { _ in },
                    )
                }
                .navigationTitle(family.title)
            } label: {
                Label(family.title, systemImage: family.icon)
            }
        }
        .navigationTitle("Browse")
    }

    private func substances(in family: LibraryFamily) -> [Substance] {
        let list: [Substance] = switch family.source {
        case let .category(category): SubstanceLibrary.substances(in: category)
        case let .tag(tag): SubstanceLibrary.substances(taggedWith: tag)
        case nil: family.subclasses.flatMap { SubstanceLibrary.substances(in: $0.category) }
        }
        return Array(list.sorted {
            if $0.popularity != $1.popularity { return $0.popularity > $1.popularity }
            return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }.prefix(20))
    }
}
