//
//  SettingsView.swift
//  Argus
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var state: AppState

    private let codecs = ["H.264", "H.265"]   // H.265 reserved for Phase 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Argus Settings").font(.title2).bold()

            Form {
                Picker("Display scaling", selection: Binding(
                    get: { state.scalingPreset },
                    set: { state.coordinator?.applyScaling($0) }
                )) {
                    ForEach(ArgusDisplaySpec.scalingPresets) { preset in
                        Text("\(preset.name)  (looks like "
                             + "\(preset.looksLike(forNativeWidth: state.tabletWidth, height: state.tabletHeight)))")
                            .tag(preset.name)
                    }
                }
                Text("Rendered at the tablet's native \(state.tabletWidth)×\(state.tabletHeight) and scaled. "
                     + "\u{201C}Default\u{201D} is sharpest; \u{201C}More Space\u{201D} fits more on screen.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading) {
                    Text(String(format: "Bitrate: %.0f Mbps", state.bitrateSetting))
                    Slider(value: Binding(
                        get: { state.bitrateSetting },
                        set: { state.coordinator?.applyBitrate($0) }
                    ), in: 5...50, step: 1)
                }

                Picker("Frame rate", selection: Binding(
                    get: { state.targetFPS },
                    set: { state.coordinator?.applyTargetFPS($0) }
                )) {
                    Text("Auto (\(state.tabletRefresh) Hz)").tag(0)
                    Text("144 fps").tag(144)
                    Text("120 fps").tag(120)
                    Text("90 fps").tag(90)
                    Text("60 fps").tag(60)
                }
                Text("Auto targets the tablet's detected native refresh rate. "
                     + "If you pick a specific rate (like 90 fps), make sure your tablet's physical display "
                     + "supports it to prevent judder. Long-press the Android HUD to cycle its physical refresh rate!")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Codec", selection: Binding(
                    get: { state.codec },
                    set: { state.coordinator?.applyCodec($0) }
                )) {
                    ForEach(codecs, id: \.self) { Text($0) }
                }
                Text("H.265 (HEVC) uses ~40% less bandwidth for the same quality. "
                     + "Changing codec reconnects the stream.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Enable stylus pressure", isOn: $state.enablePressure)
                Toggle("Enable stylus tilt", isOn: $state.enableTilt)
                Toggle("Enable hover tracking", isOn: $state.enableHover)
            }

            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
