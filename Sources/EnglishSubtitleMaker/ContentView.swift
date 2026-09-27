import AppKit
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            APIKeyBar()
            dropZone
            if !queue.jobs.isEmpty { jobList }
            progressSection
            LogView()
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 620)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.6))
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            VStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 34))
                    .foregroundColor(.secondary)
                Text("Drop movie files here (.mp4, .mkv, …)")
                    .font(.headline)
                Text("English subtitles are saved next to each movie with the same name (\"Movie.srt\"), which VLC loads automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Files…") { showImporter = true }
            }
            .padding()
        }
        .frame(height: 170)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    }
                    if let url {
                        Task { @MainActor in JobQueue.shared.add([url]) }
                    }
                }
            }
            return true
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Files").font(.subheadline.bold())
                Spacer()
                Button("Clear finished") { queue.clearFinished() }
                    .buttonStyle(.link)
                    .disabled(!queue.jobs.contains { job in
                        switch job.status {
                        case .waiting, .running: return false
                        default: return true
                        }
                    })
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(queue.jobs) { job in JobRow(job: job) }
                }
            }
            .frame(maxHeight: 110)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(queue.step)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if queue.isRunning {
                    Text("\(Int(queue.progress * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                    Button("Cancel") { queue.cancel() }
                }
            }
            ProgressView(value: queue.progress)
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            Text(job.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusText
        }
        .font(.callout)
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .waiting: Image(systemName: "clock").foregroundColor(.secondary)
        case .running: ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundColor(.orange)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch job.status {
        case .waiting: Text("Waiting").foregroundColor(.secondary)
        case .running: Text("Working…").foregroundColor(.secondary)
        case .done(let srt):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([srt]) }
                .buttonStyle(.link)
        case .failed(let code): Text("Failed (\(code))").foregroundColor(.red)
        case .cancelled: Text("Cancelled").foregroundColor(.orange)
        }
    }
}

struct APIKeyBar: View {
    @EnvironmentObject var queue: JobQueue
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundColor(.secondary)
            if queue.apiKey != nil && !editing {
                Text("Groq API key saved")
                Text("(…\(String(queue.apiKey?.suffix(4) ?? "")))").foregroundColor(.secondary)
                Spacer()
                Button("Change") { editing = true }
                Button("Remove") { queue.removeKey() }
            } else {
                SecureField("Paste your free Groq API key (starts with gsk_)", text: $draft, onCommit: save)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if editing { Button("Cancel") { editing = false; draft = "" } }
                Link("Get a free key", destination: URL(string: "https://console.groq.com/keys")!)
            }
        }
    }

    private func save() {
        queue.saveKey(draft)
        draft = ""
        editing = false
    }
}

struct LogView: View {
    @EnvironmentObject var queue: JobQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.subheadline.bold())
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(queue.logText(), forType: .string)
                }
                .buttonStyle(.link)
                Button("Open Log Folder") {
                    try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppPaths.logs)
                }
                .buttonStyle(.link)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(queue.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(queue.formattedTime(line.time)).foregroundColor(.secondary)
                                Text(line.text)
                                    .foregroundColor(color(line.level))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: queue.log.count) { _ in
                    if let last = queue.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .detail: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var queue: JobQueue
    @AppStorage(PrefKeys.model) private var model = Groq.defaultModel
    @AppStorage(PrefKeys.dialogueFocus) private var dialogueFocus = true

    var body: some View {
        Form {
            Picker("Groq model:", selection: $model) {
                Text("whisper-large-v3 (best for translation)").tag("whisper-large-v3")
                Text("whisper-large-v3-turbo (faster, weaker translation)").tag("whisper-large-v3-turbo")
            }
            Toggle("Dialogue focus: on 5.1/7.1 audio, use only the centre channel", isOn: $dialogueFocus)
            Text("Surround films put speech in the centre channel. Leaving out music and effects usually improves accuracy.")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            HStack {
                Button("Clear Saved Progress") { queue.clearResumeCache() }
                Text("Unfinished jobs are remembered so they resume where they stopped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
