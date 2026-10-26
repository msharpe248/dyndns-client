import Darwin
import Foundation

struct Options {
    let hostname: String
    let ip: String
    let username: String
    let password: String
    let force: Bool

    static let usage = """
    Usage: dyndns-client [--hostname HOST] [--username USER] [--password KEY]
                         [--interface NAME] [--ip IPv4] [--config FILE] [--force]

    Missing values come from ~/Library/Application Support/dyndns-client/config.json.
    The config may hold hostname, username, password, and interface. An explicit
    --ip takes precedence over interface lookup. --force bypasses the local
    last-successful-IP check; use it only to resynchronize a host.
    """
}

struct Config: Decodable {
    var hostname: String?
    var username: String?
    var password: String?
    var interface: String?

    static func load(path: String?) throws -> Config {
        let url: URL
        if let path {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = try applicationDirectory().appendingPathComponent("config.json")
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            if path != nil { throw ClientError.message("Config file not found: \(url.path)") }
            return Config()
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw ClientError.message("Cannot check config file permissions: \(url.path)")
        }
        guard mode & 0o077 == 0 else {
            throw ClientError.message("Config file is readable by others: \(url.path). Run chmod 600 on it")
        }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw ClientError.message("Cannot read config file \(url.path): \(error.localizedDescription)")
        }
    }
}

struct CLIArguments {
    let values: [String: String]
    let force: Bool

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var values: [String: String] = [:]
        var force = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--force" {
                guard !force else { throw ClientError.message("Duplicate option: --force") }
                force = true
                index += 1
                continue
            }
            guard ["--hostname", "--ip", "--username", "--password", "--interface", "--config"].contains(argument) else {
                throw ClientError.message("Unknown option: \(argument)")
            }
            guard values[argument] == nil else {
                throw ClientError.message("Duplicate option: \(argument)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--") else {
                throw ClientError.message("Missing value for \(argument)")
            }
            values[argument] = arguments[index + 1]
            index += 2
        }

        return CLIArguments(values: values, force: force)
    }

    func resolve(config: Config, addressForInterface: (String) throws -> String) throws -> Options {
        func required(_ name: String, fallback: String?) throws -> String {
            guard let value = values[name] ?? fallback, !value.isEmpty else {
                throw ClientError.message("Missing \(name); provide it on the command line or in config.json")
            }
            return value
        }
        let hostname = try required("--hostname", fallback: config.hostname)
        let username = try required("--username", fallback: config.username)
        let password = try required("--password", fallback: config.password)
        let ip: String
        if let explicitIP = values["--ip"] {
            ip = explicitIP
        } else {
            let interface = try required("--interface", fallback: config.interface)
            ip = try addressForInterface(interface)
        }
        guard isValidHostname(hostname) else {
            throw ClientError.message("Hostname must be a fully qualified ASCII domain name")
        }
        guard isValidIPv4(ip) else {
            throw ClientError.message("IP must be a valid IPv4 address")
        }
        guard !username.contains(":"), !username.contains("\n"), !username.contains("\r") else {
            throw ClientError.message("Username contains invalid characters")
        }
        return Options(hostname: hostname, ip: ip, username: username,
                       password: password, force: force)
    }
}

enum ClientError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case .message(let text) = self { return text }
        return "Unknown error"
    }
}

func isValidHostname(_ hostname: String) -> Bool {
    guard hostname.utf8.count <= 253 else { return false }
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
        guard !label.isEmpty, label.utf8.count <= 63,
              let first = label.utf8.first, let last = label.utf8.last,
              isASCIILetterOrDigit(first), isASCIILetterOrDigit(last) else { return false }
        return label.utf8.allSatisfy { isASCIILetterOrDigit($0) || $0 == 45 }
    }
}

func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

func isValidIPv4(_ ip: String) -> Bool {
    var address = in_addr()
    return ip.withCString { inet_pton(AF_INET, $0, &address) == 1 }
}

func ipv4Address(for interface: String) throws -> String {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else {
        throw ClientError.message("Could not read network interfaces")
    }
    defer { freeifaddrs(first) }
    var foundInterface = false
    var addresses = Set<String>()
    var current = first
    while let entry = current {
        let item = entry.pointee
        if String(cString: item.ifa_name) == interface {
            foundInterface = true
            if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil {
                    addresses.insert(String(cString: buffer))
                }
            }
        }
        current = item.ifa_next
    }
    guard foundInterface else { throw ClientError.message("Network interface \(interface) was not found") }
    guard let address = addresses.first else {
        throw ClientError.message("Network interface \(interface) has no IPv4 address")
    }
    guard addresses.count == 1 else {
        throw ClientError.message("Network interface \(interface) has multiple IPv4 addresses; use --ip")
    }
    return address
}

