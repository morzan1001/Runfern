import SwiftUI

/// Lists, adds, replaces, and removes Git credentials (SET05).
struct CredentialsView: View {
    @Environment(CredentialStore.self) private var store
    @State private var editing: CredentialDraft?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if store.credentials.isEmpty {
                    ContentUnavailableView("No Credentials", systemImage: "key",
                                           description: Text("Add a token to clone and push private repositories."))
                        .listRowBackground(Color.clear)
                }
                ForEach(store.credentials) { credential in
                    Button {
                        editing = CredentialDraft(host: credential.host, username: credential.username, isReplacing: true)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(credential.host).foregroundStyle(.primary)
                            Text("\(credential.username) · \(credential.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { remove(credential) }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } footer: {
                Text("Stored only in this iPad’s keychain, never in exports or reports.")
            }
        }
        .navigationTitle("Git Credentials")
        .toolbar {
            Button("Add Credential", systemImage: "plus") { editing = CredentialDraft() }
        }
        .sheet(item: $editing) { draft in
            CredentialEditor(draft: draft)
        }
    }

    private func remove(_ credential: Credential) {
        do {
            try store.remove(credential)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CredentialDraft: Identifiable {
    let id = UUID()
    var host = ""
    var username = ""
    var isReplacing = false
}

private struct CredentialEditor: View {
    @Environment(CredentialStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: CredentialDraft
    @State private var secret = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host, e.g. github.com", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(draft.isReplacing)
                    TextField("User Name", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(draft.isReplacing)
                    SecureField(draft.isReplacing ? "New Token" : "Token", text: $secret)
                } footer: {
                    Text("Use a personal access token with the narrowest scope your work requires.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(draft.isReplacing ? "Replace Token" : "Add Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try store.save(host: draft.host, username: draft.username, secret: secret)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(secret.isEmpty)
                }
            }
        }
    }
}
