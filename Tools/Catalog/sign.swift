// Signs catalog files with Ed25519 so the app can verify their origin (Plan 4.2).
// sign-catalog.sh builds and runs it for Catalog/catalog.json on a Mac; verify-catalog.sh uses
// `verify` on a Mac without OpenSSL 3.
//
// Usage: xcrun swiftc -O sign.swift -o /tmp/runfern-sign
//        /tmp/runfern-sign keygen                                creates catalog_signing_key (never commit it)
//        /tmp/runfern-sign pubkey [<key file>]                   prints the public key to embed in the app
//        /tmp/runfern-sign sign <file> [<key file>]              writes <file>.sig
//        /tmp/runfern-sign verify <file> <signature> <public key>  checks a signature the way the app does
// <key file> defaults to catalog_signing_key next to this file.

import CryptoKit
import Foundation

let defaultKeyURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("catalog_signing_key")

func loadKey(_ path: String?) throws -> Curve25519.Signing.PrivateKey {
    let url = path.map { URL(fileURLWithPath: $0) } ?? defaultKeyURL
    let encoded = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: encoded)!)
}

let args = CommandLine.arguments
func argument(_ index: Int) -> String? { args.count > index ? args[index] : nil }

switch (argument(1) ?? "", argument(2), argument(3), argument(4)) {
case ("keygen", _, _, _):
    guard !FileManager.default.fileExists(atPath: defaultKeyURL.path) else { print("Key already exists."); exit(1) }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(to: defaultKeyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultKeyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("pubkey", let keyFile, _, _):
    print(try loadKey(keyFile).publicKey.rawRepresentation.base64EncodedString())
case ("sign", let file?, let keyFile, _):
    let signature = try loadKey(keyFile).signature(for: try Data(contentsOf: URL(fileURLWithPath: file)))
    try signature.base64EncodedString().write(toFile: file + ".sig", atomically: true, encoding: .utf8)
    print("Signed \(file)")
case ("verify", let file?, let signatureFile?, let publicKey?):
    // The same steps as CatalogVerifier in the app.
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey)!)
    let data = try Data(contentsOf: URL(fileURLWithPath: file))
    let encoded = try String(contentsOfFile: signatureFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: encoded), key.isValidSignature(signature, for: data) else {
        print("The signature doesn't match \(file).")
        exit(1)
    }
    print("Valid signature of \(file)")
default:
    print("Usage: keygen | pubkey [<key file>] | sign <file> [<key file>] | verify <file> <signature> <public key>")
    exit(2)
}
