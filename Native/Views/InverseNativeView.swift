import SwiftUI
import Charts

/// Rolling an entered clock time to the following day is intentional.
/// The user-selected clock time is preserved, not replaced with current time.
enum PKFutureTime {
    static func nextOccurrence(_ candidate: Date, after now: Date) -> Date {
        var value = candidate
        for _ in 0..<366 where value <= now {
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: value) else { break }
            value = next
        }
        return value > now ? value : now.addingTimeInterval(3600)
    }
}

struct InverseNativeView: View {
    @EnvironmentObject private var store: NativeAppStore
    @State private var page = "point"
    @State private var targetTime = Date.now.addingTimeInterval(4 * 3600)
    @State private var durationStart = Date.now.addingTimeInterval(2 * 3600)
    @State private var durationHours = 4.0
    @State private var thresholdText = ""
    @State private var unitMode = "blood"
    @State private var maximumDoseText = ""
    @State private var fixedCount = 0
    @State private var minimumPeakText = ""
    @State private var peakMode = "equivalent"
    @State private var cycleMinimumText = ""
    @State private var cycleMode = "blood"
    @State private var totalMaximumText = ""
    @State private var targetLimitEnabled = false
    @State private var targetLimitBlood = "0.5"
    @State private var targetLimitEquivalent = "50"
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var draftRestoring = false
    @State private var draftReady = false
    @State private var selectedCurveFraction = 1.0 / 3.0
    @State private var solving = false
    @State private var result: PKInverseOutput?
    @State private var solutionMessage = ""
    @State private var previewVariant = "A"
    @State private var baselineCurve: [PKSample] = []
    @State private var scenarioCurve: [PKSample] = []
    @State private var showingExplanation = false
    @State private var showingStrengthEditor = false
    @State private var showingAdoption = false
    @State private var pendingAdoptionVariant = "A"
    @State private var strengthMg = ""
    @State private var strengthUnit = "粒"
    @State private var strengthLabel = ""
    @FocusState private var focused: Bool

