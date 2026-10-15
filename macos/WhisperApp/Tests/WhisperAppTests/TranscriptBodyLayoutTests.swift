import SwiftUI
import Testing
@testable import WhisperApp

/// Height allocation of the transcript area — notice label + transcript content — under the
/// caller's `.frame(maxHeight: .infinity)`, rendered offscreen with ImageRenderer (no window).
@MainActor
struct TranscriptBodyLayoutTests {
    private final class Layout { var contentHeight: CGFloat = 0; var contentTop: CGFloat = 0 }
    private static let containerHeight: CGFloat = 600

    private func notice() -> some View {
        Label("逐字稿已手動編輯，時間碼清單暫不顯示", systemImage: "info.circle").font(.caption)
    }

    /// Same frame as transcriptReadOnlyText; records its size and its top edge in the container.
    private func content(_ layout: Layout) -> some View {
        Color.gray.frame(minHeight: 160, maxHeight: .infinity)
            .background(GeometryReader { proxy in
                Self.record(proxy, into: layout)
            })
    }

    private static func record(_ proxy: GeometryProxy, into layout: Layout) -> some View {
        layout.contentHeight = proxy.size.height
        layout.contentTop = proxy.frame(in: .named("container")).minY
        return Color.clear
    }

    @ViewBuilder private func builderTuple(_ layout: Layout) -> some View {   // before (bug)
        notice()
        content(layout)
    }

    private func singleStack(_ layout: Layout) -> some View {                 // after (fix)
        VStack(alignment: .leading, spacing: 8) {
            notice()
            content(layout)
        }
    }

    private func render<V: View>(_ body: V) {
        _ = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 8) {
                Text("分頁列")
                body.frame(maxHeight: .infinity)
                Text("按鈕列")
            }
            .frame(width: 500, height: Self.containerHeight)
            .coordinateSpace(name: "container")
        ).nsImage
    }

    @Test func noticeKeepsNaturalHeightAndTranscriptFillsTheRest() {
        let before = Layout()
        render(builderTuple(before))
        let after = Layout()
        render(singleStack(after))
        print("[layout] before: content \(before.contentHeight)pt at y=\(before.contentTop); "
              + "after: content \(after.contentHeight)pt at y=\(after.contentTop) (container \(Self.containerHeight)pt)")

        // Before: the notice slot was flexible too, so the transcript started far down and got
        // only part of the height.
        #expect(before.contentTop > 150)
        #expect(before.contentHeight < 400)
        // After: the notice is one line right under the tab row; the transcript fills the rest.
        #expect(after.contentTop < 70)
        #expect(after.contentHeight > 480)
    }
}
