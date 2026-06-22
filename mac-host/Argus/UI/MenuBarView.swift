//
//  MenuBarView.swift
//  Argus
//

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @State private var showSettings = false

    private var statusColor: Color {
        switch state.status {
        case .disconnected: return .secondary
        case .connected:    return .orange
        case .streaming:    return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text("Argus").font(.headline)
                Spacer()
                Text(state.status.rawValue)
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Divider()

            if !state.adbAvailable {
                Label("adb not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Install: brew install android-platform-tools")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("FPS").foregroundStyle(.secondary)
                    Text("\(state.fps)")
                }
                GridRow {
                    Text("Bitrate").foregroundStyle(.secondary)
                    Text(String(format: "%.0f Mbps", state.bitrateSetting))
                }
                GridRow {
                    Text("Input").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(state.inputMode.rawValue)
                        if state.inputMode == .stylus || state.inputMode == .eraser {
                            Text(String(format: "p=%.2f", state.stylusPressure))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))

            if let err = state.lastError {
                Divider()
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                if state.status == .disconnected {
                    Button("Connect") { state.coordinator?.connect() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Disconnect") { state.coordinator?.disconnect() }
                }
                Button("Settings") { showSettings = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
        .sheet(isPresented: $showSettings) {
            SettingsView(state: state)
        }
    }
}
