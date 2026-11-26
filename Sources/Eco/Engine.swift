// Grabación, transcripción, identificación de voces, resumen, historial y Notas de Apple.
import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech
import FoundationModels
import FluidAudio
import EventKit

struct Line: Identifiable, Codable, Equatable {
    var id = UUID()
    var who: String
    var text: String
    var start: Double = 0
    var end: Double = 0
}

struct Call: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var title = ""
    var lines: [Line] = []
    var names: [String: String] = [:]   // "Persona 1" -> "Ana"
    var myNotes = ""
    var summary = ""
    var notesID: String?                // id de la nota enlazada en Notas de Apple
    var attendees: [String]?            // invitados del evento de calendario (opcional: JSON antiguos no lo tienen)
    var enhanced: [EnhancedNote]?       // tus notas ampliadas por la IA

    func name(_ who: String) -> String {
        if let n = names[who], !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return who
    }
    var speakers: [String] {
        var seen: [String] = []
        for l in lines where !seen.contains(l.who) { seen.append(l.who) }
        return seen
    }
    var displayTitle: String { title.isEmpty ? "Llamada" : title }
    var transcript: String { lines.map { "\(name($0.who)): \($0.text)" }.joined(separator: "\n") }
}

struct EnhancedNote: Codable, Equatable {
    var note: String        // lo que escribió el usuario
    var details: [String]   // lo que añadió la IA desde la transcripción
}

struct Msg: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

// MARK: - Historial (un JSON por llamada en ~/Library/Application Support/Eco; no requiere permiso de macOS)

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    static let folder = URL.applicationSupportDirectory.appending(path: "Eco")
    @Published var calls: [Call] = []

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        calls = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Call.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func save(_ c: Call) {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(c).write(to: Self.folder.appending(path: "\(c.id).json"), options: .atomic)
        } catch { NSLog("Eco: no se pudo guardar: \(error)") }
        if let i = calls.firstIndex(where: { $0.id == c.id }) { calls[i] = c } else { calls.insert(c, at: 0) }
    }

    func delete(_ c: Call) {
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(c.id).json"))
        calls.removeAll { $0.id == c.id }
    }
}

// MARK: - Audio

// Convierte buffers al formato del transcriptor y, opcionalmente, los guarda en un WAV para identificar voces.
final class Feed {
    let cont: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    var file: AVAudioFile?
    private var conv: AVAudioConverter?, fileConv: AVAudioConverter?

    init(_ cont: AsyncStream<AnalyzerInput>.Continuation, _ format: AVAudioFormat) { self.cont = cont; self.format = format }

    func push(_ buf: AVAudioPCMBuffer) {
        if let out = Self.convert(buf, to: format, &conv) { cont.yield(AnalyzerInput(buffer: out)) }
        if let file, let out = Self.convert(buf, to: file.processingFormat, &fileConv) { try? file.write(from: out) }
    }

    static func convert(_ buf: AVAudioPCMBuffer, to fmt: AVAudioFormat, _ conv: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if conv?.inputFormat != buf.format { conv = AVAudioConverter(from: buf.format, to: fmt) }
        guard let conv else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var given = false
        conv.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        return out.frameLength > 0 ? out : nil
    }
}

final class CaptureOutput: NSObject, SCStreamOutput {
    var mic: Feed?, system: Feed?
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let feed = (type == .microphone ? mic : type == .audio ? system : nil),
              let asbd = sb.formatDescription?.audioStreamBasicDescription else { return }
        try? sb.withAudioBufferList { abl, _ in
            var desc = asbd
            guard let fmt = AVAudioFormat(streamDescription: &desc),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer) else { return }
            feed.push(buf) // síncrono: el buffer sin copia solo vive dentro de este closure
        }
    }
}

// MARK: - Grabación

@MainActor final class Recorder: ObservableObject {
    static let shared = Recorder()
    @Published var finished: UUID?      // última llamada terminada, para mostrarla
    @Published var call = Call()
    @Published var live: [String: String] = [:]
    @Published var status = "Listo"
    @Published var recording = false
    @Published var busy = false

