import XCTest
@testable import TranquilityCore

/// 1 Oct 2026: a gallery of 62 inline webp screenshots was never split, so
/// the page went up whole at 15.6 MB and the hub answered 413 forever.
final class HubMirrorImageScanTests: XCTestCase {
    private func page(imageBytes: Int, count: Int = 1) -> String {
        let b64 = Data((0..<imageBytes).map { UInt8($0 % 251) }).base64EncodedString()
        let imgs = (0..<count).map { "<img id=shot-\($0) src=\"data:image/webp;base64,\(b64)\">" }.joined()
        return "<!doctype html><title>g</title><p>↓ gallery</p>\(imgs)<p>end</p>"
    }

    func testALargeInlineImageIsFound() {
        let html = page(imageBytes: 300_000)
        // The pattern this replaced finds nothing in the same page.
        let old = try! NSRegularExpression(
            pattern: "data:(image/(?:jpeg|jpg|png|gif|webp|avif));base64,([A-Za-z0-9+/=\\s]{40,})")
        XCTAssertEqual(old.numberOfMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length)), 0)
        let found = HubMirror.dataImages(in: html)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.mime, "image/webp")
        XCTAssertEqual(Data(base64Encoded: found.first!.base64)?.count, 300_000)
        XCTAssertTrue(HubMirror.hasImagesToMove(html))
        XCTAssertTrue(html.contains(found.first!.find), "the text to replace is exactly what is in the page")
    }

    func testManyImagesAndWrappedBase64() {
        let html = page(imageBytes: 5_000, count: 62)
        XCTAssertEqual(HubMirror.dataImages(in: html).count, 62)
        let wrapped = "<img src=\"data:image/png;base64,\(Data(repeating: 7, count: 300).base64EncodedString().chunked(76))\">"
        let one = HubMirror.dataImages(in: wrapped)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(Data(base64Encoded: one[0].base64)?.count, 300)
    }

    func testATinyOrNonImageDataURIIsLeftAlone() {
        XCTAssertTrue(HubMirror.dataImages(in: "<img src=\"data:image/png;base64,AAAA\">").isEmpty)
        XCTAssertTrue(HubMirror.dataImages(in: "<a href=\"data:text/plain;base64,\(String(repeating: "A", count: 80))\">").isEmpty)
    }
}

private extension String {
    func chunked(_ n: Int) -> String {
        stride(from: 0, to: count, by: n).map { i -> String in
            let s = index(startIndex, offsetBy: i), e = index(s, offsetBy: min(n, count - i))
            return String(self[s..<e])
        }.joined(separator: "\n")
    }
}
