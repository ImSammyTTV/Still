import SwiftUI
import StillCore

/// Screen Recording settings: add and remove your own bitrates, which then appear under Quality.
struct BitratePresetEditor: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var name = ""
    @State private var megabits = 12.0
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var candidate: BitratePreset { BitratePreset(name: trimmed, megabits: megabits) }
    private var canAdd: Bool { !trimmed.isEmpty && BitratePreset.megabitRange.contains(megabits) && !prefs.bitratePresets.contains { $0.tag == candidate.tag } }
    var body: some View {
        ForEach(prefs.bitratePresets) { preset in
            HStack {
                Text(preset.name)
                Spacer()
                Text(BitratePreset.label(preset.bitrate)).foregroundStyle(.secondary)
                Button { remove(preset) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Remove \(preset.name) preset")
            }
        }
        HStack {
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder).onSubmit(add)
            TextField("Bitrate", value: $megabits, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64).accessibilityLabel("Bitrate in megabits per second").onSubmit(add)
            Text("Mbps").foregroundStyle(.secondary)
            Button("Add Preset", action: add).disabled(!canAdd)
        }
        Text("Presets appear under Quality and in the Video Editor, from 1 to 100 Mbps. They set the bitrate of the finished MP4; a higher bitrate means a larger file.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func add() {
        guard canAdd else { return }
        prefs.bitratePresets.append(candidate); name = ""
    }
    private func remove(_ preset: BitratePreset) {
        prefs.bitratePresets.removeAll { $0.id == preset.id }
        if prefs.recordingQuality == preset.tag { prefs.recordingQuality = "high" }
    }
}
