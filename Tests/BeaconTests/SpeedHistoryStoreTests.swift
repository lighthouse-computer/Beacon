import XCTest
@testable import Beacon

/// Pins `SpeedHistoryStore.appendingSample` — the pure bucket-append that backs
/// the minute/hour tiers. The contract under test: bucket `start` values stay
/// **monotonically non-decreasing** even when the wall clock steps backward, and
/// the count cap trims from the (truly) oldest end.
///
/// Regression guard for the old `last.start == bucketStart` check, which appended
/// an out-of-order bucket on any backward clock step (NTP correction / manual set
/// / VM resume) — corrupting the chart's time axis and letting the `> cap` trim
/// `removeFirst` drop the newest history instead of the oldest.
final class SpeedHistoryStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_sameBucket_foldsIntoLast() {
        let a = SpeedHistoryStore.appendingSample([], bucketStart: t0, down: 10, up: 2, cap: 100)
        let b = SpeedHistoryStore.appendingSample(a, bucketStart: t0, down: 30, up: 6, cap: 100)
        XCTAssertEqual(b.count, 1, "same bucketStart must fold, not append")
        XCTAssertEqual(b[0].count, 2)
        XCTAssertEqual(b[0].downAvg, 20)   // (10 + 30) / 2
        XCTAssertEqual(b[0].upAvg, 4)      // (2 + 6) / 2
    }

    func test_forwardTime_appendsNewBucket() {
        let a = SpeedHistoryStore.appendingSample([], bucketStart: t0, down: 10, up: 1, cap: 100)
        let b = SpeedHistoryStore.appendingSample(a, bucketStart: t0.addingTimeInterval(60),
                                                  down: 20, up: 2, cap: 100)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[1].start, t0.addingTimeInterval(60))
        XCTAssertEqual(b[1].downAvg, 20)
    }

    func test_backwardClockStep_foldsIntoLast_keepsMonotonic() {
        // Newest bucket is at t0+120; the clock then jumps back to t0. The older
        // sample must fold into the most recent bucket, never append behind it.
        let a = SpeedHistoryStore.appendingSample([], bucketStart: t0.addingTimeInterval(120),
                                                  down: 10, up: 1, cap: 100)
        let b = SpeedHistoryStore.appendingSample(a, bucketStart: t0, down: 50, up: 5, cap: 100)
        XCTAssertEqual(b.count, 1, "backward step must not append an out-of-order bucket")
        XCTAssertEqual(b[0].start, t0.addingTimeInterval(120))
        XCTAssertEqual(b[0].count, 2)
        XCTAssertTrue(zip(b, b.dropFirst()).allSatisfy { $0.start <= $1.start },
                      "start values must stay monotonically non-decreasing")
    }

    func test_largeBackwardClockStep_rebasesInsteadOfFreezing() {
        // One hour of buckets, then the clock jumps back to t0+120 (far past the
        // fold window). Folding forever would freeze the chart for an hour; the
        // store must instead drop now-future buckets and resume at the new time.
        var arr: [SpeedHistoryStore.Bucket] = []
        for i in 0..<60 {
            arr = SpeedHistoryStore.appendingSample(
                arr, bucketStart: t0.addingTimeInterval(Double(i) * 60),
                down: 1, up: 1, cap: 1440)
        }
        let rebased = SpeedHistoryStore.appendingSample(
            arr, bucketStart: t0.addingTimeInterval(120), down: 9, up: 9, cap: 1440)
        XCTAssertEqual(rebased.last?.start, t0.addingTimeInterval(120),
                       "recording must resume at the new clock, not freeze at the old tail")
        XCTAssertEqual(rebased.count, 3, "buckets claiming future timestamps are dropped")
        XCTAssertTrue(zip(rebased, rebased.dropFirst()).allSatisfy { $0.start <= $1.start })
        // The rebased tail folds the new sample into the surviving t0+120 bucket.
        XCTAssertEqual(rebased.last?.count, 2)
        // And recording continues normally afterwards.
        let next = SpeedHistoryStore.appendingSample(
            rebased, bucketStart: t0.addingTimeInterval(180), down: 2, up: 2, cap: 1440)
        XCTAssertEqual(next.count, 4)
        XCTAssertEqual(next.last?.start, t0.addingTimeInterval(180))
    }

    func test_hourTier_boundaryCrossingClockStep_foldsNotRebase() {
        // The hour tier feeds appendingSample 3600s buckets with a 7200s (2× the
        // bucket width) fold window. A backward step that merely crosses an hour
        // boundary (well under 2h) must FOLD into the current partial-hour bucket,
        // not rebase it away — otherwise a few-second NTP nudge near :00 would drop
        // the accumulating hour. Regression guard for the minute-tuned foldWindow
        // leaking onto the hour tier.
        let hour = 3600.0
        let foldWindow = 2 * hour
        var arr = SpeedHistoryStore.appendingSample(
            [], bucketStart: t0.addingTimeInterval(hour), down: 10, up: 1,
            cap: 24, foldWindow: foldWindow)
        // Clock steps back ~10 min, crossing the hour boundary at t0+hour.
        arr = SpeedHistoryStore.appendingSample(
            arr, bucketStart: t0.addingTimeInterval(hour - 600), down: 20, up: 2,
            cap: 24, foldWindow: foldWindow)
        XCTAssertEqual(arr.count, 1, "a sub-2h backward step folds, keeping the partial hour")
        XCTAssertEqual(arr[0].start, t0.addingTimeInterval(hour))
        XCTAssertEqual(arr[0].count, 2)
        // A genuinely huge jump (well over 2h back) still rebases so the chart
        // can't freeze for hours.
        let rebased = SpeedHistoryStore.appendingSample(
            arr, bucketStart: t0.addingTimeInterval(-2 * hour), down: 9, up: 9,
            cap: 24, foldWindow: foldWindow)
        XCTAssertEqual(rebased.last?.start, t0.addingTimeInterval(-2 * hour),
                       "a multi-hour backward jump rebases onto the new clock")
        XCTAssertEqual(rebased.count, 1, "the now-future partial-hour bucket is dropped")
    }

    func test_capTrim_dropsOldestFront() {
        var arr: [SpeedHistoryStore.Bucket] = []
        for i in 0..<5 {
            arr = SpeedHistoryStore.appendingSample(
                arr, bucketStart: t0.addingTimeInterval(Double(i) * 60),
                down: Double(i), up: 0, cap: 3)
        }
        XCTAssertEqual(arr.count, 3, "capped at 3")
        XCTAssertEqual(arr.first?.start, t0.addingTimeInterval(120), "oldest two trimmed")
        XCTAssertEqual(arr.last?.start, t0.addingTimeInterval(240))
    }
}
