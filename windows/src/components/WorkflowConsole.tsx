import React from "react";
import { Terminal } from "lucide-react";
import { ExecutionLogEntry } from "../types/workflow";

interface WorkflowConsoleProps {
  logs: ExecutionLogEntry[];
  onClear: () => void;
}

export const WorkflowConsole: React.FC<WorkflowConsoleProps> = ({ logs, onClear }) => {
  return (
    <section className="console-drawer" aria-label="Workflow Console">
      <div className="console-header">
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <Terminal size={13} />
          <span>Workflow Console ({logs.length})</span>
        </div>
        <button
          style={{
            border: "none",
            background: "transparent",
            color: "var(--accent)",
            fontSize: 12,
            cursor: "pointer",
            fontWeight: 500,
          }}
          onClick={onClear}
        >
          Clear
        </button>
      </div>

      <div className="console-logs">
        {logs.length === 0 ? (
          <div className="console-empty">No execution logs yet. Press ▶ to run the workflow.</div>
        ) : (
          logs.map((entry, idx) => (
            <div key={idx} className={`console-line ${entry.level}`}>
              <span style={{ color: "var(--text-muted)" }}>[{entry.timestamp}]</span>
              <strong>{entry.nodeTitle}:</strong>
              <span>{entry.message}</span>
            </div>
          ))
        )}
      </div>
    </section>
  );
};
