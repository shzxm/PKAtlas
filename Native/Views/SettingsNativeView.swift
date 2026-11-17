import SwiftUI
import AuthenticationServices

struct SettingsNativeView: View {
    @EnvironmentObject private var store: NativeAppStore
    @EnvironmentObject private var reminders: NativeReminderScheduler
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var authorizingInBrowser = false
    @State private var exportURL: URL?
    @State private var showConflictConfirmation = false
    @State private var showingLogout = false
    @State private var currentSessions: [AccountSession] = []
    @State private var loadingSessions = false
    @StateObject private var remotePush = PKRemotePushManager.shared
    @StateObject private var healthMedications = PKHealthMedications.shared
    @State private var showHealthImportConfirmation = false
    @State private var healthImportResult = ""
    @State private var serverURLText = PKBackendConfiguration.baseURL?.absoluteString ?? ""
    @State private var serverSigningKey = PKBackendConfiguration.trustedKeyHex
    @State private var serverSetupStatus = "未配置时所有服药记录仅保存在本机"

    struct AccountSession: Decodable, Identifiable {
        var id: String
        var name: String
        var current: Bool
        var remembered: Bool
        var expiresAt: Double
    }
    struct SessionList: Decodable { let sessions: [AccountSession] }
    struct RevokeResponse: Decodable { let ok: Bool; let revoked: Int }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: store.isLoggedIn ? "checkmark.icloud.fill" : "iphone.gen3")
                        .font(.title2)
                        .foregroundStyle(store.isLoggedIn ? .mint : .cyan)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.isLoggedIn ? (store.username ?? "已登录") : "本机离线模式")
                            .font(.headline)
                        Text(store.syncStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("native.sync.status")
                    }
                    Spacer()
                    if store.busy { ProgressView() }
                }
                if store.hasPendingChanges {
                    Label("存在尚未完成云端确认的记录，本机密文已保存",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: { Text("数据与账号") }

            Section("可选云同步 · 私人服务器") {
                TextField("https://your-server.example", text: $serverURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("native.server.origin")
                SecureField("可选：服务器引擎验签公钥（64位十六进制）", text: $serverSigningKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存配置并重新核对模型") {
                    guard !store.isLoggedIn else {
                        serverSetupStatus = "请先退出当前云端账号再更换服务器。"
                        return
                    }
                    guard PKBackendConfiguration.validatedOrigin(serverURLText) != nil ||
                          serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        serverSetupStatus = "服务器必须是 HTTPS 域名，不支持裸 IP、端口或带凭据的 URL。"
                        return
                    }
                    guard PKBackendConfiguration.setTrustedKeyHex(serverSigningKey),
                          PKBackendConfiguration.configure(serverURLText) else {
                        serverSetupStatus = "服务器公钥应为 64 位十六进制。"
                        return
                    }
                    serverSetupStatus = PKBackendConfiguration.baseURL == nil ?
                        "已关闭云同步，保持离线本机模式" : "已保存服务器；仅在你手动配置后才与此域名通信"
                    Task { await store.refreshModel(force: true) }
                }
                .disabled(store.isLoggedIn)
                Text(serverSetupStatus).font(.caption).foregroundStyle(.secondary)
                Text("公开 IPA 不含开发者私人服务器。若配置自己掌控的 HTTPS 站点，将把登录会话及选定的同步数据传送到该站点；公开 App 无法保证你自行选择的服务器不会记录 IP。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !store.isLoggedIn {
                Section("通过官方网站登录") {
                    Button {
                        Task { await authorizeViaWebsite() }
                    } label: {
                        HStack {
                            Label("打开药时网页登录并授权", systemImage: "safari")
                            Spacer()
                            if authorizingInBrowser { ProgressView() }
                        }
                    }
                    .disabled(authorizingInBrowser || store.busy || PKBackendConfiguration.baseURL == nil)
                    .accessibilityIdentifier("native.auth.browser")
                    Text("只有手动填写自己的 HTTPS 云端服务器后，才能使用网页登录。账号密码由所选服务器处理，不会发送到 GitHub。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("首次授权后下载当前云端记录，并尝试安全恢复本机草稿。匿名草稿不会擅自上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("云端同步") {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("立即核对云端", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if store.hasPendingChanges {
                        Label("本机更改正在自动同步，网络断开时将保留草稿并在下次启动重试",
                              systemImage: "icloud.and.arrow.up")
                            .font(.footnote)
                    }
                    if store.conflict {
                        Label("云端与本机修改冲突，未自动覆盖任何记录",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("放弃本机冲突并采用云端版本", role: .destructive) {
                            showConflictConfirmation = true
                        }
                    }
                    Button {
                        Task { await fetchSessions() }
                    } label: {
                        Label("管理已登录设备", systemImage: "person.2.badge.gearshape")
                    }
                    if loadingSessions { ProgressView() }
                    ForEach(currentSessions) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(device.name)
                                Text(device.current ? "当前设备" : (device.remembered ? "个人设备" : "临时会话"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.current {
                                Image(systemName: "checkmark.circle").foregroundStyle(.mint)
                            }
                        }
                    }
                    Button("退出登录", role: .destructive) { showingLogout = true }
                }
            }

            Section("通知与 Siri") {
                Button {
                    Task { await reminders.requestPermission() }
                } label: {
                    Label("开启系统通知", systemImage: "bell.badge")
                }
                Button {
                    Task { await reminders.refresh() }
                } label: {
                    Label("同步未来 7 天本机提醒", systemImage: "clock.badge.checkmark")
                }
                Text(reminders.message)
                    .font(.footnote).foregroundStyle(.secondary)
                Label("Siri 和快捷指令支持：查询本机模型、记录已服药物、打开药时。",
                      systemImage: "waveform")
                    .font(.footnote)
                    .accessibilityIdentifier("native.siri.capabilities")
                Text(remotePush.status)
                    .font(.footnote).foregroundStyle(.secondary)
                Text("开启通知后自动登记 APNs 设备令牌。后台远程更新需要服务器 Apple APNs 凭证及有效签名，iOS 不保证每次即时唤醒。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("GitHub Releases · 版本更新") {
                HStack {
                    Label("已安装版本", systemImage: "iphone")
                    Spacer()
                    Text(store.installedReleaseDescription)
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                if let latest = store.latestRelease {
                    HStack {
                        Label("GitHub 最新版", systemImage: "checkmark.shield")
                        Spacer()
                        Text(latest.displayVersion).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if store.releaseAvailable {
                        Label("GitHub 发布了新版本", systemImage: "arrow.up.circle.fill")
                            .foregroundStyle(.orange)
                        Text(latest.releaseNotes).font(.footnote)
                        Text("GitHub Release 资产：" + latest.fileName)
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = latest.fileName
                        } label: {
                            Label("复制未签名 IPA 文件名", systemImage: "doc.on.doc")
                        }
                        if let url = URL(string: "https://github.com/shzxm/PKAtlas/releases/latest") {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("打开 GitHub Releases", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
                Text(store.releaseStatus)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("native.release.status")
                if let checked = store.releaseLastChecked {
                    Text("最近检查：" + checked.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.checkNativeRelease(force: true) }
                } label: {
                    HStack {
                        Label("通过 GitHub 检查最新版本", systemImage: "arrow.clockwise")
                        if store.releaseChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.releaseChecking)
                .accessibilityIdentifier("native.release.check")
                Toggle("启动及回到前台自动检查版本", isOn: $store.automaticReleaseChecks)
                Text("版本检查仅请求 GitHub Releases 官方 API。不会发送药物记录、账号 Cookie、HealthKit 数据或个人服务器域名；GitHub 会看到网络出口 IP，必要时使用 VPN。关闭自动检查后仅手动请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("药代模型 · 自动热更新") {
                HStack {
                    Label("模型参数版本", systemImage: "arrow.triangle.2.circlepath.icloud")
                    Spacer()
                    Text(store.modelVersion).monospaced().foregroundStyle(.secondary)
                }
                HStack {
                    Label("算法版本", systemImage: "function")
                    Spacer()
                    Text(store.engineVersion).monospaced().foregroundStyle(.secondary)
                }
                if store.modelUpdateRequiresApp {
                    Label("网站新版优化方法需要更新 IPA 才能使用；本机旧算法未被覆盖。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(store.modelStatus)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("native.model.update.status")
                if let checked = store.modelUpdatedAt {
                    Text("最近校验：" + checked.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.refreshModel(force: true) }
                } label: {
                    Label("立即核对网站模型", systemImage: "arrow.clockwise")
                }
                .disabled(store.modelChecking)
                Text("打开 App 或回到前台自动检查。药物数据、药代计算公式及兼容的反算算法通过 Ed25519 数字签名验证后自动热更新并离线保存；校验失败保留旧版。若新优化需要 App 尚未支持的桥接能力，则提醒安装新版 IPA。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Apple 健康 · 用药记录") {
                Button {
                    Task { await healthMedications.requestAndRead() }
                } label: {
                    Label("授权读取 Apple 健康已登记药物", systemImage: "heart.text.square")
                }
                Text(healthMedications.status)
                    .font(.footnote).foregroundStyle(.secondary)
                if healthMedications.reviewing { ProgressView("正在读取 Apple 健康…") }
                Text("自行签名的 IPA 必须实际授予 HealthKit 签名权限；仅在 Xcode 的 entitlements 文件中声明并不代表安装包拥有权限。若点击后闪退，请导出 PKAtlas .ips 崩溃日志以确认是否为签名、授权或系统调用问题。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let lastStage = UserDefaults.standard.string(forKey: "PKHealthLastReadStage"),
                   lastStage != "complete" {
                    Text("最近读取阶段：" + lastStage)
                        .font(.caption2).foregroundStyle(.orange)
                }
                Button {
                    healthMedications.openHealthApp()
                } label: {
                    Label("打开 Apple 健康，手动登记服药", systemImage: "arrow.up.forward.app")
                }
                Text("Apple 健康没有公开的指定药物填写页跳转或预填接口。此按钮仅尝试打开健康 App；若系统不支持，请手动进入「浏览 → 用药」。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !healthMedications.matches.isEmpty {
                    let possible = healthMedications.matches.filter { $0.drugID != nil && $0.mg != nil }
                    Text("最近 120 天已读取 \(healthMedications.matches.count) 条已服事件，其中 \(possible.count) 条药物名称及 mg 剂量可匹配。")
                        .font(.subheadline)
                    ForEach(healthMedications.matches.prefix(40)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.medicationName).font(.subheadline.bold())
                                Spacer()
                                if let drugID = entry.drugID, entry.mg != nil {
                                    Text("匹配 \(store.catalog.drugs.first(where: { $0.id == drugID })?.name ?? drugID)")
                                        .font(.caption).foregroundStyle(.mint)
                                } else {
                                    Text("待人工核对").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text("\(entry.time.formatted(date: .abbreviated, time: .shortened)) · 健康记录 \(entry.quantityText)")
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.mg == nil {
                                Text("剂量是片数、体积或未提供，不能直接按 mg 导入。")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        showHealthImportConfirmation = true
                    } label: {
                        Label("核对并导入可匹配的记录到药时", systemImage: "square.and.arrow.down")
                    }
                    .disabled(possible.isEmpty)
                    Text("导入后仅写入药时本机记录及已登录账号的云端同步，不会反向写入 Apple 健康。重复事件和现有同药同剂量的近时记录自动关联，不重复新建。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !healthImportResult.isEmpty {
                    Text(healthImportResult).font(.footnote).foregroundStyle(.mint)
                }
                if healthMedications.matches.isEmpty && !healthMedications.approvedMedications.isEmpty {
                    Text("未读到已服事件，或当前授权的药物尚无对应记录。已授权药物：" + healthMedications.approvedMedications.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("HealthKit 不允许第三方写入 Apple 健康的实际服药事件，且不应把未服用或模型假设节点当作已服。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("数据导出与完整性") {
                Button {
                    do { exportURL = try store.exportSnapshot() }
                    catch {
                        store.errorMessage = error.localizedDescription
                        store.showingError = true
                    }
                } label: {
                    Label("导出原始兼容格式 JSON", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("分享最近导出的 JSON", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                Text("文件只在明确点击导出后生成临时副本。原始记录中的扩展字段与历史来源会保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("本机模型") {
                Text("药物目录：\(store.catalog.drugs.count) 项")
                Text("本地计算支持饮食匹配、参考达峰、半衰期、叠加浓度、剂量等效量和情景对比。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("内置模型保留作为离线回退。药物参数与签名药代/反算引擎在打开 App 时从服务器自动检查更新；遇到不兼容计算接口会提示更新 IPA。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.selectedDrug?.id == "pregabalin" {
                    Text("普瑞巴林肾功能修正使用已同步账号设置中的肌酐清除率，未填写时采用参考参数。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .nativeKeyboardDismissal()
        .navigationTitle("我的药时")
        .confirmationDialog("退出当前账号？", isPresented: $showingLogout) {
            Button("退出登录", role: .destructive) {
                Task { await store.logout() }
            }
        } message: {
            Text("云端未确认的本机草稿会继续加密保存，下一次登录可尝试恢复。")
        }
        .confirmationDialog("导入 Apple 健康中已登记的实际服用？", isPresented: $showHealthImportConfirmation) {
            Button("确认导入到药时") {
                let result = store.importHealthMatches(healthMedications.matches)
                healthImportResult = "新增 \(result.imported) 条，关联已有 \(result.linked) 条，跳过 \(result.skipped) 条未匹配或已关联记录。"
            }
        } message: {
            Text("仅导入名称唯一匹配、剂量以质量单位换算为 mg 的已服记录；不把待服和假设节点作为真实服药。")
        }
        .confirmationDialog("放弃本机冲突数据？", isPresented: $showConflictConfirmation) {
            Button("采用云端版本并放弃冲突的本机更改", role: .destructive) {
                Task { await store.resolveConflictByUsingCloud() }
            }
        } message: {
            Text("此操作可能放弃本机未同步记录。建议先导出 JSON 备份。")
        }
    }

    private func authorizeViaWebsite() async {
        guard !authorizingInBrowser else { return }
        authorizingInBrowser = true
        defer { authorizingInBrowser = false }
        do {
            let pending = try PKWebAuthRequest.create()
            let result = try await webAuthenticationSession.authenticate(
                using: pending.url,
                callback: .customScheme("pkatlasopen"),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            let code = try pending.checkCallback(result)
            let token = try await PKCloudAPI.shared.exchangeNative(
                code: code, verifier: pending.verifier, state: pending.state)
            try PKSessionVault.save(token.sessionToken)
            await store.finishWebAuthorization(username: token.username)
        } catch {
            // User cancellation is not a login error.
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                store.errorMessage = error.localizedDescription
                store.showingError = true
            }
        }
    }

    private func fetchSessions() async {
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            let response: SessionList = try await PKCloudAPI.shared.request("/api/sessions")
            currentSessions = response.sessions
        } catch {
            store.errorMessage = error.localizedDescription
            store.showingError = true
        }
    }
}
