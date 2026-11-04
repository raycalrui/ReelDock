import SwiftUI

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        Form {
            Section("Folders") {
                folderRow(
                    "Projects Folder",
                    path: app.settings.projectRoot,
                    note: app.projectRootIsMissing ? "This folder can't be read." : nil
                ) {
                    Button("Choose…") { app.chooseProjectRoot(from: nil) }
                }
                folderRow(
                    "Personal Archive",
                    path: app.settings.mediaRoot,
                    note: nil
                ) {
                    Button("Clear") { app.clearMediaRoot() }
                        .disabled(app.settings.mediaRoot == nil)
                    Button("Choose…") { app.chooseMediaRoot(from: nil) }
                }
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: Binding(
                    get: { app.settings.showHidden },
                    set: { _ in app.toggleShowHidden() }
                ))
                LabeledContent {
                    Button("Reset") { app.resetSectionLayout() }
                        .disabled(app.settings.sections.isEmpty)
                } label: {
                    Text("Section layout")
                    Text("Heights and collapsed sections go back to their defaults.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ title: String, path: String?, note: String?, @ViewBuilder buttons: () -> some View) -> some View {
        LabeledContent {
            HStack { buttons() }
        } label: {
            Text(title)
            Text(path ?? "Not set")
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let note {
                Text(note).foregroundStyle(.orange)
            }
        }
    }
}
