import Foundation

/// 181 is the canonical online mathematical evaluator. The installed signed
/// engine remains an independently verified offline fallback.
enum PKServerMath {
    struct Entry: Encodable {
        let drug: String
        let time: Int64
        let mg: Double
    }
    struct Intake: Encodable {
        let kind: String
        let time: Int64
        let mealType: String
    }
    struct Request: Encodable {
        let drugId: String
        let times: [Int64]
        let records: [Entry]
        let planned: [Entry]
        let meals: [Intake]
        let renalCrCl: Double?
    }
    struct Sample: Decodable {
        let time: Int64
        let bloodMgL: Double
        let equivalentMg: Double
        let unfedMgL: Double
        let plannedBloodMgL: Double?
        let plannedEquivalentMg: Double?
    }
    struct Response: Decodable {
        let source: String
        let catalogVersion: String
        let engineVersion: String
        let serverKernelSha256: String
        let points: [Sample]
    }
    enum Invalid: Error {
        case incompatibleModel
        case invalidResult
    }

    static func fetch(model: PKModel, drug: PKDrug, actual: [PKSample],
                      planned: [PKDose], expectedCatalogPrefix: String,
                      expectedEnginePrefix: String)
        async throws -> (actual: [PKSample], planned: [PKSample]) {
        guard !actual.isEmpty, actual.count <= 650,
              !expectedEnginePrefix.isEmpty,
              !expectedCatalogPrefix.isEmpty,
              expectedCatalogPrefix != "内置" else {
            throw Invalid.incompatibleModel
        }
        let first = actual[0].time.timeIntervalSince1970 * 1000
        let last = actual[actual.count - 1].time.timeIntervalSince1970 * 1000
        let actualRows = model.doses.filter { $0.drug == drug.id }
        let meals = model.intakes.filter { $0.kind == "meal" &&
            $0.time.timeIntervalSince1970 * 1000 >= first - 3 * 86_400_000 &&
            $0.time.timeIntervalSince1970 * 1000 <= last + 86_400_000 }
        guard actualRows.count <= 300, planned.count <= 30, meals.count <= 160,
              actualRows.allSatisfy({
                let t = $0.time.timeIntervalSince1970 * 1000
                return t >= first - 180 * 86_400_000 && t <= last
              }),
              planned.allSatisfy({
                let t = $0.time.timeIntervalSince1970 * 1000
                return $0.drug == drug.id && t >= first - 180 * 86_400_000 && t <= last
              }) else { throw Invalid.invalidResult }
        let toEntry: (PKDose) -> Entry = {
            Entry(drug: drug.id, time: Int64(($0.time.timeIntervalSince1970 * 1000).rounded()),
                  mg: $0.mg)
        }
        let payload = Request(
            drugId: drug.id,
            times: actual.map { Int64(($0.time.timeIntervalSince1970 * 1000).rounded()) },
            records: actualRows.map(toEntry),
            planned: planned.map(toEntry),
            meals: meals.map { Intake(kind: "meal",
                time: Int64(($0.time.timeIntervalSince1970 * 1000).rounded()),
                mealType: $0.mealType == "highFat" ? "highFat" : "regular") },
            renalCrCl: model.renalCrCl)
        let data = try JSONEncoder().encode(payload)
        let result: Response = try await PKCloudAPI.shared.request(
            "/api/native/math/samples", method: "POST", body: data)
        guard result.source == "181-server-math",
              result.engineVersion.hasPrefix(expectedEnginePrefix == "内置"
                ? (PKModelDistribution.expectedEngineVersion ?? "__missing__")
                : expectedEnginePrefix),
              result.catalogVersion.hasPrefix(expectedCatalogPrefix),
              result.serverKernelSha256.count == 64,
              result.points.count == actual.count else {
            throw Invalid.incompatibleModel
        }
        var confirmed: [PKSample] = []
        var projected: [PKSample] = []
        for (index, point) in result.points.enumerated() {
            let base = actual[index]
            guard abs(Double(point.time) -
                      base.time.timeIntervalSince1970 * 1000) <= 2,
                  [point.bloodMgL, point.equivalentMg, point.unfedMgL]
                    .allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw Invalid.invalidResult
            }
            confirmed.append(PKSample(time: base.time, concentration: point.bloodMgL,
                                      equivalent: point.equivalentMg, unfed: point.unfedMgL))
            if !planned.isEmpty {
                guard let blood = point.plannedBloodMgL,
                      let equivalent = point.plannedEquivalentMg,
                      blood.isFinite, equivalent.isFinite,
                      blood >= 0, equivalent >= 0 else {
                    throw Invalid.invalidResult
                }
                projected.append(PKSample(time: base.time, concentration: blood,
                                          equivalent: equivalent, unfed: point.unfedMgL))
            }
        }
        return (confirmed, projected)
    }
}
