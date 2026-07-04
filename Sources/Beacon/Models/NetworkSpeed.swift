import Foundation

struct NetworkSpeed: Equatable {
    let timestamp: Date
    let downloadSpeed: Double
    let uploadSpeed: Double
    
    var downloadFormatted: String {
        FormatUtility.formatSpeed(downloadSpeed)
    }
    
    var uploadFormatted: String {
        FormatUtility.formatSpeed(uploadSpeed)
    }
}
