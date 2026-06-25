import SwiftUI
import WidgetKit

/// WidgetKit bundle for the Jot Watch app. Provides:
/// - **Complication** (`corner`, `circular`, `inline`): mic glyph that
///   deep-links to `jot-watch://record` when tapped. One-tap launch
///   into recording from any watch face.
/// - **Smart Stack tile** (`accessoryRectangular`): larger "Capture a
///   thought" affordance with the same deep-link.
///
/// **Relevance (v1):** static 0.5 — always-on, not pinned, not
/// escalated. History-based escalation (clustering on user's actual
/// capture times) is deferred to v1.1.
@main
struct JotWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JotCaptureComplication()
        JotCaptureSmartStackTile()
    }
}

// MARK: - Provider (shared by both widgets)

struct JotCaptureEntry: TimelineEntry {
    let date: Date
}

struct JotCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> JotCaptureEntry {
        JotCaptureEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (JotCaptureEntry) -> Void) {
        completion(JotCaptureEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JotCaptureEntry>) -> Void) {
        // Single-entry timeline — the widget is stateless ("tap to record").
        // Reload every 6 hours just to keep the system happy.
        let entries = [JotCaptureEntry(date: Date())]
        let next = Date().addingTimeInterval(6 * 60 * 60)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - Complication (corner / circular / inline)

struct JotCaptureComplication: Widget {
    let kind = "JotCaptureComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JotCaptureProvider()) { _ in
            JotCaptureComplicationView()
        }
        .configurationDisplayName("Capture")
        .description("Tap to start recording in Jot.")
        .supportedFamilies(Self.captureFamilies)
    }

    // `.accessoryCorner` is a watchOS-only widget family — exclude it on non-watch
    // builds so this file compiles when the Jot scheme is built for the iOS
    // Simulator (used for verification). watchOS behavior is unchanged.
    static var captureFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCorner, .accessoryCircular, .accessoryInline]
        #else
        [.accessoryCircular, .accessoryInline]
        #endif
    }
}

struct JotCaptureComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Jot", systemImage: "mic.fill")
                .widgetURL(URL(string: "jot-watch://record"))
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(JotDesignWatchSafe.jotAccent)
            }
            .widgetURL(URL(string: "jot-watch://record"))
        #if os(watchOS)
        case .accessoryCorner:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(JotDesignWatchSafe.jotAccent)
            }
            .widgetURL(URL(string: "jot-watch://record"))
        #endif
        default:
            Image(systemName: "mic.fill")
                .widgetURL(URL(string: "jot-watch://record"))
        }
    }
}

// MARK: - Smart Stack tile (rectangular)

struct JotCaptureSmartStackTile: Widget {
    let kind = "JotCaptureSmartStackTile"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JotCaptureProvider()) { _ in
            JotCaptureSmartStackView()
        }
        .configurationDisplayName("Jot — Capture")
        .description("Tap to record a thought in Jot.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct JotCaptureSmartStackView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(JotDesignWatchSafe.jotAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture a thought")
                        .font(.caption.weight(.semibold))
                    Text("Tap to record")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .widgetURL(URL(string: "jot-watch://record"))
    }
}
