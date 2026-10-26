import Foundation
import Testing
@testable import DynDNSClient

private func parseOptions(_ arguments: [String]) throws -> Options {
    try CLIArguments.parse(arguments).resolve(config: Config()) { _ in
        throw ClientError.message("Unexpected interface lookup")
    }
}

@Test func parsesValidArgumentsAndRejectsInvalidInput() throws {
    let options = try parseOptions([
        "--hostname", "home.example.com", "--ip", "8.8.8.8",
        "--username", "alice", "--password", "secret",
    ])
    #expect(options.hostname == "home.example.com")
    #expect(options.ip == "8.8.8.8")
    #expect(throws: ClientError.self) {
        try parseOptions([
            "--hostname", "bad/host.example.com", "--ip", "8.8.8.8",
            "--username", "alice", "--password", "secret",
        ])
    }
    #expect(throws: ClientError.self) {
        try parseOptions([
            "--hostname", "home.example.com", "--ip", "999.0.0.1",
            "--username", "alice", "--password", "secret",
        ])
    }
    let localOptions = try parseOptions([
        "--hostname", "home.example.com", "--ip", "192.168.1.207",
        "--username", "alice", "--password", "secret",
    ])
    #expect(localOptions.ip == "192.168.1.207")
}

@Test func requestUsesHTTPSAndBasicAuthentication() throws {
    let options = try parseOptions([
        "--hostname", "home.example.com", "--ip", "8.8.8.8",
        "--username", "alice", "--password", "secret",
    ])
    let request = makeRequest(options: options)
    #expect(request.url?.scheme == "https")
    #expect(request.url?.host == "members.dyndns.org")
    #expect(request.url?.path == "/nic/update")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ==
            [URLQueryItem(name: "hostname", value: "home.example.com"),
             URLQueryItem(name: "myip", value: "8.8.8.8")])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6c2VjcmV0")
    #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
}

@Test func interpretsSuccessAndErrors() throws {
    #expect(try interpretResponse(data: Data("good 8.8.8.8\n".utf8),
                                  statusCode: 200, requestedIP: "8.8.8.8") == "good")
    #expect(try interpretResponse(data: Data("nochg 8.8.8.8\n".utf8),
                                  statusCode: 200, requestedIP: "8.8.8.8") == "nochg")
    #expect(throws: ClientError.self) {
        try interpretResponse(data: Data("badauth\n".utf8),
                              statusCode: 401, requestedIP: "8.8.8.8")
    }
    #expect(throws: ClientError.self) {
        try interpretResponse(data: Data("good 127.0.0.1\n".utf8),
                              statusCode: 200, requestedIP: "8.8.8.8")
    }
    #expect(throws: ClientError.self) {
        try interpretResponse(data: Data("911\n".utf8),
                              statusCode: 500, requestedIP: "8.8.8.8")
    }
}

@Test func remembersLastSuccessfulIPPerAccountAndHostname() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(fileURL: directory.appendingPathComponent("updates.json"))
    #expect(try store.lastIP(username: "alice", hostname: "home.example.com") == nil)
    try store.save(ip: "8.8.8.8", username: "alice", hostname: "Home.Example.Com")
    #expect(try store.lastIP(username: "alice", hostname: "home.example.com") == "8.8.8.8")
    #expect(try store.lastIP(username: "bob", hostname: "home.example.com") == nil)
}

@Test func timeoutMessageGivesActionableAdvice() {
    let message = describeRuntimeError(URLError(.timedOut))
    #expect(message.contains("Timed out contacting members.dyndns.org:443"))
    #expect(!message.contains("Usage:"))
}

@Test func configSuppliesMissingValuesAndCLIOverridesThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("config.json")
    try Data(#"{"hostname":"home.example.com","username":"alice","password":"secret","interface":"en0"}"#.utf8)
        .write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let config = try Config.load(path: file.path)

    let defaults = try CLIArguments.parse([]).resolve(config: config) { name in
        #expect(name == "en0")
        return "192.168.1.207"
    }
    #expect(defaults.hostname == "home.example.com")
    #expect(defaults.username == "alice")
    #expect(defaults.password == "secret")
    #expect(defaults.ip == "192.168.1.207")

    let overridden = try CLIArguments.parse([
        "--hostname", "other.example.com", "--interface", "en1", "--ip", "192.168.1.159",
    ]).resolve(config: config) { _ in
        Issue.record("Explicit --ip must bypass interface lookup")
        return "127.0.0.1"
    }
    #expect(overridden.hostname == "other.example.com")
    #expect(overridden.ip == "192.168.1.159")

    let selectedInterface = try CLIArguments.parse(["--interface", "en1"])
        .resolve(config: config) { name in
            #expect(name == "en1")
            return "192.168.1.159"
        }
    #expect(selectedInterface.ip == "192.168.1.159")
}

@Test func configRequiresPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("config.json")
    try Data(#"{"password":"secret"}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: ClientError.self) { try Config.load(path: file.path) }
}

@Test func readsIPv4FromNamedInterface() throws {
    #expect(try ipv4Address(for: "lo0") == "127.0.0.1")
    #expect(throws: ClientError.self) { try ipv4Address(for: "no-such-interface") }
}
