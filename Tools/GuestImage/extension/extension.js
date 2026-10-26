// Runfern's bridge between VS Code and the iPad app: commands for the command palette. The app
// itself adds the "Runfern" entry to the status bar (EditorBridgeScript.swift).
//
// The editor runs in the app's web view. Opening a runfern:// link is the one channel the browser
// workbench offers to reach the host app: Runfern intercepts it and performs the action natively.
const vscode = require("vscode");

function openInApp(action) {
    return vscode.env.openExternal(vscode.Uri.parse(`runfern://${action}`));
}

function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand("runfern.overview", () => openInApp("overview")),
        vscode.commands.registerCommand("runfern.preview", () => openInApp("preview"))
    );
}

function deactivate() {}

module.exports = { activate, deactivate };
