import AppKit
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header()
            APIKeyBar()
            dropZone
            if !queue.jobs.isEmpty { jobList }
            progressSection
            LogView()
        }
        .padding(18)
        .frame(minWidth: 660, minHeight: 640)
        .background(Theme.background.ignoresSafeArea())
        .foregroundColor(Theme.text)
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(get: { queue.trackRequest != nil },
                                    set: { if !$0 { queue.answerTrack(nil) } })) {
            if let request = queue.trackRequest {
                TrackPickerView(request: request).environmentObject(queue)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(isTargeted ? Theme.accent.opacity(0.10) : Theme.surface)
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundColor(isTargeted ? Theme.accent : Theme.border)
            VStack(spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.accent)
                Text("Drop movies here")
                    .font(.system(size: 16, weight: .semibold))
                Text("English subtitles are saved next to each movie as \"Movie.srt\", which VLC loads automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Choose Files…") { showImporter = true }
                    .buttonStyle(.pillProminent)
                    .padding(.top, 2)
            }
            .padding()
        }
        .frame(height: 180)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
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
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle("Files")
                    Spacer()
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.pillSmall)
                        .disabled(!queue.jobs.contains { job in
                            switch job.status {
                            case .waiting, .running: return false
                            default: return true
                            }
                        })
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(queue.jobs) { job in JobRow(job: job) }
                    }
                }
                .frame(maxHeight: 104)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(queue.step)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if queue.isRunning {
                    Text("\(Int(queue.progress * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.accent)
                    Button("Cancel") { queue.cancel() }
                        .buttonStyle(.pillSmall)
                }
            }
            ProgressBar(value: queue.progress)
        }
    }
}

struct Header: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("English Subtitle Maker")
                    .font(.system(size: 15, weight: .semibold))
                Text("Whisper large-v3 on Groq")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textFaint)
            }
            Spacer()
            Button {
                // macOS 13+ renamed the action; try both.
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.pillSmall)
            .help("Settings (⌘,)")
        }
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(Theme.textFaint)
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 16)
            Text(job.url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusView
        }
    }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .waiting: Image(systemName: "clock").foregroundColor(Theme.textFaint)
        case .running: ProgressView().scaleEffect(0.45).frame(width: 16, height: 16)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(Theme.error)
        case .cancelled: Image(systemName: "stop.circle").foregroundColor(Theme.warning)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch job.status {
        case .waiting: Text("Waiting").font(.system(size: 11)).foregroundColor(Theme.textFaint)
        case .running: Text("Working…").font(.system(size: 11)).foregroundColor(Theme.accent)
        case .done(let srt):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([srt]) }
                .buttonStyle(.pillSmall)
        case .failed(let code): Text("Failed (\(code))").font(.system(size: 11)).foregroundColor(Theme.error)
        case .cancelled: Text("Cancelled").font(.system(size: 11)).foregroundColor(Theme.warning)
        }
    }
}

struct APIKeyBar: View {
    @EnvironmentObject var queue: JobQueue
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        Card(padding: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundColor(Theme.accent)
                if queue.apiKey != nil && !editing {
                    Text("Groq API key saved").font(.system(size: 12))
                    Text("…\(String(queue.apiKey?.suffix(4) ?? ""))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.textFaint)
                    Spacer()
                    Button("Change") { editing = true }.buttonStyle(.pillSmall)
                    Button("Remove") { queue.removeKey() }.buttonStyle(.pillSmall)
                } else {
                    SecureField("Paste your free Groq API key (starts with gsk_)", text: $draft, onCommit: save)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.logBackground))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
                    Button("Save", action: save)
                        .buttonStyle(PillButtonStyle(prominent: true, small: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editing {
                        Button("Cancel") { editing = false; draft = "" }.buttonStyle(.pillSmall)
                    }
                    Link("Get a free key", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Log")
                Spacer()
                FeedbackButton("Copy Log", done: "Copied") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(queue.logText(), forType: .string)
                }
                .buttonStyle(.pillSmall)
                Button("Open Log Folder") {
                    try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AppPaths.logs)
                }
                .buttonStyle(.pillSmall)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(queue.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(queue.formattedTime(line.time)).foregroundColor(Theme.textFaint)
                                Text(line.text)
                                    .foregroundColor(color(line.level))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.logBackground))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border, lineWidth: 1))
                .onChange(of: queue.log.count) { _ in
                    if let last = queue.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Theme.text
        case .detail: return Theme.textSecondary
        case .warning: return Theme.warning
        case .error: return Theme.error
        case .success: return Theme.success
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var queue: JobQueue
    @AppStorage(PrefKeys.dialogueFocus) private var dialogueFocus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Surround audio")
                Toggle("Dialogue focus: on 5.1/7.1 audio, use only the centre channel", isOn: $dialogueFocus)
                Text("Surround films put speech in the centre channel. Leaving out music and effects usually improves accuracy.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Unfinished jobs")
                HStack(spacing: 10) {
                    FeedbackButton("Clear Saved Progress", done: "Cleared") { queue.clearResumeCache() }
                        .buttonStyle(.pillSmall)
                    Text("Unfinished jobs are remembered so they resume where they stopped.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.background)
        .foregroundColor(Theme.text)
        .preferredColorScheme(.dark)
    }
}

/// A button that briefly shows a checkmark and `done` after it is clicked,
/// so actions with no other visible result (like copying) are confirmed.
struct FeedbackButton: View {
    let title: String
    let done: String
    let action: () -> Void
    @State private var showDone = false
    @State private var clicks = 0

    init(_ title: String, done: String, action: @escaping () -> Void) {
        self.title = title
        self.done = done
        self.action = action
    }

    var body: some View {
        Button {
            action()
            clicks += 1
            let click = clicks
            withAnimation(.easeOut(duration: 0.15)) { showDone = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if clicks == click { withAnimation(.easeIn(duration: 0.2)) { showDone = false } }
            }
        } label: {
            // Both labels are laid out so the button keeps its width.
            ZStack {
                Text(title).opacity(showDone ? 0 : 1)
                Label(done, systemImage: "checkmark")
                    .foregroundColor(Theme.success)
                    .opacity(showDone ? 1 : 0)
            }
        }
    }
}

struct TrackPickerView: View {
    @EnvironmentObject var queue: JobQueue
    let request: TrackRequest
    @State private var selected: Int

    init(request: TrackRequest) {
        self.request = request
        _selected = State(initialValue: request.suggested.audioIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the audio track").font(.system(size: 15, weight: .semibold))
            Text("\"\(request.fileName)\" has \(request.streams.count) audio tracks. Pick the one in the film's original language (not an English dub).")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $selected) {
                ForEach(request.streams, id: \.audioIndex) { stream in
                    Text(label(stream)).tag(stream.audioIndex)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel Job") { queue.answerTrack(nil) }
                    .buttonStyle(.pill)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Track") {
                    queue.answerTrack(request.streams.first { $0.audioIndex == selected })
                }
                .buttonStyle(.pillProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.background)
        .foregroundColor(Theme.text)
        .preferredColorScheme(.dark)
    }

    private func label(_ stream: AudioStream) -> String {
        let summary = stream.summary.prefix(1).uppercased() + stream.summary.dropFirst()
        return stream == request.suggested ? "\(summary)  (suggested)" : summary
    }
}
