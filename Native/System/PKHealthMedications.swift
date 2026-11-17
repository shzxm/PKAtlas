import Foundation
import HealthKit
import Combine
import UIKit
import os

/// One authorized Health medication dose, matched conservatively to a catalog
/// entry. Dose quantities expressed as counts or volumes are NOT mg values.
struct PKHealthDoseMatch: Identifiable {
    var id: String { eventUUID.uuidString }
    let eventUUID: UUID
    let medicationName: String
    let drugID: String?
    let mg: Double?
    let quantityText: String
    let time: Date
}

/// Read-only HealthKit bridge. Apple doesn't expose third-party creation of
/// HKMedicationDoseEvent. All imports are explicitly confirmed by the user.
@MainActor
final class PKHealthMedications: ObservableObject {
    static let shared = PKHealthMedications()
    @Published private(set) var status = "尚未读取 Apple 健康"
    @Published private(set) var approvedMedications: [String] = []
    @Published private(set) var matches: [PKHealthDoseMatch] = []
    @Published private(set) var reviewing = false

    private let healthStore = HKHealthStore()
    private let log = Logger(subsystem: "org.pkatlas.open", category: "HealthMedicationRead")

    // HealthKit requires the provisioning/signing entitlement to be valid.
    // The iOS SDK does not publicly expose SecTaskCreateFromSelf: do not
    // guess entitlement status from an unsigned app's source plist.

    private func checkpoint(_ name: String) {
        log.info("HealthKit read stage: \(name, privacy: .public)")
        UserDefaults.standard.set(name, forKey: "PKHealthLastReadStage")
    }

    /// Do not infer a drug from a brand name or guess unit conversion.
    static func matchCatalog(_ name: String, catalog: PKCatalog) -> String? {
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
        }
        let haystack = normalized(name)
        let candidates = catalog.drugs.filter { item in
            let names = [item.name, item.en ?? ""].map(normalized)
            return names.contains { token in token.count >= 4 && haystack.contains(token) }
        }
        // Ambiguous compound medicine names need human review.
        return candidates.count == 1 ? candidates.first?.id : nil
    }

    func requestAndRead() async {
        guard !reviewing else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "此设备尚不支持 Apple 健康"; return
        }
        reviewing = true
        defer { reviewing = false }
        do {
            checkpoint("begin-authorization")
            let medType = HKObjectType.userAnnotatedMedicationType()
            let doseType = HKObjectType.medicationDoseEventType()
            if medType.requiresPerObjectAuthorization() {
                checkpoint("authorize-annotated-medications")
                try await healthStore.requestPerObjectReadAuthorization(
                    for: medType, predicate: nil)
            } else {
                checkpoint("authorize-annotated-medications-standard")
                try await healthStore.requestAuthorization(toShare: [], read: [medType])
            }
            if doseType.requiresPerObjectAuthorization() {
                checkpoint("authorize-medication-dose-per-object")
                try await healthStore.requestPerObjectReadAuthorization(for: doseType, predicate: nil)
            } else {
                checkpoint("authorize-medication-dose-standard")
                try await healthStore.requestAuthorization(toShare: [], read: [doseType])
            }
            checkpoint("query-annotated-medications")
            let query = HKUserAnnotatedMedicationQueryDescriptor(limit: 250)
            let medications = try await query.result(for: healthStore)
            approvedMedications = medications.map { $0.nickname ?? $0.medication.displayText }
            let approved = medications.filter { !$0.isArchived }
            let after = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .distantPast
            let predicate = HKQuery.predicateForSamples(withStart: after, end: .now, options: [])
            checkpoint("query-medication-dose-events")
            let samples: [HKMedicationDoseEvent] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: HKObjectType.medicationDoseEventType(),
                                          predicate: predicate, limit: 500,
                                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, objects, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (objects ?? []).compactMap { $0 as? HKMedicationDoseEvent })
                }
                healthStore.execute(query)
            }
            checkpoint("match-medications")
            let catalog = NativeAppStore.shared.catalog
            matches = samples.filter { $0.logStatus == .taken }.compactMap { event -> PKHealthDoseMatch? in
                guard let medication = approved.first(where: {
                    $0.medication.identifier.isEqual(event.medicationConceptIdentifier)
                }) else { return nil }
                let name = medication.nickname ?? medication.medication.displayText
                let id = Self.matchCatalog(medication.medication.displayText, catalog: catalog)
                    ?? Self.matchCatalog(name, catalog: catalog)
                let unit = event.unit
                let amount = event.doseQuantity
                let mg = amount.flatMap { value -> Double? in
                    // Only explicitly recognized mass units. A 'tablet',
                    // 'capsule', mL, or dose count is NOT automatically mg.
                    let multiplier: Double
                    switch unit.unitString.lowercased() {
                    case "mg": multiplier = 1
                    case "g": multiplier = 1_000
                    case "µg", "μg", "mcg", "ug": multiplier = 0.001
                    default: return nil
                    }
                    let converted = value * multiplier
                    return converted.isFinite && converted > 0 && converted < 100_000 ? converted : nil
                }
                let text = amount.map { $0.formatted() } ?? "未提供"
                return PKHealthDoseMatch(eventUUID: event.uuid, medicationName: name,
                                         drugID: id, mg: mg,
                                         quantityText: text + " " + unit.unitString,
                                         time: event.endDate)
            }
            checkpoint("complete")
            status = "已授权读取 \(approvedMedications.count) 项药物、\(matches.count) 条已服药事件；仅确认后导入"
        } catch {
            checkpoint("error-" + String((error as NSError).code))
            status = "Apple 健康读取失败或权限未授权：" + error.localizedDescription
        }
    }

    /// HealthKit doesn't offer a stable public URL for a specific medication
    /// logging form. This best-effort scheme opens Health, not a pre-filled dose.
    func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                Task { @MainActor in
                    self.status = "无法自动打开健康 App。请在系统中打开「健康」→「浏览」→「用药」，手动登记实际服用。"
                }
            }
        }
    }
}
