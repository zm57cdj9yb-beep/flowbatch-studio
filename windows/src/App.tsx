import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open as openDialog, save as saveDialog } from "@tauri-apps/plugin-dialog";
import { openPath } from "@tauri-apps/plugin-opener";
import { NodeGraphCanvas } from "./components/NodeGraphCanvas";
import { NodeInspectorPopover } from "./components/NodeInspectorPopover";
import { NodeLibrarySidebar } from "./components/NodeLibrarySidebar";
import { PreviewSplitPane } from "./components/PreviewSplitPane";
import { Toolbar } from "./components/Toolbar";
import { WorkflowConsole } from "./components/WorkflowConsole";
import {
  BatchRunResult,
  DryRunReport,
  ExecutionLogEntry,
  GraphPoint,
  NodeDefinition,
  NodeErrorPolicy,
  NodeParamValue,
  PreviewResponse,
  pv,
  WorkflowDocumentModel,
  WorkflowNode,
} from "./types/workflow";

function deepClone<T>(v: T): T {
  return JSON.parse(JSON.stringify(v));
}

function canConnectClient(doc: WorkflowDocumentModel, srcID: string, dstID: string): boolean {
  if (srcID === dstID) return false;
  const adj = new Map<string, string[]>();
  for (const e of doc.edges) {
    const list = adj.get(e.sourceNodeID) ?? [];
    list.push(e.targetNodeID);
    adj.set(e.sourceNodeID, list);
  }
  const visited = new Set<string>();
  const queue = [dstID];
  while (queue.length > 0) {
    const cur = queue.shift()!;
    if (cur === srcID) return false;
    if (!visited.has(cur)) {
      visited.add(cur);
      for (const nxt of adj.get(cur) ?? []) queue.push(nxt);
    }
  }
  return true;
}

