import Foundation

public enum BugReportURL {
    public static func build(
        appVersion: String,
        osVersion: String,
        repo: String = "Shpigford/clearly"
    ) -> URL {
        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        let items: [URLQueryItem] = [
            .init(name: "template", value: "bug_report.yml"),
            .init(name: "app-version", value: appVersion),
            .init(name: "os-version", value: osVersion),
        ]
        components.queryItems = items
        return components.url!
    }
}
