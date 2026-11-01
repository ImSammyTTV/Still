import SwiftUI
import StillCore

struct HistoryView: View {
    @ObservedObject var library: Library
    let dismiss: () -> Void
    @State private var filter = "All"
    @State private var selected: UUID?
    /// Screenshots picked with ⌘-click (or ⇧-click) to combine, in the order they were picked.
    @State private var picks: [UUID] = []
    private func togglePick(_ item: CaptureItem) {
        if item.isVideo { library.toast("Only screenshots can be combined"); return }
        if let index = picks.firstIndex(of: item.id) { picks.remove(at: index) } else { picks.append(item.id) }
    }
    private func combine(vertical: Bool) {
        let chosen = picks.compactMap { id in library.items.first { $0.id == id } }
        picks = []; AppController.shared.combine(chosen, vertical: vertical); dismiss()
    }
    @State private var query = ""
    @State private var pendingDelete: CaptureItem?
    @State private var renaming: CaptureItem?
    @State private var title = ""
    private var items: [CaptureItem] { library.items.filter { (filter == "All" || (filter == "Starred" && $0.isStarred) || (filter == "Screenshots" && !$0.isVideo) || (filter == "Videos" && $0.isVideo && !$0.filename.hasSuffix("gif")) || (filter == "GIFs" && $0.filename.hasSuffix("gif"))) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.recognizedText?.localizedCaseInsensitiveContains(query) ?? false) || ($0.tags?.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ?? false)) } }
    var body: some View {
        // Filtered once here: every grid cell asks for `current`, and a search looks through recognized text.
        let items = self.items, current = items.first(where: { $0.id == selected }) ?? items.first
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close capture history")
                Text("The collection").font(Studio.heading)
                Spacer()
                ForEach(["All", "Screenshots", "Videos", "GIFs", "Starred"], id: \.self) { title in Button { filter = title; selected = nil } label: { Text(title).font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 7).background(filter == title ? Color.accentColor : Color.white.opacity(0.12), in: Capsule()) }.buttonStyle(.plain) }
                Spacer()
            }
            if items.isEmpty {
                VStack(spacing: 15) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 38, weight: .light)); Text(!query.isEmpty ? "No matching captures" : filter == "Starred" ? "No starred captures" : "No captures yet").font(.system(size: 18)); Text(filter == "Starred" ? "Right-click a capture and choose Star to find it here." : "Take a screenshot to see it in your capture history.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245))], spacing: 22) {
                            ForEach(items) { item in
                                Button { if !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { togglePick(item) } else { selected = item.id } } label: {
                                    VStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.07))
                                            if let image = library.thumbnail(item) { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(3) }
                                            else if !FileManager.default.fileExists(atPath: library.url(item).path) { Text("File moved or deleted").font(.system(size: 12)).foregroundStyle(.secondary) }
                                            if item.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 35)).shadow(radius: 5) }
                                            if item.isStarred {
                                                Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(.yellow).padding(6).background(.black.opacity(0.55), in: Circle())
                                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10).accessibilityLabel("Starred")
                                            }
                                            if let n = picks.firstIndex(of: item.id) {
                                                Text("\(n + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(minWidth: 24, minHeight: 24).background(Color.accentColor, in: Capsule())
                                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10).accessibilityLabel("Picked \(n + 1) to combine")
                                            }
                                        }.frame(width: 250, height: 190).overlay(RoundedRectangle(cornerRadius: 4).stroke(current?.id == item.id || picks.contains(item.id) ? Color.accentColor : .clear, lineWidth: 4))
                                        Text(item.title).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 245)
                                    }
                                }.buttonStyle(.plain).id(item.id).simultaneousGesture(TapGesture(count: 2).onEnded { AppController.shared.openItem(item); dismiss() })
                                .contextMenu { Button("Restore") { AppController.shared.showPreview(item); dismiss() }; Button(item.isVideo ? "Open Video Editor" : "Annotate") { AppController.shared.openItem(item); dismiss() }; Button(item.isStarred ? "Unstar" : "Star") { library.setStarred(item, !item.isStarred) }; Button("Copy") { library.copy(item) }; Button("Rename…") { title = item.title; renaming = item }; Button("Upload to Cloud") { AppController.shared.upload(item) }; if let link = item.cloudURL { Button("Copy Cloud Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }; Button("Show QR Code") { QRCodePanel.show(link) } }; if !item.isVideo { if picks.count >= 2 && picks.contains(item.id) { Button("Combine \(picks.count) Side by Side") { combine(vertical: false) }; Button("Combine \(picks.count) Top to Bottom") { combine(vertical: true) } } else { Button(picks.contains(item.id) ? "Remove from Combine" : "Select to Combine") { togglePick(item) } } }; Button("Save As…") { library.export(item) }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(item)]) }; Divider(); Button("Move to Trash", role: .destructive) { pendingDelete = item } }
                                .onDrag { NSItemProvider(contentsOf: library.url(item)) ?? NSItemProvider() }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }.scrollIndicators(.hidden)
                    .onChange(of: selected) { _, value in if let value { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) } } }
                }
                if !picks.isEmpty {
                    HStack(spacing: 10) {
                        Spacer()
                        Text(picks.count == 1 ? "1 screenshot · ⌘-click one more" : "\(picks.count) screenshots").foregroundStyle(.secondary)
                        Button { combine(vertical: false) } label: { Label("Side by Side", systemImage: "rectangle.split.2x1") }.disabled(picks.count < 2)
                        Button { combine(vertical: true) } label: { Label("Top to Bottom", systemImage: "rectangle.split.1x2") }.disabled(picks.count < 2)
                        Button("Clear") { picks = [] }
                        Spacer()
                    }.controlSize(.large)
                }
                HStack { Spacer(); Button { if let current { AppController.shared.showPreview(current); dismiss() } } label: { Label("Restore", systemImage: "return.left").font(.system(size: 16, weight: .semibold)) }.buttonStyle(.borderedProminent).clipShape(Capsule()).keyboardShortcut(.defaultAction); Spacer() }
            }
            HStack { TextField("Search captures", text: $query).textFieldStyle(.roundedBorder).frame(width: 220); Spacer(); Text("\(items.count) captures").foregroundStyle(.secondary).font(.system(size: 11)); if let current { Text(current.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).font(.system(size: 11)) } }
        }.padding(28).frame(width: 880, height: 580).background(Studio.paper).tint(Studio.accent)
        .focusable().onMoveCommand { direction in guard let current, let index = items.firstIndex(where: { $0.id == current.id }) else { return }; if direction == .left { selected = items[max(0, index-1)].id }; if direction == .right { selected = items[min(items.count-1, index+1)].id } }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 18) { Text("Rename Capture").font(.headline); TextField("Name", text: $title).textFieldStyle(.roundedBorder); HStack { Spacer(); Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction); Button("Rename") { if let renaming { library.rename(renaming, title: title.trimmingCharacters(in: .whitespacesAndNewlines)) }; renaming = nil }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 330)
        }
        .confirmationDialog("Move this capture to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) { Button("Move to Trash", role: .destructive) { if let pendingDelete { library.delete(pendingDelete) }; pendingDelete = nil } }
    }
}
