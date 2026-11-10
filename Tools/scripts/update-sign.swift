// Ed25519 keys and signatures for Duo's self-update (DuoKit AppUpdate).
//
//   xcrun swift Tools/scripts/update-sign.swift keygen [key-file]   new private key; prints the public key
//   xcrun swift Tools/scripts/update-sign.swift public [key-file]   prints the public key of a private key
//   xcrun swift Tools/scripts/update-sign.swift sign <file> [key-file]   prints the base64 signature of <file>
//
// The key file holds the raw 32-byte private key in base64 (default ~/.config/duo/update-ed25519.key).
// It never goes into the repository. The app trusts only AppUpdate.publicKey: losing the private key
// means users must reinstall with the install command once a new key ships.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let defaultKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/duo/update-ed25519.key")
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: update-sign.swift keygen|public|sign …") }
args.removeFirst()

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("cannot read the private key at \(path)") }
    return key
}

switch command {
case "keygen":
    let path = args.first ?? defaultKeyPath
    if FileManager.default.fileExists(atPath: path) { fail("\(path) exists; refusing to overwrite a signing key") }
    let key = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("cannot write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey(args.first ?? defaultKeyPath).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let file = args.first, let data = FileManager.default.contents(atPath: file) else { fail("usage: sign <file> [key-file]") }
    let key = loadKey(args.count > 1 ? args[1] : defaultKeyPath)
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    print(signature.base64EncodedString())
default:
    fail("unknown command \(command)")
}
