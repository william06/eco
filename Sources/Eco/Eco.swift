// Eco: escucha tus llamadas, separa quién habla, resume con Apple Intelligence y lo guarda en tu historial y en Notas.
import SwiftUI
import FluidAudio
import EventKit

@main struct EcoApp: App {
    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--diarize"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { // depuración: imprime quién habla y cuándo en un WAV
                do {
                    let m = OfflineDiarizerManager()
                    try await m.prepareModels()
                    for s in try await m.process(url).segments { print(s.speakerId, s.startTimeSeconds, s.endTimeSeconds) }
                    exit(0)
                } catch { print("error:", error); exit(1) }
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--demo-ai") { // depuración: resumen + notas ampliadas con una llamada de ejemplo
            Task {
                var c = Call(lines: [
                    Line(who: "Yo", text: "Bueno, hablemos del presupuesto del lanzamiento."),
                    Line(who: "Persona 1", text: "Tenemos cuarenta mil dólares aprobados, pero marketing pide diez mil más para anuncios."),
                    Line(who: "Yo", text: "¿Y las fechas?"),
                    Line(who: "Persona 1", text: "El lanzamiento se mueve al 15 de enero porque QA necesita dos semanas extra."),
                    Line(who: "Yo", text: "Ok, Ana se encarga de hablar con marketing antes del viernes."),
                ], myNotes: "- presupuesto\n- fecha lanzamiento")
                do {
                    try await Summarizer.fill(&c)
                    print("TÍTULO:", c.title, "\n", c.summary)
                    for e in try await Enhancer.enhance(c) ?? [] { print("NOTA:", e.note); e.details.forEach { print("   ·", $0) } }
                } catch { print("error:", error) }
                exit(0)
            }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--demo-chat") { // depuración: chat sobre dos reuniones de ejemplo (solo en memoria)
            Task { @MainActor in
                Store.shared.calls = [
                    Call(date: Date(timeIntervalSinceNow: -86400), title: "Revisión de ventas",
                         lines: [Line(who: "Persona 1", text: "Cerramos tres clientes nuevos este mes, el mayor es Grupo Norte.")],
                         names: ["Persona 1": "Luis"], summary: "**Resumen**\nTres clientes nuevos; el mayor es Grupo Norte.\n**Próximos pasos**\n- Luis: enviar contrato a Grupo Norte el lunes"),
                    Call(title: "Presupuesto del lanzamiento",
                         lines: [Line(who: "Persona 1", text: "Tenemos cuarenta mil aprobados y marketing pide diez mil más."),
                                 Line(who: "Yo", text: "El lanzamiento pasa al 15 de enero.")],
                         names: ["Persona 1": "Ana"], summary: "**Resumen**\nPresupuesto de 40.000 y lanzamiento el 15 de enero.\n**Próximos pasos**\n- Ana: hablar con marketing antes del viernes"),
                ]
                let chat = ChatModel()
                for q in ["¿Cuánto presupuesto tenemos y qué pide marketing?", "¿Qué pendientes tengo esta semana?", "¿Qué dijo Luis?"] {
                    chat.ask(q)
                    while chat.busy { try? await Task.sleep(for: .milliseconds(200)) }
                    print("P:", q); print("R:", chat.messages.last?.text ?? ""); print("Fuentes:", chat.messages.last?.sources.map(\.title) ?? []); print("---")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        MicWatcher.shared.start()
    }
    var body: some Scene {
        Window("Eco", id: "main") { RootView() }.defaultSize(width: 1000, height: 780).windowToolbarStyle(.unifiedCompact)
        MenuBarExtra { MenuContent() } label: { MenuIcon() }
    }
}

func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

// Estilo: columna central tipo documento, títulos con serifa y tarjetas suaves.
extension Font {
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
}

struct Avatar: View {
    let text: String
    var body: some View {
        let initial = text.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
        let hue = Double(text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) * 31 } % 360) / 360 // estable entre ejecuciones
        Text(initial).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MenuIcon: View {
    @ObservedObject var rec = Recorder.shared
    var body: some View { Image(systemName: rec.recording ? "waveform.circle.fill" : "waveform") }
}

struct MenuContent: View {
    @ObservedObject var rec = Recorder.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoDetect") private var autoDetect = true
    @AppStorage("autoStop") private var autoStop = true

