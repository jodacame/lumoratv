import Foundation

/// Result of "Test connection" for an external service.
enum ServiceTest: Sendable, Equatable {
    case ok(String)
    case fail(String)

    var isOK: Bool { if case .ok = self { return true } else { return false } }
    var message: String {
        switch self {
        case .ok(let m), .fail(let m): return m
        }
    }
}
