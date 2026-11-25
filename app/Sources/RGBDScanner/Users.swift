import SwiftUI

// Where recordings upload: a receiver's server, by the name server/users.json gives it, and the data root, the absolute path of the directory on that server's machine that the receiver stores them in. The app shows and saves the server's name only; its address is known to the build alone.
struct UploadDestination: Codable, Hashable {
    var server: String
    var dataRoot: String
}

// Where a recording goes: kept on this phone, never uploaded; taken by a computer it is plugged into by cable (server/pull.ps1), its segments while it records and the rest once it is finished, into the folder path on that computer, nil for that computer's Downloads folder, and deleted from the phone once that computer has stored it; or uploaded to a destination while it records and deleted from the phone once the receiver has stored it.
enum RecordingTarget: Codable, Hashable {
    case phone
    case wired(path: String?)
    case upload(destination: UploadDestination)

    private enum CodingKeys: String, CodingKey { case phone, wired, upload }
    private enum WiredCodingKeys: String, CodingKey { case path }
    private enum UploadCodingKeys: String, CodingKey { case destination }

    // 1.5.0.3 and 1.5.1 saved an upload by its server alone, which no receiver from 1.5.2 takes without a data root: such a recording stays on this phone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.phone) {
            self = .phone
            return
        }
        if container.contains(.wired) {
            self = .wired(path: try container.nestedContainer(keyedBy: WiredCodingKeys.self, forKey: .wired).decodeIfPresent(String.self, forKey: .path))
            return
        }
        let upload = try container.nestedContainer(keyedBy: UploadCodingKeys.self, forKey: .upload)
        self = try upload.decodeIfPresent(UploadDestination.self, forKey: .destination).map { .upload(destination: $0) } ?? .phone
    }
}

// A recording a receiver holds in a data root, as GET /recordings lists it; the fields from its scan_metadata.json are nil for a tar without one.
struct ServerRecording: Decodable, Identifiable {
    let scanId: String
    let size: Int64
    let name: String?
    let startTimeUtc: Date?
    let durationS: Double?
    let camera: String?
    let author: String?
    var id: String { scanId }
}

// server/users.json as the build embedded it: {"servers": {"<name>": "http://host:port", ...}, "users": [{"name", "configs": [{"server": "<name>", "data_root"}, ...]}, ...]}.
enum UsersFile {
    private struct File: Decodable {
        let servers: [String: String]
        let users: [User]

        struct User: Decodable {
            let name: String
            let configs: [UploadDestination]
        }
    }

    private static let file: File = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file: File
        do {
            file = try decoder.decode(File.self, from: Data(Secrets.users.utf8))
        } catch {
            preconditionFailure("server/users.json does not decode: \(error)")
        }
        for user in file.users {
            for config in user.configs where file.servers[config.server] == nil { preconditionFailure("server/users.json gives \(user.name) a config on \(config.server), which it names no address for") }
        }
        return file
    }()

    static var serverNames: [String] { file.servers.keys.sorted() }
    static var users: [(name: String, configs: [UploadDestination])] { file.users.map { ($0.name, $0.configs) } }

    // The address, http://host:port, of the server so named; nil for a name server/users.json does not give.
    static func address(of server: String) -> String? { file.servers[server] }
}

// A user: a name grouping its configs; there is no sign-in.
struct ScannerUser: Identifiable {
    let name: String
    // Keeping recordings on this phone, then wired transfer, into the folder the user set, then uploading to those server/users.json gives it, and to those added on this phone, which can be removed.
    let configs: [RecordingTarget]
    let added: [UploadDestination]
    var id: String { name }
}

// The users with their configs: server/users.json's, and those added on this phone and each user's wired transfer folder, saved in UserDefaults.
final class UserStore: ObservableObject {
    // By user.
    @Published private var added: [String: [UploadDestination]]
    // By user; a user with none has the computer's Downloads folder.
    @Published private var wiredPaths: [String: String]
    private static let key = "addedConfigs"
    private static let wiredPathsKey = "wiredPaths"

