import SwiftData
import SwiftUI

@main
struct VerdantApp: App {
    @State private var model: AppModel
    private let container: ModelContainer

    init() {
        let container: ModelContainer
        var ephemeral = false
        do {
            container = try AppContainer.makeContainer()
        } catch {
            // Last resort: an in-memory store keeps the app usable for the session. Recorded rather
            // than swallowed — the substitution is fine in the foreground and harmful in the
            // background, and only `AppModel.storeIsEphemeral` can tell the difference downstream.
            ephemeral = true
            do {
                container = try AppContainer.makeContainer(inMemory: true)
            } catch {
                fatalError("Unable to create a model container: \(error)")
            }
        }
        self.container = container

        let model = AppModel(container: container, storeIsEphemeral: ephemeral)
        // BGTaskScheduler handlers must be registered before launch completes.
        model.registerBackgroundHandlers()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .modelContainer(container)
    }
}
