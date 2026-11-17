import Foundation
import Combine

@MainActor
final class NativeAppStore: ObservableObject {
    static let shared = NativeAppStore()

    @Published private(set) var catalog = PKCatalog.bundled()
    @Published private(set) var modelStatus = "使用安装包内置模型；联网后自动检查"
    @Published private(set) var modelVersion = "内置"
    @Published private(set) var modelRevision = 0
    @Published private(set) var modelUpdatedAt: Date?
    @Published private(set) var modelChecking = false
    @Published private(set) var engineVersion = "内置"
    @Published private(set) var modelUpdateRequiresApp = false
    @Published var showingModelUpgradePrompt = false
    // Only a signature-verified script can reach JavaScriptCore.
    @Published private(set) var engineSource: String?
    @Published private(set) var snapshot = PKCloudState()
    @Published private(set) var selectedDrugID = "pregabalin"
    @Published private(set) var username: String?
    @Published private(set) var syncStatus = "本机已保存 · 未登录"
    @Published private(set) var hasPendingChanges = false
    @Published private(set) var conflict = false
    @Published private(set) var busy = false
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published private(set) var releaseStatus = "尚未检查 App 新版本"
    @Published private(set) var releaseChecking = false
    @Published private(set) var releaseLastChecked: Date?
    @Published private(set) var latestRelease: PKNativeRelease?
    @Published private(set) var releaseAvailable = false
    @Published var showingReleaseUpdatePrompt = false
    @Published var automaticReleaseChecks = UserDefaults.standard.object(forKey: "PKAtlasAutomaticReleaseChecks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticReleaseChecks, forKey: "PKAtlasAutomaticReleaseChecks") }
    }

    private var base = PKCloudState()
    private var version = 0
    private var loaded = false
    private var syncTask: Task<Void, Never>?
    private var syncRunning = false
    private var lastModelCheck: Date?
    private var lastReleaseCheck: Date?
    private var lastReleasePrompted: String?

