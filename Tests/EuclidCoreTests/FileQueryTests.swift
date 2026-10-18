import Foundation
import Testing
@testable import EuclidCore

#if canImport(Darwin)
@Suite struct FileQueryTests {
    @Test func oneWordIsAPlainPredicate() throws {
        let p = try #require(FileQuery.predicate(for: "github"))
        #expect(!(p is NSCompoundPredicate))
        #expect(p.predicateFormat == #"kMDItemFSName LIKE[cd] "*github*""#)
    }

    @Test func severalWordsAreAnded() throws {
        let p = try #require(FileQuery.predicate(for: "readme  euclid") as? NSCompoundPredicate)
        #expect(p.compoundPredicateType == .and)
        #expect(p.subpredicates.count == 2)
    }

    @Test func noWordsIsNoQuery() {
        #expect(FileQuery.predicate(for: "   ") == nil)
    }

    /// Spotlight validates the predicate when scopes are set; a bad one throws an
    /// uncaught NSException (typing "github" used to crash the app this way).
    @Test(arguments: ["github", "gh swift", "readme euclid"])
    func spotlightAcceptsThePredicate(_ text: String) throws {
        let q = NSMetadataQuery()
        q.predicate = try #require(FileQuery.predicate(for: text))
        q.searchScopes = [NSMetadataQueryUserHomeScope]
    }
}
#endif
