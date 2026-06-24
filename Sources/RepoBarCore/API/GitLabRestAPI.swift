import Foundation

public struct GitLabRestAPI {
    public static func projectsQueryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "membership", value: "true"),
            URLQueryItem(name: "order_by", value: "last_activity_at"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "simple", value: "false")
        ]
    }
}
