import Foundation
import simd

/// A parsed `.cube` LUT: an optional 1D shaper and an optional 3D cube.
/// Entries are RGB with red changing fastest, the order Core Image's color cube expects.
nonisolated struct CubeLUT: Equatable, Sendable {
    struct Table: Equatable, Sendable {
        var size: Int
        var domainMin: SIMD3<Float> = .zero
        var domainMax: SIMD3<Float> = .one
        var values: [SIMD3<Float>] = []
    }

    var title: String?
    var shaper: Table?
    var cube: Table?

    enum ParseError: LocalizedError, Equatable {
        case notText
        case missingSize
        case badSize(Int)
        case badLine(Int)
        case wrongEntryCount(expected: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .notText: "The file isn't a text .cube LUT."
            case .missingSize: "The file has no LUT_3D_SIZE or LUT_1D_SIZE line."
            case let .badSize(size): "Unsupported LUT size \(size)."
            case let .badLine(line): "Couldn't read line \(line)."
            case let .wrongEntryCount(expected, found): "Expected \(expected) entries but found \(found)."
            }
        }
    }

    init(title: String? = nil, shaper: Table? = nil, cube: Table?) {
        self.title = title
        self.shaper = shaper
        self.cube = cube
    }

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.notText
        }
        try self.init(text: text)
    }

    init(text: String) throws {
        var size1D: Int?
        var size3D: Int?
        var min1D = SIMD3<Float>.zero, max1D = SIMD3<Float>.one
        var min3D = SIMD3<Float>.zero, max3D = SIMD3<Float>.one
        var entries: [SIMD3<Float>] = []

        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = parts.first else { continue }

            if let first = keyword.first, first.isLetter {
                let arguments = parts.dropFirst()
                func floats() throws -> [Float] {
                    let values = arguments.compactMap { Float($0) }
                    guard values.count == arguments.count else { throw ParseError.badLine(index + 1) }
                    return values
                }
                func triple() throws -> SIMD3<Float> {
                    let values = try floats()
                    guard values.count == 3 else { throw ParseError.badLine(index + 1) }
                    return SIMD3(values[0], values[1], values[2])
                }
                func range() throws -> (SIMD3<Float>, SIMD3<Float>) {
                    let values = try floats()
                    guard values.count == 2 else { throw ParseError.badLine(index + 1) }
                    return (SIMD3(repeating: values[0]), SIMD3(repeating: values[1]))
                }
                switch keyword.uppercased() {
                case "TITLE":
                    let rest = line.drop(while: { $0 != " " && $0 != "\t" })
                    title = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_3D_SIZE":
                    guard let size = arguments.first.flatMap({ Int($0) }) else { throw ParseError.badLine(index + 1) }
                    guard (2...256).contains(size) else { throw ParseError.badSize(size) }
                    size3D = size
                case "LUT_1D_SIZE":
                    guard let size = arguments.first.flatMap({ Int($0) }) else { throw ParseError.badLine(index + 1) }
                    guard (2...65536).contains(size) else { throw ParseError.badSize(size) }
                    size1D = size
                case "DOMAIN_MIN":
                    min1D = try triple()
                    min3D = min1D
                case "DOMAIN_MAX":
                    max1D = try triple()
                    max3D = max1D
                case "LUT_1D_INPUT_RANGE":
                    (min1D, max1D) = try range()
                case "LUT_3D_INPUT_RANGE":
                    (min3D, max3D) = try range()
                default:
                    continue // Unknown keywords are skipped, as Resolve does.
                }
                continue
            }

            guard parts.count == 3, let red = Float(parts[0]), let green = Float(parts[1]), let blue = Float(parts[2]) else {
                throw ParseError.badLine(index + 1)
            }
            entries.append(SIMD3(red, green, blue))
        }

        guard size1D != nil || size3D != nil else { throw ParseError.missingSize }
        let count1D = size1D ?? 0
        let count3D = size3D.map { $0 * $0 * $0 } ?? 0
        guard entries.count == count1D + count3D else {
            throw ParseError.wrongEntryCount(expected: count1D + count3D, found: entries.count)
        }
        // Resolve writes the 1D shaper first, then the 3D cube.
        if let size = size1D {
            shaper = Table(size: size, domainMin: min1D, domainMax: max1D, values: Array(entries[0..<size]))
        }
        if let size = size3D {
            cube = Table(size: size, domainMin: min3D, domainMax: max3D, values: Array(entries[count1D...]))
        }
    }

    /// One RGB value through the LUT, with the same clamping and interpolation as Core Image.
    func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var color = rgb
        if let shaper {
            let position = normalized(color, shaper)
            color = SIMD3(sample1D(shaper, position.x, 0), sample1D(shaper, position.y, 1), sample1D(shaper, position.z, 2))
        }
        if let cube {
            color = sample3D(cube, normalized(color, cube))
        }
        return color
    }

    /// RGBA floats for Core Image's color cube. A LUT with a shaper, a custom domain, or more points
    /// than Core Image takes is sampled onto a new cube for 0–1 input.
    func colorCube(maxDimension: Int = 64) -> (dimension: Int, data: Data) {
        let values: [SIMD3<Float>]
        let dimension: Int
        if let cube, shaper == nil, cube.size <= maxDimension, cube.domainMin == .zero, cube.domainMax == .one {
            dimension = cube.size
            values = cube.values
        } else {
            dimension = maxDimension
            let step = 1 / Float(dimension - 1)
            var sampled: [SIMD3<Float>] = []
            sampled.reserveCapacity(dimension * dimension * dimension)
            for blue in 0..<dimension {
                for green in 0..<dimension {
                    for red in 0..<dimension {
                        sampled.append(apply(SIMD3(Float(red), Float(green), Float(blue)) * step))
                    }
                }
            }
            values = sampled
        }
        var floats = [Float]()
        floats.reserveCapacity(values.count * 4)
        for value in values { floats.append(contentsOf: [value.x, value.y, value.z, 1]) }
        return (dimension, floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private func normalized(_ color: SIMD3<Float>, _ table: Table) -> SIMD3<Float> {
        let span = table.domainMax - table.domainMin
        let safeSpan = SIMD3(span.x == 0 ? 1 : span.x, span.y == 0 ? 1 : span.y, span.z == 0 ? 1 : span.z)
        return simd_clamp((color - table.domainMin) / safeSpan, .zero, .one)
    }

    private func sample1D(_ table: Table, _ position: Float, _ channel: Int) -> Float {
        let x = position * Float(table.size - 1)
        let lower = min(Int(x), table.size - 1)
        let upper = min(lower + 1, table.size - 1)
        let fraction = x - Float(lower)
        return table.values[lower][channel] * (1 - fraction) + table.values[upper][channel] * fraction
    }

    private func sample3D(_ table: Table, _ position: SIMD3<Float>) -> SIMD3<Float> {
        let size = table.size
        let point = position * Float(size - 1)
        let lower = SIMD3<Int>(min(Int(point.x), size - 1), min(Int(point.y), size - 1), min(Int(point.z), size - 1))
        let upper = SIMD3<Int>(min(lower.x + 1, size - 1), min(lower.y + 1, size - 1), min(lower.z + 1, size - 1))
        let fraction = point - SIMD3<Float>(Float(lower.x), Float(lower.y), Float(lower.z))
        func value(_ red: Int, _ green: Int, _ blue: Int) -> SIMD3<Float> { table.values[red + green * size + blue * size * size] }
        let c00 = value(lower.x, lower.y, lower.z) * (1 - fraction.x) + value(upper.x, lower.y, lower.z) * fraction.x
        let c10 = value(lower.x, upper.y, lower.z) * (1 - fraction.x) + value(upper.x, upper.y, lower.z) * fraction.x
        let c01 = value(lower.x, lower.y, upper.z) * (1 - fraction.x) + value(upper.x, lower.y, upper.z) * fraction.x
        let c11 = value(lower.x, upper.y, upper.z) * (1 - fraction.x) + value(upper.x, upper.y, upper.z) * fraction.x
        let c0 = c00 * (1 - fraction.y) + c10 * fraction.y
        let c1 = c01 * (1 - fraction.y) + c11 * fraction.y
        return c0 * (1 - fraction.z) + c1 * fraction.z
    }
}
