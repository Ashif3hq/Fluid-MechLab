import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.workspace) {
                ForEach(Workspace.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.systemImage)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch state.workspace ?? .nodal {
            case .nodal: NodalView()
            case .damage: FormationDamageView()
            case .pvt: PVTView()
            }
        }
        .navigationTitle((state.workspace ?? .nodal).rawValue)
        .navigationSubtitle((state.workspace ?? .nodal).subtitle)
    }
}