    private var stream: SCStream?
    private let output = CaptureOutput()
    private var analyzers: [SpeechAnalyzer] = []
    private var feeds: [Feed] = []
    private var tasks: [Task<Void, Never>] = []
    private let queue = DispatchQueue(label: "audio")
    private var sysWav: URL { FileManager.default.temporaryDirectory.appending(path: "eco-\(call.id)-llamada.wav") }
    private var micWav: URL { FileManager.default.temporaryDirectory.appending(path: "eco-\(call.id)-mic.wav") }

    private func removeWavs() { [sysWav, micWav].forEach { try? FileManager.default.removeItem(at: $0) } }

    // WAV mono 16 kHz para identificar voces al terminar.
    private func wav(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func start(event: EKEvent? = nil) async {
        guard !recording, !busy else { return }
        busy = true; defer { busy = false }
        call = Call(); live = [:]
        MicWatcher.shared.prompt = false
        FloatingPanel.shared.show()
        var ev = event
        if ev == nil { ev = await Agenda.currentEvent() }
        if let ev {
            call.title = ev.title ?? ""
            call.attendees = Agenda.attendees(ev)
        }
        let localeID = UserDefaults.standard.string(forKey: "localeID") ?? "es-ES"
        do {
            status = "Preparando modelos de voz…"
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID))
            else { throw Msg("Idioma no soportado por SpeechTranscriber") }
            let mic = try await makeTranscriber(locale: locale, who: "Yo")
            mic.file = try wav(micWav)
            output.mic = mic
            let system = try await makeTranscriber(locale: locale, who: "Ellos")
            system.file = try wav(sysWav)
            output.system = system

            status = "Pidiendo permisos…"
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw Msg("No hay pantalla") }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.captureMicrophone = true
            cfg.excludesCurrentProcessAudio = true
            cfg.width = 2; cfg.height = 2 // solo audio
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try s.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            recording = true
            status = "Grabando…"
        } catch {
            await teardown()
            removeWavs()
            status = "Error: \(error.localizedDescription)"
            FloatingPanel.shared.hide()
        }
    }

    /// Devuelve la llamada guardada, o nil si no se transcribió nada.
    func stop() async {
        guard recording else { return }
        let store = Store.shared
        let sendToNotes = UserDefaults.standard.object(forKey: "sendToNotes") as? Bool ?? true
        busy = true
        defer { busy = false; FloatingPanel.shared.hide() }
        recording = false
        status = "Terminando transcripción…"
        await teardown()
        defer { removeWavs() } // el audio no se conserva
        guard !call.lines.isEmpty else { status = "No se transcribió nada"; return }

        status = "Identificando voces (la primera vez descarga el modelo)…"
        do { var lines = call.lines; try await Speakers.label(&lines, system: sysWav, mic: micWav); call.lines = lines }
        catch { NSLog("Eco: diarización falló: \(error)") }
        do { var c = call; await Namer.guess(&c); call = c }
        store.save(call)
        finished = call.id

        status = "Resumiendo con Apple Intelligence…"
        do { var c = call; try await Summarizer.fill(&c); call = c }
        catch { status = "Error al resumir: \(error.localizedDescription)" }
        store.save(call)
        if !call.myNotes.isEmpty {
            status = "Ampliando tus notas…"
            if let e = try? await Enhancer.enhance(call) { call.enhanced = e; store.save(call) }
        }

        if sendToNotes {
            do { call.notesID = try AppleNotes.send(call); store.save(call) }
            catch { status = "No se pudo enviar a Notas: \(error.localizedDescription)"; return }
        }
        status = "Listo"
    }

    private func teardown() async {
        try? await stream?.stopCapture(); stream = nil
        queue.sync {} // espera a que termine el último buffer de audio
        output.system?.file = nil; output.mic?.file = nil // cierra los WAV
        feeds.forEach { $0.cont.finish() }
        for a in analyzers { try? await a.finalizeAndFinishThroughEndOfInput() }
        for t in tasks { await t.value }
        output.mic = nil; output.system = nil
        analyzers = []; feeds = []; tasks = []
        for (who, text) in live where !text.isEmpty { call.lines.append(Line(who: who, text: text)) }
        live = [:]
    }

    private func makeTranscriber(locale: Locale, who: String) async throws -> Feed {
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            status = "Descargando modelo de voz (solo la primera vez)…"
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [t])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw Msg("Sin formato de audio") }
        let (input, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        tasks.append(Task { [weak self] in
            do {
                for try await r in t.results {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { return }
                    if r.isFinal {
                        self.live[who] = nil
                        if !text.isEmpty {
                            self.call.lines.append(Line(who: who, text: text, start: r.range.start.seconds, end: r.range.end.seconds))
                        }
                    } else { self.live[who] = text }
                }
            } catch { self?.status = "Error de transcripción: \(error.localizedDescription)" }
        })
        analyzers.append(analyzer)
        let feed = Feed(cont, fmt)
        feeds.append(feed)
        return feed
    }
}