export const App: React.FC = () => {
  const [catalog, setCatalog] = useState<NodeDefinition[]>([]);
  const [outputFormats, setOutputFormats] = useState<string[]>([
    "PNG",
    "JPEG",
    "WebP",
    "TIFF",
    "GIF",
    "BMP",
    "ICO",
    "PDF",
  ]);
  const [doc, setDoc] = useState<WorkflowDocumentModel | null>(null);
  const [filePath, setFilePath] = useState<string | null>(null);
  const [dirty, setDirty] = useState(false);

  const [undoStack, setUndoStack] = useState<WorkflowDocumentModel[]>([]);
  const [redoStack, setRedoStack] = useState<WorkflowDocumentModel[]>([]);
  const continuousBaseRef = useRef<WorkflowDocumentModel | null>(null);

  const [selectedNodeIDs, setSelectedNodeIDs] = useState<Set<string>>(new Set());
  const [selectedEdgeID, setSelectedEdgeID] = useState<string | null>(null);
  const [inspectorNodeID, setInspectorNodeID] = useState<string | null>(null);
  const [selectedAssetIndex, setSelectedAssetIndex] = useState(0);

  const [dryRun, setDryRun] = useState<DryRunReport | null>(null);
  const [preview, setPreview] = useState<PreviewResponse | null>(null);
  const [isRunning, setIsRunning] = useState(false);
  const [nodeErrors, setNodeErrors] = useState<Record<string, string>>({});
  const [logs, setLogs] = useState<ExecutionLogEntry[]>([]);

  const [showSidebar, setShowSidebar] = useState(true);
  const [showPreview, setShowPreview] = useState(true);
  const [showConsole, setShowConsole] = useState(false);

  const catalogMap = useMemo(() => {
    const m = new Map<string, NodeDefinition>();
    for (const d of catalog) m.set(d.typeID, d);
    return m;
  }, [catalog]);

  // Initial load from Rust backend
  useEffect(() => {
    (async () => {
      const [defs, fmts, starter] = await Promise.all([
        invoke<NodeDefinition[]>("get_catalog"),
        invoke<string[]>("get_output_formats"),
        invoke<WorkflowDocumentModel>("create_starter_workflow"),
      ]);
      setCatalog(defs);
      setOutputFormats(fmts);
      setDoc(starter);
      const writeNode = starter.nodes.find((n) => n.typeID === "write.images") ?? starter.nodes[starter.nodes.length - 1];
      if (writeNode) {
        setSelectedNodeIDs(new Set([writeNode.id]));
        setInspectorNodeID(writeNode.id);
      }
    })();
  }, []);

  const primarySelectedID = useMemo(() => {
    if (inspectorNodeID) return inspectorNodeID;
    const iter = selectedNodeIDs.values().next();
    return iter.done ? null : iter.value;
  }, [inspectorNodeID, selectedNodeIDs]);

  // Recompute live dry-run preflight on every document change
  useEffect(() => {
    if (!doc) return;
    let active = true;
    invoke<DryRunReport>("dry_run_workflow", { document: doc })
      .then((rep) => {
        if (active) setDryRun(rep);
      })
      .catch(() => {});
    return () => {
      active = false;
    };
  }, [doc]);

  const activeAssets = useMemo(() => {
    if (!dryRun || !doc) return [];
    const targetID = primarySelectedID ?? doc.nodes[doc.nodes.length - 1]?.id;
    const forNode = targetID ? dryRun.nodeAssets[targetID] ?? [] : [];
    if (forNode.length > 0) return forNode;
    // Fallback to all source read assets
    for (const n of doc.nodes) {
      const a = dryRun.nodeAssets[n.id];
      if (a && a.length > 0) return a;
    }
    return [];
  }, [dryRun, doc, primarySelectedID]);

  // Recompute live preview on document/selection/asset changes (debounced 40ms)
  useEffect(() => {
    if (!doc) return;
    const asset = activeAssets[selectedAssetIndex] ?? activeAssets[0];
    const timer = window.setTimeout(() => {
      invoke<PreviewResponse>("render_preview", {
        document: doc,
        targetNodeId: primarySelectedID,
        assetPath: asset?.path ?? null,
      })
        .then(setPreview)
        .catch(() => {});
    }, 40);
    return () => window.clearTimeout(timer);
  }, [doc, primarySelectedID, selectedAssetIndex, activeAssets]);

  const commitDoc = useCallback((mutator: (draft: WorkflowDocumentModel) => void) => {
    setDoc((prev) => {
      if (!prev) return prev;
      setUndoStack((u) => [...u.slice(-49), deepClone(prev)]);
      setRedoStack([]);
      setDirty(true);
      const next = deepClone(prev);
      mutator(next);
      return next;
    });
  }, []);

  const mutateTransient = useCallback((mutator: (draft: WorkflowDocumentModel) => void) => {
    setDoc((prev) => {
      if (!prev) return prev;
      if (!continuousBaseRef.current) {
        continuousBaseRef.current = deepClone(prev);
      }
      const next = deepClone(prev);
      mutator(next);
      return next;
    });
  }, []);

  const commitContinuous = useCallback(() => {
    if (continuousBaseRef.current) {
      const snap = continuousBaseRef.current;
      continuousBaseRef.current = null;
      setUndoStack((u) => [...u.slice(-49), snap]);
      setRedoStack([]);
      setDirty(true);
    }
  }, []);

  const handleUndo = useCallback(() => {
    setUndoStack((prev) => {
      if (prev.length === 0 || !doc) return prev;
      const last = prev[prev.length - 1];
      setRedoStack((r) => [...r, deepClone(doc)]);
      setDoc(last);
      return prev.slice(0, -1);
    });
  }, [doc]);

  const handleRedo = useCallback(() => {
    setRedoStack((prev) => {
      if (prev.length === 0 || !doc) return prev;
      const next = prev[prev.length - 1];
      setUndoStack((u) => [...u, deepClone(doc)]);
      setDoc(next);
      return prev.slice(0, -1);
    });
  }, [doc]);

  const handleInsertNode = useCallback(
    (typeID: string, atPos?: GraphPoint) => {
      const def = catalogMap.get(typeID);
      if (!def || !doc) return;
      const anchorNode = primarySelectedID
        ? doc.nodes.find((n) => n.id === primarySelectedID)
        : undefined;
      const pos: GraphPoint = atPos ?? {
        x: anchorNode ? anchorNode.position.x + 170 : 120 + (doc.nodes.length % 4) * 50,
        y: anchorNode ? anchorNode.position.y + 44 : 120 + (doc.nodes.length % 4) * 40,
      };
      const params: Record<string, NodeParamValue> = {};
      for (const p of def.parameters) {
        params[p.key] = deepClone(p.defaultValue);
      }
      const newNode: WorkflowNode = {
        id: crypto.randomUUID().toUpperCase(),
        typeID: def.typeID,
        title: def.title,
        position: pos,
        isEnabled: true,
        errorPolicy: "Skip Asset",
        parameters: params,
      };
      commitDoc((draft) => {
        draft.nodes.push(newNode);
        if (
          anchorNode &&
          (catalogMap.get(anchorNode.typeID)?.outputPortCount ?? 1) > 0 &&
          def.inputPortCount > 0 &&
          canConnectClient(draft, anchorNode.id, newNode.id)
        ) {
          draft.edges.push({
            id: crypto.randomUUID().toUpperCase(),
            sourceNodeID: anchorNode.id,
            sourcePortIndex: 0,
            targetNodeID: newNode.id,
            targetPortIndex: 0,
          });
        }
      });
      setSelectedNodeIDs(new Set([newNode.id]));
      setInspectorNodeID(newNode.id);
    },
    [catalogMap, doc, primarySelectedID, commitDoc]
  );

  const handleRemoveNode = useCallback(
    (id: string) => {
      commitDoc((draft) => {
        draft.nodes = draft.nodes.filter((n) => n.id !== id);
        draft.edges = draft.edges.filter((e) => e.sourceNodeID !== id && e.targetNodeID !== id);
      });
      setSelectedNodeIDs((prev) => {
        const nxt = new Set(prev);
        nxt.delete(id);
        return nxt;
      });
      setInspectorNodeID((cur) => (cur === id ? null : cur));
    },
    [commitDoc]
  );

  const handleConnect = useCallback(
    (srcID: string, srcPort: number, dstID: string, dstPort: number) => {
      commitDoc((draft) => {
        if (!canConnectClient(draft, srcID, dstID)) return;
        const exists = draft.edges.some(
          (e) =>
            e.sourceNodeID === srcID &&
            e.sourcePortIndex === srcPort &&
            e.targetNodeID === dstID &&
            e.targetPortIndex === dstPort
        );
        if (!exists) {
          draft.edges.push({
            id: crypto.randomUUID().toUpperCase(),
            sourceNodeID: srcID,
            sourcePortIndex: srcPort,
            targetNodeID: dstID,
            targetPortIndex: dstPort,
          });
        }
      });
    },
    [commitDoc]
  );

  const handleRun = useCallback(async () => {
    if (!doc || isRunning) return;
    setIsRunning(true);
    setNodeErrors({});
    try {
      const res = await invoke<BatchRunResult>("run_batch_workflow", { document: doc });
      setNodeErrors(res.nodeErrors);
      setLogs((prev) => [
        ...prev,
        ...res.logs,
        {
          timestamp: new Date().toLocaleTimeString(),
          level: "info",
          nodeTitle: "FlowBatch",
          message: `Finished: ${res.writtenFiles.length} file(s) written in ${res.elapsedMs} ms.`,
        },
      ]);
      setShowConsole(true);

      // Open output folder if requested on Write Images node
      const writeNode = doc.nodes.find(
        (n) =>
          n.typeID === "write.images" &&
          n.isEnabled &&
          pv.getBool(n.parameters.openFolderWhenFinished, false)
      );
      if (writeNode && res.writtenFiles.length > 0) {
        const folder = pv.getStr(writeNode.parameters.folderPath, "");
        if (folder) {
          openPath(folder).catch(() => {});
        }
      }
    } catch (err) {
      setLogs((prev) => [
        ...prev,
        {
          timestamp: new Date().toLocaleTimeString(),
          level: "error",
          nodeTitle: "FlowBatch",
          message: String(err),
        },
      ]);
      setShowConsole(true);
    } finally {
      setIsRunning(false);
    }
  }, [doc, isRunning]);

  const handleOpenFile = useCallback(async () => {
    try {
      const picked = await openDialog({
        multiple: false,
        filters: [{ name: "FlowBatch Workflow", extensions: ["flowbatch", "json"] }],
      });
      if (typeof picked === "string" && picked) {
        const loaded = await invoke<WorkflowDocumentModel>("load_workflow_file", { path: picked });
        setDoc(loaded);
        setFilePath(picked);
        setDirty(false);
        setUndoStack([]);
        setRedoStack([]);
        setInspectorNodeID(loaded.nodes[loaded.nodes.length - 1]?.id ?? null);
      }
    } catch {
      // User cancelled
    }
  }, []);

  const handleSaveFile = useCallback(async () => {
    if (!doc) return;
    try {
      let target = filePath;
      if (!target) {
        const picked = await saveDialog({
          defaultPath: doc.documentTitle,
          filters: [{ name: "FlowBatch Workflow", extensions: ["flowbatch"] }],
        });
        if (!picked) return;
        target = picked;
      }
      await invoke("save_workflow_file", { path: target, document: doc });
      setFilePath(target);
      setDirty(false);
    } catch {
      // Cancelled
    }
  }, [doc, filePath]);

  const handleZoomToFit = useCallback(() => {
    setDoc((prev) => {
      if (!prev || prev.nodes.length === 0) return prev;
      let minX = Infinity,
        minY = Infinity,
        maxX = -Infinity,
        maxY = -Infinity;
      for (const n of prev.nodes) {
        minX = Math.min(minX, n.position.x);
        minY = Math.min(minY, n.position.y);
        maxX = Math.max(maxX, n.position.x + 132);
        maxY = Math.max(maxY, n.position.y + 92);
      }
      const next = deepClone(prev);
      next.viewportZoom = 1.0;
      next.viewportOffset = { x: Math.max(24, 48 - minX), y: Math.max(24, 52 - minY) };
      return next;
    });
  }, []);

  // Global keyboard shortcuts (Ctrl+Z, Ctrl+Y, Ctrl+S, Ctrl+O, Ctrl+R, Delete)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA");
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "z" && !typing) {
        e.preventDefault();
        if (e.shiftKey) handleRedo();
        else handleUndo();
      } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "y" && !typing) {
        e.preventDefault();
        handleRedo();
      } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        handleSaveFile();
      } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "o") {
        e.preventDefault();
        handleOpenFile();
      } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "r") {
        e.preventDefault();
        handleRun();
      } else if ((e.key === "Delete" || e.key === "Backspace") && !typing) {
        if (selectedEdgeID) {
          commitDoc((draft) => {
            draft.edges = draft.edges.filter((edge) => edge.id !== selectedEdgeID);
          });
          setSelectedEdgeID(null);
        } else if (selectedNodeIDs.size > 0) {
          const ids = new Set(selectedNodeIDs);
          commitDoc((draft) => {
            draft.nodes = draft.nodes.filter((n) => !ids.has(n.id));
            draft.edges = draft.edges.filter((edge) => !ids.has(edge.sourceNodeID) && !ids.has(edge.targetNodeID));
          });
          setSelectedNodeIDs(new Set());
          setInspectorNodeID(null);
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [handleUndo, handleRedo, handleSaveFile, handleOpenFile, handleRun, selectedEdgeID, selectedNodeIDs, commitDoc]);

  const inspectedNode = useMemo(
    () => (doc && inspectorNodeID ? doc.nodes.find((n) => n.id === inspectorNodeID) : undefined),
    [doc, inspectorNodeID]
  );

  if (!doc) {
    return (
      <div className="app-shell" style={{ alignItems: "center", justifyContent: "center" }}>
        Loading FlowBatch Studio…
      </div>
    );
  }

  return (
    <div className="app-shell">
      <Toolbar
        title={doc.documentTitle}
        dirty={dirty}
        statusSummary={dryRun?.statusSummary ?? "Ready."}
        isRunning={isRunning}
        canUndo={undoStack.length > 0}
        canRedo={redoStack.length > 0}
        showSidebar={showSidebar}
        showPreview={showPreview}
        showConsole={showConsole}
        showInspector={inspectorNodeID !== null}
        onToggleSidebar={() => setShowSidebar((v) => !v)}
        onTogglePreview={() => setShowPreview((v) => !v)}
        onToggleConsole={() => setShowConsole((v) => !v)}
        onToggleInspector={() =>
          setInspectorNodeID((cur) => (cur ? null : primarySelectedID ?? doc.nodes[0]?.id ?? null))
        }
        onZoomToFit={handleZoomToFit}
        onRun={handleRun}
        onUndo={handleUndo}
        onRedo={handleRedo}
        onOpen={handleOpenFile}
        onSave={handleSaveFile}
      />

      <div className="workspace-body">
        {showSidebar && <NodeLibrarySidebar catalog={catalog} onInsertNode={(t) => handleInsertNode(t)} />}

        <main className="center-pane">
          <NodeGraphCanvas
            document={doc}
            catalogMap={catalogMap}
            dryRun={dryRun}
            selectedNodeIDs={selectedNodeIDs}
            selectedEdgeID={selectedEdgeID}
            nodeErrors={nodeErrors}
            inspectorNodeID={inspectorNodeID}
            inspectorContent={
              inspectedNode ? (
                <NodeInspectorPopover
                  node={inspectedNode}
                  definition={catalogMap.get(inspectedNode.typeID)}
                  outputFormats={outputFormats}
                  errorMessage={nodeErrors[inspectedNode.id]}
                  onSetParam={(key, value, transient) => {
                    const fn = (draft: WorkflowDocumentModel) => {
                      const n = draft.nodes.find((item) => item.id === inspectedNode.id);
                      if (n) n.parameters[key] = value;
                    };
                    if (transient) mutateTransient(fn);
                    else commitDoc(fn);
                  }}
                  onCommitParam={commitContinuous}
                  onToggleEnabled={(enabled) =>
                    commitDoc((draft) => {
                      const n = draft.nodes.find((item) => item.id === inspectedNode.id);
                      if (n) n.isEnabled = enabled;
                    })
                  }
                  onSetErrorPolicy={(policy: NodeErrorPolicy) =>
                    commitDoc((draft) => {
                      const n = draft.nodes.find((item) => item.id === inspectedNode.id);
                      if (n) n.errorPolicy = policy;
                    })
                  }
                />
              ) : null
            }
            onSelectNode={(id, multi, openInsp) => {
              setSelectedEdgeID(null);
              if (!id) {
                setSelectedNodeIDs(new Set());
                setInspectorNodeID(null);
                return;
              }
              setSelectedNodeIDs((prev) => {
                if (!multi) return new Set([id]);
                const nxt = new Set(prev);
                if (nxt.has(id)) nxt.delete(id);
                else nxt.add(id);
                return nxt;
              });
              if (openInsp) setInspectorNodeID(id);
            }}
            onSelectEdge={setSelectedEdgeID}
            onMoveNodesTransient={(positions) =>
              mutateTransient((draft) => {
                for (const n of draft.nodes) {
                  if (positions[n.id]) n.position = positions[n.id];
                }
              })
            }
            onCommitMove={commitContinuous}
            onRemoveNode={handleRemoveNode}
            onConnect={handleConnect}
            onDropNodeTemplate={(typeID, pos) => handleInsertNode(typeID, pos)}
            onViewportChange={(offset, zoom) =>
              setDoc((prev) => (prev ? { ...prev, viewportOffset: offset, viewportZoom: zoom } : prev))
            }
          />

          {showConsole && <WorkflowConsole logs={logs} onClear={() => setLogs([])} />}
        </main>

        {showPreview && (
          <PreviewSplitPane
            assets={activeAssets}
            selectedAssetIndex={selectedAssetIndex}
            preview={preview}
            onSelectAsset={setSelectedAssetIndex}
          />
        )}
      </div>
    </div>
  );
};
