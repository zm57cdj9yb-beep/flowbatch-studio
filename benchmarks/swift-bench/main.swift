import CoreImage
import FlowBatchCore
import Foundation
import ImageIO

private func readIHDR(_ data: Data) -> (bitDepth: UInt8, colorType: UInt8) {
    guard data.count >= 26 else { return (0, 0) }
    return (data[24], data[25])
}

private func medianMs(_ runs: Int, _ body: () throws -> Data) throws -> (data: Data, medianMs: Double) {
    var times: [Double] = []
    var last = Data()
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        last = try body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        times.append(Double(t1 - t0) / 1_000_000.0)
    }
    times.sort()
    return (last, times[times.count / 2])
}

@main
struct FlowBatchBench {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("Usage:\n  FlowBatchBench png <inputPath> [outCrushedPath]\n  FlowBatchBench batch <demoAssetsRoot> <outputDir>\n", stderr)
            exit(1)
        }

        let mode = args[1]
        if mode == "png" {
            let inputURL = URL(fileURLWithPath: args[2])
            let outPath = args.count >= 4 ? args[3] : nil
            guard let ci = CIImage(contentsOf: inputURL) else {
                fputs("Failed to load image: \(inputURL.path)\n", stderr)
                exit(1)
            }
            let ctx = CIContext(options: [.cacheIntermediates: false])
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

            // Baseline standard 24/32-bit PNG via CoreImage/ImageIO
            let base = try medianMs(3) {
                guard let d = ctx.pngRepresentation(of: ci, format: .RGBA8, colorSpace: cs, options: [:]) else {
                    throw NSError(domain: "Bench", code: 1)
                }
                return d
            }
            let baseIHDR = readIHDR(base.data)
            print(String(format: "swift|baseline_png|%d|%.1f|%d|%d", base.data.count, base.medianMs, baseIHDR.bitDepth, baseIHDR.colorType))

            let configs: [(String, IndexedPNGOptions)] = [
                ("indexed_256_fast", IndexedPNGOptions(maxColors: 256, speed: 5, dither: false, crush: false, bruteForceCrush: false)),
                ("indexed_256_dither", IndexedPNGOptions(maxColors: 256, speed: 3, dither: true, crush: false, bruteForceCrush: false)),
                ("indexed_256_crush", IndexedPNGOptions(maxColors: 256, speed: 3, dither: true, crush: true, bruteForceCrush: false)),
                ("indexed_256_bruteforce", IndexedPNGOptions(maxColors: 256, speed: 1, dither: true, crush: true, bruteForceCrush: true))
            ]

            for (label, opts) in configs {
                let res = try medianMs(3) {
                    try IndexedPNGQuantizer.encode(image: ci, context: ctx, options: opts)
                }
                let ihdr = readIHDR(res.data)
                print(String(format: "swift|%@|%d|%.1f|%d|%d", label, res.data.count, res.medianMs, ihdr.bitDepth, ihdr.colorType))
                if label == "indexed_256_crush", let outPath {
                    try res.data.write(to: URL(fileURLWithPath: outPath))
                }
            }
        } else if mode == "batch" {
            guard args.count >= 4 else { exit(1) }
            let demoRoot = URL(fileURLWithPath: args[2])
            let outDir = URL(fileURLWithPath: args[3])
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            var doc = WorkflowDocumentModel.makeStarterDocument(demoAssetsRoot: demoRoot)
            for i in doc.nodes.indices where doc.nodes[i].typeID == NodeTypeID.writeImages {
                doc.nodes[i].parameters["folderPath"] = .string(outDir.path)
                doc.nodes[i].parameters["openFolderWhenFinished"] = .bool(false)
                doc.nodes[i].parameters["overwriteExisting"] = .bool(true)
            }

            let runner = PipelineRunner()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let summary = try await runner.runWorkflow(document: doc)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = Double(t1 - t0) / 1_000_000.0
            let totalBytes = summary.writtenFiles.reduce(0) { acc, u in
                acc + ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0)
            }
            print(String(format: "swift|batch_30_indexed_png|%d|%.1f|%d", summary.writtenFiles.count, elapsedMs, totalBytes))
        }
    }
}