    private var drug: PKDrug? { store.selectedDrug }
    private var threshold: Double? {
        guard let value = Double(thresholdText.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0, value <= 1_000_000 else { return nil }
        return value
    }
    private var countText: String { fixedCount == 0 ? "" : String(fixedCount) }
    private var cap: Double {
        guard let n = Double(maximumDoseText), n.isFinite, n > 0 else { return 1_000_000 }
        return min(1_000_000, n)
    }
    private var peakFloor: Double {
        guard let n = Double(minimumPeakText), n.isFinite, n > 0 else { return 0 }
        return n
    }
    private var cycleFloor: Double {
        guard let n = Double(cycleMinimumText.replacingOccurrences(of: ",", with: ".")), n.isFinite, n > 0 else { return 0 }
        return n
    }
    private var totalCap: Double? {
        guard !totalMaximumText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Double(totalMaximumText.replacingOccurrences(of: ",", with: "."))
    }
    private func validOptional(_ raw: String) -> Bool {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        guard let n = Double(raw.replacingOccurrences(of: ",", with: ".")) else { return false }
        return n.isFinite && n > 0 && n <= 1_000_000
    }
    private var adoptedPlan: [PKDose] { store.selectedAdoptedDoses() }
    private var pickedCurvePoint: PKSample? {
        guard !baselineCurve.isEmpty else { return nil }
        let index = min(baselineCurve.count - 1,
                        max(0, Int((Double(baselineCurve.count - 1) * selectedCurveFraction).rounded())))
        return baselineCurve[index]
    }
    private var pickedScenarioPoint: PKSample? {
        guard let pickedCurvePoint else { return nil }
        return scenarioCurve.first { abs($0.time.timeIntervalSince(pickedCurvePoint.time)) < 2 }
    }

    private var activeTolerance: Double? {
        Double((unitMode == "blood" ? targetLimitBlood : targetLimitEquivalent)
            .replacingOccurrences(of: ",", with: "."))
    }

    private static func localDateString(_ value: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return format.string(from: value)
    }

    private static func parseLocalDate(_ raw: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return format.date(from: raw)
    }

    private var inverseDraftFields: [String: String] {
        ["pointTarget": Self.localDateString(targetTime),
         "pointTargetLimitEnabled": targetLimitEnabled ? "1" : "0",
         "pointTargetLimitBlood": targetLimitBlood,
         "pointTargetLimitEquivalent": targetLimitEquivalent,
         "pointMaxDose": maximumDoseText, "pointTotalMax": totalMaximumText,
         "pointCount": countText, "pointPeakMin": minimumPeakText,
         "pointPeakMode": peakMode, "pointCycleMin": cycleMinimumText,
         "pointCycleMode": cycleMode,
         "targetStart": Self.localDateString(durationStart),
         "holdHours": String(durationHours), "inverseCount": countText]
    }
    private var draftSignature: String {
        inverseDraftFields.sorted(by: { $0.key < $1.key })
            .map { $0.key + "=" + $0.value }.joined(separator: "|")
    }

    private func restoreInverseDraft() {
        draftSaveTask?.cancel()
        draftRestoring = true
        let values = store.inverseDraft(for: store.selectedDrugID)
        if let raw = values["pointTarget"],
           let date = Self.parseLocalDate(raw), date > .now,
           date < Date.now.addingTimeInterval(24 * 3600) { targetTime = date }
        else { targetTime = Date.now.addingTimeInterval(4 * 3600) }
        if let raw = values["targetStart"],
           let date = Self.parseLocalDate(raw), date > .now { durationStart = date }
        else { durationStart = Date.now.addingTimeInterval(2 * 3600) }
        maximumDoseText = values["pointMaxDose"] ?? ""
        totalMaximumText = values["pointTotalMax"] ?? ""
        fixedCount = min(8, max(0, Int(values["pointCount"] ?? "") ?? 0))
        minimumPeakText = values["pointPeakMin"] ?? ""
        peakMode = values["pointPeakMode"] == "blood" ? "blood" : "equivalent"
        cycleMinimumText = values["pointCycleMin"] ?? ""
        cycleMode = values["pointCycleMode"] == "equivalent" ? "equivalent" : "blood"
        durationHours = min(24, max(0.5, Double(values["holdHours"] ?? "") ?? 4))
        targetLimitEnabled = values["pointTargetLimitEnabled"] == "1"
        targetLimitBlood = values["pointTargetLimitBlood"] ?? "0.5"
        targetLimitEquivalent = values["pointTargetLimitEquivalent"] ?? "50"
        draftReady = true
        // Keep restoration suppression until SwiftUI publishes the new state.
        Task { @MainActor in
            await Task.yield()
            draftRestoring = false
        }
    }

    private func scheduleInverseDraft() {
        guard draftReady && !draftRestoring else { return }
        let drugID = store.selectedDrugID
        let fields = inverseDraftFields
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            store.saveInverseDraft(fields, drugID: drugID)
            draftSaveTask = nil
        }
    }


    private func loadReference() {
        let value = store.referenceValue(drugID: store.selectedDrugID, mode: unitMode)
        thresholdText = value.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? ""
    }