// MARK: - Identificar voces (FluidAudio, local)

enum Speakers {
    typealias Segment = (id: String, start: Double, end: Double)

    /// Separa voces de la llamada ("Ellos") y del micrófono ("Yo"; la voz principal sigue siendo "Yo").
    static func label(_ lines: inout [Line], system: URL, mic: URL) async throws {
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        func segments(_ url: URL) async throws -> [Segment] {
            try await manager.process(url).segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds)) }
        }
        var next = 1
        if lines.contains(where: { $0.who == "Ellos" }) {
            assign(&lines, source: "Ellos", segments: try await segments(system), next: &next)
        }
        if lines.contains(where: { $0.who == "Yo" }) {
            assign(&lines, source: "Yo", segments: try await segments(mic), next: &next)
        }
    }

    /// A cada frase de `source` le asigna la voz que más se solapa con ella. Las voces nuevas son Persona N, N+1…
    /// por orden de aparición; en el micrófono, la voz que más habla se queda como "Yo".
    static func assign(_ lines: inout [Line], source: String, segments: [Segment], next: inout Int) {
        var label: [String: String] = [:]
        if source == "Yo" {
            var talk: [String: Double] = [:]
            for s in segments { talk[s.id, default: 0] += s.end - s.start }
            if let main = talk.max(by: { $0.value < $1.value })?.key { label[main] = "Yo" }
        }
        for i in lines.indices where lines[i].who == source {
            var best: (id: String, overlap: Double)?
            for s in segments {
                let o = min(s.end, lines[i].end) - max(s.start, lines[i].start)
                if o > (best?.overlap ?? 0) { best = (s.id, o) }
            }
            guard let id = best?.id else { continue }
            if label[id] == nil { label[id] = "Persona \(next)"; next += 1 }
            lines[i].who = label[id]!
        }
    }
}

// MARK: - Poner nombre a las voces con los invitados del calendario

enum Namer {
    static func guess(_ call: inout Call) async {
        let unnamed = call.speakers.filter { $0.hasPrefix("Persona") && (call.names[$0] ?? "").isEmpty }
        guard let att = call.attendees, !att.isEmpty, !unnamed.isEmpty else { return }
        if unnamed.count == 1, att.count == 1 { call.names[unnamed[0]] = att[0]; return }
        guard SystemLanguageModel.default.isAvailable else { return }
        let prompt = """
        Invitados a la reunión: \(att.joined(separator: ", ")).
        Transcripción:
        \(call.transcript.prefix(6000))

        Para cada etiqueta (\(unnamed.joined(separator: ", "))) di quién es, solo si el texto lo deja claro \
        (alguien la llama por su nombre o se presenta). Responde una línea por etiqueta, con el formato \
        "Persona N = Nombre", o "Persona N = ?" si no está claro.
        """
        guard let answer = try? await LanguageModelSession().respond(to: prompt).content else { return }
        for (who, name) in parse(answer, labels: unnamed, known: att + [call.transcript]) { call.names[who] = name }
    }

    /// Lee líneas "Persona N = Nombre"; descarta "?" y nombres que no aparecen ni en invitados ni en la transcripción.
    static func parse(_ text: String, labels: [String], known: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "*-`\""))) }
            guard parts.count == 2, labels.contains(parts[0]), !parts[1].isEmpty, parts[1] != "?",
                  known.contains(where: { $0.localizedCaseInsensitiveContains(parts[1]) }) else { continue }
            out[parts[0]] = parts[1]
        }
        return out
    }
}

// MARK: - Resumen (Apple Intelligence)

