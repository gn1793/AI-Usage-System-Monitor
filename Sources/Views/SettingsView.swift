import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var monitor: MonitorCoordinator
    @State private var alias = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Monitor Settings").font(.title2.bold()); Spacer(); Button("Done") { NSApp.keyWindow?.close() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Menu-bar dashboard") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Height"); Spacer(); Text("\(Int(prefs.popupHeight)) pt").monospacedDigit() }
                            Slider(value: $prefs.popupHeight, in: 420...1600, step: 20).accessibilityLabel("Dashboard height")
                            HStack { Text("Width"); Spacer(); Text("\(Int(prefs.popupWidth)) pt").monospacedDigit() }
                            Slider(value: $prefs.popupWidth, in: 420...1200, step: 20).accessibilityLabel("Dashboard width")
                            Text("You can also drag the dashboard edges. Its size is saved and limited to the current screen.").font(.caption).foregroundStyle(.secondary)
                            Button("Reset size") { prefs.popupWidth = 540; prefs.popupHeight = 820 }
                            Picker("Appearance", selection: $prefs.theme) { ForEach(AppTheme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                            Toggle("Save energy when both dashboards are closed", isOn: $prefs.energySaving)
                            Text("Optional background sampling: 60 seconds. Open dashboard: normal 10 seconds or realtime 1 second.").font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    GroupBox("SSH Computers") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Use an SSH alias or user@host. Terminal SSH login must work without prompts.").font(.caption).foregroundStyle(.secondary)
                            HStack { TextField("SSH host alias", text: $alias).textFieldStyle(.roundedBorder).onSubmit(add); Button("Add", action: add) }
                            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                            if prefs.hosts.isEmpty { Text("No hosts configured.").foregroundStyle(.secondary).padding(.vertical, 8) }
                            ForEach(prefs.hosts) { host in
                                HStack {
                                    Toggle(host.alias, isOn: Binding(get: { prefs.hosts.first(where: { $0.alias == host.alias })?.enabled ?? false }, set: { value in
                                        if let index = prefs.hosts.firstIndex(where: { $0.alias == host.alias }) { prefs.hosts[index].enabled = value; monitor.reconcile(prefs.hosts) }
                                    }))
                                    Spacer()
                                    Button { prefs.hosts.removeAll { $0.alias == host.alias }; monitor.reconcile(prefs.hosts) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).accessibilityLabel("Remove \(host.alias)").help("Remove host from this monitor")
                                }
                            }
                            Text("Collection uses SSH and remote Python 3 without installing files. Linux CPU/RAM and NVIDIA NVML are supported.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(8)
                    }
                }
            }
        }.padding(20).frame(minWidth: 460, minHeight: 500)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(prefs.theme.colorScheme)
    }
    private func add() {
        error = prefs.add(alias)
        if error == nil { alias = ""; monitor.reconcile(prefs.hosts) }
    }
}
