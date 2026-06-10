import Foundation
import Darwin

enum Metrics {

  /// Cumulative user+system CPU time for the current process, in seconds.
  static func processCPUSeconds() -> Double {
    var info = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
      ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound)
      }
    }
    guard ok == 0 else { return 0 }
    let userNs = info.ri_user_time
    let sysNs  = info.ri_system_time
    return Double(userNs + sysNs) / 1_000_000_000.0
  }

  /// Resident set size for the current process, in bytes.
  static func processRSSBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard ok == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
  }
}
