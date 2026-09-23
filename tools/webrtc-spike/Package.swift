// swift-tools-version:5.9
import PackageDescription

// The spike: one macOS client that answers three questions at once.
//   Does LiveKit's WebRTC build let us name the microphone? (stasel's does not
//   ship the headers for it at all, checked 22 Sep.)
//   Does Pipecat's SmallWebRTC signalling accept an offer from this build?
//   Does audio flow both ways?
// LiveKit's framework is taken on its own, from its own package. Their server
// and room protocol are not involved: we speak Pipecat's offer/answer.
let package = Package(
    name: "webrtc-spike",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.02")
    ],
    targets: [
        .executableTarget(name: "webrtc-spike",
                          dependencies: [.product(name: "LiveKitWebRTC", package: "webrtc-xcframework")])
    ]
)