    var body: some View {
        Text(rec.recording ? "Grabando: \(rec.call.title.isEmpty ? "llamada" : rec.call.title)" : rec.status)
        Button(rec.recording ? "Detener y resumir" : "Grabar llamada") {
            Task { rec.recording ? await rec.stop() : await rec.start() }
        }.disabled(rec.busy)
        Divider()
        Button("Abrir Eco") { openWindow(id: "main"); NSApp.activate() }
        Toggle("Detectar reuniones automáticamente", isOn: $autoDetect)
        Toggle("Detener sola al terminar la llamada", isOn: $autoStop)
        Divider()
        Button("Salir de Eco") { NSApp.terminate(nil) }.disabled(rec.recording || rec.busy)
    }
}

enum Route: Hashable { case live, call(UUID) }

struct RootView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var rec = Recorder.shared
    @Environment(\.openWindow) private var openWindow
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .live: RecordView(rec: rec)
                    case .call(let id):
                        if let c = store.calls.first(where: { $0.id == id }) {
                            CallView(draft: c, store: store) { path.removeAll() }.id(id)
                        }
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    path = [.live]
                    if !rec.recording { Task { await rec.start() } }
                } label: { Label(rec.recording ? "Grabando" : "Nueva nota", systemImage: rec.recording ? "record.circle" : "plus") }
                    .labelStyle(.titleAndIcon).disabled(rec.busy && !rec.recording)
            }
        }
        .onAppear { Nav.openMain = { openWindow(id: "main"); NSApp.activate() } }
        .onChange(of: rec.finished) { if let id = rec.finished { path = [.call(id)] } }
    }
}

// MARK: - Inicio

