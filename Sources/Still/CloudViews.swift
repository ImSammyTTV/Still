import SwiftUI
import StillCore

struct CloudSettingsView: View {
    @ObservedObject var library: Library
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var local = LocalCloudServer.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var status = ""
    @State private var testing = false
    @State private var driveBusy = false
    @State private var driveConnected = GoogleDrive.refreshToken != nil
    @State private var driveStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("Upload To") {
                HStack { Text("Destination"); Spacer(); Picker("Destination", selection: $prefs.cloudProvider) { Text("Still Cloud").tag("still"); Text("Google Drive").tag("drive") }.labelsHidden().fixedSize() }
                if GoogleDrive.available {
                    HStack {
                        Text(driveConnected ? "Google Drive: \(prefs.driveEmail)" : "Google Drive"); Spacer()
                        Button(driveBusy ? "Waiting for your browser…" : driveConnected ? "Disconnect" : "Connect") { toggleDrive() }.disabled(driveBusy)
                    }
                    if driveConnected { HStack { Text("Who can open Drive links"); Spacer(); Picker("Who can open Drive links", selection: $prefs.driveAccess) { Text("Anyone with the link").tag("link"); Text("Only me").tag("private") }.labelsHidden().fixedSize() } }
                    Text("Files go into a Still folder in your Drive. Still can only see files it put there.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("Google Drive isn’t available in this build.").font(.system(size: 10)).foregroundStyle(.secondary) }
                if !driveStatus.isEmpty { Text(driveStatus).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            card("Account") {
                TextField("Server URL", text: $endpoint, prompt: Text("https://captures.example.com")).textFieldStyle(.roundedBorder).accessibilityLabel("Cloud server URL")
                SecureField("Personal Access Token", text: $token, prompt: Text("Stored securely in Keychain")).textFieldStyle(.roundedBorder)
                HStack { Button(testing ? "Connecting…" : "Save & Test Connection") { connect() }.disabled(testing || endpoint.isEmpty); Spacer(); Button("Open Cloud") { if let url = URL(string: prefs.cloudEndpoint), !prefs.cloudEndpoint.isEmpty { NSWorkspace.shared.open(url) } }.disabled(prefs.cloudEndpoint.isEmpty) }
                if !status.isEmpty { Text(status).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Button("Copy Saved Token") { if let secret = CloudKeychain.token(for: prefs.cloudEndpoint) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(secret, forType: .string); NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); library.toast("Personal token copied") } }.buttonStyle(.link).font(.system(size: 10)).disabled(prefs.cloudEndpoint.isEmpty)
            }
            card("Upload") {
                Toggle("Ask for name & show advanced options", isOn: $prefs.askUploadOptions)
                HStack { Text("Default link expiration"); Spacer(); Picker("Default link expiration", selection: $prefs.cloudExpiry) { Text("Never").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }.labelsHidden().fixedSize() }
                Text("Use Option while clicking Upload to set a password, access level, tags or view limit for a capture. Uploads include any text Still recognised in the capture and a recording’s transcript, so your server can search them.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card("Local Server") {
                Text("Run an independent server on this Mac for testing. Local links work on this Mac while Still is running. Use your own hosted server for links other people can open.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Button(local.starting ? "Starting…" : local.running ? "Stop Local Server" : "Start Local Server") { if local.running { local.stop() } else { local.start() } }.disabled(local.starting); Spacer(); Button("Open Hosting Instructions") { if let url = Bundle.main.resourceURL?.appendingPathComponent("Cloud/README.md") { NSWorkspace.shared.open(url) } } }
                if let message = local.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.onAppear { endpoint = prefs.cloudEndpoint }.onChange(of: prefs.cloudEndpoint) { _, value in endpoint = value }.toggleStyle(PreferenceToggleStyle()).controlSize(.small)
    }
    private func toggleDrive() {
        driveBusy = true; driveStatus = ""
        Task {
            if driveConnected {
                await GoogleDrive.disconnect()
                prefs.cloudProvider = "still"; prefs.driveEmail = ""; prefs.driveFolder = ""; driveConnected = false
            } else {
                do { prefs.driveEmail = try await GoogleDrive.connect(); prefs.cloudProvider = "drive"; driveConnected = true }
                catch { driveStatus = error.localizedDescription }
            }
            driveBusy = false
        }
    }
    private func connect() {
        testing = true; status = ""
        Task {
            do { let client = try CloudClient(endpoint: endpoint, token: token.isEmpty ? nil : token); let name = try await client.test(); if !token.isEmpty { try CloudKeychain.save(token, endpoint: client.endpoint.absoluteString) }; prefs.cloudEndpoint = client.endpoint.absoluteString; token = ""; status = "Connected as \(name)." }
            catch { status = error.localizedDescription }
            testing = false
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 11, weight: .semibold)); VStack(alignment: .leading, spacing: 13, content: content).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) } }
}

@MainActor final class CloudUploadModel: ObservableObject {
    let file: URL
    let item: CaptureItem?
    let library: Library
    let temporary: Bool
    @Published var title: String
    @Published var tags = ""
    @Published var password = ""
    @Published var expiry = Preferences.shared.cloudExpiry
    @Published var visibility = "link"
    @Published var views = "0"
    @Published var uploading = false
    @Published var progress: Double = 0
    @Published var error: String?
    var completed: (() -> Void)?
    var usesDrive: Bool { Preferences.shared.cloudProvider == "drive" }
    private var task: Task<Void, Never>?
    init(file: URL, item: CaptureItem?, library: Library, title: String, temporary: Bool = false) { self.file = file; self.item = item; self.library = library; self.title = title; self.temporary = temporary }
    func upload() {
        guard !uploading else { return }; uploading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if usesDrive {
                    let prefs = Preferences.shared
                    let result = try await GoogleDrive.upload(file, title: title, public: prefs.driveAccess == "link", folder: prefs.driveFolder, progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
                    prefs.driveFolder = result.folder
                    if let item { library.setCloudURL(item, url: result.link) }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.link.absoluteString, forType: .string); library.toast("Uploaded to Google Drive. Link copied to clipboard.")
                    if temporary { try? FileManager.default.removeItem(at: file) }; uploading = false; completed?(); return
                }
                let client = try CloudClient(endpoint: Preferences.shared.cloudEndpoint)
                var options = CloudOptions(title: title); options.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; options.expiryDays = expiry; options.password = password; options.visibility = visibility; options.maxViews = max(0, Int(views) ?? 0)
                if let item { options.ocr = item.recognizedText ?? ""; let metadata = library.recordingMetadata(item); options.transcript = metadata.transcript ?? ""; options.captions = metadata.captions ?? "" }
                let url = try await client.upload(file, options: options, progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
                if let item { library.setCloudURL(item, url: url) }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); library.toast("Uploaded. Link copied to clipboard.")
                if temporary { try? FileManager.default.removeItem(at: file) }; uploading = false; completed?()
            } catch is CancellationError { if temporary { try? FileManager.default.removeItem(at: file) }; uploading = false; completed?() }
            catch {
                uploading = false
                if Task.isCancelled { if temporary { try? FileManager.default.removeItem(at: file) }; completed?() }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { task?.cancel(); if !uploading { if temporary { try? FileManager.default.removeItem(at: file) }; completed?() } }
}
struct CloudUploadView: View {
    @ObservedObject var model: CloudUploadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(model.uploading ? "Uploading…" : model.usesDrive ? "Upload to Google Drive" : "Upload to Cloud").font(.system(size: 17, weight: .semibold))
            if model.uploading {
                ProgressView(value: model.progress).frame(width: 340); Text("\(Int(model.progress*100))%").monospacedDigit().foregroundStyle(.secondary)
                HStack { Spacer(); Button("Cancel Upload") { model.cancel() } }
            } else {
                Form {
                    TextField("Name", text: $model.title)
                    if !model.usesDrive {
                    TextField("Tags", text: $model.tags, prompt: Text("Design, feedback…"))
                    Picker("Access", selection: $model.visibility) { Text("Anyone with the link").tag("link"); Text("Team members").tag("team"); Text("Only you").tag("private") }
                    Picker("Expires", selection: $model.expiry) { Text("Never").tag(0); Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
                    SecureField("Password", text: $model.password)
                    TextField("View limit", text: $model.views)
                    Text("Set the view limit to 0 for unlimited views.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.frame(width: 370)
                if let error = model.error { Text(error).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                HStack { Spacer(); Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction); Button("Upload & Copy Link") { model.upload() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }.font(.system(size: 12)).padding(25)
    }
}
