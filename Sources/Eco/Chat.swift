// Chat para preguntarle a tus reuniones. El modelo local tiene poco contexto, así que primero
// buscamos los fragmentos relevantes (por palabras, nombres y fechas) y solo esos van a la IA.
import SwiftUI
import FoundationModels

// MARK: - Búsqueda de fragmentos

struct Snippet {
    let call: Call
    let text: String
    var score = 0
}

enum Retriever {
    static let stop: Set<String> = ["que", "qué", "los", "las", "del", "con", "por", "para", "una", "uno", "unos", "como", "cómo",
        "pero", "sus", "este", "esta", "esto", "ese", "esa", "hay", "fue", "son", "era", "muy", "más", "mas", "sobre", "cual", "cuál",
        "cuales", "donde", "dónde", "cuando", "cuándo", "quien", "quién", "dijo", "dije", "reunion", "reunión", "reuniones",
        "llamada", "llamadas", "mis", "mi", "tengo", "tiene", "hablamos", "hablo", "habló", "dime", "the", "and", "what", "about"]

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    static func terms(_ s: String) -> Set<String> {
        let stopFolded = Set(stop.map(fold))
        return Set(fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stopFolded.contains($0) })
    }

    static func header(_ c: Call) -> String {
        "Reunión «\(c.displayTitle)» — \(c.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))"
    }

    /// Divide cada llamada en trozos (resumen, notas, ventanas de transcripción) y devuelve los mejores
    /// hasta `limit` caracteres. Si nada coincide, devuelve los resúmenes más recientes.
    static func search(_ question: String, in calls: [Call], limit: Int = 2800) -> [Snippet] {
        var t = terms(question)
        // "pendientes", "tareas"… viven en la sección "Próximos pasos" del resumen.
        if !t.isDisjoint(with: ["pendiente", "pendientes", "tarea", "tareas", "todo", "todos", "hacer", "acciones"]) { t.formUnion(["pasos", "proximos"]) }
        var units: [Snippet] = []
        for c in calls {
            let head = header(c) + ((c.attendees ?? []).isEmpty ? "" : " · Invitados: " + c.attendees!.joined(separator: ", "))
            var parts: [String] = []
            if !c.summary.isEmpty { parts.append(c.summary) }
            if let en = c.enhanced { parts.append(en.map { "\($0.note): \($0.details.joined(separator: "; "))" }.joined(separator: "\n")) }
            else if !c.myNotes.isEmpty { parts.append("Notas: " + c.myNotes) }
            let lines = c.lines.map { "\(c.name($0.who)): \($0.text)" }
            stride(from: 0, to: lines.count, by: 6).forEach { parts.append(lines[$0..<min($0 + 6, lines.count)].joined(separator: "\n")) }
            for p in parts {
                let words = terms(head + " " + p)
                units.append(Snippet(call: c, text: head + "\n" + p, score: t.intersection(words).count))
            }
        }
        var ranked = units.filter { $0.score > 0 }.sorted { ($0.score, $0.call.date) > ($1.score, $1.call.date) }
        if ranked.isEmpty { // pregunta genérica ("¿qué pendientes tengo?"): lo más reciente
            ranked = calls.sorted { $0.date > $1.date }.filter { !$0.summary.isEmpty }.map { Snippet(call: $0, text: header($0) + "\n" + $0.summary) }
        }
        var out: [Snippet] = [], used = 0
        for s in ranked where used + s.text.count <= limit || out.isEmpty {
            out.append(Snippet(call: s.call, text: String(s.text.prefix(limit)), score: s.score))
            used += min(s.text.count, limit)
        }
        return out
    }
}

// MARK: - Conversación

struct ChatMessage: Identifiable {
    let id = UUID()
    let fromUser: Bool
    var text: String
    var sources: [Call] = []
}

@MainActor final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    let scope: UUID?   // nil = todas las reuniones; si no, solo esa

    init(scope: UUID? = nil) { self.scope = scope }

    static let instructions = """
    Respondes preguntas del usuario sobre sus reuniones usando SOLO los fragmentos que se te dan. \
    "Yo" en las transcripciones es el usuario. Si la respuesta no está en los fragmentos, dilo claramente. \
    Responde en español, breve y directo; usa viñetas para listas. Indica de qué reunión sale cada dato \
    nombrando su título (sin copiar la fecha ni la hora completas).
    """

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        let calls = Store.shared.calls.filter { scope == nil || $0.id == scope }
        // Solo si la pregunta no trae palabras propias ("¿y qué más?") se busca con la anterior.
        let previous = messages.last(where: \.fromUser)?.text ?? ""
        let snippets = Retriever.search(Retriever.terms(q).isEmpty && !previous.isEmpty ? previous : q, in: calls)
        messages.append(ChatMessage(fromUser: true, text: q))
        guard !snippets.isEmpty else {
            messages.append(ChatMessage(fromUser: false, text: "Todavía no hay reuniones con resumen o transcripción para consultar."))
            return
        }
        guard SystemLanguageModel.default.isAvailable else {
            messages.append(ChatMessage(fromUser: false, text: "Apple Intelligence no está disponible. Actívalo en Ajustes del Sistema."))
            return
        }
        var sources: [Call] = []
        for s in snippets where !sources.contains(where: { $0.id == s.call.id }) { sources.append(s.call) }
        messages.append(ChatMessage(fromUser: false, text: "", sources: sources))
        let idx = messages.count - 1

        var prompt = "Hoy es \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year())).\n\n"
        if let lastAnswer = messages.dropLast(2).last(where: { !$0.fromUser })?.text, !previous.isEmpty {
            prompt += "Conversación anterior:\nUsuario: \(previous)\nTú: \(lastAnswer.prefix(500))\n\n"
        }
        prompt += "Fragmentos de las reuniones:\n" + snippets.map(\.text).joined(separator: "\n---\n") + "\n\nPregunta: \(q)"

        busy = true
        Task {
            defer { busy = false }
            do {
                // Sesión nueva en cada pregunta: el contexto del modelo local es pequeño.
                let session = LanguageModelSession(instructions: Self.instructions)
                for try await snap in session.streamResponse(to: prompt) { messages[idx].text = snap.content }
            } catch {
                messages[idx].text = "No pude responder: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Vista

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    var open: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { m in
                        if m.fromUser {
                            Text(m.text)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                if m.text.isEmpty {
                                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Buscando en tus reuniones…").foregroundStyle(.secondary) }
                                } else {
                                    Text(md(m.text)).textSelection(.enabled).lineSpacing(3)
                                }
                                if !m.sources.isEmpty {
                                    FlowSources(calls: m.sources, open: open)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(18)
            }
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct FlowSources: View {
    let calls: [Call]
    let open: (UUID) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("Fuentes").font(.caption).foregroundStyle(.tertiary)
            ForEach(calls.prefix(4), id: \.id) { c in
                Button { open(c.id) } label: {
                    Text(c.displayTitle).lineLimit(1).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Campo de pregunta con forma de cápsula (inicio y nota).
struct AskBar: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.title3).onSubmit(onSubmit)
            if busy { ProgressView().controlSize(.small) }
            else if !text.isEmpty {
                Button(action: onSubmit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
    }
}