    var installedReleaseDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version)（Build \(build)）"
    }

    func checkNativeRelease(force: Bool = false) async {
        guard !releaseChecking, (force || automaticReleaseChecks) else { return }
        if !force, let lastReleaseCheck,
           Date.now.timeIntervalSince(lastReleaseCheck) < 6 * 3600 { return }
        releaseChecking = true
        lastReleaseCheck = .now
        defer { releaseChecking = false }
        do {
            let release = try await PKPrivateReleaseClient.shared.fetch()
            let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
            let buildNumber = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            latestRelease = release
            releaseLastChecked = .now
            releaseAvailable = PKReleaseVerifier.newer(release, than: installedVersion,
                                                        localBuild: buildNumber)
            if releaseAvailable {
                releaseStatus = "GitHub Releases 已发布 \(release.displayVersion)"
                let identifier = "\(release.version):\(release.build)"
                if lastReleasePrompted != identifier {
                    lastReleasePrompted = identifier
                    showingReleaseUpdatePrompt = true
                }
            } else {
                releaseStatus = "已是 GitHub 最新版（独立发布密钥验证通过）"
            }
        } catch {
            releaseStatus = "无法确认 App 最新版本：\(error.localizedDescription)"
            // Retry after ~10 minutes instead of suppressing checks for 6 hours
            // following a transient offline period.
            lastReleaseCheck = Date.now.addingTimeInterval(-(6 * 3600 - 600))
            if force { releaseLastChecked = .now }
        }
    }

    private init() {
        if let doc = try? PKSecureDisk.load(username: "__local__") {
            snapshot = doc.state
            base = doc.base
            version = doc.version
            selectedDrugID = doc.selectedDrug
        }
        hasPendingChanges = snapshot != base
        let bundled = PKCatalog.bundled()
        if let signed = PKSignedEngine.restored(bundled: bundled) {
            catalog = signed.catalog
            engineSource = signed.script
            engineVersion = String(signed.engineVersion.prefix(12))
            modelVersion = String(signed.catalogVersion.prefix(12))
            modelStatus = "已恢复本机签名验证的算法与药物目录 · 离线可用"
            return
        }

        if let expected = PKModelDistribution.expectedEngineVersion,
           let restored = PKModelDistribution.cached(expectedEngine: expected, bundled: bundled) {
            catalog = restored.catalog
            modelVersion = String(restored.version.prefix(12))
            modelStatus = "已恢复本机校验通过的模型 · 离线可用"
        }
    }

    var doses: [PKDose] { snapshot.doses.sorted { $0.time > $1.time } }
    var meals: [PKIntake] { snapshot.meals.sorted { $0.time > $1.time } }
    var selectedDrug: PKDrug? {
        catalog.drugs.first { $0.id == selectedDrugID } ?? catalog.drugs.first
    }
    var model: PKModel { PKModel(catalog: catalog, doses: snapshot.doses,
                                 intakes: snapshot.meals, renalCrCl: snapshot.renalCrCl,
                                 engineSource: engineSource) }
    var isLoggedIn: Bool { username != nil }

    /// At app launch and foreground activation, fetch an Ed25519-signed
    /// *data+code* bundle from the official backend. Never activate a partial
    /// or incompatible algorithm, even if the catalog itself is valid.
    func refreshModel(force: Bool = false) async {
        guard PKBackendConfiguration.baseURL != nil else {
            modelStatus = "仅使用安装包内置模型（未配置云端服务器）"
            return
        }
        guard PKSignedEngine.publicKeyData != nil else {
            modelStatus = "需要在设置中配置自己的引擎验签公钥，才会下载运行远程计算代码"
            return
        }
        guard !modelChecking else { return }
        if !force, let lastModelCheck,
           Date.now.timeIntervalSince(lastModelCheck) < 120 { return }
        modelChecking = true
        lastModelCheck = .now
        defer { modelChecking = false }
        do {
            let envelope = try await PKCloudAPI.shared.signedEnginePackage()
            let verified = try PKSignedEngine.verify(
                envelope, bundled: PKCatalog.bundled(), previous: catalog)
            let newEngine = String(verified.engineVersion.prefix(12))
            let newCatalog = String(verified.catalogVersion.prefix(12))
            if engineVersion != newEngine || modelVersion != newCatalog || engineSource == nil {
                // Executable JS can be updated only after the same offline
                // mathematical entrypoints pass an isolated JSContext test.
                try PKSignedEngine.smokeTest(verified)
                try PKSignedEngine.save(envelope)
                PKModel.invalidateCaches()
                engineSource = verified.script
                catalog = verified.catalog
                engineVersion = newEngine
                modelVersion = newCatalog
                modelRevision += 1
                modelStatus = "网站药代公式、反算引擎与药物数据已安全热更新 · 离线可用"
            } else {
                modelStatus = "当前公式及反算算法已是云端最新版 · 签名校验通过"
            }
            modelUpdatedAt = .now
            modelUpdateRequiresApp = false
        } catch let failure as PKSignedEngineFailure {
            modelStatus = failure.localizedDescription
            switch failure {
            case .updateApp, .executionFailed:
                modelUpdateRequiresApp = true
                showingModelUpgradePrompt = true
            default:
                break
            }
        } catch {
            modelStatus = "自动更新未完成，使用上次验证通过的本地算法：" +
                error.localizedDescription
        }
    }

    func start() async {
        guard !loaded else { return }
        loaded = true
        guard PKBackendConfiguration.baseURL != nil else {
            syncStatus = "离线模式 · 未配置云端服务器，不上传药物数据"
            return
        }
        do {
            let me = try await PKCloudAPI.shared.me()
            let remote = try await PKCloudAPI.shared.state()
            try adopt(remote, as: me.username)
        } catch {
            if username == nil { syncStatus = "本机模式 · 联网后可登录" }
        }
    }

    func referenceValue(drugID: String, mode: String) -> Double? {
        guard let raw = snapshot.settings["referenceMemory"]?.object?[drugID]?.object,
              raw["mode"]?.string == mode else { return nil }
        let value = raw["value"]?.number ??
                    raw["value"]?.string.flatMap(Double.init)
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Same per-drug inverseMemory fields as the deployed website. Updating
    /// them uses the existing encrypted draft and debounced cloud sync path.
    func inverseDraft(for drugID: String) -> [String: String] {
        guard let data = snapshot.settings["inverseMemory"]?.object?[drugID]?.object else { return [:] }
        return data.compactMapValues { $0.string }
    }

    func saveInverseDraft(_ fields: [String: String], drugID: String) {
        guard catalog.drugs.contains(where: { $0.id == drugID }) else { return }
        let allowed: Set<String> = [
            "pointTarget", "pointTargetLimitEnabled", "pointTargetLimitBlood", "pointTargetLimitEquivalent",
            "pointMaxDose", "pointTotalMax", "pointCount", "pointPeakMin", "pointPeakMode",
            "pointCycleMin", "pointCycleMode", "targetStart", "holdHours", "inverseCount"
        ]
        var memory = snapshot.settings["inverseMemory"]?.object ?? [:]
        var current = memory[drugID]?.object ?? [:]
        var modified = false
        for (key, value) in fields where allowed.contains(key) && value.utf8.count <= 32 {
            if current[key]?.string != value {
                current[key] = .string(value)
                modified = true
            }
        }
        guard modified else { return }
        memory[drugID] = .object(current)
        snapshot.settings["inverseMemory"] = .object(memory)
        changed()
    }

    func setReference(drugID: String, mode: String, text: String) {
        guard catalog.drugs.contains(where: { $0.id == drugID }),
              ["blood", "equivalent"].contains(mode) else { return }
        var memory = snapshot.settings["referenceMemory"]?.object ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            memory.removeValue(forKey: drugID)
        } else {
            guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
                  value.isFinite, value > 0, value <= 1_000_000 else { return }
            memory[drugID] = .object(["mode": .string(mode), "value": .number(value)])
        }
        snapshot.settings["referenceMemory"] = .object(memory)
        changed()
    }

    func selectedAdoptedDoses() -> [PKDose] {
        guard let raw = snapshot.settings["inverseMemory"]?.object?[selectedDrugID]?.object?["adoptedPointPlan"]?.object,
              let nodes = raw["doses"], case .array(let values) = nodes else { return [] }
        return values.compactMap { element in
            guard let obj = element.object, let mg = obj["mg"]?.number,
                  let at = obj["time"]?.number, mg > 0, at.isFinite else { return nil }
            return PKDose(drug: selectedDrugID, mg: mg,
                          time: Date(timeIntervalSince1970: at / 1000))
        }
    }

    func strengths(for drugID: String) -> [(id: String, mg: Double, unit: String, label: String)] {
        guard let value = snapshot.plans[drugID]?.object?["strengths"],
              case .array(let array) = value else { return [] }
        return array.compactMap { item in
            guard let row = item.object, let mg = row["mg"]?.number,
                  mg.isFinite, mg >= 0.001 else { return nil }
            return (id: row["id"]?.string ?? UUID().uuidString, mg: mg,
                    unit: row["unit"]?.string ?? "粒",
                    label: row["label"]?.string ?? "")
        }
    }

    func addStrength(mg: Double, unit: String, label: String) {
        guard mg.isFinite, mg >= 0.001, mg < 1_000_000,
              ["粒", "片", "袋"].contains(unit) else { return }
        let drugID = selectedDrugID
        var plan = snapshot.plans[drugID]?.object ?? [:]
        var strengths: [PKJSON]
        if let value = plan["strengths"], case .array(let old) = value {
            strengths = old
        } else { strengths = [] }
        guard strengths.count < 8 else { return }
        strengths.append(.object([
            "id": .string(UUID().uuidString),
            "mg": .number(mg),
            "unit": .string(unit),
            "label": .string(String(label.prefix(40)))
        ]))
        plan["strengths"] = .array(strengths)
        snapshot.plans[drugID] = .object(plan)
        changed()
    }

    func deleteStrength(id: String) {
        var plan = snapshot.plans[selectedDrugID]?.object ?? [:]
        guard let value = plan["strengths"], case .array(let old) = value else { return }
        plan["strengths"] = .array(old.filter { $0.object?["id"]?.string != id })
        snapshot.plans[selectedDrugID] = .object(plan)
        changed()
    }

    func adoptInverse(_ candidate: PKInverseCandidate, variant: String,
                      mode: String, threshold: Double, target: Date,
                      cap: String, count: String, peakMin: Double,
                      peakMode: String, cycleMin: Double, cycleMode: String,
                      totalMax: Double?) {
        guard username != nil, ["A", "B"].contains(variant),
              let doses = candidate.doses, !doses.isEmpty else { return }
        var memory = snapshot.settings["inverseMemory"]?.object ?? [:]
        var drugMemory = memory[selectedDrugID]?.object ?? [:]
        let baseline = snapshot.doses.filter { $0.drug == selectedDrugID }
            .map { PKJSON.string($0.id) }
        let planned = doses.map { item -> PKJSON in
            var object: [String: PKJSON] = [
                "time": .number(item.time),
                "mg": .number(item.mg)
            ]
            if let parts = item.parts { object["parts"] = .array(parts) }
            return .object(object)
        }
        drugMemory["adoptedPointPlan"] = .object([
            "v": .number(1),
            "variant": .string(variant),
            "drug": .string(selectedDrugID),
            "adoptedAt": .number(Date.now.timeIntervalSince1970 * 1000),
            "target": .number(target.timeIntervalSince1970 * 1000),
            "threshold": .number(threshold),
            "mode": .string(mode),
            "cap": .string(cap),
            "count": .string(count),
            "peakMin": .number(peakMin),
            "peakMode": .string(peakMode),
            "cycleMin": .number(cycleMin),
            "cycleMode": .string(cycleMode),
            "totalMax": .number(totalMax ?? 0),
            "baselineIds": .array(baseline),
            "doses": .array(planned),
            "manualMatches": .object([:])
        ])
        memory[selectedDrugID] = .object(drugMemory)
        snapshot.settings["inverseMemory"] = .object(memory)
        changed()
        Task { await NativeReminderScheduler.shared.refresh() }
    }

    func cancelAdoptedInverse() {
        var memory = snapshot.settings["inverseMemory"]?.object ?? [:]
        var drugMemory = memory[selectedDrugID]?.object ?? [:]
        drugMemory.removeValue(forKey: "adoptedPointPlan")
        memory[selectedDrugID] = .object(drugMemory)
        snapshot.settings["inverseMemory"] = .object(memory)
        changed()
        Task { await NativeReminderScheduler.shared.refresh() }
    }

    func switchDrug(_ id: String) {
        guard catalog.drugs.contains(where: { $0.id == id }) else { return }
        selectedDrugID = id
        saveLocal()
    }

    private func saveLocal() {
        do {
            try PKSecureDisk.save(
                PKDiskDocument(state: snapshot, base: base, version: version,
                               selectedDrug: selectedDrugID, savedAt: .now),
                username: username ?? "__local__"
            )
        } catch {
            errorMessage = error.localizedDescription + "。请勿清理应用数据。"
            showingError = true
            syncStatus = "本机保存失败"
        }
    }

    private func changed() {
        hasPendingChanges = snapshot != base
        saveLocal()
        guard !showingError else { return }
        if username != nil {
            syncStatus = hasPendingChanges ? "本机已保存，等待云端确认" : "云端已同步"
            syncTask?.cancel()
            syncTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                if !Task.isCancelled { await self?.sync() }
            }
        } else {
            syncStatus = "本机加密保存 · 未登录"
        }
    }

    func addDose(drug: String, mg: Double, time: Date) {
        guard catalog.drugs.contains(where: { $0.id == drug }),
              mg.isFinite, mg > 0, mg < 100_000 else { return }
        snapshot.saveDose(PKDose(drug: drug, mg: mg, time: time))
        changed()
    }

    /// Explicit Health -> App import. Linked existing doses aren't duplicated;
    /// units other than mass, unknown products, and ambiguous names are skipped.
    @discardableResult
    func importHealthMatches(_ items: [PKHealthDoseMatch]) -> (imported: Int, linked: Int, skipped: Int) {
        var imported = 0, linked = 0, skipped = 0
        var links = snapshot.settings["healthDoseLinks"]?.object ?? [:]
        for event in items {
            let key = event.eventUUID.uuidString
            guard links[key] == nil,
                  let drug = event.drugID,
                  let mg = event.mg, mg.isFinite, mg > 0, mg < 100_000,
                  catalog.drugs.contains(where: { $0.id == drug }) else {
                skipped += 1; continue
            }
            if let existing = snapshot.doses.first(where: {
                $0.drug == drug && abs($0.mg - mg) < 0.0001 &&
                    abs($0.time.timeIntervalSince(event.time)) <= 300
            }) {
                links[key] = .string(existing.id)
                linked += 1
                continue
            }
            let id = "healthkit-" + key
            let record = PKDose(id: id, drug: drug, mg: mg, time: event.time)
            snapshot.saveDose(record)
            if let index = snapshot.records.firstIndex(where: { $0["id"]?.string == id }) {
                snapshot.records[index]["source"] = .string("healthkit-read")
            }
            links[key] = .string(id)
            imported += 1
        }
        if imported + linked > 0 {
            snapshot.settings["healthDoseLinks"] = .object(links)
            changed()
        }
        return (imported, linked, skipped)
    }

    func editDose(_ dose: PKDose) {
        guard dose.mg.isFinite, dose.mg > 0, dose.mg < 100_000 else { return }
        snapshot.saveDose(dose); changed()
    }
    func removeDose(_ id: String) { snapshot.deleteDose(id); changed() }

    func addMeal(time: Date, kind: String, mealType: String,
                 drink: String, note: String) {
        guard ["meal","drink"].contains(kind) else { return }
        snapshot.saveIntake(PKIntake(id: UUID().uuidString, time: time, kind: kind,
                                     mealType: mealType, drink: drink, note: note))
        changed()
    }
    func deleteMeal(_ id: String) { snapshot.deleteIntake(id); changed() }

    func finishWebAuthorization(username user: String) async {
        busy = true
        defer { busy = false }
        do {
            let remote = try await PKCloudAPI.shared.state()
            try adopt(remote, as: user)
            await NativeReminderScheduler.shared.refresh()
            await PKRemotePushManager.shared.registerIfAuthorized()
        } catch {
            errorMessage = "网页授权已完成，但首次同步失败：" + error.localizedDescription
            showingError = true
        }
    }

    private func adopt(_ remote: PKServerResponse, as user: String) throws {
        let old = try? PKSecureDisk.load(username: user)
        username = user
        if let old, old.state != old.base {
            guard let doses = PKMerge.rows(base: old.base.records,
                                           local: old.state.records,
                                           remote: remote.state.records),
                  let meals = PKMerge.rows(base: old.base.intakes,
                                           local: old.state.intakes,
                                           remote: remote.state.intakes) else {
                snapshot = old.state
                base = old.base
                version = old.version
                conflict = true
                syncStatus = "设备修改冲突 · 未覆盖任何记录"
                saveLocal()
                return
            }
            var merged = remote.state
            merged.records = doses
            merged.intakes = meals
            guard let settings = PKMerge.fields(base: old.base.settings,
                    local: old.state.settings, remote: remote.state.settings),
                  let plans = PKMerge.fields(base: old.base.plans,
                    local: old.state.plans, remote: remote.state.plans),
                  let courses = PKMerge.rows(base: old.base.courses,
                    local: old.state.courses, remote: remote.state.courses) else {
                snapshot = old.state; base = old.base; version = old.version
                conflict = true
                syncStatus = "账号配置与云端修改冲突 · 已保留本机快照"
                saveLocal()
                return
            }
            merged.settings = settings
            merged.plans = plans
            merged.courses = courses
            snapshot = merged
            selectedDrugID = old.selectedDrug
        } else {
            snapshot = remote.state
            selectedDrugID = old?.selectedDrug ?? remote.state.settings["currentDrug"]?.string ?? "pregabalin"
        }
        base = remote.state
        version = remote.version
        conflict = false
        hasPendingChanges = snapshot != base
        saveLocal()
        syncStatus = hasPendingChanges ? "本机草稿已恢复，等待同步" : "云端已同步"
        if hasPendingChanges { Task { await sync() } }
    }

    func refresh() async {
        guard username != nil, !syncRunning, !hasPendingChanges else {
            if hasPendingChanges { await sync() }
            return
        }
        do {
            let remote = try await PKCloudAPI.shared.state()
            if !hasPendingChanges {
                snapshot = remote.state
                base = remote.state
                version = remote.version
                saveLocal()
                syncStatus = "云端已同步"
            }
        } catch {
            syncStatus = "离线 · 本机模型仍可使用"
        }
    }

    func sync() async {
        guard username != nil, !syncRunning, !conflict, hasPendingChanges else { return }
        syncRunning = true
        defer { syncRunning = false }
        syncStatus = "正在确认云端保存…"

        for _ in 0..<3 {
            let sent = snapshot
            let previous = base
            var sections: [String: PKJSON] = [:]
            if sent.records != previous.records {
                sections["records"] = .array(sent.records.map { .object($0) })
            }
            if sent.intakes != previous.intakes {
                sections["intakes"] = .array(sent.intakes.map { .object($0) })
            }
            if sent.settings != previous.settings {
                sections["settings"] = .object(sent.settings)
            }
            if sent.plans != previous.plans {
                sections["plans"] = .object(sent.plans)
            }
            if sent.courses != previous.courses {
                sections["courses"] = .array(sent.courses.map { .object($0) })
            }
            if sections.isEmpty {
                hasPendingChanges = false
                syncStatus = "云端已同步"
                return
            }
            do {
                try await PKCloudAPI.shared.putSections(version: version, sections: sections)
                let remote = try await PKCloudAPI.shared.state()
                // Preserve edits made while network was in flight. We do not
                // declare success until a real server read-back matches.
                guard remote.state.records == sent.records ||
                      sections["records"] == nil else {
                    conflict = true; syncStatus = "云端回读不一致，保留本机记录"; saveLocal()
                    return
                }
                guard remote.state.intakes == sent.intakes ||
                      sections["intakes"] == nil else {
                    conflict = true; syncStatus = "云端饮食回读不一致"; saveLocal()
                    return
                }
                guard (sections["settings"] == nil || remote.state.settings == sent.settings),
                      (sections["plans"] == nil || remote.state.plans == sent.plans),
                      (sections["courses"] == nil || remote.state.courses == sent.courses) else {
                    conflict = true
                    syncStatus = "云端配置回读不一致，保留本机修改"
                    saveLocal()
                    return
                }
                base = remote.state
                version = remote.version
                if snapshot == sent {
                    snapshot = remote.state
                }
                hasPendingChanges = snapshot != base
                saveLocal()
                syncStatus = hasPendingChanges ? "已保留较新的本机更改" : "云端已回读确认"
                if hasPendingChanges {
                    Task { try? await Task.sleep(for: .milliseconds(500)); await self.sync() }
                }
                await NativeReminderScheduler.shared.refresh()
                return
            } catch let error as PKHTTPError where error.status == 409 {
                do {
                    let remote = try await PKCloudAPI.shared.state()
                    guard let mergedRecords = PKMerge.rows(
                        base: base.records, local: snapshot.records, remote: remote.state.records),
                          let mergedIntakes = PKMerge.rows(
                            base: base.intakes, local: snapshot.intakes, remote: remote.state.intakes) else {
                        conflict = true
                        syncStatus = "同一条记录在其他设备修改 · 暂停同步"
                        saveLocal()
                        return
                    }
                    guard let mergedSettings = PKMerge.fields(
                            base: base.settings, local: snapshot.settings,
                            remote: remote.state.settings),
                          let mergedPlans = PKMerge.fields(
                            base: base.plans, local: snapshot.plans,
                            remote: remote.state.plans),
                          let mergedCourses = PKMerge.rows(base: base.courses,
                            local: snapshot.courses, remote: remote.state.courses) else {
                        conflict = true
                        syncStatus = "云端与本机配置存在冲突 · 暂停覆盖"
                        saveLocal()
                        return
                    }
                    snapshot.records = mergedRecords
                    snapshot.intakes = mergedIntakes
                    snapshot.settings = mergedSettings
                    snapshot.plans = mergedPlans
                    snapshot.courses = mergedCourses
                    base = remote.state
                    version = remote.version
                    hasPendingChanges = snapshot != base
                    saveLocal()
                } catch {
                    syncStatus = "网络暂不可用，本机记录已保留"
                    return
                }
            } catch {
                syncStatus = "网络暂不可用，本机记录已保留"
                return
            }
        }
        syncStatus = "云端版本变动较快，保留本机更改"
    }

    func resolveConflictByUsingCloud() async {
        guard username != nil else { return }
        do {
            let latest = try await PKCloudAPI.shared.state()
            snapshot = latest.state
            base = latest.state
            version = latest.version
            conflict = false; hasPendingChanges = false
            syncStatus = "已选择云端版本"
            saveLocal()
        } catch {
            syncStatus = "无法读取云端版本，请稍后重试"
        }
    }

    func logout() async {
        // Never erase encrypted local state. Offline drafts must remain
        // recoverable after re-authentication.
        saveLocal()
        await PKRemotePushManager.shared.unregisterCurrentDevice()
        try? await PKCloudAPI.shared.logout()
        PKSessionVault.clear()
        await NativeReminderScheduler.shared.clear()
        username = nil
        if let anonymous = try? PKSecureDisk.load(username: "__local__") {
            snapshot = anonymous.state; base = anonymous.base
            version = anonymous.version; selectedDrugID = anonymous.selectedDrug
        } else {
            snapshot = PKCloudState(); base = snapshot; version = 0
        }
        hasPendingChanges = snapshot != base
        conflict = false
        syncStatus = "已退出 · 本机私人快照仍加密保存"
    }

    func exportSnapshot() throws -> URL {
        let data = try JSONEncoder().encode(snapshot)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PKAtlas-state-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: out, options: .atomic)
        return out
    }
}
