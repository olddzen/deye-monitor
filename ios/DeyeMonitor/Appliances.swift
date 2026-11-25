import SwiftUI

/// The flat's own appliances (models from the purchase history and SmartThings).
/// `watts` is the average draw while in use — what drains the battery; `peak` is the short maximum
/// that has to fit into the inverter's 6 kW. Values are typical figures for these models (≈).
struct Appliance: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let symbol: String
    let watts: Double
    var peak: Double? = nil
    /// Program-based appliances: typical cycle length (h) and energy (kWh).
    var cycleH: Double? = nil
    var cycleKwh: Double? = nil

    var peakW: Double { peak ?? watts }

    static let presets: [Appliance] = [
        .init(id: "fridge", name: "Холодильник", model: "Bosch KBN96ADD0", symbol: "refrigerator.fill", watts: 30, peak: 120),
        .init(id: "router", name: "Роутер", model: "Wi-Fi", symbol: "wifi.router.fill", watts: 15),
        .init(id: "monitor", name: "Монітор", model: "Dell U2725QE", symbol: "display", watts: 25, peak: 60),
        .init(id: "laptop", name: "Ноутбук", model: "зарядка", symbol: "laptopcomputer", watts: 45),
        .init(id: "lights", name: "Світло в кімнатах", model: "LED", symbol: "lightbulb.fill", watts: 40),
        .init(id: "tv", name: "Телевізор", model: "Samsung 55\" OLED S95D", symbol: "tv.fill", watts: 110, peak: 180),
        .init(id: "musicframe", name: "Music Frame ×2", model: "Samsung HW-LS60D", symbol: "hifispeaker.2.fill", watts: 30),
        .init(id: "freestyle", name: "Проєктор", model: "Samsung The Freestyle", symbol: "videoprojector.fill", watts: 45),
        .init(id: "ac12", name: "Кондиціонер 12K", model: "Samsung AR60F12 WindFree", symbol: "air.conditioner.horizontal.fill", watts: 600, peak: 1300),
        .init(id: "ac18", name: "Кондиціонер 18K", model: "Samsung AR60F18 WindFree", symbol: "air.conditioner.horizontal.fill", watts: 900, peak: 1900),
        .init(id: "boiler", name: "Бойлер", model: "Ariston Velis Pro Dry 100", symbol: "drop.degreesign.fill", watts: 1500),
        .init(id: "microwave", name: "Мікрохвильовка", model: "Bosch BFL7221B1", symbol: "microwave.fill", watts: 1200),
        .init(id: "hob", name: "Індукція, 1 конфорка", model: "Bosch PIF651HC1E (до 7,4 кВт)", symbol: "cooktop.fill", watts: 1500, peak: 2200),
        .init(id: "oven", name: "Духова шафа", model: "Bosch HBG7341B1", symbol: "oven.fill", watts: 1100, peak: 3600),
        .init(id: "dishwasher", name: "Посудомийка", model: "Bosch SMV8YCX02E", symbol: "dishwasher.fill", watts: 250, peak: 2400,
              cycleH: 3.5, cycleKwh: 0.9),
        .init(id: "washer", name: "Пральна машина", model: "Samsung", symbol: "washer.fill", watts: 350, peak: 2200,
              cycleH: 2, cycleKwh: 0.7),
        .init(id: "dryer", name: "Сушарка", model: "Samsung, тепловий насос", symbol: "dryer.fill", watts: 600, peak: 1000,
              cycleH: 3, cycleKwh: 1.6),
        .init(id: "kettle", name: "Чайник", model: "", symbol: "cup.and.saucer.fill", watts: 2000),
    ]

    static func byId(_ id: String) -> Appliance? { presets.first { $0.id == id } }
}
