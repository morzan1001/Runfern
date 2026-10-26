import SwiftUI

struct HelpView: View {
    var body: some View {
        List {
            Section("Local on Your iPad") {
                Text("The editor, Linux, the terminal, and your programs run on this iPad. You only need the internet for new Linux bases, packages, or Git remotes.")
            }
            Section("Project and Environment") {
                Text("A project is your files. The environment is Linux with your tools. You can reset an environment without losing project files.")
            }
            Section("Saving") {
                Label("Saved locally: the change is stored durably in Runfern.", systemImage: "internaldrive")
                Label("Saved to folder: the change is also in the selected folder in Files.", systemImage: "checkmark.circle")
                Label("Conflict: both sides changed. Runfern keeps both versions until you decide.", systemImage: "exclamationmark.2")
            }
            Section("Switching Projects") {
                Text("Exactly one environment runs at a time. When you switch, Runfern saves your changes, shuts down the active environment cleanly, and starts the new project. Running processes are stopped.")
            }
            Section("Background") {
                Text("When you leave Runfern, iPadOS may pause running builds or servers. Saved files are not affected.")
            }
            #if RUNFERN_JIT
            Section("JIT Compilation") {
                Text("With JIT, Linux runs several times faster. Before the first Linux start after opening Runfern, its VPN connects briefly so a debugger can attach to Runfern; afterwards the VPN disconnects again.")
                Text("This needs a pairing file of this iPad, created once on a Mac that trusts it, for example with idevice_pair. Send it to the iPad and import it under Settings › Performance.")
            }
            #endif
        }
        .navigationTitle("How Runfern Works")
    }
}
