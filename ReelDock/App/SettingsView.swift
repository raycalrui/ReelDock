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
                folderRow(
                    "Project Archive",
                    path: app.settings.projectArchive,
                    note: nil
                ) {
                    Button("Clear") { app.clearProjectArchive() }
                        .disabled(app.settings.projectArchive == nil)
                    Button("Choose…") { app.chooseProjectArchive(from: nil) }
                }
            }
            Section("Preview") {
                Toggle("Show log footage with its LUT", isOn: Binding(
                    get: { PreviewLUTs.shared.isEnabled },
                    set: { PreviewLUTs.shared.setEnabled($0) }
                ))
                ForEach(LogGamma.allCases, id: \.self) { gamma in
                    folderRow(
                        "\(gamma.rawValue) LUT",
                        path: PreviewLUTs.shared.paths[gamma].map { ($0 as NSString).lastPathComponent },
                        note: nil
                    ) {
                        Button("Clear") { PreviewLUTs.shared.clear(gamma) }
                            .disabled(PreviewLUTs.shared.paths[gamma] == nil)
                        Button("Choose…") { app.chooseLUT(for: gamma, from: nil) }
                    }
                }
            }
            Section("Browsing") {
                Toggle("Show hidden files", isOn: Binding(
                    get: { app.settings.showHidden },
                    set: { _ in app.toggleShowHidden() }
                ))
                LabeledContent {
                    Button("Reset") { app.resetSectionLayout() }
                        .disabled(!app.hasSectionLayout)
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
