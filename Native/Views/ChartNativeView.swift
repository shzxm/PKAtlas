import SwiftUI
import Charts
import Combine

/// Curve samples are recomputed only when source records, drug, or the time
/// window changes, not when the user moves the time scrubber.
@MainActor
final class PKChartRenderState: ObservableObject {
    @Published private(set) var samples: [PKSample] = []
    @Published private(set) var plannedSamples: [PKSample] = []
    @Published private(set) var computing = false
    @Published private(set) var modelOrigin = "本机数学模型（离线可用）"
    private var generation = 0
    private var job: Task<Void, Never>?

    func load(model: PKModel, drug: PKDrug?, center: Date,
              adopted: [PKDose], catalogVersion: String,
              engineVersion: String) {
        generation += 1
        let requested = generation
        job?.cancel()
        guard let drug, drug.canCalculate else {
            samples = []; plannedSamples = []; computing = false
            return
        }
        computing = true
        job = Task {
            let result = await Task.detached(priority: .utility) {
                let start = center.addingTimeInterval(-8 * 3600)
                let actual = model.curve(drug: drug, from: start, hours: 24, stepMinutes: 5)
                let planned = adopted.isEmpty ? [] :
                    model.curve(drug: drug, from: start, hours: 24,
                                stepMinutes: 5, additional: adopted)
                return (actual, planned)
            }.value
            guard !Task.isCancelled, generation == requested else { return }
            samples = result.0
            plannedSamples = result.1
            computing = false
            modelOrigin = model.engineSource == nil
                ? "本机内置数学模型（正在核对181）"
                : "本机签名热更新算法（正在核对181）"
            do {
                let verified = try await PKServerMath.fetch(
                    model: model, drug: drug, actual: result.0, planned: adopted,
                    expectedCatalogPrefix: catalogVersion,
                    expectedEnginePrefix: engineVersion)
                guard !Task.isCancelled, generation == requested else { return }
                samples = verified.actual
                plannedSamples = verified.planned
                modelOrigin = "181服务器权威数学模型"
            } catch {
                guard !Task.isCancelled, generation == requested else { return }
                modelOrigin = model.engineSource == nil
                    ? "本机内置数学模型（离线可用）"
                    : "本机签名热更新算法（离线可用）"
            }
        }
    }
}

struct ChartNativeView: View {
    @EnvironmentObject private var store: NativeAppStore
    @StateObject private var chart = PKChartRenderState()
    @State private var referenceValue = ""
    @State private var displayMode = "blood"
    @State private var selectedPoint = 1.0 / 3.0
    @State private var showOtherUnit = true
    @State private var anchor = Date.now
    @State private var referenceTask: Task<Void, Never>?
    @FocusState private var referenceFocused: Bool

    private var values: [PKSample] { chart.samples }
    private var selectedIndex: Int {
        min(max(0, Int((Double(values.count - 1) * selectedPoint).rounded())),
            max(0, values.count - 1))
    }
    private var point: PKSample? {
        values.indices.contains(selectedIndex) ? values[selectedIndex] : nil
    }
    private var projectedPoint: PKSample? {
        chart.plannedSamples.indices.contains(selectedIndex)
            ? chart.plannedSamples[selectedIndex] : nil
    }
    private var threshold: Double? {
        guard let value = Double(referenceValue.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0, value <= 1_000_000 else { return nil }
        return value
    }
    private var hasMeals: Bool { store.meals.contains { $0.kind == "meal" } }
    private var selectedDrugID: String { store.selectedDrugID }

    private func refreshCurve() {
        chart.load(model: store.model, drug: store.selectedDrug,
                   center: anchor, adopted: store.selectedAdoptedDoses(),
                   catalogVersion: store.modelVersion,
                   engineVersion: store.engineVersion)
    }

    private func loadReference() {
        let value = store.referenceValue(drugID: store.selectedDrugID, mode: displayMode)
        referenceValue = value.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? ""
    }

    private func scheduleReferenceSync(_ value: String) {
        referenceTask?.cancel()
        let drugID = store.selectedDrugID, mode = displayMode
        referenceTask = Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || (Double(clean) != nil && Double(clean)! > 0) {
                store.setReference(drugID: drugID, mode: mode, text: clean)
            }
        }
    }

    private func format(_ value: Double, decimals: Int = 3) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelNotice()
                DrugNativePicker()