    init() {
        added = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: [UploadDestination]].self, from: $0) } ?? [:]
        wiredPaths = UserDefaults.standard.dictionary(forKey: Self.wiredPathsKey) as? [String: String] ?? [:]
    }

    var users: [ScannerUser] { UsersFile.users.map { ScannerUser(name: $0.name, configs: [.phone, .wired(path: wiredPaths[$0.name])] + $0.configs.map { .upload(destination: $0) }, added: added[$0.name] ?? []) } }

    // The folder on the computer the user's wired transfer recordings go to; nil for the computer's Downloads folder.
    func wiredPath(of user: String) -> String? { wiredPaths[user] }

    func setWiredPath(_ path: String?, of user: String) {
        wiredPaths[user] = path
        UserDefaults.standard.set(wiredPaths, forKey: Self.wiredPathsKey)
    }

    func add(_ config: UploadDestination, to user: String) {
        added[user, default: []].append(config)
        save()
    }

    func remove(at offsets: IndexSet, from user: String) {
        added[user]?.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(added), forKey: Self.key)
    }
}

// The page the app opens on: each user with its configs; choosing a config opens the scanner, whose recordings then upload there.
struct ConfigSelectionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: UserStore
    // The user a config is being added to.
    @State private var addingTo: String?
    // The user whose wired transfer folder is being changed.
    @State private var changingFolderOf: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.users) { user in
                    Section(user.name) {
                        // Two configs of one user may be equal, so they are told apart by position.
                        ForEach(Array(user.configs.enumerated()), id: \.offset) { _, config in
                            HStack {
                                Button { model.select(user: user.name, target: config) } label: { TargetLabel(target: config) }
                                if case .wired = config {
                                    Spacer()
                                    Button("Folder") { changingFolderOf = user.name }
                                }
                            }
                            // Two buttons in one row each take their own taps.
                            .buttonStyle(.borderless)
                        }
                        ForEach(Array(user.added.enumerated()), id: \.offset) { _, config in
                            Button { model.select(user: user.name, target: .upload(destination: config)) } label: { TargetLabel(target: .upload(destination: config)) }
                        }
                        .onDelete { store.remove(at: $0, from: user.name) }
                        Button("Add config") { addingTo = user.name }
                    }
                }
            }
            .navigationTitle("Choose a config")
            .sheet(isPresented: Binding(get: { addingTo != nil }, set: { if !$0 { addingTo = nil } })) {
                if let user = addingTo { AddConfigView(user: user) { store.add($0, to: user) } }
            }
            .sheet(isPresented: Binding(get: { changingFolderOf != nil }, set: { if !$0 { changingFolderOf = nil } })) {
                if let user = changingFolderOf { WiredFolderView(user: user, path: store.wiredPath(of: user) ?? "") { store.setWiredPath($0, of: user) } }
            }
        }
    }
}

// A new config for a user: one of the build's servers, by name, and a data root on its machine.
struct AddConfigView: View {
    let user: String
    let save: (UploadDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    // No server is chosen until the user chooses one.
    @State private var server = ""
    @State private var dataRoot = ""

    private var trimmedRoot: String { dataRoot.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Server", selection: $server) {
                    Text("Choose").tag("")
                    ForEach(UsersFile.serverNames, id: \.self) { Text($0).tag($0) }
                }
                TextField("Data root, /path/on/the/server", text: $dataRoot)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            .navigationTitle("New config for \(user)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(UploadDestination(server: server, dataRoot: trimmedRoot))
                        dismiss()
                    }
                    .disabled(server.isEmpty || !trimmedRoot.hasPrefix("/"))
                }
            }
        }
    }
}

// The folder on the computer that a user's wired transfer recordings go to: a path, written as that computer writes it, or none for its Downloads folder.
struct WiredFolderView: View {
    let user: String
    @State var path: String
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Downloads folder", text: $path)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } footer: {
                    Text("A folder on the computer, such as C:\\Users\\you\\scans or /Users/you/scans, which must already exist there. Leave it empty for the computer's Downloads folder. Recordings already made keep the folder they were made with.")
                }
            }
            .navigationTitle("Wired transfer folder for \(user)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(trimmedPath.isEmpty ? nil : trimmedPath)
                        dismiss()
                    }
                }
            }
        }
    }
}

// A config as the selection page shows it: This phone, Wired transfer, or the server's name, then where its recordings go.
struct TargetLabel: View {
    let target: RecordingTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.title)
            Text(target.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension RecordingTarget {
    var title: String {
        switch self {
        case .phone: return "This phone"
        case .wired: return "Wired transfer"
        case .upload(let destination): return destination.server
        }
    }

    var detail: String {
        switch self {
        case .phone: return "kept here, not uploaded"
        case .wired(let path): return "by cable to \(path ?? "the computer's Downloads folder")"
        case .upload(let destination): return destination.dataRoot
        }
    }
}
