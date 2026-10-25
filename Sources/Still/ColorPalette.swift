import SwiftUI
import StillCore

@MainActor final class ColorPalette: ObservableObject {
    static let shared = ColorPalette()
    @Published private(set) var colors: [String]
    init() { colors = (UserDefaults.standard.stringArray(forKey: "annotationPalette") ?? ["FF414E", "FF9C30", "F8CE46", "41CD52", "1687FF", "9C55E8", "FFFFFF", "141414"]).filter { $0.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil } }
    func add(_ value: String) { let hex = value.uppercased(); guard !colors.contains(hex), hex.range(of: "^[0-9A-F]{6}$", options: .regularExpression) != nil else { return }; colors.append(hex); if colors.count > 32 { colors.removeFirst() }; save() }
    func remove(_ value: String) { colors.removeAll { $0 == value }; save() }
    private func save() { UserDefaults.standard.set(colors, forKey: "annotationPalette") }
}
struct PaletteEditor: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var palette = ColorPalette.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Color Palette").font(.headline); Spacer(); Button("Done") { model.activeSheet = nil }.keyboardShortcut(.defaultAction) }
            ColorPicker("Current Color", selection: hexColor(Binding(get: { model.color }, set: { model.setColor($0) })), supportsOpacity: false)
            HStack { Button("Save Current Color") { palette.add(model.color) }; Spacer(); Button("Pick from Screen…") { model.pickScreenColor() } }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 8), spacing: 12) {
                ForEach(palette.colors, id: \.self) { hex in
                    Button { model.setColor(hex) } label: { Circle().fill(Color(hex: hex)).frame(width: 30, height: 30).overlay(Circle().stroke(Color.primary.opacity(0.2))).overlay { if model.color == hex { Image(systemName: "checkmark").foregroundStyle(hex == "141414" ? .white : .black) } } }.buttonStyle(.plain).help("#\(hex)").accessibilityLabel("Choose color \(hex)").contextMenu { Button("Remove from Palette") { palette.remove(hex) } }
                }
            }
            Text("Right-click a color to remove it. Saved colors are available in every editor window.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 440)
    }
}
