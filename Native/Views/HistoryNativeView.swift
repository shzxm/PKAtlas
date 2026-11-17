import SwiftUI

struct HistoryNativeView: View {
    @EnvironmentObject private var store: NativeAppStore
    @State private var query = ""
    @State private var editing: PKDose?
    @State private var confirmDelete: PKDose?
    @State private var add = false
    @State private var onlyDrug = "all"

    private var filtered: [PKDose] {
        store.doses.filter { dose in
            let display = store.catalog.drugs.first(where: { $0.id == dose.drug })?.name ?? dose.drug
            return (onlyDrug == "all" || onlyDrug == dose.drug) &&
                   (query.isEmpty || display.localizedCaseInsensitiveContains(query) ||
                    dose.mg.formatted().contains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("筛选药物", selection: $onlyDrug) {
                    Text("全部").tag("all")
                    ForEach(store.catalog.drugs) { drug in
                        Text(drug.name).tag(drug.id)
                    }
                }
                Text("已记录 \(filtered.count) 条，全部保留在本机加密数据中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("服用记录") {
                ForEach(filtered) { dose in
                    Button { editing = dose } label: {
                        HStack(spacing: 12) {
                            Image(systemName: dose.isImported ? "square.and.arrow.down" : "pills.fill")
                                .foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.catalog.drugs.first(where: { $0.id == dose.drug })?.name
                                     ?? dose.drug)
                                    .font(.headline)
                                Text(dose.time, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(dose.mg.formatted()) mg")
                                .monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { confirmDelete = dose }
                    }
                }
            }
            Section("饮食记录") {
                ForEach(store.meals) { meal in
                    HStack {
                        Image(systemName: meal.kind == "meal" ? "fork.knife" : "cup.and.saucer")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meal.kind == "meal"
                                 ? (meal.mealType == "highFat" ? "高脂餐" : "普通餐")
                                 : "饮品")
                            Text(meal.time, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !meal.note.isEmpty { Text(meal.note).lineLimit(1) }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { store.deleteMeal(meal.id) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "按药物或剂量查找")
        .navigationTitle("历史记录")
        .nativeKeyboardDismissal()
        .sheet(item: $editing) { dose in DoseEditorNativeView(existing: dose) }
        .confirmationDialog("确定删除该记录？", item: $confirmDelete) { dose in
            Button("删除", role: .destructive) { store.removeDose(dose.id) }
        } message: { _ in
            Text("删除后，本机记录和模型重新计算，并在联网时同步。")
        }
        .accessibilityIdentifier("native.history.list")
    }
}

private extension View {
    // The system's confirmationDialog supports item-based editing by
    // keeping the identified record in a nonoptional presentation state.
    func confirmationDialog<Item: Identifiable>(
        _ title: String,
        item: Binding<Item?>,
        @ViewBuilder actions: @escaping (Item) -> some View,
        @ViewBuilder message: @escaping (Item) -> some View
    ) -> some View {
        self.confirmationDialog(title,
                                isPresented: Binding(
                                    get: { item.wrappedValue != nil },
                                    set: { if !$0 { item.wrappedValue = nil } }
                                )) {
            if let current = item.wrappedValue { actions(current) }
        } message: {
            if let current = item.wrappedValue { message(current) }
        }
    }
}
