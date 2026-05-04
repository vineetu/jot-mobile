import SwiftUI
import WidgetKit

/// Entry point for the `JotWidget` app extension (see `project.yml`).
///
/// `WidgetBundle` is how a widget extension declares what it ships. For now
/// we only ship the Live Activity — if we later add a home-screen or lock
/// screen widget, list it here too.
@main
struct JotWidgetBundle: WidgetBundle {
    var body: some Widget {
        JotLiveActivity()
    }
}