                Picker("模型口径", selection: $displayMode) {
                    Text("浓度 mg/L").tag("blood")
                    Text("剂量等效量 mg").tag("equivalent")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("native.chart.mode")

                if let drug = store.selectedDrug, drug.canCalculate {
                    GlassPanel {
                        HStack {
                            Label("24 小时模型曲线", systemImage: "chart.xyaxis.line")
                                .font(.headline)
                            Spacer()
                            if chart.computing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(chart.modelOrigin).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text("当前时间前 8 小时 · 后 16 小时")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("同时显示血药浓度和剂量等效曲线", isOn: $showOtherUnit)
                            .font(.footnote)
                            .tint(.mint)
                        if !values.isEmpty {
                            Chart {
                                ForEach(values) { sample in
                                    LineMark(
                                        x: .value("时间", sample.time),
                                        y: .value("数值", displayMode == "blood"
                                                  ? sample.concentration : sample.equivalent)
                                    )
                                    .foregroundStyle(Color.orange)
                                    .interpolationMethod(.linear)
                                }
                                if displayMode == "blood" {
                                    ForEach(values) { sample in
                                        LineMark(x: .value("时间", sample.time),
                                                 y: .value("未计饮食", sample.unfed))
                                            .foregroundStyle(Color.cyan)
                                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 5]))
                                    }
                                }
                                if !chart.plannedSamples.isEmpty {
                                    ForEach(chart.plannedSamples) { sample in
                                        LineMark(
                                            x: .value("时间", sample.time),
                                            y: .value("已采用情景", displayMode == "blood"
                                                      ? sample.concentration : sample.equivalent)
                                        )
                                        .foregroundStyle(.purple)
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 5]))
                                    }
                                }
                                if let threshold {
                                    RuleMark(y: .value("当前口径的参考线", threshold))
                                        .foregroundStyle(.pink)
                                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 5]))
                                }
                                RuleMark(x: .value("当前时刻", anchor))
                                    .foregroundStyle(.mint.opacity(0.85))
                                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 4]))
                                if let point {
                                    RuleMark(x: .value("查看位置", point.time))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineStyle(StrokeStyle(lineWidth: 1))
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                                    AxisGridLine().foregroundStyle(.white.opacity(0.12))
                                    AxisValueLabel(format: .dateTime.hour().minute())
                                        .font(.caption2)
                                }
                            }
                            .chartYAxis { AxisMarks(position: .leading) }
                            .chartOverlay { proxy in
                                GeometryReader { geometry in
                                    Rectangle().fill(.clear).contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                                            guard let frame = proxy.plotFrame else { return }
                                            let plot = geometry[frame]
                                            let fraction = (gesture.location.x - plot.origin.x) / max(1, plot.width)
                                            selectedPoint = min(1, max(0, fraction))
                                        })
                                }
                            }
                            .frame(height: 245)
                            .accessibilityIdentifier("native.chart.curve")

                            if showOtherUnit {
                                let otherMode = displayMode == "blood" ? "equivalent" : "blood"
                                Text(otherMode == "blood" ? "血药浓度 · mg/L" : "剂量等效 · mg")
                                    .font(.subheadline.bold()).foregroundStyle(.secondary)
                                Chart {
                                    ForEach(values) { item in
                                        LineMark(x: .value("时间", item.time),
                                            y: .value("数值", otherMode == "blood" ? item.concentration : item.equivalent))
                                            .foregroundStyle(.mint)
                                    }
                                    if otherMode == "blood" {
                                        ForEach(values) { item in
                                            LineMark(x: .value("时间", item.time),
                                                y: .value("未计饮食", item.unfed))
                                                .foregroundStyle(.cyan)
                                                .lineStyle(StrokeStyle(dash: [5, 4]))
                                        }
                                    }
                                    ForEach(chart.plannedSamples) { item in
                                        LineMark(x: .value("时间", item.time),
                                            y: .value("采用情景", otherMode == "blood" ? item.concentration : item.equivalent))
                                            .foregroundStyle(.purple)
                                            .lineStyle(StrokeStyle(dash: [4, 5]))
                                    }
                                    if let point {
                                        RuleMark(x: .value("查看位置", point.time))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                                .chartYAxis { AxisMarks(position: .leading) }
                                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                                    AxisValueLabel(format: .dateTime.hour().minute())
                                } }
                                .chartOverlay { proxy in
                                    GeometryReader { geometry in
                                        Rectangle().fill(.clear).contentShape(Rectangle())
                                            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                                                guard let frame = proxy.plotFrame else { return }
                                                let plot = geometry[frame]
                                                selectedPoint = min(1, max(0,
                                                    (gesture.location.x - plot.origin.x) / max(1, plot.width)))
                                            })
                                    }
                                }
                                .frame(height: 180)
                                Text("两种计量口径使用独立纵轴，同一时间游标；橙/薄荷为已记、青色为未计饮食、紫色为已采用情景。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            HStack(spacing: 12) {
                                Label("已计饮食", systemImage: "line.diagonal")
                                    .foregroundStyle(.orange)
                                if hasMeals {
                                    Label("未计饮食", systemImage: "line.diagonal")
                                        .foregroundStyle(.cyan)
                                }
                                if !chart.plannedSamples.isEmpty {
                                    Label("已采用情景", systemImage: "line.diagonal")
                                        .foregroundStyle(.purple)
                                }
                            }
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            Slider(value: $selectedPoint, in: 0...1)
                                .tint(.orange)
                                .accessibilityIdentifier("native.chart.scrubber")
                            if let point {
                                Text(point.time.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline.bold())
                                HStack {
                                    Text(displayMode == "blood"
                                         ? "\(format(point.concentration)) mg/L"
                                         : "\(format(point.equivalent)) mg（等效）")
                                        .font(.title2.bold()).monospacedDigit()
                                    Spacer()
                                    Button("现在") {
                                        selectedPoint = 1.0 / 3.0
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.glass)
                                }
                            }
                        } else {
                            ProgressView("正在计算本地曲线…")
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    }

                    if let point {
                        GlassPanel {
                            Text("所选时刻 · 完整模型数值").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 12)], spacing: 12) {
                                MetricTile(label: "计入饮食 · 血药浓度",
                                           amount: format(point.concentration),
                                           unit: "mg/L", tint: .orange)
                                MetricTile(label: "剂量等效量",
                                           amount: format(point.equivalent, decimals: 1),
                                           unit: "mg（等效）", tint: .mint)
                                MetricTile(label: "未计饮食 · 浓度",
                                           amount: format(point.unfed),
                                           unit: "mg/L", tint: .cyan)
                                if let projectedPoint {
                                    MetricTile(label: "采用方案后 · 浓度",
                                               amount: format(projectedPoint.concentration),
                                               unit: "mg/L", tint: .purple)
                                    MetricTile(label: "采用方案后 · 等效",
                                               amount: format(projectedPoint.equivalent, decimals: 1),
                                               unit: "mg（等效）", tint: .purple)
                                }
                                if let threshold {
                                    MetricTile(label: "当前参考线",
                                               amount: format(threshold),
                                               unit: displayMode == "blood" ? "mg/L" : "mg",
                                               tint: .pink)
                                }
                            }
                            Text("模型估算值不代表个人实测浓度。假设情景不会自动变成已服用记录。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    GlassPanel {
                        Label("参考线 · 显示单位", systemImage: "line.diagonal")
                            .font(.headline)
                        Picker("参考线类型", selection: $displayMode) {
                            Text("血药浓度").tag("blood")
                            Text("剂量等效量").tag("equivalent")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("native.chart.reference.mode")
                        HStack {
                            TextField("自动同步参考值", text: $referenceValue)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($referenceFocused)
                                .accessibilityIdentifier("native.chart.reference")
                            Text(displayMode == "blood" ? "mg/L" : "mg")
                                .foregroundStyle(.secondary)
                        }
                        Text("编辑后自动保存本机并同步云端；切换单位不会沿用另一计量口径的数值。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    GlassPanel {
                        Text("药代依据").font(.headline)
                        Text(drug.note ?? "采用简化口服吸收模型及文献群体参数。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let source = drug.source,
                           let str = drug.url, let url = URL(string: str), url.scheme == "https" {
                            Link(source, destination: url).font(.subheadline)
                        }
                        if let food = store.catalog.food[drug.id], let summary = food.summary {
                            DisclosureGroup("饮食和饮料研究依据") {
                                Text(summary).font(.footnote)
                                if let drink = food.drink {
                                    Text(drink).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("当前药物没有量化曲线", systemImage: "chart.xyaxis.line")
                }
            }
            .frame(maxWidth: 850)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(red: 0.035, green: 0.055, blue: 0.095))
        .navigationTitle("药代曲线")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { referenceFocused = false }
            }
        }
        .onAppear {
            anchor = Date.now
            selectedPoint = 1.0 / 3.0
            loadReference()
            refreshCurve()
        }
        .onChange(of: store.modelRevision) { _, _ in
            refreshCurve()
        }
        .onChange(of: store.selectedDrugID) { _, _ in
            referenceTask?.cancel()
            loadReference()
            refreshCurve()
        }
        .onChange(of: store.snapshot) { _, _ in
            if !referenceFocused { loadReference() }
            refreshCurve()
        }
        .onChange(of: displayMode) { _, _ in
            referenceTask?.cancel()
            referenceValue = ""
            referenceFocused = false
        }
        .onChange(of: referenceValue) { _, value in
            // Changing mode deliberately clears the INPUT only; it must not
            // delete an existing cloud reference without explicit editing.
            if referenceFocused { scheduleReferenceSync(value) }
        }
    }
}