struct HomeView: View {
    @Binding var path: [Route]
    @ObservedObject private var store = Store.shared
    @ObservedObject private var rec = Recorder.shared
    @State private var events: [EKEvent] = []
    @State private var query = ""
    @StateObject private var chat = ChatModel()
    @State private var showChat = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Próximas").font(.serif(34)).padding(.top, 24)
                    upcoming
                    if rec.recording || rec.busy { liveCard }
                    history
                    Color.clear.frame(height: 90) // espacio para la barra de búsqueda
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 10) {
                if showChat { chatPanel }
                AskBar(text: $query, placeholder: "Busca o pregúntale a tus reuniones…", busy: chat.busy) {
                    chat.ask(query); query = ""; showChat = true
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 32).padding(.bottom, 20)
        }
        .task { events = await Agenda.upcoming() }
    }

    private var upcoming: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Date(), format: .dateTime.day()).font(.serif(40))
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(Date(), format: .dateTime.month(.wide)).font(.callout.weight(.medium))
                            Circle().fill(.red).frame(width: 6, height: 6)
                        }
                        Text(Date(), format: .dateTime.weekday(.wide)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 190, alignment: .leading)

                if events.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.secondary)
                        Text("No hay más reuniones hoy").foregroundStyle(.secondary)
                        Text("Revisa qué calendarios están visibles").font(.caption).foregroundStyle(.tertiary)
                        Button("Abrir Calendario") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(events, id: \.calendarItemIdentifier) { ev in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: ev.calendar.color)).frame(width: 3, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title ?? "Reunión").lineLimit(1)
                                    Text(timeRange(ev) + attendeesText(ev)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Grabar") { path = [.live]; Task { await rec.start(event: ev) } }
                                    .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(rec.recording || rec.busy)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var liveCard: some View {
        Button { path = [.live] } label: {
            Card {
                HStack(spacing: 12) {
                    if rec.recording { Circle().fill(.red).frame(width: 10, height: 10) } else { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.recording ? (rec.call.title.isEmpty ? "Grabando llamada" : rec.call.title) : "Procesando llamada")
                        Text(rec.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        }.buttonStyle(.plain)
    }

    private var filtered: [Call] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.calls }
        return store.calls.filter { c in
            [c.displayTitle, c.summary, c.myNotes, c.transcript, (c.attendees ?? []).joined(separator: " ")]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var history: some View {
        let days = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
        return VStack(alignment: .leading, spacing: 18) {
            if store.calls.isEmpty {
                Text("Tus reuniones aparecerán aquí. Pulsa “Nueva nota” o “Grabar” en una reunión.")
                    .foregroundStyle(.secondary).padding(.top, 8)
            } else if filtered.isEmpty {
                Text("Nada coincide con “\(query)”.").foregroundStyle(.secondary)
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                VStack(alignment: .leading, spacing: 2) {
                    Text(day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 6)
                    ForEach(days[day]!.sorted { $0.date > $1.date }) { c in
                        Button { path = [.call(c.id)] } label: { CallRow(call: c) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pregúntale a tus reuniones").font(.serif(18))
                Spacer()
                Button { showChat = false; chat.messages = [] } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 14)
            ChatView(chat: chat) { id in path = [.call(id)] }
        }
        .frame(height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func timeRange(_ ev: EKEvent) -> String {
        "\(ev.startDate.formatted(date: .omitted, time: .shortened)) – \(ev.endDate.formatted(date: .omitted, time: .shortened))"
    }
    private func attendeesText(_ ev: EKEvent) -> String {
        let a = Agenda.attendees(ev)
        return a.isEmpty ? "" : " · " + a.joined(separator: ", ")
    }
}

struct CallRow: View {
    let call: Call
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Avatar(text: call.attendees?.first ?? call.displayTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(call.date, format: .dateTime.hour().minute()).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(hover ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
    private var subtitle: String {
        if let a = call.attendees, !a.isEmpty { return a.joined(separator: ", ") }
        let people = call.speakers.filter { $0 != "Yo" }.map(call.name)
        return people.isEmpty ? "Solo tú" : people.joined(separator: ", ")
    }
}

// Encabezado de sección dentro de una nota.
struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.serif(20)).padding(.top, 10) }
}

// MARK: - Grabar

struct RecordView: View {
    @ObservedObject var rec: Recorder
    @AppStorage("localeID") private var localeID = "es-ES"
    @AppStorage("autoStop") private var autoStop = true
    @AppStorage("sendToNotes") private var sendToNotes = true
    @AppStorage("autoDetect") private var autoDetect = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(rec.call.title.isEmpty ? "Nueva nota" : rec.call.title).font(.serif(30)).lineLimit(1)
                Spacer()
                if rec.busy { ProgressView().controlSize(.small) }
                Button(rec.recording ? "Detener y resumir" : "Grabar") {
                    Task { rec.recording ? await rec.stop() : await rec.start() }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(rec.recording ? .red : .accentColor)
                .keyboardShortcut(.defaultAction).disabled(rec.busy)
            }
            HStack(spacing: 14) {
                if rec.recording { Label("Grabando", systemImage: "record.circle").foregroundStyle(.red) }
                if let a = rec.call.attendees, !a.isEmpty { Label(a.joined(separator: ", "), systemImage: "person.2").lineLimit(1) }
                Text(rec.status).foregroundStyle(.secondary).lineLimit(1)
            }.font(.callout)

            TextEditor(text: $rec.call.myNotes)
                .font(.title3).scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if rec.call.myNotes.isEmpty {
                        Text("Escribe tus notas… la IA las completará al terminar").font(.title3).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 180)

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcripción en vivo").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(rec.call.lines) { l in Text(md("**\(l.who):** \(l.text)")).textSelection(.enabled) }
                                ForEach(rec.live.sorted { $0.key > $1.key }, id: \.key) { who, text in
                                    Text(md("**\(who):** \(text)")).foregroundStyle(.secondary)
                                }
                                Color.clear.frame(height: 1).id("end")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: rec.call.lines.count) { proxy.scrollTo("end") }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 260)

            HStack(spacing: 16) {
                Picker("Idioma", selection: $localeID) {
                    Text("Español").tag("es-ES"); Text("Español (MX)").tag("es-MX"); Text("English").tag("en-US")
                }.fixedSize().disabled(rec.recording || rec.busy)
                Toggle("Enviar a Notas al terminar", isOn: $sendToNotes)
                Toggle("Detectar reuniones", isOn: $autoDetect)
                Toggle("Detener sola al colgar", isOn: $autoStop)
            }
            .toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 760)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
    }
}

// MARK: - Nota de una llamada

struct CallView: View {
    @State var draft: Call
    let store: Store
    let onDelete: () -> Void
    @StateObject private var chat: ChatModel
    @State private var question = ""
    @State private var showChat = false

    init(draft: Call, store: Store, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.store = store
        self.onDelete = onDelete
        _chat = StateObject(wrappedValue: ChatModel(scope: draft.id))
    }
    @State private var status = ""
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var editingNotes = false
    @State private var showTranscript = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Título", text: $draft.title).font(.serif(32)).textFieldStyle(.plain).padding(.top, 20)
                HStack(spacing: 14) {
                    Label(draft.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    let people = draft.speakers.filter { $0 != "Yo" }.map(draft.name)
                    if !people.isEmpty { Label(people.joined(separator: ", "), systemImage: "person.2").lineLimit(1) }
                    if draft.notesID != nil { Label("En Notas", systemImage: "note.text") }
                }
                .font(.callout).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }

                // Tus notas: tu texto + lo que añadió la IA en gris.
                SectionTitle(text: "Mis notas")
                VStack(alignment: .leading, spacing: 6) {
                    if let en = draft.enhanced, !editingNotes {
                        ForEach(Array(en.enumerated()), id: \.offset) { _, e in
                            Text(e.note).font(.body.weight(.semibold)).textSelection(.enabled).padding(.top, 4)
                            ForEach(e.details, id: \.self) { d in
                                Text("•  " + d).foregroundStyle(.secondary).padding(.leading, 12).textSelection(.enabled)
                            }
                        }
                        Text("En gris, lo que añadió la IA").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                    } else {
                        TextEditor(text: $draft.myNotes).font(.body).frame(minHeight: 90).scrollContentBackground(.hidden)
                            .padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        if draft.enhanced != nil {
                            Button(editingNotes ? "Listo" : "Editar") {
                                // Si cambiaste las notas, vuelve a ampliarlas.
                                if editingNotes, Enhancer.noteLines(draft.myNotes) != draft.enhanced?.map(\.note) { enhance() }
                                editingNotes.toggle()
                            }
                        }
                        Button("Mejorar con IA") { editingNotes = false; enhance() }
                            .disabled(draft.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).disabled(busy)
                }

                SectionTitle(text: "Resumen")
                Text(md(draft.summary.isEmpty ? "_Sin resumen_" : draft.summary))
                    .lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)

                let others = draft.speakers.filter { $0 != "Yo" }
                if !others.isEmpty {
                    SectionTitle(text: "Personas")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(others, id: \.self) { who in
                                HStack {
                                    Avatar(text: draft.name(who))
                                    Text(who).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                    TextField("Nombre", text: Binding(get: { draft.names[who] ?? "" }, set: { draft.names[who] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                    if let att = draft.attendees, !att.isEmpty {
                                        Menu("Invitados") { ForEach(att, id: \.self) { n in Button(n) { draft.names[who] = n } } }.fixedSize()
                                    }
                                }
                            }
                            Text("Pon los nombres y pulsa “Regenerar resumen” para que salgan en las notas.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showTranscript) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(draft.lines) { l in Text(md("**\(draft.name(l.who)):** \(l.text)")).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: { Text("Transcripción").font(.serif(20)) }
                .padding(.top, 10)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32).padding(.bottom, 110)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if showChat && !chat.messages.isEmpty {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Sobre esta reunión").font(.serif(18))
                            Spacer()
                            Button { showChat = false; chat.messages = [] } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.horizontal, 18).padding(.top, 14)
                        ChatView(chat: chat)
                    }
                    .frame(height: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                }
                AskBar(text: $question, placeholder: "Pregunta sobre esta reunión…", busy: chat.busy) {
                    chat.ask(question); question = ""; showChat = true
                }
            }
            .frame(maxWidth: 780).padding(.horizontal, 32).padding(.bottom, 20)
        }
        .toolbar {
            ToolbarItemGroup {
                if busy { ProgressView().controlSize(.small) }
                Button(draft.notesID == nil ? "Enviar a Notas" : "Actualizar en Notas", systemImage: "square.and.arrow.up") { sendToNotes() }.disabled(busy)
                if let id = draft.notesID { Button("Abrir en Notas", systemImage: "note.text") { AppleNotes.show(id) } }
                Menu {
                    Button("Regenerar resumen") { regenerate() }.disabled(busy)
                    Divider()
                    Button("Eliminar", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .navigationTitle("")
        .onChange(of: draft) { store.save(draft) }
        .confirmationDialog("¿Eliminar esta llamada del historial?", isPresented: $confirmDelete) {
            Button("Eliminar", role: .destructive) { store.delete(draft); onDelete() }
        } message: { Text("No se puede deshacer. La nota en Notas de Apple, si existe, no se borra.") }
    }

    private func sendToNotes() {
        do { draft.notesID = try AppleNotes.send(draft); status = "Enviado a Notas (carpeta Eco)" }
        catch { status = "No se pudo enviar a Notas: \(error.localizedDescription)" }
    }

    private func enhance() {
        busy = true; status = "Ampliando tus notas…"
        Task {
            do {
                let e = try await Enhancer.enhance(draft)
                draft.enhanced = e
                status = e == nil ? "Escribe alguna nota primero" : "Notas ampliadas"
            } catch { status = "Error al ampliar: \(error.localizedDescription)" }
            busy = false
        }
    }

    private func regenerate() {
        busy = true; status = "Resumiendo con Apple Intelligence…"
        Task {
            var c = draft
            do { try await Summarizer.fill(&c); draft = c; status = "Resumen actualizado" }
            catch { status = "Error al resumir: \(error.localizedDescription)" }
            busy = false
        }
    }
}
