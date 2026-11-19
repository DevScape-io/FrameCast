import CoreGraphics

enum DeviceFamily: String, Codable {
    case iPad, iPhone
}

enum TopFeature {
    case none, cameraDot, notch, dynamicIsland
}

/// Physical description of a device, used to draw the built-in (procedural) frame,
/// to match a capture stream by resolution, and to place the clean status bar.
struct DeviceSpec: Identifiable, Hashable {
    static func == (lhs: DeviceSpec, rhs: DeviceSpec) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    let name: String
    let family: DeviceFamily
    /// Native screen size in pixels, portrait.
    let pixelSize: CGSize
    let scale: CGFloat
    /// `ProductType` values reported over USB (e.g. "iPad16,3").
    let productTypes: [String]
    let hasHomeButton: Bool
    /// Display corner radius ÷ portrait screen width.
    let screenCornerRatio: CGFloat
    /// Side bezel ÷ portrait screen width.
    let sideBezelRatio: CGFloat
    /// Top/bottom bezel ÷ portrait screen width.
    let endBezelRatio: CGFloat
    let topFeature: TopFeature

    var aspect: CGFloat { pixelSize.height / pixelSize.width }

    var bodyCornerRatio: CGFloat {
        if hasHomeButton { return family == .iPad ? 0.075 : 0.16 }
        return screenCornerRatio + sideBezelRatio
    }

    /// Status bar height in points (portrait).
    var statusBarPoints: CGFloat {
        switch (family, topFeature, hasHomeButton) {
        case (.iPad, _, true): return 20
        case (.iPad, _, false): return 24
        case (.iPhone, .dynamicIsland, _): return 54
        case (.iPhone, .notch, _): return 47
        default: return 20
        }
    }
}

enum DeviceCatalog {
    private static func pad(_ id: String, _ name: String, _ w: CGFloat, _ h: CGFloat, _ types: [String],
                            corner: CGFloat, side: CGFloat, end: CGFloat? = nil, home: Bool = false) -> DeviceSpec {
        DeviceSpec(id: id, name: name, family: .iPad, pixelSize: CGSize(width: w, height: h), scale: 2,
                   productTypes: types, hasHomeButton: home, screenCornerRatio: corner,
                   sideBezelRatio: side, endBezelRatio: end ?? side, topFeature: .cameraDot)
    }

    private static func phone(_ id: String, _ name: String, _ w: CGFloat, _ h: CGFloat, _ types: [String],
                              corner: CGFloat, side: CGFloat, end: CGFloat? = nil,
                              feature: TopFeature = .dynamicIsland, home: Bool = false, scale: CGFloat = 3) -> DeviceSpec {
        DeviceSpec(id: id, name: name, family: .iPhone, pixelSize: CGSize(width: w, height: h), scale: scale,
                   productTypes: types, hasHomeButton: home, screenCornerRatio: corner,
                   sideBezelRatio: side, endBezelRatio: end ?? side, topFeature: feature)
    }