func applicationDirectory() throws -> URL {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else {
        throw ClientError.message("Cannot find the user Application Support directory")
    }
    return support.appendingPathComponent("dyndns-client", isDirectory: true)
}

struct StateStore {
    let fileURL: URL

    static func defaultStore() throws -> StateStore {
        StateStore(fileURL: try applicationDirectory().appendingPathComponent("updates.json"))
    }

    private func read() throws -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    func lastIP(username: String, hostname: String) throws -> String? {
        try read()[username]?[hostname.lowercased()]
    }

    func save(ip: String, username: String, hostname: String) throws {
        var state = try read()
        state[username, default: [:]][hostname.lowercased()] = ip
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
    }
}

func makeRequest(options: Options) -> URLRequest {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "members.dyndns.org"
    components.path = "/nic/update"
    components.queryItems = [
        URLQueryItem(name: "hostname", value: options.hostname),
        URLQueryItem(name: "myip", value: options.ip),
    ]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    let credentials = Data("\(options.username):\(options.password)".utf8).base64EncodedString()
    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    request.setValue("Personal - macOS DynDNS Client - 0.1", forHTTPHeaderField: "User-Agent")
    return request
}

func interpretResponse(data: Data, statusCode: Int, requestedIP: String) throws -> String {
    guard let body = String(data: data, encoding: .utf8) else {
        throw ClientError.message("Dyn returned a response that is not UTF-8")
    }
    let fields = body.split(whereSeparator: \.isWhitespace).map(String.init)
    let code = fields.first ?? ""
    let errors: [String: String] = [
        "badauth": "Dyn rejected the username or updater client key",
        "nohost": "This hostname is not in the account or cannot be updated",
        "notfqdn": "Dyn rejected the hostname as invalid",
        "numhost": "Dyn found an ambiguous hostname record",
        "abuse": "Dyn has blocked updates for this hostname",
        "badagent": "Dyn rejected this updater client",
        "badsys": "Dyn rejected the update system",
        "!donator": "This Dyn account cannot use a requested feature",
        "dnserr": "Dyn could not complete the DNS update; wait before retrying",
        "911": "Dyn is temporarily unavailable; wait at least 30 minutes before retrying",
    ]
    if let message = errors[code] { throw ClientError.message("\(code): \(message)") }
    guard statusCode == 200 else {
        throw ClientError.message("Dyn returned HTTP \(statusCode) with response: \(body.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard code == "good" || code == "nochg", fields.count == 2 else {
        throw ClientError.message("Unexpected Dyn response: \(body.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    guard fields[1] == requestedIP else {
        throw ClientError.message("Dyn reported \(fields[1]) instead of the requested IP \(requestedIP)")
    }
    return code
}

func describeRuntimeError(_ error: Error) -> String {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut:
            return "Timed out contacting members.dyndns.org:443. Check your Internet connection, DNS, VPN, and firewall. The update may have reached Dyn, so verify the record before retrying."
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not resolve members.dyndns.org. Check your DNS and Internet connection."
        default:
            return "Network request failed: \(urlError.localizedDescription)"
        }
    }
    return String(describing: error)
}

@main
struct DynDNSClient {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(Options.usage)
            return
        }
        let options: Options
        do {
            let cli = try CLIArguments.parse(arguments)
            let config = try Config.load(path: cli.values["--config"])
            options = try cli.resolve(config: config, addressForInterface: ipv4Address)
        } catch {
            fputs("Error: \(error)\n\n\(Options.usage)\n", stderr)
            exit(2)
        }
        do {
            let store = try StateStore.defaultStore()
            if !options.force,
               try store.lastIP(username: options.username, hostname: options.hostname) == options.ip {
                print("Skipped \(options.hostname): \(options.ip) was already updated by this client")
                return
            }
            let (data, response) = try await URLSession.shared.data(for: makeRequest(options: options))
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError.message("Dyn did not return an HTTP response")
            }
            let code = try interpretResponse(data: data, statusCode: httpResponse.statusCode,
                                             requestedIP: options.ip)
            try store.save(ip: options.ip, username: options.username, hostname: options.hostname)
            print(code == "good" ? "Updated \(options.hostname) to \(options.ip)" :
                  "\(options.hostname) is already set to \(options.ip)")
        } catch {
            fputs("Error: \(describeRuntimeError(error))\n", stderr)
            exit(1)
        }
    }
}
