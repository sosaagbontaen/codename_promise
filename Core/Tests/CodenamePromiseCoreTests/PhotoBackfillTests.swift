import Foundation
import Testing

@testable import CodenamePromiseCore

@Suite("Fill in from Photos")
struct PhotoBackfillTests {
    let zone = TimeZone(identifier: "America/Chicago")!

    private func at(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: text)!
    }

    @Test func groupsByTheDayTakenInLocalTime() {
        let assets = [
            PhotoBackfill.Asset(id: "b", date: at("2024-03-05T18:00:00Z"), isVideo: false),
            PhotoBackfill.Asset(id: "a", date: at("2024-03-05T15:00:00Z"), isVideo: true),
            // 1am UTC on the 6th is still the evening of the 5th in Chicago.
            PhotoBackfill.Asset(id: "c", date: at("2024-03-06T01:00:00Z"), isVideo: false),
            PhotoBackfill.Asset(id: "d", date: at("2023-12-31T20:00:00Z"), isVideo: false),
        ]
        let plan = PhotoBackfill.plan(assets, alreadyIn: [], timeZone: zone)
        #expect(plan.map(\.day.rawValue) == ["2023-12-31", "2024-03-05"], "oldest day first")
        #expect(plan.last?.assets.map(\.id) == ["a", "b", "c"], "in the order taken")
    }

    @Test func whatsAlreadyInIsLeftOut() {
        let assets = [
            PhotoBackfill.Asset(id: "x", date: at("2024-03-05T15:00:00Z"), isVideo: false),
            PhotoBackfill.Asset(id: "y", date: at("2024-03-05T16:00:00Z"), isVideo: false),
        ]
        let plan = PhotoBackfill.plan(assets, alreadyIn: [PhotoBackfill.mediaId(forAsset: "x")], timeZone: zone)
        #expect(plan.flatMap(\.assets).map(\.id) == ["y"])
        #expect(PhotoBackfill.mediaId(forAsset: "x") == PhotoBackfill.mediaId(forAsset: "x"), "stable across runs")
        #expect(PhotoBackfill.plan(assets, alreadyIn: Set(assets.map { PhotoBackfill.mediaId(forAsset: $0.id) })).isEmpty)
    }

    @Test func quickSuccessionMakesARun() {
        let start = at("2024-06-01T12:00:00Z")
        func shot(_ id: String, _ seconds: TimeInterval, video: Bool = false) -> PhotoBackfill.Asset {
            PhotoBackfill.Asset(id: id, date: start.addingTimeInterval(seconds), isVideo: video)
        }
        let assets = [shot("a", 0), shot("b", 2), shot("c", 5), shot("v", 6, video: true),
                      shot("lone", 60), shot("d", 300), shot("e", 307)]
        let runs = PhotoBackfill.runs(assets)
        #expect(runs.map { $0.map(\.id) } == [["a", "b", "c"], ["d", "e"]], "videos and lone shots aren't runs")
    }

    @Test func leftOutShotsAreNotOfferedAgain() {
        let assets = [PhotoBackfill.Asset(id: "keep", date: at("2024-06-01T12:00:00Z"), isVideo: false),
                      PhotoBackfill.Asset(id: "extra", date: at("2024-06-01T12:00:02Z"), isVideo: false)]
        let plan = PhotoBackfill.plan(assets, alreadyIn: [], leftOut: ["extra"], timeZone: zone)
        #expect(plan.flatMap(\.assets).map(\.id) == ["keep"])
    }
}
