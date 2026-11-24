import SwiftUI

/// Offers support when a search matches a distress keyword.
struct QuickLogHelpBanner: View {
    var body: some View {
        Section {
            Text("You don't have to do this alone. Help is one tap away.")
            ForEach(EmergencyServices.services(for: EmergencyServices.regionCode)) { service in
                if let destination = URL(string: service.url) {
                    Link(destination: destination) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(service.title)
                                Text(verbatim: service.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: service.systemImage)
                        }
                    }
                }
            }
        } header: {
            Text("Take a breath.")
        } footer: {
            Text("Breathe slowly. 4 seconds in, hold for 4, out for 4.")
        }
    }
}
