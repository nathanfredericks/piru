import Foundation
import Testing
@testable import Piru

@Suite("Body weight units")
struct BodyWeightUnitTests {
    private let range = 20.0 ... 300.0

    @Test
    func `weight display converts without changing the physical weight`() {
        let pounds = BodyWeightUnit.pounds.value(fromKilograms: 73.5)
        #expect(abs(pounds - 162.0398) < 0.001)
        #expect(abs(BodyWeightUnit.pounds.kilograms(from: pounds) - 73.5) < 0.000_001)
        #expect(BodyWeightUnit.defaultUnit(in: Locale(identifier: "en_US")) == .pounds)
        #expect(BodyWeightUnit.defaultUnit(in: Locale(identifier: "es_ES")) == .kilograms)
    }

    @Test
    func `accepts localized decimals and rejects partial or out of range inputs`() {
        let locale = Locale(identifier: "es_ES")
        let unit = BodyWeightUnit.kilograms
        #expect(unit.parseKilograms("73,5", locale: locale, range: range) == 73.5)
        #expect(unit.parseKilograms("73,5x", locale: locale, range: range) == nil)
        #expect(unit.parseKilograms("73.5", locale: locale, range: range) == nil)
        #expect(unit.parseKilograms("301", locale: locale, range: range) == nil)
        #expect(BodyWeightUnit.pounds.parseKilograms("20", locale: locale, range: range) == nil)
    }
}
