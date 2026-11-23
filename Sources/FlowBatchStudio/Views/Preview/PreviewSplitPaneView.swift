import AppKit
import CoreImage
import FlowBatchCore
import SwiftUI

/// Right-hand split view combining the live GPU preview (`MetalPreviewView`),
/// a responsive 256px ImageIO thumbnail grid, and the bottom zoom/background/info toolbar.
struct PreviewSplitPaneView: View {
    @Bindable var store: WorkflowStore
    let runner: PipelineRunner

    @State private var previewImage: CIImage?
    @State private var originalImage: CIImage?
    @State private var assetInfo: AssetInspectorInfo?
    @State private var previewContext: CIContext?
    @State private var previewError: String?

    @State private var zoomPercent: Double = 100.0
    @State private var darkBackground: Bool = false
    @State private var showOriginal: Bool = false
    @State private var showInfoPopover: Bool = false
    @State private var splitRatio: CGFloat = 0.40

    private let gridColumns = [
        GridItem(.adaptive(minimum: 62, maximum: 84), spacing: 6)
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top Live Preview
                ZStack(alignment: .topLeading) {
                    MetalPreviewView(
                        image: showOriginal ? originalImage : previewImage,
                        previewContext: previewContext,
                        zoomScale: zoomPercent / 100.0,
                        darkBackground: darkBackground
                    )

                    if store.activePreviewAssets.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.secondary)
                            Text(String(localized: "No assets selected for preview"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if let previewError {
                        Text(previewError)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.88), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
                .frame(height: max(160, (geo.size.height - 34) * splitRatio))

                // Draggable horizontal divider
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 8)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let next = (geo.size.height * splitRatio + value.translation.height) / max(200, geo.size.height - 34)
                                        splitRatio = min(0.82, max(0.25, next))
                                    }
                            )
                            .onHover { hovering in
                                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                            }
                    )

                // Bottom Contact Sheet Thumbnail Grid
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        ForEach(Array(store.activePreviewAssets.enumerated()), id: \.element.id) { index, assetRef in
                            ThumbnailTileView(
                                assetRef: assetRef,
                                isSelected: index == store.selectedAssetIndex
                            )
                            .onTapGesture {
                                store.selectedAssetIndex = index
                            }
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Bottom Zoom & Preview Utility Bar
                HStack(spacing: 8) {
                    Text("\(Int(zoomPercent.rounded()))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    Button {
                        zoomPercent = max(25, zoomPercent - 15)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Slider(value: $zoomPercent, in: 25...300)
                        .controlSize(.mini)
                        .frame(maxWidth: 130)

                    Button {
                        zoomPercent = min(300, zoomPercent + 15)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        showOriginal.toggle()
                    } label: {
                        Image(systemName: showOriginal ? "eye.fill" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(showOriginal ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Toggle Original vs Processed"))

                    Button {
                        darkBackground.toggle()
                    } label: {
                        Image(systemName: darkBackground ? "circle.lefthalf.filled" : "circle.righthalf.filled")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Toggle Dark / Light Preview Backdrop"))

                    Button {
                        showInfoPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(showInfoPopover ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Asset Information"))
                    .popover(isPresented: $showInfoPopover, arrowEdge: .top) {
                        AssetInfoPopoverView(info: assetInfo)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.bar)
            }
        }
        .task(id: PreviewTriggerKey(
            doc: store.document,
            nodeID: store.primarySelectedNodeID,
            assetIndex: store.selectedAssetIndex
        )) {
            await refreshPreview()
        }
    }

    private func refreshPreview() async {
        if previewContext == nil {
            previewContext = await runner.previewContext
        }
        let assets = store.activePreviewAssets
        let ref: DryRunAssetRef? = (store.selectedAssetIndex < assets.count) ? assets[store.selectedAssetIndex] : assets.first
        let genID = await runner.nextPreviewGeneration()
        let result = await runner.renderPreview(
            document: store.document,
            targetNodeID: store.primarySelectedNodeID,
            assetRef: ref,
            generationID: genID
        )
        await MainActor.run {
            if let img = result.processedImage {
                self.previewImage = img
            } else if ref == nil {
                self.previewImage = nil
            }
            self.originalImage = result.originalImage
            self.assetInfo = result.info
            self.previewError = result.errorMessage
        }
    }
}

private struct PreviewTriggerKey: Equatable {
    let doc: WorkflowDocumentModel
    let nodeID: UUID?
    let assetIndex: Int
}

private struct ThumbnailTileView: View {
    let assetRef: DryRunAssetRef
    let isSelected: Bool

    @State private var cgImage: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .underPageBackgroundColor))

            if let cgImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 50)
                    .clipped()
                    .cornerRadius(3)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 70, height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isSelected ? 2.5 : 0.5)
        )
        .task(id: assetRef.id) {
            guard let url = assetRef.url else { return }
            let loaded = await Task.detached(priority: .utility) {
                ThumbnailLoader.shared.loadThumbnail(for: url, maxPixelSize: 256)
            }.value
            self.cgImage = loaded
        }
    }
}

private struct AssetInfoPopoverView: View {
    let info: AssetInspectorInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Asset Information"))
                .font(.headline)
            Divider()
            if let info {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        Text("File:").foregroundStyle(.secondary)
                        Text(info.fileName).lineLimit(1)
                    }
                    GridRow {
                        Text("Dimensions:").foregroundStyle(.secondary)
                        Text("\(info.pixelWidth) × \(info.pixelHeight) px")
                    }
                    GridRow {
                        Text("DPI / Depth:").foregroundStyle(.secondary)
                        Text("\(info.dpi) DPI • \(info.bitsPerChannel)-bit")
                    }
                    GridRow {
                        Text("Color Space:").foregroundStyle(.secondary)
                        Text(info.colorSpaceName)
                    }
                    GridRow {
                        Text("File Size:").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: info.originalByteCount, countStyle: .file))
                    }
                    GridRow {
                        Text("GPS Tag:").foregroundStyle(.secondary)
                        Text(info.gpsPresent ? "Present" : "None")
                    }
                    if let model = info.cameraModel {
                        GridRow {
                            Text("Camera:").foregroundStyle(.secondary)
                            Text("\(info.cameraMake ?? "") \(model)")
                        }
                    }
                }
                .font(.caption)

                if !info.classifications.isEmpty {
                    Divider()
                    Text("Vision Classifications:")
                        .font(.caption.bold())
                    ForEach(info.classifications, id: \.identifier) { tag in
                        Text("• \(tag.identifier) (\(Int(tag.confidence * 100))%)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Select an asset to inspect metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
