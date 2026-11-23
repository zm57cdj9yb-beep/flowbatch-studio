export type NodeCategory =
  | "Read Images"
  | "Write Images"
  | "Blur"
  | "Color Adjustment"
  | "Color Effect"
  | "Generator"
  | "Metadata"
  | "Misc"
  | "PDF"
  | "Photos Library"
  | "Script"
  | "Sharpen"
  | "Sort"
  | "Transform"
  | "Watermark";

export const ALL_CATEGORIES: NodeCategory[] = [
  "Read Images",
  "Write Images",
  "Blur",
  "Color Adjustment",
  "Color Effect",
  "Generator",
  "Metadata",
  "Misc",
  "PDF",
  "Photos Library",
  "Script",
  "Sharpen",
  "Sort",
  "Transform",
  "Watermark",
];

export type NodeErrorPolicy = "Skip Asset" | "Halt Workflow" | "Pass Input Through";

export interface CodableColor {
  red: number;
  green: number;
  blue: number;
  alpha: number;
}

export interface FilterRule {
  id: string;
  field:
    | "File Name"
    | "File Extension"
    | "Width"
    | "Height"
    | "Megapixels"
    | "DPI"
    | "Has Alpha"
    | "Color Space"
    | "Classification";
  op: "Contains" | "Matches" | "Equals" | "Greater Than" | "Less Than" | "Is True" | "Is False";
  value: string;
}

export interface ScaleBranchSpec {
  id: string;
  label: string;
  scaleFactor: number;
  suffix: string;
}

export type NodeParamValue =
  | { string: { _0: string } }
  | { int: { _0: number } }
  | { double: { _0: number } }
  | { bool: { _0: boolean } }
  | { color: { _0: CodableColor } }
  | { rules: { _0: FilterRule[] } }
  | { scales: { _0: ScaleBranchSpec[] } };

export type ParameterControlKind =
  | { kind: "text"; placeholder: string }
  | { kind: "multilineCode"; language: string }
  | { kind: "folderPath" }
  | { kind: "filePath"; allowedExtensions: string[] }
  | { kind: "toggle" }
  | { kind: "slider"; min: number; max: number; step: number; unit: string }
  | { kind: "intSlider"; min: number; max: number; unit: string }
  | { kind: "picker"; options: string[] }
  | { kind: "color" }
  | { kind: "anchorGrid" }
  | { kind: "tokenField" };

export interface ParameterDescriptor {
  key: string;
  label: string;
  control: ParameterControlKind;
  defaultValue: NodeParamValue;
}

export interface NodeDefinition {
  typeID: string;
  title: string;
  category: NodeCategory;
  summary: string;
  inputPortCount: number;
  outputPortCount: number;
  outputPortLabels: string[];
  isSink: boolean;
  isSource: boolean;
  isBatchCollector: boolean;
  parameters: ParameterDescriptor[];
}

export interface GraphPoint {
  x: number;
  y: number;
}

export interface WorkflowNode {
  id: string;
  typeID: string;
  title: string;
  position: GraphPoint;
  isEnabled: boolean;
  errorPolicy: NodeErrorPolicy;
  parameters: Record<string, NodeParamValue>;
}

export interface WorkflowEdge {
  id: string;
  sourceNodeID: string;
  sourcePortIndex: number;
  targetNodeID: string;
  targetPortIndex: number;
}

export interface WorkflowDocumentModel {
  schemaVersion: number;
  documentTitle: string;
  nodes: WorkflowNode[];
  edges: WorkflowEdge[];
  viewportOffset: GraphPoint;
  viewportZoom: number;
}

export interface DryRunAssetRef {
  id: string;
  path: string;
  fileName: string;
  sourceNodeID: string;
}

export interface DryRunReport {
  totalToRead: number;
  totalToWrite: number;
  nodeCounts: Record<string, number>;
  nodeSubtitles: Record<string, string>;
  nodeAssets: Record<string, DryRunAssetRef[]>;
  statusSummary: string;
}

export interface AssetInspectorInfo {
  fileName: string;
  pixelWidth: number;
  pixelHeight: number;
  dpi: number;
  bitsPerChannel: number;
  colorSpaceName: string;
  originalByteCount: number;
  gpsPresent: boolean;
  cameraModel?: string | null;
  classifications: string[];
}

export interface PreviewResponse {
  processedDataUrl?: string | null;
  originalDataUrl?: string | null;
  info?: AssetInspectorInfo | null;
  errorMessage?: string | null;
}

export interface ExecutionLogEntry {
  timestamp: string;
  level: "info" | "warn" | "error" | string;
  nodeTitle: string;
  message: string;
}

export interface BatchRunResult {
  processedAssets: number;
  writtenFiles: string[];
  nodeErrors: Record<string, string>;
  logs: ExecutionLogEntry[];
  elapsedMs: number;
}

// Helper accessors for Swift-compatible NodeParamValue objects
export const pv = {
  str: (v: string): NodeParamValue => ({ string: { _0: v } }),
  int: (v: number): NodeParamValue => ({ int: { _0: Math.round(v) } }),
  dbl: (v: number): NodeParamValue => ({ double: { _0: v } }),
  bool: (v: boolean): NodeParamValue => ({ bool: { _0: v } }),
  color: (c: CodableColor): NodeParamValue => ({ color: { _0: c } }),
  rules: (r: FilterRule[]): NodeParamValue => ({ rules: { _0: r } }),
  scales: (s: ScaleBranchSpec[]): NodeParamValue => ({ scales: { _0: s } }),

  getStr: (val: NodeParamValue | undefined, fallback = ""): string =>
    val && "string" in val ? val.string._0 : fallback,
  getNum: (val: NodeParamValue | undefined, fallback = 0): number => {
    if (!val) return fallback;
    if ("double" in val) return val.double._0;
    if ("int" in val) return val.int._0;
    return fallback;
  },
  getBool: (val: NodeParamValue | undefined, fallback = false): boolean =>
    val && "bool" in val ? val.bool._0 : fallback,
  getColor: (val: NodeParamValue | undefined): CodableColor =>
    val && "color" in val ? val.color._0 : { red: 1, green: 1, blue: 1, alpha: 1 },
  getRules: (val: NodeParamValue | undefined): FilterRule[] =>
    val && "rules" in val ? val.rules._0 : [],
  getScales: (val: NodeParamValue | undefined): ScaleBranchSpec[] =>
    val && "scales" in val ? val.scales._0 : [],
};

export function colorToHex(c: CodableColor): string {
  const toHex = (n: number) =>
    Math.round(Math.max(0, Math.min(1, n)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${toHex(c.red)}${toHex(c.green)}${toHex(c.blue)}`;
}

export function hexToColor(hex: string, alpha = 1): CodableColor {
  const clean = hex.replace("#", "");
  if (clean.length !== 6) return { red: 1, green: 1, blue: 1, alpha };
  return {
    red: parseInt(clean.slice(0, 2), 16) / 255,
    green: parseInt(clean.slice(2, 4), 16) / 255,
    blue: parseInt(clean.slice(4, 6), 16) / 255,
    alpha,
  };
}
