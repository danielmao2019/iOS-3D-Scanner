import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            if model.availableCameras.count > 1 {
                Picker("Camera", selection: $model.camera) {
                    ForEach(model.availableCameras) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRecording || model.isFinishing)
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
                Text(model.isRecording ? "Stop" : (model.isFinishing ? "Packaging…" : "Record"))
                    .font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.isStarting || model.isFinishing || model.formatSummary.isEmpty)

            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }

            HStack {
                Text("Server").font(.caption)
                TextField("http://host:port", text: $model.server)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
            }

            List(model.files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.info.name).font(.caption.bold())
                    Text([
                        file.info.startTime.formatted(date: .abbreviated, time: .standard),
                        Duration.seconds(file.info.durationSeconds).formatted(.time(pattern: .minuteSecond)),
                        ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                    ].joined(separator: " · ")).font(.caption2.monospacedDigit())
                    HStack {
                        Text(file.upload.label).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        // Every recording uploads once it is named; a failed upload can be retried.
                        if case .failed = file.upload {
                            Button("Retry") { model.upload(file.id) }.font(.caption).buttonStyle(.bordered)
                        }
                        Button { model.pendingDelete = file } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                            .disabled(!file.canDelete)
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(.horizontal)
        .onAppear { model.startPreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stopRecording(because: "the app went to the background") }
        }
        .alert("Name this recording", isPresented: $model.asksNameBeforeStart) {
            TextField("Name", text: $model.nameDraft)
            Button("Later") { model.startRecording(named: false) }
            Button("Start") { model.startRecording(named: true) }
        }
        .alert("Name this recording", isPresented: $model.asksNameAfterStop) {
            TextField("Name", text: $model.nameDraft)
            Button("Use date and time") { model.nameStopped(named: false) }
            Button("Save") { model.nameStopped(named: true) }
        }
        .alert("Delete recording?", isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), presenting: model.pendingDelete) { file in
            Button("Delete", role: .destructive) { model.delete(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("\(file.info.name) is deleted from this iPhone. The copy on the server is kept.")
        }
    }
}

// Shows a capture source's live color stream, a view the source owns.
struct PreviewView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