    private func execute() {
        guard !solving, let drug, drug.canCalculate, let threshold else {
            solutionMessage = "请先填写大于零的参考数值。"
            return
        }
        focused = false
        guard [maximumDoseText, minimumPeakText, cycleMinimumText, totalMaximumText]
            .allSatisfy(validOptional),
              !targetLimitEnabled || (activeTolerance != nil &&
                activeTolerance!.isFinite && activeTolerance! > 0 &&
                activeTolerance! <= 1_000_000) else {
            solutionMessage = "剂量上限及最低值约束必须为空，或在 0～1,000,000 范围内。"; return
        }
        let now = Date.now
        if page == "point" {
            targetTime = PKFutureTime.nextOccurrence(targetTime, after: now)
            guard targetTime.timeIntervalSince(now) <= 24 * 3600 else {
                solutionMessage = "与网站一致，目标时刻限定在未来 24 小时内。请调整日期与时间。"
                return
            }
        } else {
            durationStart = PKFutureTime.nextOccurrence(durationStart, after: now)
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        // The web uses only recorded doses of this drug within the 48-hour
        // model lookback and never counts future planned events as taken.
        let recordRows = store.snapshot.records.filter { record in
            guard record["drug"]?.string == drug.id,
                  let at = record["time"]?.number, at.isFinite else { return false }
            return at <= nowMs && at >= nowMs - 48 * 3_600_000
        }
        let input = PKInverseInput(
            kind: page,
            drugId: drug.id,
            rows: recordRows,
            plan: store.snapshot.plans[drug.id] ?? .object([:]),
            meals: store.snapshot.intakes,
            renalState: store.snapshot.settings["renal"] ?? .null,
            threshold: threshold,
            target: targetTime.timeIntervalSince1970 * 1000,
            cap: cap,
            now: now.timeIntervalSince1970 * 1000,
            fixedCount: fixedCount == 0 ? nil : fixedCount,
            mode: unitMode,
            peakFloor: peakFloor,
            start: durationStart.timeIntervalSince1970 * 1000,
            hours: durationHours,
            countText: countText,
            cycleFloor: PKInverseLimit(value: cycleFloor, mode: cycleMode),
            peakRequirement: PKInverseLimit(value: peakFloor, mode: peakMode),
            totalCap: totalCap,
            targetWindow: PKInverseTargetWindow(enabled: targetLimitEnabled,
                value: activeTolerance ?? 0),
            catalog: store.catalog
        )
        scheduleInverseDraft()
        solving = true
        solutionMessage = "正在使用与网站相同的本地反算引擎计算…"
        result = nil
        Task {
            do {
                let output = try await PKNativeInverseSolver.solve(
                    input, engineSource: store.engineSource)
                result = output
                previewVariant = "A"
                refreshPreview(output)
                solutionMessage = "数学搜索已完成，可查看 A/B 候选方案。"
            } catch {
                result = nil
                solutionMessage = "计算未完成：" + error.localizedDescription
            }
            solving = false
        }
    }

    private func refreshPreview(_ output: PKInverseOutput? = nil) {
        guard let drug, drug.canCalculate else {
            baselineCurve = []; scenarioCurve = []; return
        }
        let candidate = previewVariant == "B"
            ? (output ?? result)?.minimum
            : ((output ?? result)?.display ?? (output ?? result)?.result)
        let doses = (candidate?.doses ?? []).map {
            PKDose(drug: drug.id, mg: $0.mg,
                   time: Date(timeIntervalSince1970: $0.time / 1000))
        }
        let start = Date.now.addingTimeInterval(-8 * 3600)
        baselineCurve = store.model.curve(drug: drug, from: start, hours: 24, stepMinutes: 10)
        scenarioCurve = candidate?.doses != nil ?
            store.model.curve(drug: drug, from: start, hours: 24,
                              stepMinutes: 10, additional: doses) : []
    }

    @ViewBuilder
    private var inversePreview: some View {
        if !baselineCurve.isEmpty {
            GlassPanel {
                Label("反算曲线对比 · 当前前 8 小时 / 后 16 小时",
                      systemImage: "chart.xyaxis.line").font(.headline)
                if page == "point" && result != nil {
                    Picker("预览候选", selection: $previewVariant) {
                        Text("方案 A").tag("A")
                        Text("方案 B").tag("B")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: previewVariant) { _, _ in refreshPreview() }
                }
                Chart {
                    ForEach(baselineCurve) { sample in
                        LineMark(x: .value("时间", sample.time),
                                 y: .value("当前", unitMode == "blood" ? sample.concentration : sample.equivalent))
                            .foregroundStyle(.orange)
                    }
                    ForEach(scenarioCurve) { sample in
                        LineMark(x: .value("时间", sample.time),
                                 y: .value("候选", unitMode == "blood" ? sample.concentration : sample.equivalent))
                            .foregroundStyle(.purple)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    if targetLimitEnabled, let threshold, let tolerance = activeTolerance,
                       tolerance > 0 {
                        RuleMark(y: .value("目标偏差上界", threshold + tolerance))
                            .foregroundStyle(.green.opacity(0.6))
                            .lineStyle(StrokeStyle(dash: [2, 3]))
                        RuleMark(y: .value("目标偏差下界", max(0, threshold - tolerance)))
                            .foregroundStyle(.green.opacity(0.6))
                            .lineStyle(StrokeStyle(dash: [2, 3]))
                    }
                    if let pickedCurvePoint {
                        RuleMark(x: .value("当前查看位置", pickedCurvePoint.time))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    if let threshold {
                        RuleMark(y: .value("参考值", threshold))
                            .foregroundStyle(.pink)
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                    RuleMark(x: .value("目标时刻", page == "point" ? targetTime : durationStart))
                        .foregroundStyle(.mint)
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                                guard let frame = proxy.plotFrame else { return }
                                let plot = geometry[frame]
                                selectedCurveFraction = min(1, max(0,
                                    (gesture.location.x - plot.origin.x) / max(1, plot.width)))
                            })
                    }
                }
                .frame(height: 250)
                .chartYAxis { AxisMarks(position: .leading) }
                Slider(value: $selectedCurveFraction, in: 0...1)
                    .tint(.mint)
                    .accessibilityIdentifier("native.inverse.curve.scrubber")
                if let pickedCurvePoint {
                    HStack {
                        Text(pickedCurvePoint.time.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.bold())
                        Spacer()
                        Button("现在") { selectedCurveFraction = 1.0 / 3.0 }
                            .buttonStyle(.glass)
                    }
                    Text("已记：\((unitMode == "blood" ? pickedCurvePoint.concentration : pickedCurvePoint.equivalent).formatted(.number.precision(.fractionLength(3)))) \(unitMode == "blood" ? "mg/L" : "mg（等效）")")
                        .font(.subheadline).foregroundStyle(.orange)
                    if let pickedScenarioPoint {
                        Text("方案：\((unitMode == "blood" ? pickedScenarioPoint.concentration : pickedScenarioPoint.equivalent).formatted(.number.precision(.fractionLength(3)))) \(unitMode == "blood" ? "mg/L" : "mg（等效）")")
                            .font(.subheadline).foregroundStyle(.purple)
                    }
                }
                Text("拖动滑块查看任一时刻；橙色为已记录模型、紫色为候选数学情景、粉色为参考线、绿色为可选目标精度范围。假设节点不代表实际服药。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelNotice()
                DrugNativePicker()
                inversePreview
                Picker("反算模式", selection: $page) {
                    Text("目标时刻 / A、B 方案").tag("point")
                    Text("维持时长").tag("duration")
                }
                .pickerStyle(.segmented)

                if let drug, drug.canCalculate {
                    GlassPanel {
                        Label("参考值与目标", systemImage: "scope")
                            .font(.headline)
                        Picker("口径", selection: $unitMode) {
                            Text("血药浓度 mg/L").tag("blood")
                            Text("剂量等效量 mg").tag("equivalent")
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            TextField("参考数值", text: $thresholdText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .focused($focused)
                                .accessibilityIdentifier("native.inverse.threshold")
                            Text(unitMode == "blood" ? "mg/L" : "mg")
                                .foregroundStyle(.secondary)
                        }
                        if page == "point" {
                            DatePicker("目标时刻", selection: $targetTime,
                                       displayedComponents: [.date, .hourAndMinute])
                                .onChange(of: targetTime) { _, next in
                                    if next <= Date.now {
                                        targetTime = PKFutureTime.nextOccurrence(next, after: .now)
                                    }
                                }
                            Toggle("启用目标时刻精度限定", isOn: $targetLimitEnabled)
                                .accessibilityIdentifier("native.inverse.target.limit.enabled")
                            if targetLimitEnabled {
                                HStack {
                                    Text("目标时刻允许偏差 ±")
                                    Spacer()
                                    TextField(unitMode == "blood" ? "0.5" : "50",
                                              text: unitMode == "blood" ? $targetLimitBlood : $targetLimitEquivalent)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .focused($focused)
                                        .frame(width: 96)
                                        .accessibilityIdentifier("native.inverse.target.tolerance")
                                    Text(unitMode == "blood" ? "mg/L" : "mg")
                                        .foregroundStyle(.secondary)
                                }
                                Text("允许目标时刻落在参考值 ± 偏差内；同时保持连续覆盖参考线等独立约束。默认浓度 ±0.5 mg/L、等效 ±50 mg，均可修改。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("未开启精度限定：目标时刻只需达到或高于参考值，不要求精确相等。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("单个节点最大剂量")
                                Spacer()
                                TextField("不设置", text: $maximumDoseText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focused)
                                    .frame(width: 94)
                                Text("mg").foregroundStyle(.secondary)
                            }
                            Picker("假设节点数", selection: $fixedCount) {
                                Text("自动").tag(0)
                                ForEach(1...8, id: \.self) { count in
                                    Text("\(count) 次").tag(count)
                                }
                            }
                            HStack {
                                Text("现在至目标总新增剂量上限")
                                Spacer()
                                TextField("不限", text: $totalMaximumText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focused)
                                    .frame(width: 100)
                                Text("mg").foregroundStyle(.secondary)
                            }
                            Divider()
                            HStack {
                                Text("周期内模型最低值")
                                Spacer()
                                TextField("不限", text: $cycleMinimumText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focused)
                                    .frame(width: 92)
                            }
                            Picker("周期最低值单位", selection: $cycleMode) {
                                Text("血药浓度 mg/L").tag("blood")
                                Text("剂量等效 mg").tag("equivalent")
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Text("覆盖段峰值最低值")
                                Spacer()
                                TextField("不限", text: $minimumPeakText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .focused($focused)
                                    .frame(width: 92)
                            }
                            Picker("峰值最低值单位", selection: $peakMode) {
                                Text("血药浓度 mg/L").tag("blood")
                                Text("剂量等效 mg").tag("equivalent")
                            }
                            .pickerStyle(.segmented)
                            Text("各约束独立校验；累计上限统计的是新增假设节点的总 mg，而非等效剂量。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            DatePicker("维持窗口开始", selection: $durationStart,
                                       displayedComponents: [.date, .hourAndMinute])
                                .onChange(of: durationStart) { _, next in
                                    if next <= Date.now {
                                        durationStart = PKFutureTime.nextOccurrence(next, after: .now)
                                    }
                                }
                            HStack {
                                Text("持续时长")
                                Spacer()
                                Text(durationHours.formatted(.number.precision(.fractionLength(1))))
                                    .monospacedDigit()
                                Text("小时").foregroundStyle(.secondary)
                            }
                            Slider(value: $durationHours, in: 0.5...24, step: 0.5)
                            Picker("假设节点数", selection: $fixedCount) {
                                Text("自动").tag(0)
                                ForEach(1...8, id: \.self) { count in
                                    Text("\(count) 次").tag(count)
                                }
                            }
                        }
                        Button {
                            showingStrengthEditor = true
                        } label: {
                            Label("药盒规格 · \(store.strengths(for: drug.id).count) 项",
                                  systemImage: "pills")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }

                    Button {
                        execute()
                    } label: {
                        HStack {
                            if solving { ProgressView().tint(.white) }
                            Label(solving ? "正在本地搜索…" : "计算反算方案",
                                  systemImage: "function")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(solving || threshold == nil)
                    .accessibilityIdentifier("native.inverse.calculate")

                    if !solutionMessage.isEmpty {
                        Text(solutionMessage).font(.callout).foregroundStyle(.secondary)
                    }
                    if let result {
                        if page == "point" {
                            candidateCard("方案 A · 连续覆盖", candidate: result.result,
                                          variant: "A")
                            candidateCard("方案 B · 最小量 / 稳定搜索",
                                          candidate: result.minimum, variant: "B")
                        } else {
                            candidateCard("维持时长搜索结果",
                                          candidate: result.display ?? result.result,
                                          variant: nil)
                        }
                    }
                    if !adoptedPlan.isEmpty {
                        GlassPanel {
                            Label("已采用的数学模型方案", systemImage: "checkmark.circle")
                                .font(.headline).foregroundStyle(.mint)
                            Text("已有 \(adoptedPlan.count) 个假设节点。采用方案后，云端记录与提醒按用户已保存配置同步；假设节点不等于已服用。")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(adoptedPlan) { dose in
                                HStack {
                                    Text(dose.time, format: .dateTime.month().day().hour().minute())
                                    Spacer()
                                    Text("\(dose.mg.formatted()) mg")
                                }.font(.subheadline)
                            }
                            Button("取消采用方案", role: .destructive) {
                                store.cancelAdoptedInverse()
                            }
                        }
                    }
                    Button {
                        showingExplanation = true
                    } label: {
                        Label("算法和安全说明", systemImage: "info.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    ContentUnavailableView("该药物仅能记录",
                                           systemImage: "exclamationmark.circle")
                }
            }
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .nativeKeyboardDismissal()
        .background(Color(red: 0.035, green: 0.055, blue: 0.095))
        .navigationTitle("数学反算")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { restoreInverseDraft(); loadReference(); refreshPreview() }
        .onChange(of: store.selectedDrugID) { _, _ in
            result = nil; restoreInverseDraft(); loadReference(); refreshPreview()
        }
        .onChange(of: draftSignature) { _, _ in
            scheduleInverseDraft()
        }
        .onChange(of: unitMode) { _, _ in
            result = nil
            refreshPreview()
            thresholdText = ""
        }
        .onChange(of: page) { _, _ in result = nil; refreshPreview() }
        .onChange(of: store.modelRevision) { _, _ in
            result = nil
            solutionMessage = "云端模型参数已更新，请重新计算反算方案。"
            refreshPreview()
        }
        .onChange(of: store.snapshot) { _, _ in
            if !focused && !draftRestoring {
                let cloud = store.inverseDraft(for: store.selectedDrugID)
                if let target = cloud["pointTarget"],
                   target != Self.localDateString(targetTime),
                   draftSaveTask == nil { restoreInverseDraft() }
            }
            refreshPreview()
        }
        .onChange(of: thresholdText) { _, value in
            if focused, let threshold = Double(value), threshold > 0 {
                store.setReference(drugID: store.selectedDrugID, mode: unitMode, text: value)
            }
        }
        .sheet(isPresented: $showingStrengthEditor) { strengthsEditor }
        .sheet(isPresented: $showingExplanation) {
            NavigationStack {
                ScrollView {
                    Text("""
                    当前使用生产网站同版本的本地 JavaScriptCore 数学反算内核，
                    包含目标时刻连续覆盖、药盒完整规格、固定节点数、A/B 候选、
                    稳定性和维持时长搜索。运算完全在本机进行，不调用网页。
                    模型值为群体估计，反算结果是有限数学候选，不是治疗处方，
                    不保证对个人安全或有效。不要依据输出自行加药、改间隔或停药。
                    """)
                    .padding()
                }
                .navigationTitle("模型说明")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingExplanation = false }
                } }
            }
        }
        .confirmationDialog("采用数学情景 \(pendingAdoptionVariant)？",
                            isPresented: $showingAdoption) {
            Button("确认采用模型情景") {
                guard let selected = pendingAdoptionVariant == "A"
                        ? result?.result : result?.minimum,
                      let threshold else { return }
                store.adoptInverse(selected, variant: pendingAdoptionVariant,
                                   mode: unitMode, threshold: threshold,
                                   target: targetTime, cap: maximumDoseText,
                                   count: countText, peakMin: peakFloor,
                                   peakMode: peakMode, cycleMin: cycleFloor,
                                   cycleMode: cycleMode, totalMax: totalCap)
            }
        } message: {
            Text("仅保存数学情景，不会新增真实服用记录。需由专业人士核对，不构成服药建议。")
        }
    }

    private func candidateCard(_ title: String, candidate: PKInverseCandidate?,
                               variant: String?) -> some View {
        GlassPanel {
            Text(title).font(.headline)
            if let candidate {
                if let reason = candidate.reason {
                    Text(failureText(reason)).foregroundStyle(.orange)
                } else if let doses = candidate.doses {
                    HStack {
                        Text("合计 \(candidate.mg ?? doses.reduce(0, { $0 + $1.mg }), format: .number.precision(.fractionLength(1))) mg（模型）")
                            .font(.headline)
                        Spacer()
                        Text("\(doses.count) 个节点").foregroundStyle(.secondary)
                    }
                    if let min = candidate.minLevel {
                        Text("窗口最低模型值：\(min.formatted(.number.precision(.fractionLength(3)))) \(unitMode == "blood" ? "mg/L" : "mg")")
                            .font(.subheadline)
                    }
                    if let peak = candidate.peak {
                        Text("窗口最高模型值：\(peak.formatted(.number.precision(.fractionLength(3)))) \(unitMode == "blood" ? "mg/L" : "mg")")
                            .font(.subheadline)
                    }
                    if let modeled = candidate.modeled {
                        Text("目标时刻模型值：\(modeled.formatted(.number.precision(.fractionLength(3)))) \(unitMode == "blood" ? "mg/L" : "mg")")
                            .font(.subheadline)
                    }
                    if let continuous = candidate.continuousFrom {
                        Text("连续达到参考值的模型起点：\(Date(timeIntervalSince1970: continuous / 1000).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(doses) { dose in
                        HStack {
                            Text(Date(timeIntervalSince1970: dose.time / 1000),
                                 format: .dateTime.month().day().hour().minute())
                            Spacer()
                            Text("\(dose.mg.formatted()) mg").monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    if let variant, !doses.isEmpty {
                        Button("采用模型情景 \(variant)") {
                            pendingAdoptionVariant = variant
                            showingAdoption = true
                        }
                        .buttonStyle(.glass)
                        .disabled(!store.isLoggedIn)
                        if !store.isLoggedIn {
                            Text("请先通过网站授权登录，再保存采用方案。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("搜索未找到满足设定的数学候选。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("暂无候选。调整参考值、药盒规格或节点数后重新计算。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("数学情景，不是处方或实际服药提醒。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func failureText(_ reason: String) -> String {
        switch reason {
        case "specs": return "该药物尚未保存药盒规格，请先添加完整单位。"
        case "cap": return "单次上限小于可组合的最小药盒规格。"
        case "fixedNoSolution": return "在固定次数和时间窗口内未找到数学候选。"
        case "peakNoSolution": return "覆盖段模型峰值条件无法满足。"
        case "cycleAlreadyBelow": return "当前模型值已经低于周期最低要求，口服吸收无法立即消除缺口。"
        case "cycleNoSolution": return "周期最低值约束在此搜索范围内无解。"
        case "totalNoSolution": return "累计新增剂量上限与其他约束无法同时满足。"
        case "targetWindowUnreached": return "在已有规格及有限搜索中未找到目标时刻落入设定 ± 偏差范围的候选；不代表数学上绝对无解。"
        case "targetWindowInvalid": return "目标时刻偏差需要填写正数。"
        case "constraintNoSolution": return "无法同时满足全部模型约束。"
        default: return "未找到数学候选：\(reason)"
        }
    }

    private var strengthsEditor: some View {
        NavigationStack {
            Form {
                Section("当前药物的完整药盒规格") {
                    ForEach(store.strengths(for: store.selectedDrugID), id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(item.mg.formatted()) mg / \(item.unit)")
                                if !item.label.isEmpty {
                                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.deleteStrength(id: item.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                Section("新增规格") {
                    HStack {
                        TextField("单个完整单位的含量", text: $strengthMg)
                            .keyboardType(.decimalPad)
                        Text("mg").foregroundStyle(.secondary)
                    }
                    Picker("单位", selection: $strengthUnit) {
                        Text("粒").tag("粒")
                        Text("片").tag("片")
                        Text("袋").tag("袋")
                    }
                    TextField("规格备注（可选）", text: $strengthLabel)
                    Button("添加规格") {
                        if let mg = Double(strengthMg), mg > 0 {
                            store.addStrength(mg: mg, unit: strengthUnit,
                                              label: strengthLabel)
                            strengthMg = ""; strengthLabel = ""
                        }
                    }
                    .disabled(store.strengths(for: store.selectedDrugID).count >= 8 ||
                              Double(strengthMg) == nil)
                }
                Text("仅用于验证数学搜索是否由完整单位组合而成，不决定实际服药剂量。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .nativeKeyboardDismissal()
            .navigationTitle("药盒规格")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingStrengthEditor = false }
                }
            }
        }
    }
}
