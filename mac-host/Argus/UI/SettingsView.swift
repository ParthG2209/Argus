//
//  SettingsView.swift
//  Argus
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private let resolutions = ["2732x2048", "2560x1600", "1920x1200"]
    private let codecs = ["H.264", "H.265"]   // H.265 reserved for Phase 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Argus Settings").font(.title2).bold()

            Form {
                Picker("Resolution", selection: $state.resolutionPreset) {
                    ForEach(resolutions, id: \.self) { Text($0) }
                }

                VStack(alignment: .leading) {
                    Text(String(format: "Bitrate: %.0f Mbps", state.bitrateSetting))
                    Slider(value: Binding(
                        get: { state.bitrateSetting },
                        set: { state.coordinator?.applyBitrate($0) }
                    ), in: 5...50, step: 1)
                }

                Picker("Codec", selection: $state.codec) {
                    ForEach(codecs, id: \.self) {
                        Text($0 + ($0 == "H.265" ? " (Phase 2)" : ""))
                    }
                }
                .disabled(true) // H.264 only in Phase 1

                Toggle("Enable stylus pressure", isOn: $state.enablePressure)
                Toggle("Enable stylus tilt", isOn: $state.enableTilt)
                Toggle("Enable hover tracking", isOn: $state.enableHover)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
