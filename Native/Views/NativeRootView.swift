import SwiftUI
import Charts
import UIKit

private enum AtlasStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let accent = Color(red: 0.39, green: 0.80, blue: 0.99)
    static let warm = Color(red: 0.99, green: 0.78, blue: 0.50)
    static let mint = Color(red: 0.44, green: 0.86, blue: 0.74)
}

enum NativeTab: Hashable {
    case today, chart, inverse, history, settings
}

struct NativeRootView: View {
    @StateObject private var store = NativeAppStore.shared
    @StateObject private var reminders = NativeReminderScheduler.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showGlobalDose = false

    @ToolbarContentBuilder
    private var globalAdd: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showGlobalDose = true
            } label: {
                Label("记录服用", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("native.global.add.dose")
        }
    }

    var body: some View {
        TabView {
            Tab("今天", systemImage: "house.fill") {
                NavigationStack { TodayNativeView().toolbar { globalAdd } }
            }
            Tab("曲线", systemImage: "waveform.path.ecg") {
                NavigationStack { ChartNativeView().toolbar { globalAdd } }
            }
            Tab("反算", systemImage: "function") {
                NavigationStack { InverseNativeView().toolbar { globalAdd } }
            }
            Tab("历史", systemImage: "clock.arrow.circlepath") {
                NavigationStack { HistoryNativeView().toolbar { globalAdd } }
            }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack { SettingsNativeView().toolbar { globalAdd } }
            }
        }
        .tint(AtlasStyle.accent)
        .sheet(isPresented: $showGlobalDose) { DoseEditorNativeView() }
        .environmentObject(store)
        .environmentObject(reminders)
        .preferredColorScheme(.dark)
        .task { await store.start() }
        .task { await store.refreshModel(force: true) }
        .task { await store.checkNativeRelease(force: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                PKBackgroundSync.schedule()
                Task { await store.refreshModel() }
                Task { await store.checkNativeRelease() }
                Task {
                    await store.refresh()
                    await reminders.refresh()
                }
            }
        }
        .alert("发现药时 App 新版本", isPresented: $store.showingReleaseUpdatePrompt) {
            Button("稍后更新", role: .cancel) {}
        } message: {
            if let release = store.latestRelease {
                Text("最新版本 \(release.displayVersion)；当前为 \(store.installedReleaseDescription)。\n\n\(release.releaseNotes)\n\n请到 GitHub Releases 下载 \(release.fileName)，验证 SHA-256 后使用自己的签名方式安装。App 不会自行下载安装包或访问私人版本服务器。")
            }
        }
        .alert("需要更新药时 App", isPresented: $store.showingModelUpgradePrompt) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("网站算法采用了当前版本不认识的反算优化能力，已保留原有可用模型。请安装新版未签名 IPA 后再同步。")
        }
        .alert("药时", isPresented: $store.showingError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(store.errorMessage)
        }
    }
}

