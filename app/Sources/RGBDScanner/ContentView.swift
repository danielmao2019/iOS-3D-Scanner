import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                Button { model.leaveScanner() } label: { Label("Configs", systemImage: "chevron.left") }
                    .disabled(model.isRecording || model.isStarting)
                Spacer()
                if let selection = model.selection {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(selection.user).font(.caption.bold())
                        Text("\(selection.target.title) · \(selection.target.detail)").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }

            if model.availableCameras.count > 1 {
                Picker("Camera", selection: $model.camera) {
                    ForEach(model.availableCameras) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRecording)
                .onChange(of: model.camera) { _, _ in model.startPreview() }
            } else if let only = model.availableCameras.first {
                Text(only.label).font(.headline)
            }

            ZStack {
                if model.availableCameras.contains(model.camera) {
                    PreviewView(view: model.recorder.preview(for: model.camera)).id(model.camera)
                }
                if model.showsDepth {
                    Color.black
                    if let frame = model.depthFrame {
                        Image(uiImage: frame.image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    }
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxHeight: 360)
            .clipped()
            .overlay(alignment: .topLeading) {
                if model.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let s = Int(context.date.timeIntervalSince(model.recordingStart))
                        Text(String(format: "● REC %d:%02d", s / 60, s % 60))
                            .font(.caption.monospacedDigit()).padding(4)
                            .background(.red).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 4)).padding(6)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                HStack {
                    if model.showsDepth, let frame = model.depthFrame { DepthLegend(frame: frame) }
                    Spacer()
                    Button(model.showsDepth ? "Color" : "Depth") { model.showsDepth.toggle() }
                        .font(.caption.bold()).buttonStyle(.borderedProminent).tint(.black.opacity(0.6))
                }
                .padding(6)
            }

            Text(model.formatSummary).font(.caption)
            Text(String(format: "depth valid %.0f%% · median %.2f m", model.stats.depthValidFraction * 100, model.stats.depthMedianMeters))
                .font(.caption2.monospacedDigit())
            Text(String(format: "recorded: color %d · depth %d · dropped %d / %d",
                        model.stats.colorFrames, model.stats.depthFrames, model.stats.droppedColor, model.stats.droppedDepth))
                .font(.caption2.monospacedDigit())

            Button(action: model.recordTapped) {
                Text(model.isRecording ? "Stop" : "Record")
                    .font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.isStarting || model.formatSummary.isEmpty)

            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }

            List {
                // The recordings on this phone, then, for a server config, those its receiver holds in the data root.
                ForEach(model.shownFiles) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.info.name).font(.caption.bold())
                    Text("by \(file.info.user ?? "unknown")").font(.caption2)
                    Text([
                        file.info.startTime.formatted(date: .abbreviated, time: .standard),
                        Duration.seconds(file.info.durationSeconds).formatted(.time(pattern: .minuteSecond)),
                        ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                    ].joined(separator: " · ")).font(.caption2.monospacedDigit())
                    HStack {
                        Text(file.upload.label).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        // A recording on a server config uploads once it is named; a failed upload can be retried.
                        if case .failed = file.upload {
                            Button("Retry") { model.upload(file.id) }.font(.caption).buttonStyle(.bordered)
                        }
                        if file.canDelete {
                            Button { model.pendingDelete = file } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).foregroundStyle(.red)
                        }
                    }
                }
                }
                ForEach(model.serverRecordings) { recording in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.name ?? recording.scanId).font(.caption.bold())
                        Text("by \(recording.author ?? "unknown")").font(.caption2)
                        Text([
                            recording.startTimeUtc?.formatted(date: .abbreviated, time: .standard),
                            recording.durationS.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) },
                            ByteCountFormatter.string(fromByteCount: recording.size, countStyle: .file),
                        ].compactMap { $0 }.joined(separator: " · ")).font(.caption2.monospacedDigit())
                        Text("on the server").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { model.refreshServerRecordings() }
        }
        .padding(.horizontal)
        .onAppear { model.startPreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stopRecording(because: "the app went to the background") }
        }
        .alert("Name this recording", isPresented: $model.asksNameBeforeStart) {
            TextField("Name", text: $model.nameDraft)
            // Start takes a name; Later records unnamed, to be named at Stop; Cancel goes back without recording.
            Button("Start") { model.startRecording(named: true) }.disabled(model.enteredName == nil)
            Button("Later") { model.startRecording(named: false) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Name this recording", isPresented: $model.asksNameAfterStop) {
            TextField("Name", text: $model.nameDraft)
            Button("Save") { model.nameStopped(named: true) }.disabled(model.enteredName == nil)
            Button("Use date and time") { model.nameStopped(named: false) }
        }
        .alert("Delete recording?", isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), presenting: model.pendingDelete) { file in
            Button("Delete", role: .destructive) { model.delete(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("\(file.info.name) is deleted from this iPhone, the only place it is kept.")
        }
    }
}

// Shows a capture source's live color stream, a view the source owns.
struct PreviewView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
