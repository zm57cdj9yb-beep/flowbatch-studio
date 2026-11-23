import React from "react";
import {
  FileText,
  FolderOpen,
  Maximize2,
  PanelLeft,
  PanelRight,
  Play,
  Redo2,
  Save,
  SlidersHorizontal,
  Square,
  Terminal,
  Undo2,
  Image as ImageIcon,
} from "lucide-react";

interface ToolbarProps {
  title: string;
  dirty: boolean;
  statusSummary: string;
  isRunning: boolean;
  canUndo: boolean;
  canRedo: boolean;
  showSidebar: boolean;
  showPreview: boolean;
  showConsole: boolean;
  showInspector: boolean;
  onToggleSidebar: () => void;
  onTogglePreview: () => void;
  onToggleConsole: () => void;
  onToggleInspector: () => void;
  onZoomToFit: () => void;
  onRun: () => void;
  onUndo: () => void;
  onRedo: () => void;
  onOpen: () => void;
  onSave: () => void;
}

export const Toolbar: React.FC<ToolbarProps> = ({
  title,
  dirty,
  statusSummary,
  isRunning,
  canUndo,
  canRedo,
  showSidebar,
  showPreview,
  showConsole,
  showInspector,
  onToggleSidebar,
  onTogglePreview,
  onToggleConsole,
  onToggleInspector,
  onZoomToFit,
  onRun,
  onUndo,
  onRedo,
  onOpen,
  onSave,
}) => {
  return (
    <header className="toolbar">
      <div className="toolbar-left">
        <button
          className={`icon-btn ${showSidebar ? "active" : ""}`}
          title="Toggle Node Library (Ctrl+1)"
          onClick={onToggleSidebar}
        >
          <PanelLeft size={16} />
        </button>

        <div className="doc-title">
          <FileText size={14} strokeWidth={2} />
          <span>{title}</span>
          {dirty && <span className="doc-dirty-dot" title="Unsaved changes" />}
        </div>

        <div className="toolbar-divider" />

        <button className="icon-btn" title="Open Workflow… (Ctrl+O)" onClick={onOpen}>
          <FolderOpen size={15} />
        </button>
        <button className="icon-btn" title="Save Workflow (Ctrl+S)" onClick={onSave}>
          <Save size={15} />
        </button>
        <button className="icon-btn" title="Undo (Ctrl+Z)" disabled={!canUndo} onClick={onUndo}>
          <Undo2 size={15} />
        </button>
        <button className="icon-btn" title="Redo (Ctrl+Y)" disabled={!canRedo} onClick={onRedo}>
          <Redo2 size={15} />
        </button>
      </div>

      <div className="toolbar-center">
        <button
          className={`run-btn ${isRunning ? "running" : ""}`}
          title={isRunning ? "Running Batch…" : "Run Batch Workflow (Ctrl+R)"}
          onClick={onRun}
          disabled={isRunning}
        >
          {isRunning ? <Square size={14} fill="currentColor" /> : <Play size={15} fill="currentColor" />}
        </button>

        <div className="status-capsule">
          <ImageIcon size={13} strokeWidth={1.8} />
          <span>{isRunning ? "Processing batch in parallel (Rayon)…" : statusSummary}</span>
        </div>
      </div>

      <div className="toolbar-right">
        <button
          className={`icon-btn ${showPreview ? "active" : ""}`}
          title="Toggle Preview & Contact Sheet (Ctrl+2)"
          onClick={onTogglePreview}
        >
          <PanelRight size={16} />
        </button>
        <button
          className={`icon-btn ${showConsole ? "active" : ""}`}
          title="Toggle Workflow Console (Ctrl+3)"
          onClick={onToggleConsole}
        >
          <Terminal size={15} />
        </button>
        <button
          className={`icon-btn ${showInspector ? "active" : ""}`}
          title="Toggle Node Inspector (Ctrl+I)"
          onClick={onToggleInspector}
        >
          <SlidersHorizontal size={15} />
        </button>
        <button className="icon-btn" title="Zoom to Fit (Ctrl+0)" onClick={onZoomToFit}>
          <Maximize2 size={14} />
        </button>
      </div>
    </header>
  );
};
