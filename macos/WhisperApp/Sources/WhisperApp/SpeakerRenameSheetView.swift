import SwiftUI

/// Identifiable payload driving the "重新命名講者" sheet via `.sheet(item:)`.
///
/// Deliberately NOT a plain `Bool` + separate `[String: String]` pair of
/// `@State` vars (that was the original design): SwiftUI's `.sheet(isPresented:)`
/// can present its content using a state snapshot captured before a *companion*
/// `@State` write in the same action has propagated, which rendered this sheet
/// with zero rows even when real speaker labels existed. Bundling the labels
/// into the same value that drives presentation makes that ordering bug
/// impossible: the sheet cannot appear without its data.
struct SpeakerRenameSheetData: Identifiable {
    let id = UUID()
    let labels: [String]
}

/// "重新命名講者" sheet content. Owns its own edit buffer (`inputs`), seeded once
/// from `labels` in `init`, so it never depends on state living outside this view.
///
/// `inputs` is an array positionally parallel to `labels` (not a `[String: String]`
/// dictionary keyed by label) so each `TextField` can bind via `$inputs[index]` —
/// SwiftUI's native `Binding` conformance to `RandomAccessCollection`/
/// `MutableCollection` for array-valued state. That native subscript binding has
/// a stable identity tied directly to the `@State` storage slot.
///
/// This matters specifically for CJK input: the original implementation used a
/// `[String: String]` dictionary with a hand-built `Binding(get:set:)` per row.
/// That kind of manually constructed binding is recreated fresh on every `body`
/// evaluation and has no stable identity across renders. An IME (Pinyin/注音/etc.)
/// holds uncommitted "marked text" while composing a character; if any unrelated
/// re-render swaps in a new binding instance mid-composition, SwiftUI treats the
/// field's displayed value as externally overwritten and drops/garbles the
/// in-progress composition. Plain ASCII typing has no such intermediate composing
/// state, so it was never affected — only Chinese/Japanese/Korese name entry was.
struct SpeakerRenameSheetView: View {
    let labels: [String]
    let onConfirm: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var inputs: [String]

    init(labels: [String], onConfirm: @escaping ([String: String]) -> Void, onCancel: @escaping () -> Void) {
        self.labels = labels
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _inputs = State(initialValue: labels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重新命名講者").font(.headline)
            ForEach(labels.indices, id: \.self) { index in
                TextField(labels[index], text: $inputs[index])
            }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("確認") {
                    onConfirm(Dictionary(uniqueKeysWithValues: zip(labels, inputs)))
                }
                .buttonStyle(.borderedProminent)
                .tint(DaylightPalette.accentActive)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}