    static let all: [DeviceSpec] = [
        // iPad
        pad("ipad-pro-13-m4", "iPad Pro 13-inch (M4 or later)", 2064, 2752,
            ["iPad16,5", "iPad16,6", "iPad17,3", "iPad17,4"], corner: 0.0175, side: 0.043),
        pad("ipad-pro-11-m4", "iPad Pro 11-inch (M4 or later)", 1668, 2420,
            ["iPad16,3", "iPad16,4", "iPad17,1", "iPad17,2"], corner: 0.0216, side: 0.043),
        pad("ipad-pro-12-9", "iPad Pro 12.9-inch (3rd–6th gen)", 2048, 2732,
            ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8", "iPad8,11", "iPad8,12",
             "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", "iPad14,5", "iPad14,6"], corner: 0.0176, side: 0.045),
        pad("ipad-pro-11", "iPad Pro 11-inch (1st–4th gen)", 1668, 2388,
            ["iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4", "iPad8,9", "iPad8,10",
             "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad14,3", "iPad14,4"], corner: 0.0216, side: 0.046),
        pad("ipad-air-13", "iPad Air 13-inch", 2048, 2732,
            ["iPad14,10", "iPad14,11", "iPad15,5", "iPad15,6"], corner: 0.0176, side: 0.05),
        pad("ipad-air-11", "iPad Air 11-inch / Air (4th–5th gen)", 1640, 2360,
            ["iPad13,1", "iPad13,2", "iPad13,16", "iPad13,17", "iPad14,8", "iPad14,9", "iPad15,3", "iPad15,4"],
            corner: 0.022, side: 0.05),
        pad("ipad-10", "iPad (10th gen / A16)", 1640, 2360,
            ["iPad13,18", "iPad13,19", "iPad15,7", "iPad15,8"], corner: 0.022, side: 0.06),
        pad("ipad-mini-6", "iPad mini (6th gen / A17 Pro)", 1488, 2266,
            ["iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2"], corner: 0.029, side: 0.055),
        pad("ipad-9", "iPad (7th–9th gen, Home button)", 1620, 2160,
            ["iPad7,11", "iPad7,12", "iPad11,6", "iPad11,7", "iPad12,1", "iPad12,2"],
            corner: 0, side: 0.058, end: 0.137, home: true),

        // iPhone
        phone("iphone-pro-max-69", "iPhone 16/17 Pro Max", 1320, 2868,
              ["iPhone17,2", "iPhone18,2"], corner: 0.141, side: 0.032),
        phone("iphone-pro-63", "iPhone 16/17 Pro, iPhone 17", 1206, 2622,
              ["iPhone17,1", "iPhone18,1", "iPhone18,3"], corner: 0.142, side: 0.033),
        phone("iphone-air", "iPhone Air", 1260, 2736,
              ["iPhone18,4"], corner: 0.14, side: 0.03),
        phone("iphone-67-island", "iPhone 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus", 1290, 2796,
              ["iPhone15,3", "iPhone15,5", "iPhone16,2", "iPhone17,4"], corner: 0.128, side: 0.036),
        phone("iphone-61-island", "iPhone 14 Pro / 15 / 15 Pro / 16", 1179, 2556,
              ["iPhone15,2", "iPhone15,4", "iPhone16,1", "iPhone17,3"], corner: 0.14, side: 0.04),
        phone("iphone-61-notch", "iPhone 12 / 13 / 14 / 16e", 1170, 2532,
              ["iPhone13,2", "iPhone13,3", "iPhone14,2", "iPhone14,5", "iPhone14,7", "iPhone17,5"],
              corner: 0.121, side: 0.045, feature: .notch),
        phone("iphone-se", "iPhone SE (2nd/3rd gen)", 750, 1334,
              ["iPhone12,8", "iPhone14,6"], corner: 0, side: 0.076, end: 0.294,
              feature: .cameraDot, home: true, scale: 2),
    ]

    static let genericIPad = pad("generic-ipad", "Generic iPad", 1640, 2360, [], corner: 0.022, side: 0.05)
    static let genericIPhone = phone("generic-iphone", "Generic iPhone", 1179, 2556, [], corner: 0.14, side: 0.04)

    static func spec(id: String) -> DeviceSpec? {
        if id == genericIPad.id { return genericIPad }
        if id == genericIPhone.id { return genericIPhone }
        return all.first { $0.id == id }
    }

    static func spec(productType: String) -> DeviceSpec? {
        all.first { $0.productTypes.contains(productType) }
    }

    /// Returns a catalog entry whose aspect ratio matches, or nil.
    static func match(size: CGSize, tolerance: CGFloat = 0.015) -> DeviceSpec? {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        guard short > 0 else { return nil }
        let aspect = long / short
        let candidates = all.filter { abs($0.aspect - aspect) / aspect < tolerance }
        return candidates.min { abs($0.pixelSize.width - short) < abs($1.pixelSize.width - short) }
    }

    /// Best guess for a capture stream of the given size (never nil).
    static func bestMatch(size: CGSize) -> DeviceSpec {
        if let m = match(size: size) { return m }
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return (short > 0 && long / short < 1.7) ? genericIPad : genericIPhone
    }
}
