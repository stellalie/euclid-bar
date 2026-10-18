import Foundation

#if canImport(Darwin) // NSPredicate(format:) and Spotlight are Apple-only
/// Spotlight predicates for file search by name.
public enum FileQuery {
    /// Every word must appear in the name: "readme euclid" finds euclid-bar/README.md's siblings too.
    /// One word is a plain predicate: Spotlight throws on an AND with a single subpredicate.
    public static func predicate(for text: String) -> NSPredicate? {
        let words = text.split(separator: " ").map {
            NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", "*\($0)*")
        }
        switch words.count {
        case 0: return nil
        case 1: return words[0]
        default: return NSCompoundPredicate(andPredicateWithSubpredicates: words)
        }
    }
}
#endif