enum Summarizer {
    static let instructions = """
    Eres un asistente que toma notas de reuniones. Recibes la transcripción de una llamada \
    ("Yo" es el usuario; los demás aparecen por su nombre o como "Persona N") y, a veces, notas del propio usuario. \
    Escribe en español notas concisas en Markdown con: **Resumen** (2-3 frases), **Puntos clave** (viñetas), \
    **Decisiones** y **Próximos pasos** (con responsable si se menciona). Da prioridad a lo que el usuario anotó. \
    No inventes nada que no esté en el texto.
    """

    static func fill(_ call: inout Call) async throws {
        let notes = call.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        var context = ""
        if !call.title.isEmpty { context += "Reunión: \(call.title)\n" }
        if let a = call.attendees, !a.isEmpty { context += "Invitados: \(a.joined(separator: ", "))\n" }
        if !notes.isEmpty { context += "Notas del usuario:\n\(notes)\n" }
        call.summary = try await summarize(context + (context.isEmpty ? "" : "\nTranscripción:\n") + call.transcript)
        guard call.title.isEmpty else { return } // respeta el título que puso el usuario
        call.title = try await LanguageModelSession()
            .respond(to: "Escribe solo un título de 3 a 6 palabras, sin comillas ni punto final, para esta reunión:\n\(call.summary)")
            .content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"*#")))
    }

    // El modelo local tiene ~4k tokens de contexto: resume por trozos y luego resume los resúmenes.
    static func summarize(_ text: String) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw Msg("Apple Intelligence no está disponible (actívalo en Ajustes del Sistema)")
        }
        var parts: [String] = []
        for c in chunk(text, max: 5000) {
            parts.append(try await LanguageModelSession(instructions: instructions).respond(to: c).content)
        }
        return parts.count == 1 ? parts[0] : try await summarize(parts.joined(separator: "\n\n"))
    }

    static func chunk(_ text: String, max: Int) -> [String] {
        var out: [String] = [], cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !cur.isEmpty && cur.count + line.count > max { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + line.prefix(max)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - Tus notas ampliadas (como Granola: tu texto + detalles de la IA en gris)

enum Enhancer {
    static let instructions = """
    Amplías las notas breves que el usuario tomó durante una reunión con detalles de la transcripción. \
    Para cada nota, añade los detalles concretos (datos, cifras, nombres, acuerdos) que el fragmento da sobre ella, en frases cortas. \
    Cada detalle va solo en la nota a la que corresponde. No repitas la nota ni inventes nada. Escribe en español.
    """

    static func noteLines(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "-*•"))).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func enhance(_ call: Call) async throws -> [EnhancedNote]? {
        let notes = noteLines(call.myNotes)
        guard !notes.isEmpty, !call.lines.isEmpty else { return nil }
        guard SystemLanguageModel.default.isAvailable else { throw Msg("Apple Intelligence no está disponible") }
        let list = notes.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        var details = Array(repeating: [String](), count: notes.count)
        // Recorre la transcripción por trozos (contexto pequeño) y acumula detalles por nota.
        // Un campo obligatorio por nota: el modelo pequeño se salta notas si le damos una lista libre.
        let props = notes.indices.map { i in
            DynamicGenerationSchema.Property(
                name: "nota_\(i + 1)", description: "Detalles del fragmento sobre la nota \(i + 1) («\(notes[i])»); vacío si no la trata",
                schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), maximumElements: 3))
        }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "NotasAmpliadas", properties: props), dependencies: [])
        for chunk in Summarizer.chunk(call.transcript, max: 4000) {
            let r = try await LanguageModelSession(instructions: instructions)
                .respond(to: "Notas del usuario:\n\(list)\n\nFragmento de la transcripción:\n\(chunk)", schema: schema)
                .content
            merge(&details, notes.indices.map { i in (i + 1, (try? r.value([String].self, forProperty: "nota_\(i + 1)")) ?? []) })
        }
        return zip(notes, details).map { EnhancedNote(note: $0, details: $1) }
    }

    /// Añade detalles a la nota indicada (1-based); ignora números fuera de rango, vacíos y repetidos.
    static func merge(_ details: inout [[String]], _ items: [(note: Int, details: [String])]) {
        for (n, ds) in items where details.indices.contains(n - 1) {
            for d in ds.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !d.isEmpty
                && !details[n - 1].contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) {
                details[n - 1].append(d)
            }
        }
    }
}

// MARK: - Notas de Apple (AppleScript, carpeta "Eco")

