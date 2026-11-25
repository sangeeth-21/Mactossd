import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Copying to SSD") {
                Toggle("Organize copies into Year / Month folders", isOn: $model.organizeByDate)
                Text("For example: 2025/2025-08/IMG_1234.HEIC. Originals are always copied untouched, at full quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("People") {
                LabeledContent("Photos library") {
                    HStack {
                        Text(model.photosLibraryPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.choosePhotosLibrary() }
                    }
                }
                Toggle("Include unnamed people", isOn: $model.includeUnnamedPeople)
                HStack {
                    Text("Reading People needs Full Disk Access.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                }
            }

            Section("Performance") {
                HStack {
                    Text("Filename and metadata caches make rescans fast.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Caches") { model.clearCaches() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
