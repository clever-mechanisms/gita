import Foundation
import Testing

@testable import GitaCore

@Test func websiteLinksCarryUTMTagsAndHideWithoutAHost() throws {
    #expect(ProductWebsite.url(host: nil, campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "", campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "clevermechanisms.dev", campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "https://gita.app", campaign: "about", content: "website") == nil)
    let home = try #require(ProductWebsite.url(host: "Gita.app", campaign: "about", content: "website"))
    #expect(
        home.absoluteString
            == "https://gita.app/?utm_source=gita&utm_medium=app&utm_campaign=about&utm_content=website")
    let notes = try #require(
        ProductWebsite.url(host: "gita.app", path: "changelog", campaign: "about", content: "release_notes"))
    #expect(
        notes.absoluteString
            == "https://gita.app/changelog?utm_source=gita&utm_medium=app&utm_campaign=about&utm_content=release_notes"
    )
}