enum AppleNotes {
    /// Crea la nota o actualiza la ya enlazada. Devuelve su id.
    static func send(_ c: Call) throws -> String {
        let body = html(c)
        if let id = c.notesID, (try? run("tell application \"Notes\" to set body of note id \"\(q(id))\" to \"\(q(body))\"")) != nil {
            return id
        }
        // Sin nota enlazada (o la borraron): crea una nueva.
        return try run("""
        tell application "Notes"
            if not (exists folder "Eco") then make new folder with properties {name:"Eco"}
            set n to make new note at folder "Eco" with properties {body:"\(q(body))"}
            return id of n
        end tell
        """)
    }

    static func show(_ id: String) {
        _ = try? run("tell application \"Notes\"\nshow note id \"\(q(id))\"\nactivate\nend tell")
    }

    @discardableResult static func run(_ source: String) throws -> String {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { throw Msg(err[NSAppleScript.errorMessage] as? String ?? "Error con Notas") }
        return r?.stringValue ?? ""
    }

    static func q(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(_ c: Call) -> String {
        var h = "<h1>\(esc(c.displayTitle))</h1><div><i>\(esc(c.date.formatted(date: .long, time: .shortened)))</i></div><br>"
        h += markdown(c.summary)
        if let en = c.enhanced {
            h += "<h2>Mis notas</h2>" + en.map { e in
                "<div><b>\(esc(e.note))</b></div>" + (e.details.isEmpty ? "" :
                    "<ul>" + e.details.map { "<li><span style=\"color:#8a8a8a\">\(esc($0))</span></li>" }.joined() + "</ul>")
            }.joined()
        } else if !c.myNotes.isEmpty { h += "<h2>Mis notas</h2>" + markdown(c.myNotes) }
        h += "<h2>Transcripción</h2>"
        h += c.lines.map { "<div><b>\(esc(c.name($0.who))):</b> \(esc($0.text))</div>" }.joined()
        return h
    }

    // shortcut: solo viñetas, títulos y negritas, que es lo que produce el resumen; usar un parser real si hace falta más.
    static func markdown(_ md: String) -> String {
        var out = "", inList = false
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = esc(raw.trimmingCharacters(in: .whitespaces))
            l = l.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            let item = l.hasPrefix("- ") || l.hasPrefix("* ")
            if item != inList { out += item ? "<ul>" : "</ul>"; inList = item }
            if item { out += "<li>\(l.dropFirst(2))</li>" }
            else if l.hasPrefix("#") { out += "<h2>\(l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))</h2>" }
            else if !l.isEmpty { out += "<div>\(l)</div>" }
        }
        return out + (inList ? "</ul>" : "")
    }
}

// MARK: - Autoprueba: `Eco.app/Contents/MacOS/Eco --selftest`

