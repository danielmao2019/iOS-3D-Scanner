import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

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

            PreviewView(session: model.recorder.session)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxHeight: 360)
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

            Text(model.formatSummary).font(.caption)
            Text(String(format: "depth valid %.0f%% · median %.2f m", model.stats.depthValidFraction * 100, model.stats.depthMedianMeters))
                .font(.caption2.monospacedDigit())
            Text(String(format: "recorded: color %d · depth %d · dropped %d / %d",
                        model.stats.colorFrames, model.stats.depthFrames, model.stats.droppedColor, model.stats.droppedDepth))
                .font(.caption2.monospacedDigit())

            Button(action: model.toggleRecording) {
                Text(model.isRecording ? "Stop" : (model.isFinishing ? "Packaging…" : "Record"))
                    .font(.title2.bold()).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .disabled(model.isFinishing || model.formatSummary.isEmpty)

            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }

            HStack {
                Text("Server").font(.caption)
                TextField("http://host:port", text: $model.server)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
            }

            List {
                ForEach(model.files) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.id).font(.caption.bold())
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption2)
                            Text(file.upload.label).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            // Every recording uploads when it is stopped; a failed upload can be retried.
                            if case .failed = file.upload {
                                Button("Retry") { model.upload(file.url) }.font(.caption).buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .onDelete { indexSet in indexSet.map { model.files[$0] }.forEach(model.delete) }
            }
            .listStyle(.plain)
        }
        .padding(.horizontal)
        .onAppear { model.startPreview() }
    }
}

// Shows the capture session's color stream.
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}