struct ModelNotice: View {
    var body: some View {
        Label("群体药代模型 · 不是个人血药实测，也不是用药建议", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct MetricTile: View {
    let label: String
    let amount: String
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(amount).font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            Rectangle().fill(tint).frame(height: 3).clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct DrugNativePicker: View {
    @EnvironmentObject var store: NativeAppStore
    var body: some View {
        Picker("药物", selection: Binding(
            get: { store.selectedDrugID },
            set: { store.switchDrug($0) }
        )) {
            ForEach(store.catalog.drugs) { drug in
                Text(drug.name).tag(drug.id)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("native.drug.picker")
    }
}

struct TodayNativeView: View {
    @EnvironmentObject var store: NativeAppStore
    @State private var addDose = false
    @State private var addMeal = false

    private var recent: [PKDose] {
        store.doses.filter { Calendar.current.isDateInToday($0.time) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "pills.circle.fill")
                            .font(.title)
                            .foregroundStyle(AtlasStyle.mint)
                        Text("药时").font(.largeTitle.bold())
                        Spacer()
                        Text("本地计算").font(.caption.bold())
                            .padding(8).glassEffect(.regular, in: Capsule())
                    }
                    ModelNotice()
                }
                DrugNativePicker()
                    .padding(.horizontal, 5)

                if let drug = store.selectedDrug {
                    if drug.canCalculate {
                        let blood = store.model.concentration(drug, at: .now)
                        let equivalent = store.model.equivalent(drug, at: .now)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154), spacing: 12)], spacing: 12) {
                            MetricTile(label: "当前模型浓度",
                                       amount: blood.isFinite ? blood.formatted(.number.precision(.fractionLength(2))) : "不可用",
                                       unit: "mg/L", tint: AtlasStyle.warm)
                            MetricTile(label: "剂量等效量",
                                       amount: equivalent.isFinite ? equivalent.formatted(.number.precision(.fractionLength(1))) : "不可用",
                                       unit: "mg", tint: AtlasStyle.mint)
                        }
                        GlassPanel {
                            HStack {
                                Label("本地药代参数", systemImage: "function")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                VStack(alignment: .leading) {
                                    Text("参考达峰").font(.caption).foregroundStyle(.secondary)
                                    Text("\((drug.tmax ?? 0).formatted()) h").font(.title3.bold())
                                }
                                Spacer()
                                VStack(alignment: .leading) {
                                    Text("消除半衰期").font(.caption).foregroundStyle(.secondary)
                                    Text("\(store.model.effectiveHalfLife(drug).formatted(.number.precision(.fractionLength(2)))) h")
                                        .font(.title3.bold())
                                }
                            }
                            Text("每次改变剂量、用餐或模型时间后，直接在设备内重新计算。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        GlassPanel {
                            Label("记录专用药物", systemImage: "note.text")
                            Text("尚无可用于量化浓度的可靠参数，只显示已服记录。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                GlassPanel {
                    HStack {
                        Text("今天的记录").font(.headline)
                        Spacer()
                        Text("\(recent.count) 条").font(.caption).foregroundStyle(.secondary)
                    }
                    if recent.isEmpty {
                        ContentUnavailableView("今天还没有服用记录",
                                               systemImage: "pills",
                                               description: Text("只记录已经实际服用的药物"))
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(recent.prefix(8)) { dose in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AtlasStyle.mint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.catalog.drugs.first(where: { $0.id == dose.drug })?.name
                                         ?? dose.drug).font(.subheadline.bold())
                                    Text(dose.time, format: .dateTime.hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(dose.mg.formatted()) mg").monospacedDigit()
                            }
                            if dose.id != recent.prefix(8).last?.id { Divider().opacity(0.35) }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        addDose = true
                    } label: {
                        Label("记录服用", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("native.add.dose")
                    Button {
                        addMeal = true
                    } label: {
                        Label("饮食记录", systemImage: "fork.knife")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.glass)
                }
                Label(store.syncStatus, systemImage: store.conflict ? "exclamationmark.icloud" : "checkmark.icloud")
                    .font(.caption2)
                    .foregroundStyle(store.conflict ? .orange : .secondary)
                    .padding(.vertical, 4)
            }
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .background(AtlasStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addDose) { DoseEditorNativeView() }
        .sheet(isPresented: $addMeal) { MealEditorNativeView() }
    }
}

struct DoseEditorNativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: NativeAppStore
    var existing: PKDose?

    @State private var drugID = ""
    @State private var amount = ""
    @State private var when = Date.now
    @State private var confirmDelete = false

    private var number: Double? {
        guard let parsed = Double(amount.replacingOccurrences(of: ",", with: ".")),
              parsed.isFinite, parsed > 0, parsed < 100_000 else { return nil }
        return parsed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("已服用的记录") {
                    Picker("药物", selection: $drugID) {
                        ForEach(store.catalog.drugs) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
                    HStack {
                        Text("剂量")
                        TextField("毫克", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("native.dose.amount")
                        Text("mg").foregroundStyle(.secondary)
                    }
                    DatePicker("服用时间", selection: $when,
                               displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Text("仅填写已经实际服用的剂量，不依据模型建议服药。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if existing != nil {
                    Section {
                        Button("删除该记录", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .nativeKeyboardDismissal()
            .navigationTitle(existing == nil ? "记录服药" : "编辑服药")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let mg = number {
                            store.editDose(PKDose(id: existing?.id ?? UUID().uuidString,
                                                  drug: drugID, mg: mg, time: when,
                                                  courseId: existing?.courseId,
                                                  unit: "mg",
                                                  isImported: existing?.isImported ?? false))
                            dismiss()
                        }
                    }
                    .disabled(number == nil || drugID.isEmpty)
                    .accessibilityIdentifier("native.dose.save")
                }
            }
            .confirmationDialog("确定删除这条服药记录？", isPresented: $confirmDelete) {
                Button("确认删除", role: .destructive) {
                    if let existing { store.removeDose(existing.id) }
                    dismiss()
                }
            } message: {
                Text("删除会影响本机计算并同步到云端，不可撤销。")
            }
            .onAppear {
                drugID = existing?.drug ?? store.selectedDrug?.id ?? "pregabalin"
                amount = (existing?.mg ?? store.selectedDrug?.defaultDose ?? 0).formatted()
                when = existing?.time ?? .now
            }
        }
        .presentationDetents([.large])
    }
}

struct MealEditorNativeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: NativeAppStore
    @State private var kind = "meal"
    @State private var mealType = "regular"
    @State private var drink = "none"
    @State private var when = Date.now
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("类别", selection: $kind) {
                    Text("用餐").tag("meal")
                    Text("饮品").tag("drink")
                }
                DatePicker("发生时间", selection: $when,
                           displayedComponents: [.date, .hourAndMinute])
                if kind == "meal" {
                    Picker("餐型", selection: $mealType) {
                        Text("普通餐").tag("regular")
                        Text("高脂餐").tag("highFat")
                    }
                }
                Picker("饮料", selection: $drink) {
                    Text("无").tag("none")
                    Text("水").tag("water")
                    Text("咖啡").tag("coffee")
                    Text("茶").tag("tea")
                    Text("牛奶").tag("milk")
                    Text("果汁").tag("juice")
                    Text("酒精").tag("alcohol")
                    Text("其他").tag("other")
                }
                TextField("备注（可选）", text: $note)
                    .onChange(of: note) { _, new in
                        if new.count > 100 { note = String(new.prefix(100)) }
                    }
                Text("餐后模型仅使用已收录的文献参数，缺少依据的饮料不会改变计算曲线。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .nativeKeyboardDismissal()
            .navigationTitle("饮食记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.addMeal(time: when, kind: kind, mealType: mealType,
                                      drink: drink, note: note)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct NativeKeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}

extension View {
    func nativeKeyboardDismissal() -> some View {
        modifier(NativeKeyboardDismissModifier())
    }
}
