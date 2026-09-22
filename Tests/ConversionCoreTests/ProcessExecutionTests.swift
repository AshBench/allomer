import Foundation
import XCTest

@testable import ConversionCore

final class ProcessExecutionTests: XCTestCase {
    func testExternalToolBoundsGeneratedFiles() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Generated files \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let arguments = ["if=/dev/zero", "of=\(work.appendingPathComponent("frame.png").path)", "bs=2048", "count=1"]
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/bin/dd"), arguments: arguments,
            workDirectory: work, workDirectoryByteLimit: 1024))
        XCTAssertNoThrow(try ExternalTool.run(URL(fileURLWithPath: "/bin/dd"), arguments: arguments,
            workDirectory: work, workDirectoryByteLimit: 4096))
    }
    func testCancellationStopsChildAndCleansLogs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task.detached {
            try ExternalTool.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], workDirectory: directory)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled process must not report success.")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func testExternalToolFailureAndTimeout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try ExternalTool.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["captured"],
            workDirectory: directory, captureOutput: true)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "captured\n")
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "1048577", "/dev/zero"], workDirectory: directory, captureOutput: true))
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [], workDirectory: directory))
        let streamed = directory.appendingPathComponent("output.xml")
        try ExternalTool.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["<root/>"], workDirectory: directory,
                             outputFile: streamed, outputLimit: 32)
        XCTAssertEqual(try String(contentsOf: streamed, encoding: .utf8), "<root/>\n")
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["overwrite"],
            workDirectory: directory, outputFile: streamed))
        XCTAssertEqual(try String(contentsOf: streamed, encoding: .utf8), "<root/>\n")
        try FileManager.default.removeItem(at: streamed)
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["too much output"],
            workDirectory: directory, outputFile: streamed, outputLimit: 4))
        try FileManager.default.removeItem(at: streamed)
        let start = Date()
        XCTAssertThrowsError(try ExternalTool.run(URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], workDirectory: directory, timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    func testCPUProfilesOnSmallAndLargeMachines() {
        for cores in [-1, 0, 1] {
            for profile in CPUProfile.allCases {
                XCTAssertEqual(profile.limits(activeCores: cores).jobs, 1)
                XCTAssertEqual(profile.limits(activeCores: cores).encoderThreads, 1)
            }
        }
        XCTAssertEqual(CPUProfile.medium.limits(activeCores: 2).jobs, 1)
        XCTAssertEqual(CPUProfile.medium.limits(activeCores: 2).encoderThreads, 2)
        XCTAssertEqual(CPUProfile.high.limits(activeCores: 4).encoderThreads, 3)
        for (profile, jobs, threads) in [(CPUProfile.low, 1, 1), (.medium, 2, 2), (.high, 3, 4)] {
            XCTAssertEqual(profile.limits(activeCores: 16).jobs, jobs)
            XCTAssertEqual(profile.limits(activeCores: 16).encoderThreads, threads)
        }
    }
}
