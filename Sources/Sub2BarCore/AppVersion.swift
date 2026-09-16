import Foundation

public enum AppVersion {
    public static func display(in info: [String: Any]?) -> String {
        for field in ["Sub2BarVersion", "CFBundleShortVersionString"] {
            if let value = info?[field] as? String, !value.isEmpty { return value }
        }
        return "开发版"
    }
}
