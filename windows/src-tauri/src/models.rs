use serde::de::{self, MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NodeCategory {
    #[serde(rename = "Read Images")]
    ReadImages,
    #[serde(rename = "Write Images")]
    WriteImages,
    #[serde(rename = "Blur")]
    Blur,
    #[serde(rename = "Color Adjustment")]
    ColorAdjustment,
    #[serde(rename = "Color Effect")]
    ColorEffect,
    #[serde(rename = "Generator")]
    Generator,
    #[serde(rename = "Metadata")]
    Metadata,
    #[serde(rename = "Misc")]
    Misc,
    #[serde(rename = "PDF")]
    Pdf,
    #[serde(rename = "Photos Library")]
    PhotosLibrary,
    #[serde(rename = "Script")]
    Script,
    #[serde(rename = "Sharpen")]
    Sharpen,
    #[serde(rename = "Sort")]
    Sort,
    #[serde(rename = "Transform")]
    Transform,
    #[serde(rename = "Watermark")]
    Watermark,
}

impl NodeCategory {
    pub fn all() -> &'static [NodeCategory] {
        &[
            NodeCategory::ReadImages,
            NodeCategory::WriteImages,
            NodeCategory::Blur,
            NodeCategory::ColorAdjustment,
            NodeCategory::ColorEffect,
            NodeCategory::Generator,
            NodeCategory::Metadata,
            NodeCategory::Misc,
            NodeCategory::Pdf,
            NodeCategory::PhotosLibrary,
            NodeCategory::Script,
            NodeCategory::Sharpen,
            NodeCategory::Sort,
            NodeCategory::Transform,
            NodeCategory::Watermark,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum NodeErrorPolicy {
    #[default]
    #[serde(rename = "Skip Asset")]
    SkipAsset,
    #[serde(rename = "Halt Workflow")]
    HaltWorkflow,
    #[serde(rename = "Pass Input Through")]
    PassThroughOnFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CodableColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

impl CodableColor {
    pub const WHITE: Self = Self { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };
    pub const BLACK: Self = Self { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    pub const CLEAR: Self = Self { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0 };

    pub fn to_rgba8(&self) -> [u8; 4] {
        [
            (self.red.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.green.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.blue.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.alpha.clamp(0.0, 1.0) * 255.0).round() as u8,
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RuleField {
    #[serde(rename = "File Name")]
    FileName,
    #[serde(rename = "File Extension")]
    FileExtension,
    #[serde(rename = "Width")]
    Width,
    #[serde(rename = "Height")]
    Height,
    #[serde(rename = "Megapixels")]
    Megapixels,
    #[serde(rename = "DPI")]
    Dpi,
    #[serde(rename = "Has Alpha")]
    HasAlpha,
    #[serde(rename = "Color Space")]
    ColorSpace,
    #[serde(rename = "Classification")]
    Classification,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RuleOperator {
    #[serde(rename = "Contains")]
    Contains,
    #[serde(rename = "Matches")]
    MatchesRegex,
    #[serde(rename = "Equals")]
    Equals,
    #[serde(rename = "Greater Than")]
    GreaterThan,
    #[serde(rename = "Less Than")]
    LessThan,
    #[serde(rename = "Is True")]
    IsTrue,
    #[serde(rename = "Is False")]
    IsFalse,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilterRule {
    pub id: String,
    pub field: RuleField,
    pub op: RuleOperator,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScaleBranchSpec {
    pub id: String,
    pub label: String,
    #[serde(rename = "scaleFactor")]
    pub scale_factor: f64,
    pub suffix: String,
}

/// Wire-compatible with Swift's Codable enum encoding (`{"string":{"_0":"..."}}`)
/// while also deserializing flat JSON values if edited by hand.
#[derive(Debug, Clone, PartialEq)]
pub enum NodeParamValue {
    String(String),
    Int(i64),
    Double(f64),
    Bool(bool),
    Color(CodableColor),
    Rules(Vec<FilterRule>),
    Scales(Vec<ScaleBranchSpec>),
}

impl NodeParamValue {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s.as_str()),
            _ => None,
        }
    }
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Int(i) => Some(*i),
            Self::Double(d) => Some(d.round() as i64),
            _ => None,
        }
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Double(d) => Some(*d),
            Self::Int(i) => Some(*i as f64),
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_color(&self) -> Option<CodableColor> {
        match self {
            Self::Color(c) => Some(*c),
            _ => None,
        }
    }
    pub fn as_rules(&self) -> Option<&[FilterRule]> {
        match self {
            Self::Rules(r) => Some(r.as_slice()),
            _ => None,
        }
    }
    pub fn as_scales(&self) -> Option<&[ScaleBranchSpec]> {
        match self {
            Self::Scales(s) => Some(s.as_slice()),
            _ => None,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct SwiftWrapped<T> {
    #[serde(rename = "_0")]
    inner: T,
}

impl Serialize for NodeParamValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(1))?;
        match self {
            Self::String(v) => map.serialize_entry("string", &SwiftWrapped { inner: v })?,
            Self::Int(v) => map.serialize_entry("int", &SwiftWrapped { inner: v })?,
            Self::Double(v) => map.serialize_entry("double", &SwiftWrapped { inner: v })?,
            Self::Bool(v) => map.serialize_entry("bool", &SwiftWrapped { inner: v })?,
            Self::Color(v) => map.serialize_entry("color", &SwiftWrapped { inner: v })?,
            Self::Rules(v) => map.serialize_entry("rules", &SwiftWrapped { inner: v })?,
            Self::Scales(v) => map.serialize_entry("scales", &SwiftWrapped { inner: v })?,
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for NodeParamValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ParamVisitor;
        impl<'de> Visitor<'de> for ParamVisitor {
            type Value = NodeParamValue;

            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                write!(f, "a Swift-tagged NodeParamValue object or primitive JSON value")
            }

            fn visit_bool<E: de::Error>(self, v: bool) -> Result<Self::Value, E> {
                Ok(NodeParamValue::Bool(v))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> Result<Self::Value, E> {
                Ok(NodeParamValue::Int(v))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> Result<Self::Value, E> {
                Ok(NodeParamValue::Int(v as i64))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> Result<Self::Value, E> {
                Ok(NodeParamValue::Double(v))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(NodeParamValue::String(v.to_owned()))
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let key: String = map
                    .next_key()?
                    .ok_or_else(|| de::Error::custom("empty NodeParamValue object"))?;
                let val: serde_json::Value = map.next_value()?;
                let payload = val.get("_0").cloned().unwrap_or(val);
                match key.as_str() {
                    "string" => Ok(NodeParamValue::String(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "int" => Ok(NodeParamValue::Int(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "double" => Ok(NodeParamValue::Double(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "bool" => Ok(NodeParamValue::Bool(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "color" => Ok(NodeParamValue::Color(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "rules" => Ok(NodeParamValue::Rules(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    "scales" => Ok(NodeParamValue::Scales(
                        serde_json::from_value(payload).map_err(de::Error::custom)?,
                    )),
                    other => Err(de::Error::custom(format!("unknown NodeParamValue tag: {other}"))),
                }
            }
        }
        deserializer.deserialize_any(ParamVisitor)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum ParameterControlKind {
    #[serde(rename = "text")]
    Text { placeholder: String },
    #[serde(rename = "multilineCode")]
    MultilineCode { language: String },
    #[serde(rename = "folderPath")]
    FolderPath,
    #[serde(rename = "filePath")]
    FilePath {
        #[serde(rename = "allowedExtensions")]
        allowed_extensions: Vec<String>,
    },
    #[serde(rename = "toggle")]
    Toggle,
    #[serde(rename = "slider")]
    Slider {
        min: f64,
        max: f64,
        step: f64,
        unit: String,
    },
    #[serde(rename = "intSlider")]
    IntSlider { min: i64, max: i64, unit: String },
    #[serde(rename = "picker")]
    Picker { options: Vec<String> },
    #[serde(rename = "color")]
    Color,
    #[serde(rename = "anchorGrid")]
    AnchorGrid,
    #[serde(rename = "tokenField")]
    TokenField,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParameterDescriptor {
    pub key: String,
    pub label: String,
    pub control: ParameterControlKind,
    #[serde(rename = "defaultValue")]
    pub default_value: NodeParamValue,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeDefinition {
    #[serde(rename = "typeID")]
    pub type_id: String,
    pub title: String,
    pub category: NodeCategory,
    pub summary: String,
    #[serde(rename = "inputPortCount")]
    pub input_port_count: usize,
    #[serde(rename = "outputPortCount")]
    pub output_port_count: usize,
    #[serde(rename = "outputPortLabels")]
    pub output_port_labels: Vec<String>,
    #[serde(rename = "isSink")]
    pub is_sink: bool,
    #[serde(rename = "isSource")]
    pub is_source: bool,
    #[serde(rename = "isBatchCollector")]
    pub is_batch_collector: bool,
    pub parameters: Vec<ParameterDescriptor>,
}

impl NodeDefinition {
    pub fn default_parameters(&self) -> HashMap<String, NodeParamValue> {
        self.parameters
            .iter()
            .map(|p| (p.key.clone(), p.default_value.clone()))
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
pub struct GraphPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkflowNode {
    pub id: String,
    #[serde(rename = "typeID")]
    pub type_id: String,
    pub title: String,
    pub position: GraphPoint,
    #[serde(rename = "isEnabled", default = "default_true")]
    pub is_enabled: bool,
    #[serde(rename = "errorPolicy", default)]
    pub error_policy: NodeErrorPolicy,
    #[serde(default)]
    pub parameters: HashMap<String, NodeParamValue>,
}

fn default_true() -> bool {
    true
}

impl WorkflowNode {
    pub fn new(type_id: &str, x: f64, y: f64) -> Self {
        let def = crate::catalog::definition_for(type_id);
        let title = def
            .as_ref()
            .map(|d| d.title.clone())
            .unwrap_or_else(|| type_id.to_string());
        let parameters = def
            .as_ref()
            .map(|d| d.default_parameters())
            .unwrap_or_default();
        Self {
            id: Uuid::new_v4().to_string().to_uppercase(),
            type_id: type_id.to_string(),
            title,
            position: GraphPoint { x, y },
            is_enabled: true,
            error_policy: NodeErrorPolicy::SkipAsset,
            parameters,
        }
    }

    pub fn with_param(mut self, key: &str, value: NodeParamValue) -> Self {
        self.parameters.insert(key.to_string(), value);
        self
    }

    pub fn param_str(&self, key: &str, default: &str) -> String {
        self.parameters
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or(default)
            .to_string()
    }

    pub fn param_i64(&self, key: &str, default: i64) -> i64 {
        self.parameters
            .get(key)
            .and_then(|v| v.as_i64())
            .unwrap_or(default)
    }

    pub fn param_f64(&self, key: &str, default: f64) -> f64 {
        self.parameters
            .get(key)
            .and_then(|v| v.as_f64())
            .unwrap_or(default)
    }

    pub fn param_bool(&self, key: &str, default: bool) -> bool {
        self.parameters
            .get(key)
            .and_then(|v| v.as_bool())
            .unwrap_or(default)
    }

    pub fn param_color(&self, key: &str, default: CodableColor) -> CodableColor {
        self.parameters
            .get(key)
            .and_then(|v| v.as_color())
            .unwrap_or(default)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowEdge {
    pub id: String,
    #[serde(rename = "sourceNodeID")]
    pub source_node_id: String,
    #[serde(rename = "sourcePortIndex", default)]
    pub source_port_index: usize,
    #[serde(rename = "targetNodeID")]
    pub target_node_id: String,
    #[serde(rename = "targetPortIndex", default)]
    pub target_port_index: usize,
}

impl WorkflowEdge {
    pub fn new(src: &str, dst: &str) -> Self {
        Self {
            id: Uuid::new_v4().to_string().to_uppercase(),
            source_node_id: src.to_string(),
            source_port_index: 0,
            target_node_id: dst.to_string(),
            target_port_index: 0,
        }
    }

    pub fn with_source_port(mut self, port: usize) -> Self {
        self.source_port_index = port;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkflowDocumentModel {
    #[serde(rename = "schemaVersion", default = "default_schema_version")]
    pub schema_version: u32,
    #[serde(rename = "documentTitle")]
    pub document_title: String,
    pub nodes: Vec<WorkflowNode>,
    pub edges: Vec<WorkflowEdge>,
    #[serde(rename = "viewportOffset", default)]
    pub viewport_offset: GraphPoint,
    #[serde(rename = "viewportZoom", default = "default_zoom")]
    pub viewport_zoom: f64,
}

fn default_schema_version() -> u32 {
    1
}
fn default_zoom() -> f64 {
    1.0
}

impl WorkflowDocumentModel {
    pub fn can_connect(&self, source_id: &str, target_id: &str) -> bool {
        if source_id == target_id {
            return false;
        }
        // Check if target_id can already reach source_id (would create a cycle)
        let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
        for e in &self.edges {
            adj.entry(e.source_node_id.as_str())
                .or_default()
                .push(e.target_node_id.as_str());
        }
        let mut visited: HashSet<&str> = HashSet::new();
        let mut queue = VecDeque::new();
        queue.push_back(target_id);
        while let Some(curr) = queue.pop_front() {
            if curr == source_id {
                return false;
            }
            if visited.insert(curr) {
                if let Some(nexts) = adj.get(curr) {
                    for &n in nexts {
                        queue.push_back(n);
                    }
                }
            }
        }
        true
    }

    /// Deterministic topological order respecting visual x/y ties.
    pub fn topological_order(&self) -> Vec<String> {
        let mut in_degree: HashMap<&str, usize> = HashMap::new();
        let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
        let mut pos_map: HashMap<&str, (f64, f64)> = HashMap::new();

        for n in &self.nodes {
            in_degree.insert(n.id.as_str(), 0);
            pos_map.insert(n.id.as_str(), (n.position.x, n.position.y));
        }
        for e in &self.edges {
            if in_degree.contains_key(e.source_node_id.as_str())
                && in_degree.contains_key(e.target_node_id.as_str())
            {
                adj.entry(e.source_node_id.as_str())
                    .or_default()
                    .push(e.target_node_id.as_str());
                *in_degree.entry(e.target_node_id.as_str()).or_insert(0) += 1;
            }
        }

        let mut ready: Vec<&str> = in_degree
            .iter()
            .filter(|(_, &deg)| deg == 0)
            .map(|(&id, _)| id)
            .collect();
        ready.sort_by(|a, b| {
            let pa = pos_map[a];
            let pb = pos_map[b];
            pa.0.total_cmp(&pb.0).then(pa.1.total_cmp(&pb.1))
        });

        let mut result = Vec::with_capacity(self.nodes.len());
        while !ready.is_empty() {
            let curr = ready.remove(0);
            result.push(curr.to_string());
            if let Some(nexts) = adj.get(curr) {
                for &n in nexts {
                    if let Some(d) = in_degree.get_mut(n) {
                        *d = d.saturating_sub(1);
                        if *d == 0 {
                            ready.push(n);
                        }
                    }
                }
                ready.sort_by(|a, b| {
                    let pa = pos_map[a];
                    let pb = pos_map[b];
                    pa.0.total_cmp(&pb.0).then(pa.1.total_cmp(&pb.1))
                });
            }
        }
        // Append any cycle-isolated nodes safely
        if result.len() < self.nodes.len() {
            let seen: HashSet<String> = result.iter().cloned().collect();
            for n in &self.nodes {
                if !seen.contains(&n.id) {
                    result.push(n.id.clone());
                }
            }
        }
        result
    }

    pub fn upstream_subgraph(&self, target_id: &str) -> Vec<String> {
        let mut needed: HashSet<&str> = HashSet::new();
        let mut queue = VecDeque::new();
        queue.push_back(target_id);
        while let Some(curr) = queue.pop_front() {
            if needed.insert(curr) {
                for e in &self.edges {
                    if e.target_node_id == curr {
                        queue.push_back(e.source_node_id.as_str());
                    }
                }
            }
        }
        self.topological_order()
            .into_iter()
            .filter(|id| needed.contains(id.as_str()))
            .collect()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DryRunAssetRef {
    pub id: String,
    pub path: String,
    #[serde(rename = "fileName")]
    pub file_name: String,
    #[serde(rename = "sourceNodeID")]
    pub source_node_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DryRunReport {
    #[serde(rename = "totalToRead")]
    pub total_to_read: usize,
    #[serde(rename = "totalToWrite")]
    pub total_to_write: usize,
    #[serde(rename = "nodeCounts")]
    pub node_counts: HashMap<String, usize>,
    #[serde(rename = "nodeSubtitles")]
    pub node_subtitles: HashMap<String, String>,
    #[serde(rename = "nodeAssets")]
    pub node_assets: HashMap<String, Vec<DryRunAssetRef>>,
    #[serde(rename = "statusSummary")]
    pub status_summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetInspectorInfo {
    #[serde(rename = "fileName")]
    pub file_name: String,
    #[serde(rename = "pixelWidth")]
    pub pixel_width: u32,
    #[serde(rename = "pixelHeight")]
    pub pixel_height: u32,
    pub dpi: u32,
    #[serde(rename = "bitsPerChannel")]
    pub bits_per_channel: u32,
    #[serde(rename = "colorSpaceName")]
    pub color_space_name: String,
    #[serde(rename = "originalByteCount")]
    pub original_byte_count: u64,
    #[serde(rename = "gpsPresent")]
    pub gps_present: bool,
    #[serde(rename = "cameraModel")]
    pub camera_model: Option<String>,
    pub classifications: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreviewResponse {
    #[serde(rename = "processedDataUrl")]
    pub processed_data_url: Option<String>,
    #[serde(rename = "originalDataUrl")]
    pub original_data_url: Option<String>,
    pub info: Option<AssetInspectorInfo>,
    #[serde(rename = "errorMessage")]
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionLogEntry {
    pub timestamp: String,
    pub level: String,
    #[serde(rename = "nodeTitle")]
    pub node_title: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchRunResult {
    #[serde(rename = "processedAssets")]
    pub processed_assets: usize,
    #[serde(rename = "writtenFiles")]
    pub written_files: Vec<String>,
    #[serde(rename = "nodeErrors")]
    pub node_errors: HashMap<String, String>,
    pub logs: Vec<ExecutionLogEntry>,
    #[serde(rename = "elapsedMs")]
    pub elapsed_ms: u128,
}
