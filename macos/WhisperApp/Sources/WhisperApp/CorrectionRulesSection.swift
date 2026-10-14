import SwiftUI

/// 詞庫頁「誤聽修正」：手動新增、停用、刪除 `錯誤寫法 → 正確寫法` 規則。
/// 規則只在之後的轉錄由 Worker 套用，不改已存在的歷史。
struct CorrectionRulesSection: View {
    @Environment(CorrectionRuleStore.self) private var corrections
    @State private var wrong = ""
    @State private var right = ""
    @State private var message: String?

    var body: some View {
        DisclosureGroup("誤聽修正（啟用 \(corrections.activeCorrections.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("轉錄完成後把錯誤寫法換成正確寫法（精確比對、區分大小寫），不佔詞彙 token。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("錯誤寫法（例：Articature）", text: $wrong)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("正確寫法", text: $right)
                    Button("加入") { addRule() }
                        .disabled(wrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = message ?? corrections.loadError.map({ "修正規則讀取失敗，暫以空規則運作：\($0)" }) {
                    Text(error).font(.caption).foregroundStyle(DaylightPalette.accentRecord)
                }
                ForEach(corrections.rules) { rule in
                    HStack {
                        Toggle("\(rule.wrong) → \(rule.right)", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { _ in perform { try corrections.toggle(rule) } }
                        ))
                        Spacer()
                        Button("刪除", role: .destructive) { perform { try corrections.remove(rule) } }
                    }
                }
            }.padding(.top, 8)
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    private func addRule() {
        perform {
            try corrections.add(wrong: wrong, right: right)
            wrong = ""
            right = ""
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); message = nil }
        catch { message = error.localizedDescription }
    }
}
