import Darwin
import Foundation

struct Sample: Encodable {
    let elapsedSeconds: Double
    let physicalFootprintBytes: UInt64
    let userCPUTimeNanoseconds: UInt64
    let systemCPUTimeNanoseconds: UInt64
    let totalCPUTimeNanoseconds: UInt64
}

struct Report: Encodable {
    let pid: Int32
    let requestedDurationSeconds: Double
    let intervalSeconds: Double
    let sampleCount: Int
    let samples: [Sample]
}

struct MeasurementError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func usage(for pid: pid_t) throws -> rusage_info_v2 {
    // libproc's rusage_info_t* is an ABI spelling for the caller's struct buffer,
    // not an out-parameter receiving an allocated pointer. V2 determines its exact size.
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { buffer in
        buffer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V2), $0)
        }
    }
    guard result == 0 else {
        let failure = errno
        throw MeasurementError("proc_pid_rusage failed for PID \(pid): \(String(cString: strerror(failure))) (errno \(failure))")
    }
    return info
}

func nanoseconds(_ ticks: UInt64, timebase: mach_timebase_info_data_t) throws -> UInt64 {
    let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
    let denominator = UInt64(timebase.denom)
    guard product.high < denominator else { throw MeasurementError("CPU time conversion overflow") }
    return denominator.dividingFullWidth(product).quotient
}

func run(arguments: [String]) throws {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        guard key == "--pid" || key == "--seconds" else { throw MeasurementError("Unknown option: \(key)") }
        guard options[key] == nil else { throw MeasurementError("Duplicate option: \(key)") }
        guard index + 1 < arguments.count else { throw MeasurementError("Missing value for \(key)") }
        options[key] = arguments[index + 1]; index += 2
    }
    guard let pidText = options["--pid"],
          let pid = pidText == "self" ? getpid() : Int32(pidText), pid > 0 else {
        throw MeasurementError("--pid must be a positive PID or self")
    }
    let durationText = options["--seconds"] ?? "10"
    guard let duration = Double(durationText), duration.isFinite, duration > 0, duration <= 3600 else {
        throw MeasurementError("--seconds must be a number greater than 0 and at most 3600")
    }
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
        throw MeasurementError("Could not obtain the Mach clock timebase")
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let count = max(2, Int(ceil(duration)) + 1)
    let interval = duration / Double(count - 1)
    var samples: [Sample] = []
    var processStart: UInt64?
    var previousCPU: UInt64 = 0
    for index in 0..<count {
        let deadline = interval * Double(index)
        // Schedule from a monotonic origin; sampling work does not accumulate sleep drift.
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if deadline > elapsed { Thread.sleep(forTimeInterval: deadline - elapsed) }
        let info = try usage(for: pid)
        if let processStart, info.ri_proc_start_abstime != processStart {
            throw MeasurementError("PID identity changed during sampling; no mixed-process report emitted")
        }
        processStart = info.ri_proc_start_abstime
        let user = try nanoseconds(info.ri_user_time, timebase: timebase)
        let system = try nanoseconds(info.ri_system_time, timebase: timebase)
        let total = user.addingReportingOverflow(system)
        guard !total.overflow, total.partialValue >= previousCPU else {
            throw MeasurementError("CPU counter overflow or regression")
        }
        previousCPU = total.partialValue
        samples.append(Sample(
            elapsedSeconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9,
            physicalFootprintBytes: info.ri_phys_footprint,
            userCPUTimeNanoseconds: user,
            systemCPUTimeNanoseconds: system,
            totalCPUTimeNanoseconds: total.partialValue
        ))
    }
    let report = Report(pid: pid, requestedDurationSeconds: duration, intervalSeconds: interval,
                        sampleCount: samples.count, samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = "MeasureProcess: \(error)\nUsage: MeasureProcess --pid PID|self [--seconds SECONDS]\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
