import AppKit
import FlowBatchCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// High-FPS AppKit canvas view rendering the graph-paper grid, rounded node cards,
/// directional-chevron Bézier wires, rubber-band wiring, marquee selection, drag-and-drop,
/// keyboard/VoiceOver accessibility, and anchored `NSPopover` node inspectors.
@MainActor
final class NodeGraphCanvasNSView: NSView {
    let store: WorkflowStore

    private let nodeSize = CGSize(width: 128, height: 90)
    private var hoveredNodeID: UUID?
    private var hoveredEdgeID: UUID?
    private var hoveredRemoveButtonNodeID: UUID?

    private enum DragMode {
        case none
        case movingNodes(startMouseCanvas: CGPoint, initialPositions: [UUID: GraphPoint])
        case wiring(sourceNodeID: UUID, sourcePort: Int, currentCanvas: CGPoint)
        case marquee(startCanvas: CGPoint, currentCanvas: CGPoint)
        case panning(startMouseView: CGPoint, initialOffset: GraphPoint)
    }

    private var dragMode: DragMode = .none
    private var trackingAreaRef: NSTrackingArea?
    private var inspectorPopover: NSPopover?
    private var popoverAnchoredNodeID: UUID?
    private var runningAnimTimer: Timer?
    private var chevronPhaseOffset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: WorkflowStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.flowbatchNodeTemplate.identifier),
            .string,
            .fileURL
        ])
        observeStoreChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let pop = inspectorPopover, pop.isShown,
           let targetID = popoverAnchoredNodeID,
           let node = store.document.nodes.first(where: { $0.id == targetID }) {
            pop.positioningRect = viewRect(for: node)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    // MARK: - Observation Loop

    private func observeStoreChanges() {
        withObservationTracking {
            _ = store.document
            _ = store.selectedNodeIDs
            _ = store.selectedEdgeID
            _ = store.inspectorVisibleNodeID
            _ = store.dryRun.nodeCounts
            _ = store.dryRun.nodeSubtitles
            _ = store.nodeErrors
            _ = store.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.needsDisplay = true
                self.syncRunningAnimation()
                self.syncInspectorPopover()
                NSAccessibility.post(element: self, notification: .layoutChanged)
                self.observeStoreChanges()
            }
        }
    }

    private func syncRunningAnimation() {
        if store.isRunning {
            if runningAnimTimer == nil {
                runningAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.chevronPhaseOffset = (self.chevronPhaseOffset + 1.2).truncatingRemainder(dividingBy: 22.0)
                        self.needsDisplay = true
                    }
                }
            }
        } else {
            runningAnimTimer?.invalidate()
            runningAnimTimer = nil
            chevronPhaseOffset = 0
        }
    }

    // MARK: - Popover Inspector Anchor Management

    func syncInspectorPopover() {
        guard window != nil else { return }
        guard let targetID = store.inspectorVisibleNodeID,
              let node = store.document.nodes.first(where: { $0.id == targetID }) else {
            inspectorPopover?.close()
            inspectorPopover = nil
            popoverAnchoredNodeID = nil
            return
        }

        if popoverAnchoredNodeID == targetID, let pop = inspectorPopover, pop.isShown {
            return
        }

        inspectorPopover?.close()
        let pop = NSPopover()
        pop.behavior = .applicationDefined
        pop.animates = true
        let hosting = NSHostingController(rootView: NodeInspectorPopoverView(store: store, nodeID: targetID))
        pop.contentViewController = hosting

        let viewRect = viewRect(for: node)
        pop.show(relativeTo: viewRect, of: self, preferredEdge: .maxY)
        inspectorPopover = pop
        popoverAnchoredNodeID = targetID
    }

    func zoomToFit() {
        guard !store.document.nodes.isEmpty else {
            store.document.viewportOffset = GraphPoint(x: 0, y: 0)
            store.document.viewportZoom = 1.0
            needsDisplay = true
            return
        }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for node in store.document.nodes {
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + Double(nodeSize.width))
            maxY = max(maxY, node.position.y + Double(nodeSize.height))
        }
        let topInset = Double(safeAreaInsets.top)
        let usableH = max(120, Double(bounds.height) - topInset)
        let contentW = max(120, maxX - minX + 120)
        let contentH = max(120, maxY - minY + 120)
        let zoomX = Double(bounds.width) / contentW
        let zoomY = usableH / contentH
        let zoom = max(0.45, min(1.2, min(zoomX, zoomY)))

        store.document.viewportZoom = zoom
        let centerGraphX = (minX + maxX) * 0.5
        let centerGraphY = (minY + maxY) * 0.5
        store.document.viewportOffset = GraphPoint(
            x: Double(bounds.width) * 0.5 - centerGraphX * zoom,
            y: topInset + usableH * 0.5 - centerGraphY * zoom
        )
        needsDisplay = true
        syncInspectorPopover()
    }

    // MARK: - Coordinate Conversion

    private var zoom: CGFloat { CGFloat(max(0.35, min(2.5, store.document.viewportZoom))) }
    private var pan: CGPoint { store.document.viewportOffset.cgPoint }

    private func canvasToView(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: pt.x * zoom + pan.x, y: pt.y * zoom + pan.y)
    }

    private func viewToCanvas(_ pt: CGPoint) -> CGPoint {
        CGPoint(x: (pt.x - pan.x) / zoom, y: (pt.y - pan.y) / zoom)
    }

    private func canvasRect(for node: WorkflowNode) -> CGRect {
        CGRect(origin: node.position.cgPoint, size: nodeSize)
    }

    private func viewRect(for node: WorkflowNode) -> CGRect {
        let cr = canvasRect(for: node)
        let origin = canvasToView(cr.origin)
        return CGRect(x: origin.x, y: origin.y, width: cr.width * zoom, height: cr.height * zoom)
    }

    private func inputPortCanvasPoint(for node: WorkflowNode, portIndex: Int = 0) -> CGPoint {
        CGPoint(x: node.position.x, y: node.position.y + Double(nodeSize.height) * 0.5)
    }

    private func outputPortCanvasPoint(for node: WorkflowNode, portIndex: Int = 0) -> CGPoint {
        let count = max(1, node.definition?.outputPortCount ?? 1)
        let yRatio = count == 1 ? 0.5 : (portIndex == 0 ? 0.34 : 0.66)
        return CGPoint(x: node.position.x + Double(nodeSize.width), y: node.position.y + Double(nodeSize.height) * yRatio)
    }

    private func removeButtonCanvasRect(for node: WorkflowNode) -> CGRect {
        CGRect(
            x: node.position.x + Double(nodeSize.width) * 0.5 - 8,
            y: node.position.y + Double(nodeSize.height) - 20,
            width: 16,
            height: 16
        )
    }

    // MARK: - Drawing (Grid, Directional Chevron Wires, Nodes)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        NSColor(calibratedWhite: 0.985, alpha: 1.0).setFill()
        dirtyRect.fill()

        drawGrid(in: ctx)

        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)

        // Draw edges
        let nodeMap = Dictionary(uniqueKeysWithValues: store.document.nodes.map { ($0.id, $0) })
        for edge in store.document.edges {
            guard let src = nodeMap[edge.sourceNodeID], let dst = nodeMap[edge.targetNodeID] else { continue }
            let p0 = outputPortCanvasPoint(for: src, portIndex: edge.sourcePortIndex)
            let p1 = inputPortCanvasPoint(for: dst, portIndex: edge.targetPortIndex)
            let isSelected = (store.selectedEdgeID == edge.id)
            let isHovered = (hoveredEdgeID == edge.id)
            drawChevronBezier(from: p0, to: p1, highlighted: isSelected || isHovered, in: ctx)
        }

        // Rubber-band wiring preview
        if case .wiring(let srcID, let srcPort, let curPt) = dragMode, let srcNode = nodeMap[srcID] {
            let p0 = outputPortCanvasPoint(for: srcNode, portIndex: srcPort)
            drawChevronBezier(from: p0, to: curPt, highlighted: true, in: ctx)
        }

        // Draw nodes
        for node in store.document.nodes {
            drawNode(node, in: ctx)
        }

        // Marquee rectangle
        if case .marquee(let s, let c) = dragMode {
            let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            rect.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            let bp = NSBezierPath(rect: rect)
            bp.lineWidth = 1.0
            bp.setLineDash([4, 3], count: 2, phase: 0)
            bp.stroke()
        }

        ctx.restoreGState()
    }

    private func drawGrid(in ctx: CGContext) {
        let minorStep = 16.0 * zoom
        let majorStep = 80.0 * zoom
        guard minorStep >= 5.0 else { return }

        let minorColor = NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.95, alpha: 1.0).cgColor
        let majorColor = NSColor(calibratedRed: 0.87, green: 0.88, blue: 0.91, alpha: 1.0).cgColor

        func drawLines(step: CGFloat, color: CGColor) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(0.75)
            ctx.beginPath()

            var x = pan.x.truncatingRemainder(dividingBy: step)
            if x < 0 { x += step }
            while x <= bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += step
            }

            var y = pan.y.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y <= bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += step
            }
            ctx.strokePath()
        }

        drawLines(step: minorStep, color: minorColor)
        drawLines(step: majorStep, color: majorColor)
    }

    private func bezierControlPoints(from p0: CGPoint, to p1: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(45.0, abs(p1.x - p0.x) * 0.5)
        return (CGPoint(x: p0.x + dx, y: p0.y), CGPoint(x: p1.x - dx, y: p1.y))
    }

    private func cubicPoint(t: CGFloat, p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint) -> CGPoint {
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t
        let x = uuu * p0.x + 3 * uu * t * c1.x + 3 * u * tt * c2.x + ttt * p1.x
        let y = uuu * p0.y + 3 * uu * t * c1.y + 3 * u * tt * c2.y + ttt * p1.y
        return CGPoint(x: x, y: y)
    }

    private func cubicTangent(t: CGFloat, p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint) -> CGPoint {
        let u = 1 - t
        let x = 3 * u * u * (c1.x - p0.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p1.x - c2.x)
        let y = 3 * u * u * (c1.y - p0.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p1.y - c2.y)
        return CGPoint(x: x, y: y)
    }

    private func drawChevronBezier(from p0: CGPoint, to p1: CGPoint, highlighted: Bool, in ctx: CGContext) {
        let (c1, c2) = bezierControlPoints(from: p0, to: p1)

        // Base subtle connecting spline
        ctx.saveGState()
        let lineColor = highlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor(calibratedWhite: 0.45, alpha: 0.65).cgColor
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(highlighted ? 2.0 : 1.4)
        ctx.beginPath()
        ctx.move(to: p0)
        ctx.addCurve(to: p1, control1: c1, control2: c2)
        ctx.strokePath()

        // Sample evenly along curve to stamp directional triangle chevrons (▶▶▶)
        let samples = 48
        var arcLengths: [CGFloat] = [0]
        var prev = p0
        for i in 1...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let pt = cubicPoint(t: t, p0: p0, c1: c1, c2: c2, p1: p1)
            arcLengths.append(arcLengths.last! + hypot(pt.x - prev.x, pt.y - prev.y))
            prev = pt
        }
        let totalLen = arcLengths.last ?? 0
        guard totalLen > 16 else {
            ctx.restoreGState()
            return
        }

        let pitch: CGFloat = 15.0
        var dist: CGFloat = 10.0 + chevronPhaseOffset.truncatingRemainder(dividingBy: pitch)
        let triColor = highlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor(calibratedWhite: 0.36, alpha: 0.85).cgColor
        ctx.setFillColor(triColor)

        while dist < totalLen - 8.0 {
            // Find t for arc length `dist`
            var t: CGFloat = 0.5
            for i in 1..<arcLengths.count where arcLengths[i] >= dist {
                let segStart = arcLengths[i - 1]
                let segEnd = arcLengths[i]
                let frac = (dist - segStart) / max(0.001, segEnd - segStart)
                t = (CGFloat(i - 1) + frac) / CGFloat(samples)
                break
            }
            let pt = cubicPoint(t: t, p0: p0, c1: c1, c2: c2, p1: p1)
            let tang = cubicTangent(t: t, p0: p0, c1: c1, c2: c2, p1: p1)
            let angle = atan2(tang.y, tang.x)

            ctx.saveGState()
            ctx.translateBy(x: pt.x, y: pt.y)
            ctx.rotate(by: angle)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 4.5, y: 0))
            ctx.addLine(to: CGPoint(x: -3.5, y: -4.2))
            ctx.addLine(to: CGPoint(x: -2.0, y: 0))
            ctx.addLine(to: CGPoint(x: -3.5, y: 4.2))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()

            dist += pitch
        }

        ctx.restoreGState()
    }

    private func drawNode(_ node: WorkflowNode, in ctx: CGContext) {
        let rect = canvasRect(for: node)
        let isSelected = store.selectedNodeIDs.contains(node.id)
        let isHovered = (hoveredNodeID == node.id)
        let hasError = store.nodeErrors[node.id] != nil

        ctx.saveGState()
        if !node.isEnabled {
            ctx.setAlpha(0.48)
        }

        // Soft drop shadow
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: isSelected ? 10 : 6,
            color: (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.11)).cgColor
        )
        NSColor.white.setFill()
        path.fill()
        ctx.restoreGState()

        // Crisp card border
        if hasError {
            NSColor.systemRed.setStroke()
            path.lineWidth = 2.0
        } else if isSelected {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2.2
        } else {
            NSColor(calibratedWhite: 0.78, alpha: 1.0).setStroke()
            path.lineWidth = 1.0
        }
        path.stroke()

        // Line 1: Bold Node Title
        let titlePara = NSMutableParagraphStyle()
        titlePara.alignment = .center
        titlePara.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titlePara
        ]
        let titleRect = CGRect(x: rect.minX + 8, y: rect.minY + 13, width: rect.width - 16, height: 18)
        (node.title as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        // Line 2: Dynamic Subtitle Summary
        let subtitle = store.dryRun.nodeSubtitles[node.id] ?? ""
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: titlePara
        ]
        let subRect = CGRect(x: rect.minX + 8, y: rect.minY + 34, width: rect.width - 16, height: 15)
        (subtitle as NSString).draw(in: subRect, withAttributes: subAttrs)

        // Line 3: File / Asset Count
        let count = store.dryRun.nodeCounts[node.id] ?? 0
        let countText = count == 1 ? "1 File" : "\(count) Files"
        let countAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: titlePara
        ]
        let countRect = CGRect(x: rect.minX + 8, y: rect.minY + 50, width: rect.width - 16, height: 14)
        (countText as NSString).draw(in: countRect, withAttributes: countAttrs)

        // Bottom Center Remove Circle (`⊖`)
        let rmRect = removeButtonCanvasRect(for: node)
        let rmHovered = (hoveredRemoveButtonNodeID == node.id)
        let rmColor = rmHovered ? NSColor.systemRed : NSColor.tertiaryLabelColor
        rmColor.setStroke()
        let rmCircle = NSBezierPath(ovalIn: rmRect.insetBy(dx: 2, dy: 2))
        rmCircle.lineWidth = 1.0
        rmCircle.stroke()
        let minus = NSBezierPath()
        minus.move(to: CGPoint(x: rmRect.midX - 3.2, y: rmRect.midY))
        minus.line(to: CGPoint(x: rmRect.midX + 3.2, y: rmRect.midY))
        minus.lineWidth = 1.1
        minus.stroke()

        // Connection Ports (always drawn subtly on hover/wiring or multi-port Rules)
        let def = node.definition
        let inPorts = def?.inputPortCount ?? 1
        let outPorts = def?.outputPortCount ?? 1
        let showPorts = isHovered || isSelected || outPorts > 1 || {
            if case .wiring = dragMode { return true }
            return false
        }()

        if showPorts {
            if inPorts > 0 {
                let p = inputPortCanvasPoint(for: node)
                drawPortCircle(at: p, label: nil)
            }
            for portIdx in 0..<outPorts {
                let p = outputPortCanvasPoint(for: node, portIndex: portIdx)
                let portLabel = outPorts > 1 ? (portIdx == 0 ? "✓" : "✕") : nil
                drawPortCircle(at: p, label: portLabel)
            }
        }

        // Error Badge (`⚠`)
        if hasError {
            let badgeRect = CGRect(x: rect.maxX - 18, y: rect.minY + 4, width: 14, height: 14)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            let bangAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 9.5),
                .foregroundColor: NSColor.white,
                .paragraphStyle: titlePara
            ]
            ("!" as NSString).draw(in: badgeRect.offsetBy(dx: 0, dy: 0.5), withAttributes: bangAttrs)
        }

        ctx.restoreGState()
    }

    private func drawPortCircle(at center: CGPoint, label: String?) {
        let r = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        let oval = NSBezierPath(ovalIn: r)
        oval.fill()
        oval.lineWidth = 1.4
        oval.stroke()
        if let label {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 7.5),
                .foregroundColor: NSColor.controlAccentColor
            ]
            (label as NSString).draw(at: CGPoint(x: center.x - 3, y: center.y - 5), withAttributes: attrs)
        }
    }

    // MARK: - Hit Testing

    private func hitTestOutputPort(at canvasPt: CGPoint) -> (UUID, Int)? {
        for node in store.document.nodes.reversed() {
            let outCount = node.definition?.outputPortCount ?? 1
            for portIdx in 0..<outCount {
                let p = outputPortCanvasPoint(for: node, portIndex: portIdx)
                if hypot(canvasPt.x - p.x, canvasPt.y - p.y) <= 12.0 {
                    return (node.id, portIdx)
                }
            }
        }
        return nil
    }

    private func hitTestInputPort(at canvasPt: CGPoint) -> (UUID, Int)? {
        for node in store.document.nodes.reversed() {
            guard (node.definition?.inputPortCount ?? 1) > 0 else { continue }
            let p = inputPortCanvasPoint(for: node)
            if hypot(canvasPt.x - p.x, canvasPt.y - p.y) <= 14.0 || canvasRect(for: node).contains(canvasPt) {
                return (node.id, 0)
            }
        }
        return nil
    }

    private func hitTestNode(at canvasPt: CGPoint) -> WorkflowNode? {
        store.document.nodes.reversed().first { canvasRect(for: $0).contains(canvasPt) }
    }

    private func hitTestEdge(at canvasPt: CGPoint) -> WorkflowEdge? {
        let nodeMap = Dictionary(uniqueKeysWithValues: store.document.nodes.map { ($0.id, $0) })
        for edge in store.document.edges {
            guard let src = nodeMap[edge.sourceNodeID], let dst = nodeMap[edge.targetNodeID] else { continue }
            let p0 = outputPortCanvasPoint(for: src, portIndex: edge.sourcePortIndex)
            let p1 = inputPortCanvasPoint(for: dst, portIndex: edge.targetPortIndex)
            let (c1, c2) = bezierControlPoints(from: p0, to: p1)
            for step in 0...24 {
                let pt = cubicPoint(t: CGFloat(step) / 24.0, p0: p0, c1: c1, c2: c2, p1: p1)
                if hypot(pt.x - canvasPt.x, pt.y - canvasPt.y) <= 8.0 {
                    return edge
                }
            }
        }
        return nil
    }

    // MARK: - Mouse & Trackpad Events

    override func mouseMoved(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPt = viewToCanvas(viewPt)

        let nextHoveredNode = hitTestNode(at: canvasPt)?.id
        let nextHoveredEdge = nextHoveredNode == nil ? hitTestEdge(at: canvasPt)?.id : nil
        var nextRm: UUID?
        if let nID = nextHoveredNode,
           let node = store.document.nodes.first(where: { $0.id == nID }),
           removeButtonCanvasRect(for: node).insetBy(dx: -3, dy: -3).contains(canvasPt) {
            nextRm = nID
        }

        if nextHoveredNode != hoveredNodeID || nextHoveredEdge != hoveredEdgeID || nextRm != hoveredRemoveButtonNodeID {
            hoveredNodeID = nextHoveredNode
            hoveredEdgeID = nextHoveredEdge
            hoveredRemoveButtonNodeID = nextRm
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPt = viewToCanvas(viewPt)

        // Middle click or Space+click pans
        if event.modifierFlags.contains(.option) {
            dragMode = .panning(startMouseView: viewPt, initialOffset: store.document.viewportOffset)
            return
        }

        // 1. Output port drag -> create wire
        if let (srcID, srcPort) = hitTestOutputPort(at: canvasPt) {
            dragMode = .wiring(sourceNodeID: srcID, sourcePort: srcPort, currentCanvas: canvasPt)
            needsDisplay = true
            return
        }

        // 2. Node hit -> remove button or select + move
        if let node = hitTestNode(at: canvasPt) {
            if removeButtonCanvasRect(for: node).insetBy(dx: -3, dy: -3).contains(canvasPt) {
                store.removeNodes(ids: [node.id])
                return
            }

            let shiftHeld = event.modifierFlags.contains(.shift)
            if !store.selectedNodeIDs.contains(node.id) || shiftHeld {
                store.selectNode(node.id, toggle: shiftHeld, showInspector: !shiftHeld)
            } else if store.selectedNodeIDs.count == 1 {
                store.inspectorVisibleNodeID = node.id
            }

            var starts: [UUID: GraphPoint] = [:]
            for n in store.document.nodes where store.selectedNodeIDs.contains(n.id) {
                starts[n.id] = n.position
            }
            store.beginContinuousEdit()
            dragMode = .movingNodes(startMouseCanvas: canvasPt, initialPositions: starts)
            syncInspectorPopover()
            return
        }

        // 3. Edge hit -> select wire
        if let edge = hitTestEdge(at: canvasPt) {
            store.selectNode(nil)
            store.selectedEdgeID = edge.id
            needsDisplay = true
            return
        }

        // 4. Empty canvas -> clear selection & start marquee
        store.selectNode(nil)
        dragMode = .marquee(startCanvas: canvasPt, currentCanvas: canvasPt)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPt = viewToCanvas(viewPt)

        switch dragMode {
        case .movingNodes(let startMouse, let initials):
            let dx = Double(canvasPt.x - startMouse.x)
            let dy = Double(canvasPt.y - startMouse.y)
            var updates: [UUID: GraphPoint] = [:]
            for (id, orig) in initials {
                updates[id] = GraphPoint(x: orig.x + dx, y: orig.y + dy)
            }
            store.updateNodePositionsTransient(updates)
            needsDisplay = true

        case .wiring(let srcID, let srcPort, _):
            dragMode = .wiring(sourceNodeID: srcID, sourcePort: srcPort, currentCanvas: canvasPt)
            needsDisplay = true

        case .marquee(let s, _):
            dragMode = .marquee(startCanvas: s, currentCanvas: canvasPt)
            let rect = CGRect(x: min(s.x, canvasPt.x), y: min(s.y, canvasPt.y), width: abs(canvasPt.x - s.x), height: abs(canvasPt.y - s.y))
            let hits = Set(store.document.nodes.filter { rect.intersects(canvasRect(for: $0)) }.map(\.id))
            store.selectedNodeIDs = hits
            needsDisplay = true

        case .panning(let startView, let initialOffset):
            store.document.viewportOffset = GraphPoint(
                x: initialOffset.x + Double(viewPt.x - startView.x),
                y: initialOffset.y + Double(viewPt.y - startView.y)
            )
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPt = viewToCanvas(viewPt)

        switch dragMode {
        case .movingNodes:
            store.commitContinuousEdit(actionName: String(localized: "Move Node"))
            syncInspectorPopover()
        case .wiring(let srcID, let srcPort, _):
            if let (dstID, dstPort) = hitTestInputPort(at: canvasPt) {
                _ = store.connect(sourceID: srcID, sourcePort: srcPort, targetID: dstID, targetPort: dstPort)
            }
        case .marquee, .panning, .none:
            break
        }
        dragMode = .none
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1.0 + Double(event.scrollingDeltaY) * 0.01
            let nextZoom = max(0.35, min(2.5, store.document.viewportZoom * factor))
            store.document.viewportZoom = nextZoom
        } else {
            store.document.viewportOffset.x += Double(event.scrollingDeltaX)
            store.document.viewportOffset.y += Double(event.scrollingDeltaY)
        }
        needsDisplay = true
        syncInspectorPopover()
    }

    override func magnify(with event: NSEvent) {
        let nextZoom = max(0.35, min(2.5, store.document.viewportZoom * (1.0 + Double(event.magnification))))
        store.document.viewportZoom = nextZoom
        needsDisplay = true
        syncInspectorPopover()
    }

    // MARK: - Keyboard Navigation & Accessibility Actions

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""

        // Delete / Backspace
        if event.keyCode == 51 || event.keyCode == 117 {
            if let edgeID = store.selectedEdgeID {
                store.removeEdge(id: edgeID)
                return
            }
            if !store.selectedNodeIDs.isEmpty {
                store.removeNodes(ids: store.selectedNodeIDs)
                return
            }
        }

        // Tab cycles nodes
        if event.keyCode == 48 {
            cycleSelectedNode(reverse: event.modifierFlags.contains(.shift))
            return
        }

        // Return opens/toggles inspector popover
        if event.keyCode == 36, let selected = store.primarySelectedNodeID {
            store.inspectorVisibleNodeID = (store.inspectorVisibleNodeID == selected) ? nil : selected
            syncInspectorPopover()
            return
        }

        // Cmd+L opens keyboard-accessible "Connect To…" menu
        if event.modifierFlags.contains(.command), chars.lowercased() == "l",
           let src = store.primarySelectedNode {
            presentConnectMenu(from: src)
            return
        }

        // Arrow keys nudge selected nodes
        let step: Double = event.modifierFlags.contains(.shift) ? 10.0 : 2.0
        switch event.keyCode {
        case 123: store.nudgeSelectedNodes(dx: -step, dy: 0)
        case 124: store.nudgeSelectedNodes(dx: step, dy: 0)
        case 125: store.nudgeSelectedNodes(dx: 0, dy: step)
        case 126: store.nudgeSelectedNodes(dx: 0, dy: -step)
        default: super.keyDown(with: event)
        }
    }

    private func cycleSelectedNode(reverse: Bool) {
        let order = store.document.topologicalOrder()
        guard !order.isEmpty else { return }
        if let cur = store.primarySelectedNodeID, let idx = order.firstIndex(of: cur) {
            let nextIdx = reverse ? (idx - 1 + order.count) % order.count : (idx + 1) % order.count
            store.selectNode(order[nextIdx], showInspector: true)
        } else {
            store.selectNode(order[0], showInspector: true)
        }
    }

    private func presentConnectMenu(from source: WorkflowNode) {
        let menu = NSMenu(title: "Connect To")
        for target in store.document.nodes where store.document.canConnect(from: source.id, to: target.id) {
            let item = NSMenuItem(title: target.title, action: #selector(connectMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [source.id, target.id]
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "No compatible downstream nodes", action: nil, keyEquivalent: ""))
        }
        let anchor = canvasToView(CGPoint(x: source.position.x + Double(nodeSize.width), y: source.position.y + 20))
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func connectMenuItemSelected(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [UUID], pair.count == 2 else { return }
        _ = store.connect(sourceID: pair[0], targetID: pair[1])
    }

    // MARK: - Drag & Drop Destination (Sidebar Node Templates + Finder Files/Folders)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let viewPt = convert(sender.draggingLocation, from: nil)
        let canvasPt = viewToCanvas(viewPt)
        let centeredPos = GraphPoint(
            x: Double(canvasPt.x - nodeSize.width * 0.5),
            y: Double(canvasPt.y - nodeSize.height * 0.5)
        )

        let pb = sender.draggingPasteboard

        if let data = pb.data(forType: NSPasteboard.PasteboardType(UTType.flowbatchNodeTemplate.identifier)),
           let payload = try? JSONDecoder().decode(NodeDragPayload.self, from: data) {
            let autoSource = store.primarySelectedNodeID
            store.addNode(typeID: payload.typeID, at: centeredPos, autoConnectFrom: autoSource)
            return true
        }

        if let str = pb.string(forType: .string), str.hasPrefix("flowbatch-node:") {
            let typeID = String(str.dropFirst("flowbatch-node:".count))
            let autoSource = store.primarySelectedNodeID
            store.addNode(typeID: typeID, at: centeredPos, autoConnectFrom: autoSource)
            return true
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var folders: [URL] = []
            var files: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    folders.append(url)
                } else {
                    files.append(url)
                }
            }
            var offsetY = 0.0
            for folder in folders {
                let node = store.addNode(
                    typeID: NodeTypeID.readFolder,
                    at: GraphPoint(x: centeredPos.x, y: centeredPos.y + offsetY)
                )
                store.setParameter(nodeID: node.id, key: "folderPath", value: .string(folder.path), actionName: "Drop Folder")
                offsetY += 110
            }
            if !files.isEmpty {
                let joined = files.map(\.path).joined(separator: ";")
                let node = store.addNode(
                    typeID: NodeTypeID.readFiles,
                    at: GraphPoint(x: centeredPos.x, y: centeredPos.y + offsetY)
                )
                store.setParameter(nodeID: node.id, key: "filePaths", value: .string(joined), actionName: "Drop Files")
            }
            return true
        }

        return false
    }

    // MARK: - VoiceOver Accessibility Tree

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        String(localized: "Workflow Node Graph Canvas")
    }

    override func accessibilityChildren() -> [Any]? {
        store.document.nodes.map { node in
            let subtitle = store.dryRun.nodeSubtitles[node.id] ?? ""
            let count = store.dryRun.nodeCounts[node.id] ?? 0
            let label = "\(node.title), \(subtitle), \(count) files"
            let rectInView = viewRect(for: node)
            let rectInWindow = convert(rectInView, to: nil)
            let screenRect = window?.convertToScreen(rectInWindow) ?? rectInView
            let nodeID = node.id
            let storeRef = store
            return NodeAccessibilityElement(
                title: node.title,
                identifier: "canvas.node.\(node.typeID)",
                label: label,
                screenRect: screenRect,
                parentView: self,
                onSelect: { storeRef.selectNode(nodeID, showInspector: true) }
            )
        }
    }

    private final class NodeAccessibilityElement: NSAccessibilityElement {
        private let onSelect: @MainActor @Sendable () -> Void

        @MainActor
        init(
            title: String,
            identifier: String,
            label: String,
            screenRect: CGRect,
            parentView: NodeGraphCanvasNSView,
            onSelect: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onSelect = onSelect
            super.init()
            setAccessibilityParent(parentView)
            setAccessibilityRole(.button)
            setAccessibilityTitle(title)
            setAccessibilityLabel(label)
            setAccessibilityIdentifier(identifier)
            setAccessibilityEnabled(true)
            setAccessibilityFrame(screenRect)
        }

        override func accessibilityPerformPress() -> Bool {
            let select = onSelect
            MainActor.assumeIsolated {
                select()
            }
            return true
        }
    }
}
