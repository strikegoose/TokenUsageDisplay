import Foundation

struct ServiceConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: String  // UUID string
    var serviceType: ServiceType
    var displayName: String
    var isEnabled: Bool
    var keychainAccount: String  // Keychain account identifier for the API key

    init(id: String = UUID().uuidString,
         serviceType: ServiceType,
         displayName: String,
         isEnabled: Bool = true) {
        self.id = id
        self.serviceType = serviceType
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.keychainAccount = "\(serviceType.rawValue)-api-key-\(id)"
    }
}
