import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  DryRunReport,
  GraphPoint,
  NodeDefinition,
  WorkflowDocumentModel,
  WorkflowEdge,
  WorkflowNode,
} from "../types/workflow";

const NODE_W = 132;
const NODE_H = 92;

interface NodeGraphCanvasProps {
  document: WorkflowDocumentModel;
  catalogMap: Map<string, NodeDefinition>;
  dryRun: DryRunReport | null;
  selectedNodeIDs: Set<string>;
  selectedEdgeID: string | null;
  nodeErrors: Record<string, string>;
  inspectorContent: React.ReactNode;
  inspectorNodeID: string | null;
  onSelectNode: (id: string | null, multi?: boolean, openInspector?: boolean) => void;
  onSelectEdge: (id: string | null) => void;
  onMoveNodesTransient: (positions: Record<string, GraphPoint>) => void;
  onCommitMove: () => void;
  onRemoveNode: (id: string) => void;
  onConnect: (srcID: string, srcPort: number, dstID: string, dstPort: number) => void;
  onDropNodeTemplate: (typeID: string, pos: GraphPoint) => void;
  onViewportChange: (offset: GraphPoint, zoom: number) => void;
}

function inputPortPos(node: WorkflowNode): GraphPoint {
  return { x: node.position.x, y: node.position.y + NODE_H * 0.5 };
}

function outputPortPos(node: WorkflowNode, def: NodeDefinition | undefined, portIdx = 0): GraphPoint {
  const count = Math.max(1, def?.outputPortCount ?? 1);
  const ratio = count === 1 ? 0.5 : portIdx === 0 ? 0.34 : 0.66;
  return { x: node.position.x + NODE_W, y: node.position.y + NODE_H * ratio };
}

function bezierPathAndChevrons(p0: GraphPoint, p1: GraphPoint) {
  const dx = Math.max(46, Math.abs(p1.x - p0.x) * 0.5);
  const c1 = { x: p0.x + dx, y: p0.y };
  const c2 = { x: p1.x - dx, y: p1.y };
  const d = `M ${p0.x} ${p0.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p1.x} ${p1.y}`;

  const chevrons: { x: number; y: number; angle: number }[] = [];
  const approxLen = Math.hypot(p1.x - p0.x, p1.y - p0.y);
  const count = Math.max(2, Math.min(8, Math.floor(approxLen / 28)));
  for (let i = 1; i <= count; i++) {
    const t = i / (count + 1);
    const u = 1 - t;
    const x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x;
    const y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y;
    const tx = 3 * u * u * (c1.x - p0.x) + 6 * u * t * (c2.x - c1.x) + 3 * t * t * (p1.x - c2.x);
    const ty = 3 * u * u * (c1.y - p0.y) + 6 * u * t * (c2.y - c1.y) + 3 * t * t * (p1.y - c2.y);
    const angle = (Math.atan2(ty, tx) * 180) / Math.PI;
    chevrons.push({ x, y, angle });
  }
  return { d, chevrons };
}

