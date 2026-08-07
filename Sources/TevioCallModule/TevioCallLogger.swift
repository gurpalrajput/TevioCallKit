import Foundation

struct DefaultCallLogger: CallLogging {
    func log(_ category: String, message: String, context: [String: String]) {
        let contextString = context
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        if contextString.isEmpty {
            print("[TevioCall.\(category)] \(message)")
        } else {
            print("[TevioCall.\(category)] \(message) \(contextString)")
        }
    }
}
