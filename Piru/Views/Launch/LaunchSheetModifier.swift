import SwiftData
import SwiftUI

struct LaunchSheetModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @State private var notice: UpdateNotice?

    func body(content: Content) -> some View {
        content
            .sheet(item: $notice) { notice in
                UpdateNoticeView(notice: notice)
            }
            .task {
                InstallRecord.recordIfNeeded()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                #if DEBUG
                    if let forced = UserDefaults.standard.string(forKey: "piruShowUpdateNotice").flatMap(UpdateNotice.init) {
                        notice = forced
                        return
                    }
                    if ScreenshotTour.isRequested { return }
                #endif
                notice = UpdateNotice.next(in: modelContext)
            }
    }
}