export const NodeGraphCanvas: React.FC<NodeGraphCanvasProps> = ({
  document,
  catalogMap,
  dryRun,
  selectedNodeIDs,
  selectedEdgeID,
  nodeErrors,
  inspectorContent,
  inspectorNodeID,
  onSelectNode,
  onSelectEdge,
  onMoveNodesTransient,
  onCommitMove,
  onRemoveNode,
  onConnect,
  onDropNodeTemplate,
  onViewportChange,
}) => {
  const containerRef = useRef<HTMLDivElement>(null);
  const [containerSize, setContainerSize] = useState<{ w: number; h: number }>({ w: 760, h: 760 });
  const [hoveredNodeID, setHoveredNodeID] = useState<string | null>(null);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const sync = () => setContainerSize({ w: el.clientWidth, h: el.clientHeight });
    sync();
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const [wiring, setWiring] = useState<{
    srcID: string;
    srcPort: number;
    cur: GraphPoint;
  } | null>(null);
  const dragRef = useRef<{
    kind: "move" | "pan";
    startClient: GraphPoint;
    initialPositions: Record<string, GraphPoint>;
    initialOffset: GraphPoint;
    moved: boolean;
  } | null>(null);

  const zoom = Math.max(0.35, Math.min(2.5, document.viewportZoom || 1));
  const pan = document.viewportOffset || { x: 0, y: 0 };

  const nodeMap = useMemo(() => {
    const m = new Map<string, WorkflowNode>();
    for (const n of document.nodes) m.set(n.id, n);
    return m;
  }, [document.nodes]);

  const clientToCanvas = (clientX: number, clientY: number): GraphPoint => {
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return { x: 0, y: 0 };
    return {
      x: (clientX - rect.left - pan.x) / zoom,
      y: (clientY - rect.top - pan.y) / zoom,
    };
  };

  const handleCanvasMouseDown = (e: React.MouseEvent) => {
    if (e.target !== containerRef.current && !(e.target as HTMLElement).classList.contains("canvas-world")) {
      return;
    }
    if (e.button === 1 || e.altKey) {
      dragRef.current = {
        kind: "pan",
        startClient: { x: e.clientX, y: e.clientY },
        initialPositions: {},
        initialOffset: { ...pan },
        moved: false,
      };
      return;
    }
    onSelectNode(null, false, false);
    onSelectEdge(null);
  };

  const handleNodeMouseDown = (e: React.MouseEvent, node: WorkflowNode) => {
    e.stopPropagation();
    const multi = e.shiftKey;
    const alreadySelected = selectedNodeIDs.has(node.id);
    if (!alreadySelected || multi) {
      onSelectNode(node.id, multi, !multi);
    } else if (selectedNodeIDs.size === 1) {
      onSelectNode(node.id, false, true);
    }

    const activeSet = alreadySelected && !multi ? selectedNodeIDs : new Set([node.id]);
    const initialPositions: Record<string, GraphPoint> = {};
    for (const n of document.nodes) {
      if (activeSet.has(n.id)) {
        initialPositions[n.id] = { ...n.position };
      }
    }
    dragRef.current = {
      kind: "move",
      startClient: { x: e.clientX, y: e.clientY },
      initialPositions,
      initialOffset: pan,
      moved: false,
    };
  };

  const handleMouseMove = (e: React.MouseEvent) => {
    if (wiring) {
      setWiring((prev) => (prev ? { ...prev, cur: clientToCanvas(e.clientX, e.clientY) } : null));
      return;
    }
    const drag = dragRef.current;
    if (!drag) return;

    const dxScreen = e.clientX - drag.startClient.x;
    const dyScreen = e.clientY - drag.startClient.y;
    if (Math.hypot(dxScreen, dyScreen) > 2) {
      drag.moved = true;
    }

    if (drag.kind === "pan") {
      onViewportChange(
        { x: drag.initialOffset.x + dxScreen, y: drag.initialOffset.y + dyScreen },
        zoom
      );
    } else if (drag.kind === "move") {
      const dx = dxScreen / zoom;
      const dy = dyScreen / zoom;
      const next: Record<string, GraphPoint> = {};
      for (const [id, orig] of Object.entries(drag.initialPositions)) {
        next[id] = { x: orig.x + dx, y: orig.y + dy };
      }
      onMoveNodesTransient(next);
    }
  };

  const handleMouseUp = (e: React.MouseEvent) => {
    if (wiring) {
      const pt = clientToCanvas(e.clientX, e.clientY);
      // Hit test any node input port or body
      for (const n of [...document.nodes].reverse()) {
        const def = catalogMap.get(n.typeID);
        if ((def?.inputPortCount ?? 1) === 0) continue;
        const pIn = inputPortPos(n);
        const insideNode =
          pt.x >= n.position.x - 14 &&
          pt.x <= n.position.x + NODE_W &&
          pt.y >= n.position.y &&
          pt.y <= n.position.y + NODE_H;
        if (Math.hypot(pt.x - pIn.x, pt.y - pIn.y) <= 16 || insideNode) {
          onConnect(wiring.srcID, wiring.srcPort, n.id, 0);
          break;
        }
      }
      setWiring(null);
    }

    if (dragRef.current) {
      if (dragRef.current.kind === "move" && dragRef.current.moved) {
        onCommitMove();
      }
      dragRef.current = null;
    }
  };

  const handleWheel = (e: React.WheelEvent) => {
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      const nextZoom = Math.max(0.35, Math.min(2.5, zoom * (1 - e.deltaY * 0.0015)));
      onViewportChange(pan, nextZoom);
    } else {
      onViewportChange({ x: pan.x - e.deltaX, y: pan.y - e.deltaY }, zoom);
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    const typeID = e.dataTransfer.getData("application/x-flowbatch-node");
    if (!typeID) return;
    const pt = clientToCanvas(e.clientX, e.clientY);
    onDropNodeTemplate(typeID, { x: pt.x - NODE_W * 0.5, y: pt.y - NODE_H * 0.5 });
  };

  // Compute floating popover screen position anchored cleanly below the selected node
  const popoverStyle = useMemo<React.CSSProperties | null>(() => {
    if (!inspectorNodeID) return null;
    const node = nodeMap.get(inspectorNodeID);
    if (!node) return null;
    const popoverW = 376;
    const margin = 16;
    const viewX = node.position.x * zoom + pan.x + (NODE_W * zoom) * 0.5 - popoverW * 0.5;
    const viewY = (node.position.y + NODE_H) * zoom + pan.y + 12;
    const clampedLeft = Math.max(margin, Math.min(Math.max(margin, containerSize.w - popoverW - margin), viewX));
    const clampedTop = Math.max(margin, Math.min(Math.max(margin, containerSize.h - 220), viewY));
    const maxHeight = Math.max(200, containerSize.h - clampedTop - margin);
    return { left: clampedLeft, top: clampedTop, maxHeight };
  }, [inspectorNodeID, nodeMap, zoom, pan, containerSize]);

  const minorStep = 16 * zoom;
  const majorStep = 80 * zoom;
  const gridBgStyle: React.CSSProperties = {
    backgroundImage: `
      linear-gradient(to right, #ebeef4 1px, transparent 1px),
      linear-gradient(to bottom, #ebeef4 1px, transparent 1px),
      linear-gradient(to right, #dfe4ed 1px, transparent 1px),
      linear-gradient(to bottom, #dfe4ed 1px, transparent 1px)
    `,
    backgroundSize: `${minorStep}px ${minorStep}px, ${minorStep}px ${minorStep}px, ${majorStep}px ${majorStep}px, ${majorStep}px ${majorStep}px`,
    backgroundPosition: `${pan.x}px ${pan.y}px`,
  };

  return (
    <div
      ref={containerRef}
      className="canvas-viewport"
      style={gridBgStyle}
      onMouseDown={handleCanvasMouseDown}
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onWheel={handleWheel}
      onDragOver={(e) => e.preventDefault()}
      onDrop={handleDrop}
    >
      <div
        className="canvas-world"
        style={{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }}
      >
        {/* Directed Chevron Bézier Wires */}
        <svg className="canvas-svg-edges" width="4000" height="3000">
          {document.edges.map((edge: WorkflowEdge) => {
            const src = nodeMap.get(edge.sourceNodeID);
            const dst = nodeMap.get(edge.targetNodeID);
            if (!src || !dst) return null;
            const p0 = outputPortPos(src, catalogMap.get(src.typeID), edge.sourcePortIndex);
            const p1 = inputPortPos(dst);
            const { d, chevrons } = bezierPathAndChevrons(p0, p1);
            const isSel = selectedEdgeID === edge.id;
            const stroke = isSel ? "#0067c0" : "#8b94a6";
            return (
              <g key={edge.id}>
                <path
                  d={d}
                  fill="none"
                  stroke="transparent"
                  strokeWidth={14}
                  className="canvas-edge-hit"
                  onMouseDown={(ev) => {
                    ev.stopPropagation();
                    onSelectNode(null, false, false);
                    onSelectEdge(edge.id);
                  }}
                />
                <path d={d} fill="none" stroke={stroke} strokeWidth={isSel ? 2.4 : 1.75} />
                {chevrons.map((c, idx) => (
                  <polygon
                    key={idx}
                    points="-4,-3.2 4,0 -4,3.2"
                    fill={stroke}
                    transform={`translate(${c.x},${c.y}) rotate(${c.angle})`}
                  />
                ))}
              </g>
            );
          })}

          {wiring && (() => {
            const src = nodeMap.get(wiring.srcID);
            if (!src) return null;
            const p0 = outputPortPos(src, catalogMap.get(src.typeID), wiring.srcPort);
            const { d } = bezierPathAndChevrons(p0, wiring.cur);
            return <path d={d} fill="none" stroke="#0067c0" strokeWidth={2.2} strokeDasharray="5 4" />;
          })()}
        </svg>

        {/* Node Cards */}
        {document.nodes.map((node) => {
          const def = catalogMap.get(node.typeID);
          const isSelected = selectedNodeIDs.has(node.id);
          const isHovered = hoveredNodeID === node.id;
          const subtitle = dryRun?.nodeSubtitles[node.id] ?? "";
          const count = dryRun?.nodeCounts[node.id] ?? 0;
          const inPorts = def?.inputPortCount ?? 1;
          const outPorts = def?.outputPortCount ?? 1;
          const showPorts = isHovered || isSelected || outPorts > 1 || wiring !== null;
          const errMsg = nodeErrors[node.id];

          return (
            <div
              key={node.id}
              className={`node-card ${isSelected ? "selected" : ""} ${node.isEnabled ? "" : "disabled"}`}
              style={{ left: node.position.x, top: node.position.y }}
              onMouseEnter={() => setHoveredNodeID(node.id)}
              onMouseLeave={() => setHoveredNodeID((cur) => (cur === node.id ? null : cur))}
              onMouseDown={(e) => handleNodeMouseDown(e, node)}
            >
              <div className="node-card-title">{node.title}</div>
              {subtitle && <div className="node-card-sub">{subtitle}</div>}
              <div className="node-card-count">{count} Files</div>

              <button
                className="node-remove-btn"
                title="Remove node"
                onMouseDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  e.stopPropagation();
                  onRemoveNode(node.id);
                }}
              >
                −
              </button>

              {errMsg && (
                <div className="node-error-badge" title={errMsg}>
                  !
                </div>
              )}

              {showPorts && inPorts > 0 && (
                <div className="node-port" style={{ left: 0, top: NODE_H * 0.5 }} title="Input" />
              )}

              {showPorts &&
                Array.from({ length: outPorts }).map((_, portIdx) => {
                  const yRatio = outPorts === 1 ? 0.5 : portIdx === 0 ? 0.34 : 0.66;
                  return (
                    <div
                      key={portIdx}
                      className="node-port"
                      style={{ left: NODE_W, top: NODE_H * yRatio }}
                      title={def?.outputPortLabels[portIdx] ?? "Drag to connect"}
                      onMouseDown={(e) => {
                        e.stopPropagation();
                        setWiring({
                          srcID: node.id,
                          srcPort: portIdx,
                          cur: clientToCanvas(e.clientX, e.clientY),
                        });
                      }}
                    >
                      {outPorts > 1 ? (portIdx === 0 ? "✓" : "✕") : ""}
                    </div>
                  );
                })}
            </div>
          );
        })}
      </div>

      {/* Anchored Popover Inspector */}
      {inspectorNodeID && popoverStyle && inspectorContent && (
        <div
          className="inspector-popover"
          style={popoverStyle}
          onMouseDown={(e) => e.stopPropagation()}
        >
          {inspectorContent}
        </div>
      )}
    </div>
  );
};
