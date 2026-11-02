import SwiftUI
import UIKit

/// Lists, adds, replaces, and removes Git credentials (SET05).
struct CredentialsView: View {
    @Environment(CredentialStore.self) private var store
    @State private var editing: CredentialDraft?
    @State private var credentialToRemove: Credential?
    @State private var removeError: String?

    var body: some View {
        Form {
            if !store.credentials.isEmpty {
                Section {
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
                        .swipeActions(allowsFullSwipe: false) {
                            // Not `role: .destructive`, so the row stays until the person confirms (as in the sidebar).
                            Button("Remove", systemImage: "trash") { credentialToRemove = credential }
                                .tint(.red)
                        }
                        .contextMenu {
                            Button("Replace Token…", systemImage: "key") {
                                editing = CredentialDraft(host: credential.host, username: credential.username, isReplacing: true)
                            }
                            Divider()
                            Button("Remove…", systemImage: "trash", role: .destructive) { credentialToRemove = credential }
                        }
                        // On the row, not the Section, so only this row presents it and the popover points at it.
                        .confirmationDialog("Remove Credential?",
                                            isPresented: Binding(get: { credentialToRemove?.id == credential.id },
                                                                 set: { if !$0 { credentialToRemove = nil } }),
                                            titleVisibility: .visible) {
                            Button("Remove", role: .destructive) { remove(credential) }
                        } message: {
                            Text("Runfern can no longer clone from or push to \(credential.host) with it.")
                        }
                    }
                } footer: {
                    Text("Stored only in this iPad’s keychain, never in exports or reports.")
                }
            }
        }
        .overlay {
            if store.credentials.isEmpty {
                ContentUnavailableView {
                    Label("No Credentials", systemImage: "key")
                } description: {
                    Text("Add a token to clone and push private repositories.")
                } actions: {
                    Button("Add Credential") { editing = CredentialDraft() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Git Credentials")
        .toolbar {
            Button("Add Credential", systemImage: "plus") { editing = CredentialDraft() }
        }
        .sheet(item: $editing) { draft in
            CredentialEditor(draft: draft)
        }
        .errorAlert("Couldn't Remove Credential", message: $removeError)
    }

    private func remove(_ credential: Credential) {
        do {
            try store.remove(credential)
        } catch {
            removeError = error.localizedDescription
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
    private nonisolated enum Field: Hashable {
        case host, username, token
    }

    @Environment(CredentialStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: CredentialDraft
    @State private var secret = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Field?

    /// Anything typed that Cancel or a swipe down would throw away (A2). A blank sheet closes without asking.
    private var hasInput: Bool {
        !secret.isEmpty || (!draft.isReplacing && (!draft.host.isEmpty || !draft.username.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.isReplacing {
                        LabeledContent("Host", value: draft.host)
                        LabeledContent("User Name", value: draft.username)
                    } else {
                        TextField("Host, e.g. github.com", text: $draft.host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .host)
                        TextField("User Name", text: $draft.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .username)
                    }
                    if draft.isReplacing {
                        SecureField("New Token", text: $secret)
                            .focused($focused, equals: .token)
                    } else {
                        SecureField("Token", text: $secret)
                            .focused($focused, equals: .token)
                    }
                } footer: {
                    Text("Use a personal access token with the narrowest scope your work requires.")
                }
            }
            .navigationTitle(draft.isReplacing ? Text("Replace Token") : Text("Add Credential"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasInput)
            .errorAlert("Couldn't Save Credential", message: $errorMessage)
            .onAppear { focused = draft.isReplacing ? .token : .host }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasInput)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm, action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(secret.isEmpty || isBlank(draft.host) || isBlank(draft.username))
                }
            }
        }
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        do {
            try store.save(host: draft.host, username: draft.username, secret: secret)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