enum SelfTest {
    static func run() {
        var lines = [Line(who: "Yo", text: "hola", start: 0, end: 1),
                     Line(who: "Ellos", text: "a", start: 1, end: 3),
                     Line(who: "Ellos", text: "b", start: 3, end: 6),
                     Line(who: "Ellos", text: "c", start: 6, end: 8)]
        var next = 1
        Speakers.assign(&lines, source: "Ellos", segments: [("S7", 0.9, 3.1), ("S2", 3.0, 5.5), ("S7", 5.8, 9)], next: &next)
        precondition(lines.map(\.who) == ["Yo", "Persona 1", "Persona 2", "Persona 1"], "\(lines.map(\.who))")

        // Micrófono: S1 habla más (es "Yo"); S2 es alguien en la sala y sigue la numeración.
        var room = [Line(who: "Yo", text: "x", start: 0, end: 5), Line(who: "Yo", text: "y", start: 5, end: 7),
                    Line(who: "Yo", text: "z", start: 7, end: 12)]
        Speakers.assign(&room, source: "Yo", segments: [("S1", 0, 5), ("S2", 5, 7), ("S1", 7, 12)], next: &next)
        precondition(room.map(\.who) == ["Yo", "Persona 3", "Yo"], "\(room.map(\.who))")

        precondition(Summarizer.chunk("aaa\nbbb\nccc", max: 7) == ["aaa\nbbb", "ccc"])
        precondition(AppleNotes.markdown("**Hola** <x>\n- uno\n- dos\nfin") ==
               "<div><b>Hola</b> &lt;x&gt;</div><ul><li>uno</li><li>dos</li></ul><div>fin</div>")
        precondition(AppleNotes.q("a\"b\\c") == "a\\\"b\\\\c")
        precondition(Namer.parse("Persona 1 = Ana López\n**Persona 2** = ?\nPersona 3 = Inventado\nPersona 9 = Ana",
                                 labels: ["Persona 1", "Persona 2", "Persona 3"], known: ["Ana López", "Luis"]) == ["Persona 1": "Ana López"])
        precondition(Enhancer.noteLines("- presupuesto\n\n  • fechas \n*x") == ["presupuesto", "fechas", "x"])
        var det: [[String]] = [[], ["ya"]]
        Enhancer.merge(&det, [(1, ["a", " "]), (2, ["YA", "b"]), (3, ["fuera"]), (0, ["cero"])])
        precondition(det == [["a"], ["ya", "b"]], "\(det)")
        precondition(Retriever.terms("¿Qué dijo Ana sobre el PRESUPUESTO?") == ["ana", "presupuesto"], "\(Retriever.terms("¿Qué dijo Ana sobre el PRESUPUESTO?"))")
        let old = Call(date: Date(timeIntervalSinceNow: -86400), title: "Ventas", lines: [Line(who: "Yo", text: "hablemos de clientes")], summary: "Clientes nuevos")
        let new = Call(title: "Lanzamiento", lines: [Line(who: "Persona 1", text: "el presupuesto es de 40 mil")], names: ["Persona 1": "Ana"], summary: "Presupuesto y fechas")
        let hits = Retriever.search("presupuesto de Ana", in: [old, new])
        precondition(hits.first?.call.title == "Lanzamiento" && !hits.contains { $0.call.title == "Ventas" }, "\(hits.map(\.call.title))")
        precondition(Retriever.search("¿qué tal?", in: [old, new]).first?.call.title == "Lanzamiento") // sin coincidencias: lo más reciente
        precondition(Set(Retriever.search("¿qué pendientes tengo?", in: [
            Call(title: "A", summary: "**Próximos pasos**\n- enviar contrato"), Call(title: "B", summary: "Nada")]).map(\.call.title)) == ["A"])
        MainActor.assumeIsolated { micWatcherTest() }
        print("selftest ok")
    }
}

@MainActor func micWatcherTest() {
    let w = MicWatcher()
    var stops = 0
    w.showPanel = {}; w.hidePanel = {}; w.stopRecording = { stops += 1 }; w.fetchEventTitle = { nil }
    var t = Date()
    func step(_ users: Set<pid_t>, rec: Bool, busy: Bool = false, autoStop: Bool = true) {
        w.tick(users: users, recording: rec, busy: busy, autoDetect: true, autoStop: autoStop, now: t)
        t += 1
    }
    // Zoom (100) empieza: aviso. Grabamos; nuestro daemon (200) aparece al arrancar.
    step([100], rec: false); precondition(w.prompt)
    step([100, 200], rec: false, busy: true)          // arrancando: no cuenta como "antes"
    for _ in 0..<3 { step([100, 200], rec: true) }    // ventana inicial: 200 es nuestro
    step([100, 200], rec: true); precondition(w.endingIn == nil && stops == 0)
    // Zoom cuelga: cuenta atrás de 15 s y se detiene.
    for _ in 0..<MicWatcher.grace { step([200], rec: true) }   // muestra 15, 14… 1
    precondition(stops == 0 && w.endingIn == 1, "\(String(describing: w.endingIn))")
    step([200], rec: true); precondition(stops == 1 && w.endingIn == nil)
    // Si vuelve la llamada durante la cuenta atrás, se cancela.
    step([], rec: false); step([300], rec: false)
    for _ in 0..<4 { step([300, 200], rec: true) }
    step([200], rec: true); precondition(w.endingIn != nil)
    step([300, 200], rec: true); precondition(w.endingIn == nil)
    // "Seguir grabando" y grabaciones sin llamada (reunión presencial) no se detienen solas.
    step([200], rec: true); w.keepRecording()
    for _ in 0..<20 { step([200], rec: true) }
    step([], rec: false)
    for _ in 0..<25 { step([200], rec: true) }
    precondition(stops == 1, "stops=\(stops)")
}
