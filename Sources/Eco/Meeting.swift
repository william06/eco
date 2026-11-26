// Calendario, detección automática de reuniones y ventanita flotante.
import SwiftUI
import EventKit
import CoreAudio

// MARK: - Calendario

@MainActor enum Agenda {
    static let store = EKEventStore()

    /// El evento que está en curso o empieza en los próximos 15 minutos (el más cercano a ahora).
    static func currentEvent() async -> EKEvent? {
        guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        let now = Date()
        let soon = now.addingTimeInterval(15 * 60)
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: soon, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.startDate < soon }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    /// Reuniones que quedan hoy (las que no han terminado).
    static func upcoming() async -> [EKEvent] {
        guard (try? await store.requestFullAccessToEvents()) == true else { return [] }
        let now = Date()
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
    }

    static func attendees(_ ev: EKEvent) -> [String] {
        (ev.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p in
            if let n = p.name, !n.isEmpty, !n.contains("@") { return n }
            // Sin nombre: usa la parte del correo antes de la @.
            return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").split(separator: "@").first.map(String.init)
        }
    }
}

// MARK: - Detección: inicio y fin de reuniones según qué apps usan el micrófono

@MainActor final class MicWatcher: ObservableObject {
    static let shared = MicWatcher()
    init() {}
    static let grace = 15                // segundos de aviso antes de detener sola

    @Published var prompt = false
    @Published var eventTitle: String?
    @Published var endingIn: Int?        // cuenta atrás para detener sola

    private var timer: Timer?
    private var wasRunning = false
    private var before: Set<pid_t> = []  // quién usaba el micrófono justo antes de empezar a grabar
    private var ours: Set<pid_t> = []    // procesos que usan el micrófono por nuestra grabación (p. ej. el de ScreenCaptureKit)
    private var since: Date?
    private var sawCall = false          // durante esta grabación, otra app usó el micrófono
    private var keep = false             // el usuario pidió seguir grabando
    // Efectos, inyectables para la autoprueba.
    var showPanel: () -> Void = { FloatingPanel.shared.show() }
    var hidePanel: () -> Void = { FloatingPanel.shared.hide() }
    var stopRecording: () -> Void = { Task { await Recorder.shared.stop() } }
    var fetchEventTitle: () async -> String? = { await Agenda.currentEvent()?.title }

    func start() {
        // shortcut: sondeo cada segundo en vez de listeners de Core Audio; cambiar a AudioObjectAddPropertyListenerBlock si importa la batería.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in MicWatcher.shared.tick() } }
    }

    private func tick() {
        let d = UserDefaults.standard
        tick(users: Self.micUsers().subtracting([getpid()]), recording: Recorder.shared.recording, busy: Recorder.shared.busy,
             autoDetect: d.object(forKey: "autoDetect") as? Bool ?? true, autoStop: d.object(forKey: "autoStop") as? Bool ?? true)
    }

    func tick(users: Set<pid_t>, recording: Bool, busy: Bool, autoDetect: Bool, autoStop: Bool, now: Date = Date()) {
        if recording {
            if since == nil { since = now }
            // Lo que aparece en los primeros segundos de grabar es nuestra propia captura.
            if now.timeIntervalSince(since!) < 3 { ours.formUnion(users.subtracting(before)); return }
            if !users.subtracting(ours).isEmpty { sawCall = true; endingIn = nil; return }
            // Ninguna otra app usa el micrófono: la llamada terminó (solo si hubo llamada mientras grabábamos).
            guard sawCall, !keep, autoStop else { return }
            endingIn = (endingIn ?? Self.grace + 1) - 1
            showPanel()
            if endingIn! <= 0 { endingIn = nil; stopRecording() }
            return
        }
        if since != nil { since = nil; ours = []; sawCall = false; keep = false; endingIn = nil }
        // Mientras arranca o procesa, no tomamos la foto de "antes": incluiría nuestra propia captura.
        if busy { return }

        let running = !users.isEmpty
        defer { wasRunning = running; before = users }
        guard autoDetect else { return }
        if running && !wasRunning {
            prompt = true
            eventTitle = nil
            showPanel()
            Task { eventTitle = await fetchEventTitle() }
        } else if !running && wasRunning && prompt {
            dismiss() // la llamada terminó sin grabar
        }
    }

    func dismiss() { prompt = false; hidePanel() }
    func keepRecording() { keep = true; endingIn = nil }

    /// PIDs de los procesos que están capturando audio de entrada ahora mismo.
    static func micUsers() -> Set<pid_t> {
        func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            .init(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        var out: Set<pid_t> = []
        for id in ids {
            var running: UInt32 = 0, pid: pid_t = 0
            var s4 = UInt32(MemoryLayout<UInt32>.size)
            var p = addr(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(id, &p, 0, nil, &s4, &running) == noErr, running != 0 else { continue }
            p = addr(kAudioProcessPropertyPID); s4 = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(id, &p, 0, nil, &s4, &pid) == noErr { out.insert(pid) }
        }
        return out
    }
}

// MARK: - Ventanita flotante (siempre encima, en todos los escritorios)

@MainActor final class FloatingPanel {
    static let shared = FloatingPanel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.hasShadow = true
            let host = NSHostingView(rootView: PanelView())
            host.sizingOptions = [.preferredContentSize]
            p.contentView = host
            if let f = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 340, y: f.maxY - 12))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

/// Abre (o trae al frente) la ventana principal. La asigna RootView, que tiene acceso a `openWindow`.
@MainActor enum Nav { static var openMain: () -> Void = {} }

struct PanelView: View {
    @ObservedObject var rec = Recorder.shared
    @ObservedObject var watcher = MicWatcher.shared
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rec.recording, let n = watcher.endingIn {
                Text("La llamada terminó").font(.headline)
                Text("Eco se detendrá y resumirá en \(n) s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                HStack {
                    Button("Seguir grabando") { watcher.keepRecording() }
                    Spacer()
                    Button("Detener ya") { Task { await rec.stop() } }.buttonStyle(.borderedProminent).tint(.red)
                }
            } else if rec.recording {
                HStack {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(rec.call.title.isEmpty ? "Grabando" : rec.call.title).font(.headline).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(lastLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("Abrir Eco") { Nav.openMain() }
                    Spacer()
                    Button("Detener y resumir") { Task { await rec.stop() } }.buttonStyle(.borderedProminent).tint(.red)
                }
            } else if rec.busy {
                HStack { ProgressView().controlSize(.small); Text(rec.status).font(.callout).lineLimit(2) }
            } else if watcher.prompt {
                Text("¿Grabar esta reunión?").font(.headline)
                if let t = watcher.eventTitle { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack {
                    Button("Ignorar") { watcher.dismiss() }
                    Spacer()
                    Button("Grabar") { Task { await rec.start() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: rec.recording) { if rec.recording { started = Date() } }
    }

    private var lastLine: String {
        if let l = rec.call.lines.last { return "\(rec.call.name(l.who)): \(l.text)" }
        return rec.status
    }
}
