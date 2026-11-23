import React from "react";
import { CheckCircle2, Circle, Folder, Plus, Trash2 } from "lucide-react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import {
  colorToHex,
  FilterRule,
  hexToColor,
  NodeDefinition,
  NodeErrorPolicy,
  NodeParamValue,
  ParameterDescriptor,
  pv,
  ScaleBranchSpec,
  WorkflowNode,
} from "../types/workflow";

interface NodeInspectorPopoverProps {
  node: WorkflowNode;
  definition: NodeDefinition | undefined;
  outputFormats: string[];
  errorMessage?: string;
  onSetParam: (key: string, value: NodeParamValue, transient?: boolean) => void;
  onCommitParam: () => void;
  onToggleEnabled: (enabled: boolean) => void;
  onSetErrorPolicy: (policy: NodeErrorPolicy) => void;
}

const TOKENS = ["[File Name]", "[Width]", "[Height]", "[Counter]", "[Date]", "[Classification]"];

const ANCHORS = [
  "topLeft",
  "topCenter",
  "topRight",
  "middleLeft",
  "center",
  "middleRight",
  "bottomLeft",
  "bottomCenter",
  "bottomRight",
];

function folderLeaf(path: string): string {
  if (!path) return "Choose Folder…";
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] || path;
}

export const NodeInspectorPopover: React.FC<NodeInspectorPopoverProps> = ({
  node,
  definition,
  outputFormats,
  errorMessage,
  onSetParam,
  onCommitParam,
  onToggleEnabled,
  onSetErrorPolicy,
}) => {
  const pickFolder = async (key: string) => {
    try {
      const selected = await openDialog({ directory: true, multiple: false });
      if (typeof selected === "string" && selected) {
        onSetParam(key, pv.str(selected));
      }
    } catch {
      // Fallback when running in plain Vite browser preview outside Tauri
    }
  };

  const pickFile = async (key: string, exts: string[]) => {
    try {
      const selected = (await openDialog({
        directory: false,
        multiple: key === "filePaths",
        filters: exts.length ? [{ name: "Images", extensions: exts }] : undefined,
      })) as string | string[] | null;
      if (typeof selected === "string") {
        onSetParam(key, pv.str(selected));
      } else if (Array.isArray(selected) && selected.length > 0) {
        onSetParam(key, pv.str(selected.join(";")));
      }
    } catch {
      // Browser preview fallback
    }
  };

  const renderWriteImagesBody = () => {
    const format = pv.getStr(node.parameters.format, "PNG");
    const makeIndexed = pv.getBool(node.parameters.makeIndexedPNG, true);
    const colors = pv.getNum(node.parameters.indexedColors, 256);
    const speed = pv.getNum(node.parameters.indexedSpeed, 1);
    const writeBack = pv.getBool(node.parameters.writeBackToOriginal, false);
    const askFolder = pv.getBool(node.parameters.askForOutputFolder, false);
    const filePattern = pv.getStr(node.parameters.fileNamePattern, "[File Name]");

    const cb = (label: string, key: string, disabled = false) => (
      <label className="check-label" style={{ opacity: disabled ? 0.45 : 1 }}>
        <input
          type="checkbox"
          disabled={disabled}
          checked={pv.getBool(node.parameters[key], false)}
          onChange={(e) => onSetParam(key, pv.bool(e.target.checked))}
        />
        <span>{label}</span>
      </label>
    );

    const speedLabel =
      speed <= 2
        ? `Best quality (${speed})`
        : speed >= 9
          ? `Fastest (${speed})`
          : `Balanced (${speed})`;

    return (
      <>
        <div className="inspector-row">
          <div className="inspector-row-label">Folder:</div>
          <button
            className="inspector-folder-btn"
            disabled={writeBack || askFolder}
            onClick={() => pickFolder("folderPath")}
            title={pv.getStr(node.parameters.folderPath, "")}
          >
            <Folder size={13} color="#0067c0" />
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {folderLeaf(pv.getStr(node.parameters.folderPath, ""))}
            </span>
          </button>
        </div>

        <div className="inspector-checkbox-col">
          {cb("Open folder when export finishes", "openFolderWhenFinished")}
          {cb("Overwrite existing images", "overwriteExisting")}
        </div>

        <div className="inspector-row" style={{ alignItems: "start" }}>
          <div className="inspector-row-label" style={{ paddingTop: 2 }}>
            Advanced:
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
            {cb("Write back to original images", "writeBackToOriginal")}
            {cb("Ask for output folder when run", "askForOutputFolder")}
            {cb("Read back encoded image", "readBackEncoded")}
            {cb("Keep original and modified dates", "keepOriginalDates")}
          </div>
        </div>

        <div className="inspector-row" style={{ alignItems: "start" }}>
          <div className="inspector-row-label" style={{ paddingTop: 6 }}>
            File name:
          </div>
          <div className="token-box">
            <input
              type="text"
              value={filePattern}
              onChange={(e) => onSetParam("fileNamePattern", pv.str(e.target.value))}
            />
            <div className="token-chips">
              {TOKENS.slice(0, 4).map((t) => (
                <button
                  key={t}
                  className="token-chip"
                  type="button"
                  onClick={() => onSetParam("fileNamePattern", pv.str(filePattern + t))}
                >
                  {t}
                </button>
              ))}
            </div>
          </div>
        </div>

        <div className="inspector-row">
          <div className="inspector-row-label">Convert to:</div>
          <select
            className="inspector-select"
            value={format}
            onChange={(e) => onSetParam("format", pv.str(e.target.value))}
          >
            {outputFormats.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </div>

        {format === "PNG" ? (
          <>
            <div className="inspector-checkbox-col">
              {cb("Remove alpha channel if opaque", "removeAlphaIfOpaque")}
              {cb("Crush (slow)", "crushPNG")}
              {cb(
                "Brute force crush (very slow)",
                "bruteForceCrushPNG",
                !pv.getBool(node.parameters.crushPNG, false) && !makeIndexed
              )}
              {cb("Remove color profile", "removeColorProfile")}
            </div>

            <div className="inspector-divider" />

            <div className="inspector-checkbox-col">{cb("Make indexed PNG", "makeIndexedPNG")}</div>

            <div className="inspector-row" style={{ opacity: makeIndexed ? 1 : 0.45 }}>
              <div className="inspector-row-label">Colors:</div>
              <div className="inspector-slider-wrap">
                <input
                  type="range"
                  min={2}
                  max={256}
                  disabled={!makeIndexed}
                  value={colors}
                  onChange={(e) => onSetParam("indexedColors", pv.int(Number(e.target.value)), true)}
                  onMouseUp={onCommitParam}
                />
                <span className="inspector-val-readout">{Math.round(colors)}</span>
              </div>
            </div>

            <div className="inspector-row" style={{ opacity: makeIndexed ? 1 : 0.45 }}>
              <div className="inspector-row-label">Speed:</div>
              <div className="inspector-slider-wrap">
                <input
                  type="range"
                  min={1}
                  max={10}
                  step={1}
                  disabled={!makeIndexed}
                  value={speed}
                  onChange={(e) => onSetParam("indexedSpeed", pv.int(Number(e.target.value)), true)}
                  onMouseUp={onCommitParam}
                />
                <span style={{ fontSize: 11, color: "var(--text-secondary)", whiteSpace: "nowrap" }}>
                  {speedLabel}
                </span>
              </div>
            </div>

            <div className="inspector-checkbox-col" style={{ opacity: makeIndexed ? 1 : 0.45 }}>
              {cb("Dither", "indexedDither", !makeIndexed)}
            </div>
          </>
        ) : format === "JPEG" || format === "WebP" ? (
          <div className="inspector-row">
            <div className="inspector-row-label">Quality:</div>
            <div className="inspector-slider-wrap">
              <input
                type="range"
                min={0.1}
                max={1}
                step={0.01}
                value={pv.getNum(node.parameters.quality, 0.88)}
                onChange={(e) => onSetParam("quality", pv.dbl(Number(e.target.value)), true)}
                onMouseUp={onCommitParam}
              />
              <span className="inspector-val-readout">
                {Math.round(pv.getNum(node.parameters.quality, 0.88) * 100)}%
              </span>
            </div>
          </div>
        ) : null}
      </>
    );
  };

  const renderRulesBody = () => {
    const matchAll = pv.getBool(node.parameters.matchAll, true);
    const rules = pv.getRules(node.parameters.rules);

    const updateRules = (next: FilterRule[]) => onSetParam("rules", pv.rules(next));

    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <label className="check-label">
          <input
            type="checkbox"
            checked={matchAll}
            onChange={(e) => onSetParam("matchAll", pv.bool(e.target.checked))}
          />
          <span>Match ALL rules (AND logic)</span>
        </label>

        {rules.map((r, idx) => (
          <div key={r.id} style={{ display: "grid", gridTemplateColumns: "1fr 1fr 78px 22px", gap: 4 }}>
            <select
              className="inspector-select"
              value={r.field}
              onChange={(e) => {
                const next = [...rules];
                next[idx] = { ...r, field: e.target.value as FilterRule["field"] };
                updateRules(next);
              }}
            >
              {["File Name", "File Extension", "Width", "Height", "Megapixels", "DPI", "Has Alpha", "Color Space", "Classification"].map(
                (f) => (
                  <option key={f} value={f}>
                    {f}
                  </option>
                )
              )}
            </select>
            <select
              className="inspector-select"
              value={r.op}
              onChange={(e) => {
                const next = [...rules];
                next[idx] = { ...r, op: e.target.value as FilterRule["op"] };
                updateRules(next);
              }}
            >
              {["Contains", "Matches", "Equals", "Greater Than", "Less Than", "Is True", "Is False"].map((op) => (
                <option key={op} value={op}>
                  {op}
                </option>
              ))}
            </select>
            <input
              className="inspector-input"
              value={r.value}
              onChange={(e) => {
                const next = [...rules];
                next[idx] = { ...r, value: e.target.value };
                updateRules(next);
              }}
            />
            <button
              className="icon-btn"
              style={{ width: 22, height: 26 }}
              onClick={() => updateRules(rules.filter((_, i) => i !== idx))}
            >
              <Trash2 size={12} />
            </button>
          </div>
        ))}

        <button
          className="inspector-folder-btn"
          style={{ justifyContent: "center" }}
          onClick={() =>
            updateRules([
              ...rules,
              { id: crypto.randomUUID(), field: "Width", op: "Greater Than", value: "800" },
            ])
          }
        >
          <Plus size={13} /> Add Rule
        </button>
      </div>
    );
  };

  const renderMultiScaleBody = () => {
    const scales = pv.getScales(node.parameters.scales);
    const updateScales = (next: ScaleBranchSpec[]) => onSetParam("scales", pv.scales(next));
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {scales.map((s, idx) => (
          <div key={s.id} style={{ display: "grid", gridTemplateColumns: "60px 72px 1fr 22px", gap: 5 }}>
            <input
              className="inspector-input"
              value={s.label}
              onChange={(e) => {
                const next = [...scales];
                next[idx] = { ...s, label: e.target.value };
                updateScales(next);
              }}
            />
            <input
              className="inspector-input"
              type="number"
              step="0.25"
              value={s.scaleFactor}
              onChange={(e) => {
                const next = [...scales];
                next[idx] = { ...s, scaleFactor: Number(e.target.value) || 1 };
                updateScales(next);
              }}
            />
            <input
              className="inspector-input"
              placeholder="Suffix (@2x)"
              value={s.suffix}
              onChange={(e) => {
                const next = [...scales];
                next[idx] = { ...s, suffix: e.target.value };
                updateScales(next);
              }}
            />
            <button
              className="icon-btn"
              style={{ width: 22, height: 26 }}
              onClick={() => updateScales(scales.filter((_, i) => i !== idx))}
            >
              <Trash2 size={12} />
            </button>
          </div>
        ))}
        <button
          className="inspector-folder-btn"
          style={{ justifyContent: "center" }}
          onClick={() =>
            updateScales([
              ...scales,
              { id: crypto.randomUUID(), label: "3x", scaleFactor: 3.0, suffix: "@3x" },
            ])
          }
        >
          <Plus size={13} /> Add Scale Variant
        </button>
      </div>
    );
  };

  const renderGenericRow = (param: ParameterDescriptor) => {
    const val = node.parameters[param.key] ?? param.defaultValue;
    const ctrl = param.control;

    switch (ctrl.kind) {
      case "toggle":
        return (
          <div key={param.key} className="inspector-checkbox-col">
            <label className="check-label">
              <input
                type="checkbox"
                checked={pv.getBool(val, false)}
                onChange={(e) => onSetParam(param.key, pv.bool(e.target.checked))}
              />
              <span>{param.label}</span>
            </label>
          </div>
        );

      case "text":
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <input
              className="inspector-input"
              placeholder={ctrl.placeholder}
              value={pv.getStr(val, "")}
              onChange={(e) => onSetParam(param.key, pv.str(e.target.value))}
            />
          </div>
        );

      case "tokenField": {
        const cur = pv.getStr(val, "");
        return (
          <div key={param.key} className="inspector-row" style={{ alignItems: "start" }}>
            <div className="inspector-row-label" style={{ paddingTop: 5 }}>
              {param.label}:
            </div>
            <div className="token-box">
              <input
                type="text"
                value={cur}
                onChange={(e) => onSetParam(param.key, pv.str(e.target.value))}
              />
              <div className="token-chips">
                {TOKENS.slice(0, 4).map((t) => (
                  <button
                    key={t}
                    className="token-chip"
                    type="button"
                    onClick={() => onSetParam(param.key, pv.str(cur + t))}
                  >
                    {t}
                  </button>
                ))}
              </div>
            </div>
          </div>
        );
      }

      case "multilineCode":
        return (
          <div key={param.key} style={{ marginBottom: 8 }}>
            <div style={{ fontSize: 12, color: "var(--text-secondary)", marginBottom: 4 }}>
              {param.label} ({ctrl.language}):
            </div>
            <textarea
              className="inspector-code"
              value={pv.getStr(val, "")}
              onChange={(e) => onSetParam(param.key, pv.str(e.target.value))}
            />
          </div>
        );

      case "folderPath":
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <button className="inspector-folder-btn" onClick={() => pickFolder(param.key)}>
              <Folder size={13} color="#0067c0" />
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {folderLeaf(pv.getStr(val, ""))}
              </span>
            </button>
          </div>
        );

      case "filePath":
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <button
              className="inspector-folder-btn"
              onClick={() => pickFile(param.key, ctrl.allowedExtensions)}
            >
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {folderLeaf(pv.getStr(val, "")) || "Choose File…"}
              </span>
            </button>
          </div>
        );

      case "slider": {
        const num = pv.getNum(val, ctrl.min);
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <div className="inspector-slider-wrap">
              <input
                type="range"
                min={ctrl.min}
                max={ctrl.max}
                step={ctrl.step}
                value={num}
                onChange={(e) => onSetParam(param.key, pv.dbl(Number(e.target.value)), true)}
                onMouseUp={onCommitParam}
              />
              <span className="inspector-val-readout">
                {num.toFixed(2)}
                {ctrl.unit ? ` ${ctrl.unit}` : ""}
              </span>
            </div>
          </div>
        );
      }

      case "intSlider": {
        const num = Math.round(pv.getNum(val, ctrl.min));
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <div className="inspector-slider-wrap">
              <input
                type="range"
                min={ctrl.min}
                max={ctrl.max}
                step={1}
                value={num}
                onChange={(e) => onSetParam(param.key, pv.int(Number(e.target.value)), true)}
                onMouseUp={onCommitParam}
              />
              <span className="inspector-val-readout">
                {num}
                {ctrl.unit ? ` ${ctrl.unit}` : ""}
              </span>
            </div>
          </div>
        );
      }

      case "picker":
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <select
              className="inspector-select"
              value={pv.getStr(val, ctrl.options[0] ?? "")}
              onChange={(e) => onSetParam(param.key, pv.str(e.target.value))}
            >
              {ctrl.options.map((opt) => (
                <option key={opt} value={opt}>
                  {opt}
                </option>
              ))}
            </select>
          </div>
        );

      case "color": {
        const c = pv.getColor(val);
        return (
          <div key={param.key} className="inspector-row">
            <div className="inspector-row-label">{param.label}:</div>
            <input
              type="color"
              value={colorToHex(c)}
              onChange={(e) => onSetParam(param.key, pv.color(hexToColor(e.target.value, c.alpha)))}
              style={{ width: 48, height: 24, border: "1px solid var(--border-strong)", borderRadius: 4, padding: 1 }}
            />
          </div>
        );
      }

      case "anchorGrid": {
        const cur = pv.getStr(val, "center");
        return (
          <div key={param.key} className="inspector-row" style={{ alignItems: "start" }}>
            <div className="inspector-row-label" style={{ paddingTop: 4 }}>
              {param.label}:
            </div>
            <div className="anchor-grid">
              {ANCHORS.map((a) => (
                <button
                  key={a}
                  type="button"
                  title={a}
                  className={`anchor-cell ${cur === a ? "active" : ""}`}
                  onClick={() => onSetParam(param.key, pv.str(a))}
                />
              ))}
            </div>
          </div>
        );
      }
    }
  };

  return (
    <div>
      <div className="inspector-header">
        <span className="inspector-title">{node.title}</span>
        <button
          className="inspector-enable-btn"
          title={node.isEnabled ? "Disable Node" : "Enable Node"}
          onClick={() => onToggleEnabled(!node.isEnabled)}
        >
          {node.isEnabled ? (
            <CheckCircle2 size={18} fill="#0067c0" color="#ffffff" />
          ) : (
            <Circle size={17} color="#8a93a6" />
          )}
        </button>
      </div>

      {errorMessage && (
        <div
          style={{
            background: "rgba(209,52,56,0.09)",
            color: "#b91c1c",
            borderRadius: 6,
            padding: "6px 8px",
            fontSize: 11.5,
            marginBottom: 10,
          }}
        >
          {errorMessage}
        </div>
      )}

      {node.typeID === "write.images" ? (
        renderWriteImagesBody()
      ) : node.typeID === "sort.rules" ? (
        renderRulesBody()
      ) : node.typeID === "write.multiScale" ? (
        renderMultiScaleBody()
      ) : definition && definition.parameters.length > 0 ? (
        definition.parameters.map(renderGenericRow)
      ) : (
        <div style={{ color: "var(--text-secondary)", fontSize: 12, padding: "4px 0 8px" }}>
          {definition?.summary ?? "No configurable parameters."}
        </div>
      )}

      <div className="inspector-divider" />

      <div className="inspector-row" style={{ marginBottom: 0 }}>
        <div className="inspector-row-label">On error:</div>
        <select
          className="inspector-select"
          value={node.errorPolicy}
          onChange={(e) => onSetErrorPolicy(e.target.value as NodeErrorPolicy)}
        >
          <option value="Skip Asset">Skip Asset</option>
          <option value="Halt Workflow">Halt Workflow</option>
          <option value="Pass Input Through">Pass Input Through</option>
        </select>
      </div>
    </div>
  );
};
