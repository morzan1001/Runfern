// Signs catalog files with Ed25519 so the app can verify their origin (Plan 4.2).
// sign-catalog.sh builds and runs it for Catalog/catalog.json.
//
// Usage: xcrun swiftc -O sign.swift -o /tmp/runfern-sign
//        /tmp/runfern-sign keygen          creates catalog_signing_key (never commit it)
//        /tmp/runfern-sign pubkey          prints the public key to embed in the app
//        /tmp/runfern-sign sign <file>     writes <file>.sig

import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("catalog_signing_key")

func loadKey() throws -> Curve25519.Signing.PrivateKey {
    let encoded = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: encoded)!)
}

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count > 2 ? args[2] : nil) {
case ("keygen", _):
    guard !FileManager.default.fileExists(atPath: keyURL.path) else { print("Key already exists."); exit(1) }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("pubkey", _):
    print(try loadKey().publicKey.rawRepresentation.base64EncodedString())
case ("sign", let file?):
    let signature = try loadKey().signature(for: try Data(contentsOf: URL(fileURLWithPath: file)))
    try signature.base64EncodedString().write(toFile: file + ".sig", atomically: true, encoding: .utf8)
    print("Signed \(file)")
default:
    print("Usage: keygen | pubkey | sign <file>")
    exit(2)
}
