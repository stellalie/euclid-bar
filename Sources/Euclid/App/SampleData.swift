import EuclidCore

/// Step 1 placeholder data. Replaced by the clipboard store in step 2.
/// Padded to 5k rows so speed is measured against a realistic history size.
enum SampleData {
    static func make() -> [SearchItem] {
        let real = [
            "git rebase -i HEAD~3",
            "https://staging.example.com/dashboard?tab=metrics",
            "kubectl get pods -n production",
            "SELECT * FROM users WHERE created_at > now() - interval '7 days';",
            "docker compose up -d --build",
            "ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.4.12",
            "export AWS_PROFILE=dev",
            "Café meeting notes: ship v1 by Friday",
            "npm install --save-dev typescript",
            "https://developer.apple.com/documentation/appkit/nspanel",
            "brew install sqlite",
            "{\"name\": \"euclid\", \"version\": \"0.1.0\"}",
        ]
        let words = ["alpha", "build", "commit", "deploy", "error", "fetch", "lambda", "query", "token", "update"]
        var items = real.enumerated().map { SearchItem(id: $0.offset, title: $0.element, subtitle: "sample") }
        for i in 0..<(5_000 - real.count) {
            let title = (0..<8).map { words[($0 * 3 + i * 7) % words.count] }.joined(separator: " ") + " #\(i)"
            items.append(SearchItem(id: real.count + i, title: title, subtitle: "synthetic"))
        }
        return items
    }
}
