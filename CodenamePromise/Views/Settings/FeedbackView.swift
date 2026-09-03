import CodenamePromiseCore
import MessageUI
import SwiftUI

/// The way a user reaches a human.
///
/// This is deliberately the whole of the analytics story for now. Instrumenting a journaling
/// app means either sending behaviour off the device or claiming less on Apple's privacy
/// questionnaire, and "data not collected" is one of the strongest things this product can
/// truthfully say. A person telling you what went wrong is worth more than a funnel chart,
/// and costs nobody their privacy.
///
/// The diagnostics attached are the app version, the device model and the OS &mdash; nothing
/// about entries, ever &mdash; and they are shown in full before anything is sent, because a
/// journaling app that quietly attaches unknown data to an email has missed the point.
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var kind: Kind = .idea
    @State private var message = ""
    @State private var showingDiagnostics = false

    /// Where feedback goes. One address, changed in one place.
    /// **Placeholder. This has to be a real address before submission.**
    ///
    /// As it stands the feedback button opens a mail composer addressed to a domain reserved
    /// for documentation, so every message a user sends goes nowhere and they get no bounce
    /// telling them so. It is also one of the two places the contact has to exist for App
    /// Review and for Notion's integration review; the other is the privacy policy at
    /// https://sosaagbontaen.github.io/codename_promise/privacy.html
    static let address = "hello@example.com"

    enum Kind: String, CaseIterable, Identifiable {
        case idea = "An idea"
        case problem = "Something's broken"
        case hello = "Just saying hello"

        var id: String { rawValue }
        var subjectTag: String {
            switch self {
            case .idea: "Feature request"
            case .problem: "Bug report"
            case .hello: "Hello"
            }
        }
        var prompt: String {
            switch self {
            case .idea: "What would you like it to do?"
            case .problem: "What happened, and what did you expect instead?"
            case .hello: "Anything at all."
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 150)
                        .overlay(alignment: .topLeading) {
                            if message.isEmpty {
                                Text(kind.prompt)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section {
                    DisclosureGroup("What gets attached", isExpanded: $showingDiagnostics) {
                        Text(Diagnostics.current.description)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Nothing from your entries is ever included: not text, not titles, not recordings.")
                }

                Section {
                    Button {
                        send()
                    } label: {
                        Label("Compose the email", systemImage: "envelope")
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("This opens your mail app with the message ready. Nothing is sent until you send it.")
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func send() {
        let subject = "\(Bundle.main.appDisplayName): \(kind.subjectTag)"
        let body = """
        \(message)

        ---
        \(Diagnostics.current.description)
        """

        var components = URLComponents(string: "mailto:\(Self.address)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components?.url {
            openURL(url)
            dismiss()
        }
    }
}

/// The only thing ever attached to feedback. Deliberately tiny, and printable in full so the
/// person can read exactly what they are sending.
struct Diagnostics {
    let appVersion: String
    let build: String
    let system: String
    let model: String

    static var current: Diagnostics {
        Diagnostics(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            model: UIDevice.current.model
        )
    }

    var description: String {
        """
        app      \(appVersion) (\(build))
        system   \(system)
        device   \(model)
        """
    }
}
