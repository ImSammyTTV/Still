import SwiftUI
import StillCore

struct HistoryView: View {
    @ObservedObject var library: Library
    let dismiss: () -> Void
    @State private var filter = "All"
    @State private var selected: UUID?
    @State private var query = ""
    @State private var pendingDelete: CaptureItem?
    @State private var renaming: CaptureItem?
    @State private var title = ""
    private var items: [CaptureItem] { library.items.filter { (filter == "All" || (filter == "Screenshots" && !$0.isVideo) || (filter == "Videos" && $0.isVideo && !$0.filename.hasSuffix("gif")) || (filter == "GIFs" && $0.filename.hasSuffix("gif"))) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.recognizedText?.localizedCaseInsensitiveContains(query) ?? false) || ($0.tags?.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ?? false)) } }
    private var current: CaptureItem? { items.first(where: { $0.id == selected }) ?? items.first }
    var body: some View {
        VStack(spacing: 25) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close capture history")
                Spacer()
                ForEach(["All", "Screenshots", "Videos", "GIFs"], id: \.self) { title in Button { filter = title; selected = nil } label: { Text(title).font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 7).background(filter == title ? Color.accentColor : Color.white.opacity(0.12), in: Capsule()) }.buttonStyle(.plain) }
                Spacer()
            }
            if items.isEmpty {
                VStack(spacing: 15) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 38, weight: .light)); Text(query.isEmpty ? "No captures yet" : "No matching captures").font(.system(size: 18)); Text("Take a screenshot to see it in your capture history.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 22) {
                            ForEach(items) { item in
                                Button { selected = item.id } label: {
                                    VStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.07))
                                            if let image = library.thumbnail(item) { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18)).padding(3) }
                                            if item.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 35)).shadow(radius: 5) }
                                        }.frame(width: 250, height: 190).overlay(RoundedRectangle(cornerRadius: 20).stroke(current?.id == item.id ? Color.accentColor : .clear, lineWidth: 4))
                                        Text(item.title).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 245)
                                    }
                                }.buttonStyle(.plain).id(item.id).simultaneousGesture(TapGesture(count: 2).onEnded { AppController.shared.openItem(item); dismiss() })
                                .contextMenu { Button("Restore") { AppController.shared.showPreview(item); dismiss() }; Button(item.isVideo ? "Open Video Editor" : "Annotate") { AppController.shared.openItem(item); dismiss() }; Button("Copy") { library.copy(item) }; Button("Rename…") { title = item.title; renaming = item }; Button("Upload to Cloud") { AppController.shared.upload(item) }; if let link = item.cloudURL { Button("Copy Cloud Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) } }; Button("Save As…") { library.export(item) }; Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(item)]) }; Divider(); Button("Move to Trash", role: .destructive) { pendingDelete = item } }
                                .onDrag { NSItemProvider(contentsOf: library.url(item)) ?? NSItemProvider() }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }.scrollIndicators(.hidden)
                    .onChange(of: selected) { _, value in if let value { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) } } }
                }
                HStack { Spacer(); Button { if let current { AppController.shared.showPreview(current); dismiss() } } label: { Label("Restore", systemImage: "return.left").font(.system(size: 16, weight: .semibold)) }.buttonStyle(.borderedProminent).clipShape(Capsule()).keyboardShortcut(.defaultAction); Spacer() }
            }
            HStack { TextField("Search captures", text: $query).textFieldStyle(.roundedBorder).frame(width: 220); Spacer(); Text("\(items.count) captures").foregroundStyle(.secondary).font(.system(size: 11)); if let current { Text(current.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).font(.system(size: 11)) } }
        }.padding(28).frame(width: 880, height: 430).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12))).environment(\.colorScheme, .dark)
        .focusable().onMoveCommand { direction in guard let current, let index = items.firstIndex(where: { $0.id == current.id }) else { return }; if direction == .left { selected = items[max(0, index-1)].id }; if direction == .right { selected = items[min(items.count-1, index+1)].id } }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            VStack(alignment: .leading, spacing: 18) { Text("Rename Capture").font(.headline); TextField("Name", text: $title).textFieldStyle(.roundedBorder); HStack { Spacer(); Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction); Button("Rename") { if let renaming { library.rename(renaming, title: title.trimmingCharacters(in: .whitespacesAndNewlines)) }; renaming = nil }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(24).frame(width: 330)
        }
        .confirmationDialog("Move this capture to Trash?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) { Button("Move to Trash", role: .destructive) { if let pendingDelete { library.delete(pendingDelete) }; pendingDelete = nil } }
    }
}
