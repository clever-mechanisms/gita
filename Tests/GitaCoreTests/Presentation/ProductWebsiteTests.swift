import Foundation
import Testing

@testable import GitaCore

@Test func websiteLinksCarryUTMTagsAndHideWithoutAHost() throws {
    #expect(ProductWebsite.url(host: nil, campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "", campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "clevermechanisms.dev", campaign: "about", content: "website") == nil)
    #expect(ProductWebsite.url(host: "gita.clevermechanisms.dev", campaign: "about", content: "website") == nil)
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

@Test func changelogAndSupportBuildersTagURLsAndRejectCleverMechanismsDev() throws {
    #expect(ProductWebsite.changelog(host: "clevermechanisms.dev") == nil)
    #expect(ProductWebsite.changelog(host: "sub.clevermechanisms.dev") == nil)
    #expect(ProductWebsite.support(host: "clevermechanisms.dev") == nil)
    #expect(ProductWebsite.support(host: "sub.clevermechanisms.dev") == nil)
    #expect(ProductWebsite.changelog(host: nil) == nil)
    #expect(ProductWebsite.support(host: "") == nil)

    let changelog = try #require(ProductWebsite.changelog(host: "getgita.app"))
    #expect(
        changelog.absoluteString
            == "https://getgita.app/changelog?utm_source=gita&utm_medium=app&utm_campaign=about&utm_content=release_notes"
    )

    let support = try #require(ProductWebsite.support(host: "getgita.app"))
    #expect(
        support.absoluteString
            == "https://getgita.app/support?utm_source=gita&utm_medium=app&utm_campaign=about&utm_content=support")

    let custom = try #require(ProductWebsite.support(host: "getgita.app", campaign: "menu", content: "help"))
    #expect(
        custom.absoluteString
            == "https://getgita.app/support?utm_source=gita&utm_medium=app&utm_campaign=menu&utm_content=help")
}
