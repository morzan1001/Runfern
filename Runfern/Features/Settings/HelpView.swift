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
                Text("With JIT, Linux runs several times faster. With the Built-In method, Runfern’s VPN connects briefly before the first Linux start after opening Runfern, so a debugger can attach to Runfern; afterwards the VPN disconnects again. The first time, and after Reset Developer Disk Image, this downloads the Developer Disk Image from the internet.")
                Text("It needs Wi-Fi and a pairing file of this iPad (a Remote Pairing file, not a lockdown record).")
                if OnDevicePairing.isSupported {
                    Text("Runfern Settings › Performance › Set Up JIT does everything else: Runfern adds its VPN, appears in the Settings app under Privacy & Security › Developer Mode, where you confirm the pairing with the code Runfern shows, and checks that JIT works.")
                }
                Text("On a computer the iPad trusts, create it with Tools/JIT/create-pairing-file.sh from Runfern’s source, idevice_pair, or iloader, and import it under Runfern Settings › Performance › Built-In JIT. Create a new pairing file after changing or removing the iPad’s passcode.")
            }
            #endif
        }
        .navigationTitle("How Runfern Works")
    }
}
