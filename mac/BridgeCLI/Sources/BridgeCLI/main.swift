import Foundation
import BridgeCore

struct CLIOptions {
    let server: URL
    let workspace: URL
    let name: String
    let pairingCode: String
}

@main
struct BridgeCLI {
    static func main() async {
        do {
            let options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
            let config = BridgeConfiguration(
                serverURL: options.server,
                deviceName: options.name,
                workspaceRoot: options.workspace,
                pairingCode: options.pairingCode
            )

            let bridge = BridgeCore(configuration: config)
            await bridge.setStatusHandler { snapshot in
                print("[status] connection=\(snapshot.connectionState) paired=\(snapshot.paired) deviceId=\(snapshot.deviceId) lastExitCode=\(snapshot.lastExitCode.map(String.init) ?? "n/a")")
            }
            await bridge.setLogHandler { line in
                print("[bridge] \(line)")
            }

            print("Abyss Bridge CLI")
            print("Server: \(options.server.absoluteString)")
            print("Workspace: \(options.workspace.path)")
            print("Name: \(options.name)")
            print("Pairing code: \(options.pairingCode)")
            print("Enter this code in iOS -> Settings -> Pair Computer.")

            await bridge.start()
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                source.setEventHandler {
                    continuation.resume()
                }
                source.resume()
            }
            await bridge.stop()
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private func parseArgs(_ args: [String]) throws -> CLIOptions {
    var server: String?
    var workspace: String?
    var name: String?
    var pairingCode: String?

    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--server":
            index += 1
            server = value(at: index, in: args)
        case "--workspace":
            index += 1
            workspace = value(at: index, in: args)
        case "--name":
            index += 1
            name = value(at: index, in: args)
        case "--pairing":
            index += 1
            pairingCode = value(at: index, in: args)
        case "--help", "-h":
            printUsageAndExit()
        default:
            throw NSError(domain: "BridgeCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(arg)"])
        }
        index += 1
    }

    guard let serverRaw = server, let serverURL = URL(string: serverRaw) else {
        throw NSError(domain: "BridgeCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--server ws://host:port/ws is required"])
    }

    guard let workspaceRaw = workspace else {
        throw NSError(domain: "BridgeCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "--workspace /path is required"])
    }

    let deviceName = name ?? Host.current().localizedName ?? "Abyss CLI"
    let code = (pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()).flatMap { $0.isEmpty ? nil : $0 }
        ?? generatePairingCode()

    return CLIOptions(
        server: serverURL,
        workspace: URL(fileURLWithPath: workspaceRaw),
        name: deviceName,
        pairingCode: code
    )
}

private func value(at index: Int, in args: [String]) -> String? {
    guard args.indices.contains(index) else {
        return nil
    }
    return args[index]
}

private func generatePairingCode() -> String {
    let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<6).map { _ in alphabet.randomElement()! })
}

private func printUsageAndExit() -> Never {
    print("Usage: abyss-bridge --server ws://localhost:8080/ws --workspace /path --name \"My Mac\" [--pairing ABC123]")
    exit(0)
}
