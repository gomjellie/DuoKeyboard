import SwiftUI

/// The main window: a System Settings–style sidebar (일반, 앱별 설정, 학습, 정보) and grouped forms.
struct SettingsRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(keepingSelection: $app.selectedPane)) { pane in
                SettingsSidebarLabel(pane: pane).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            SettingsPaneView(pane: app.selectedPane)
                .navigationTitle(Text(app.selectedPane.title))
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: DuoStyle.settingsMinimumSize.width, minHeight: DuoStyle.settingsMinimumSize.height)
        .onAppear { app.status.beginMonitoring() }
        .onDisappear { app.status.endMonitoring() }
    }

}

/// One sidebar row: a colored squircle and the pane name.
struct SettingsSidebarLabel: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(symbol: pane.symbol, color: pane.color)
        }
    }
}

/// The detail column for a pane.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .apps: AppsPane()
        case .learning: LearningPane()
        case .about: AboutPane()
        }
    }
}

private extension Binding {
    /// `List(selection:)` wants an optional; a deselect keeps the current pane.
    init(keepingSelection source: Binding<SettingsPane>) where Value == SettingsPane? {
        self.init(get: { source.wrappedValue }, set: { if let pane = $0 { source.wrappedValue = pane } })
    }
}
