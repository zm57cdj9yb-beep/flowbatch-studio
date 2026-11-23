use crate::catalog::{definition_for, node_type};
use crate::models::{
    AssetInspectorInfo, BatchRunResult, CodableColor, DryRunAssetRef, DryRunReport,
    ExecutionLogEntry, FilterRule, NodeErrorPolicy, NodeParamValue, PreviewResponse, RuleField,
    RuleOperator, WorkflowDocumentModel, WorkflowEdge, WorkflowNode,
};
use crate::pdf_writer::{build_multipage_pdf, extract_jpeg_images_from_pdf};
use crate::png_indexed::{crush_standard_png, encode_indexed_png, IndexedPngOptions};
use base64::Engine;
use chrono::Local;
use image::codecs::gif::{GifEncoder, Repeat};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, Frame, GenericImageView, ImageEncoder, Rgba, RgbaImage};
use rayon::prelude::*;
use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use walkdir::WalkDir;

const SUPPORTED_EXTS: &[&str] = &["png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "gif", "ico", "pdf"];

#[derive(Clone)]
pub struct PipelineAsset {
    pub id: String,
    pub source_path: Option<PathBuf>,
    pub base_name: String,
    pub extension: String,
    pub image: DynamicImage,
    pub dpi: u32,
    pub bits_per_channel: u32,
    pub color_space: String,
    pub original_bytes: u64,
    pub gps_present: bool,
    pub metadata_stripped: bool,
    pub author: String,
    pub copyright: String,
    pub classifications: Vec<String>,
    pub scale_suffix: String,
    pub pdf_bytes: Option<Vec<u8>>,
    pub gif_bytes: Option<Vec<u8>>,
}

impl PipelineAsset {
    fn from_file(path: &Path) -> Result<Self, String> {
        let meta = fs::metadata(path).map_err(|e| format!("Cannot read {}: {e}", path.display()))?;
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("png")
            .to_lowercase();
        let base_name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Image")
            .to_string();

        if ext == "pdf" {
            let raw = fs::read(path).map_err(|e| format!("PDF read failed: {e}"))?;
            let extracted = extract_jpeg_images_from_pdf(&raw);
            let img = extracted
                .into_iter()
                .next()
                .unwrap_or_else(|| DynamicImage::ImageRgba8(RgbaImage::from_pixel(640, 480, Rgba([245, 245, 248, 255]))));
            return Ok(Self {
                id: path.to_string_lossy().to_string(),
                source_path: Some(path.to_path_buf()),
                base_name,
                extension: ext,
                image: img,
                dpi: 150,
                bits_per_channel: 8,
                color_space: "sRGB".into(),
                original_bytes: meta.len(),
                gps_present: false,
                metadata_stripped: false,
                author: String::new(),
                copyright: String::new(),
                classifications: vec![],
                scale_suffix: String::new(),
                pdf_bytes: Some(raw),
                gif_bytes: None,
            });
        }

        let img = image::open(path).map_err(|e| format!("Failed to decode {}: {e}", path.display()))?;
        Ok(Self {
            id: path.to_string_lossy().to_string(),
            source_path: Some(path.to_path_buf()),
            base_name,
            extension: ext,
            image: img,
            dpi: 72,
            bits_per_channel: 8,
            color_space: "sRGB".into(),
            original_bytes: meta.len(),
            gps_present: false,
            metadata_stripped: false,
            author: String::new(),
            copyright: String::new(),
            classifications: vec![],
            scale_suffix: String::new(),
            pdf_bytes: None,
            gif_bytes: None,
        })
    }

    fn synthetic(name: &str, image: DynamicImage) -> Self {
        Self {
            id: format!("synthetic:{name}"),
            source_path: None,
            base_name: name.to_string(),
            extension: "png".into(),
            image,
            dpi: 72,
            bits_per_channel: 8,
            color_space: "sRGB".into(),
            original_bytes: 0,
            gps_present: false,
            metadata_stripped: false,
            author: String::new(),
            copyright: String::new(),
            classifications: vec![],
            scale_suffix: String::new(),
            pdf_bytes: None,
            gif_bytes: None,
        }
    }
}

/// Ensures 30 crisp scenic starter photos exist (`Aug 9 Shots` (16) + `Aug 11 Shots` (14))
/// inside the app data directory (matching macOS `Watermark Images.flowbatch`).
pub fn ensure_demo_assets(base_dir: &Path) -> Result<PathBuf, String> {
    let root = base_dir.join("DemoAssets");
    let aug9 = root.join("Aug 9 Shots");
    let aug11 = root.join("Aug 11 Shots");
    fs::create_dir_all(&aug9).map_err(|e| e.to_string())?;
    fs::create_dir_all(&aug11).map_err(|e| e.to_string())?;

    let existing9 = list_image_files(&aug9, false, "");
    let existing11 = list_image_files(&aug11, false, "");
    if existing9.len() >= 16 && existing11.len() >= 14 {
        return Ok(root);
    }

    let palettes: &[([u8; 3], [u8; 3], [u8; 3], bool)] = &[
        ([34, 65, 114], [244, 179, 89], [36, 56, 78], true),   // Golden Ocean Sunset
        ([45, 38, 78], [218, 126, 148], [32, 36, 58], false),  // Alpine Dusk
        ([48, 128, 198], [166, 218, 245], [34, 96, 144], true),// Coastal Midday
        ([64, 108, 102], [198, 224, 212], [28, 62, 54], false),// Misty Emerald Peak
        ([112, 58, 42], [242, 162, 86], [56, 36, 30], true),   // Canyon Sunset
        ([28, 42, 74], [120, 152, 198], [22, 32, 52], false),  // Twilight Ridge
    ];

    for i in 1..=16usize {
        let p = aug9.join(format!("Shot_0809_{:02}.jpg", i));
        if !p.exists() {
            let pal = palettes[(i - 1) % palettes.len()];
            save_scenic_jpeg(&p, 960, 640, pal.0, pal.1, pal.2, pal.3, i as u32)?;
        }
    }
    for i in 1..=14usize {
        let p = aug11.join(format!("Shot_0811_{:02}.jpg", i));
        if !p.exists() {
            let pal = palettes[(i + 1) % palettes.len()];
            save_scenic_jpeg(&p, 960, 640, pal.0, pal.1, pal.2, pal.3, (i + 20) as u32)?;
        }
    }
    Ok(root)
}

fn save_scenic_jpeg(
    path: &Path,
    w: u32,
    h: u32,
    top: [u8; 3],
    mid: [u8; 3],
    bot: [u8; 3],
    is_ocean: bool,
    seed: u32,
) -> Result<(), String> {
    let mut img = RgbaImage::new(w, h);
    let horizon = (h as f32 * 0.56) as u32;
    let sun_x = w as f32 * (0.28 + ((seed * 37) % 44) as f32 / 100.0);
    let sun_y = horizon as f32 * 0.82;

    for y in 0..h {
        for x in 0..w {
            let (r, g, b) = if y < horizon {
                let t = y as f32 / horizon as f32;
                let mut r = top[0] as f32 * (1.0 - t) + mid[0] as f32 * t;
                let mut g = top[1] as f32 * (1.0 - t) + mid[1] as f32 * t;
                let mut b = top[2] as f32 * (1.0 - t) + mid[2] as f32 * t;

                let dx = x as f32 - sun_x;
                let dy = y as f32 - sun_y;
                let dist = (dx * dx + dy * dy).sqrt();
                let glow = (-dist / (w as f32 * 0.16)).exp();
                r = (r + glow * 115.0).min(255.0);
                g = (g + glow * 100.0).min(255.0);
                b = (b + glow * 70.0).min(255.0);
                (r as u8, g as u8, b as u8)
            } else if is_ocean {
                let t = (y - horizon) as f32 / (h - horizon) as f32;
                let mut r = mid[0] as f32 * (1.0 - t) + bot[0] as f32 * t;
                let mut g = mid[1] as f32 * (1.0 - t) + bot[1] as f32 * t;
                let mut b = mid[2] as f32 * (1.0 - t) + bot[2] as f32 * t;
                let shimmer = (-(x as f32 - sun_x).abs() / (34.0 + t * 80.0)).exp()
                    * (((y as f32 * 0.45 + seed as f32).sin() * 0.5 + 0.5));
                r = (r + shimmer * 85.0).min(255.0);
                g = (g + shimmer * 78.0).min(255.0);
                b = (b + shimmer * 55.0).min(255.0);
                (r as u8, g as u8, b as u8)
            } else {
                // Mountain silhouette ridges
                let nx = x as f32 / w as f32;
                let ridge = horizon as f32
                    - (((nx * 6.5 + seed as f32 * 0.7).sin().abs()) * (h as f32 * 0.18)
                        + ((nx * 13.0 + seed as f32).cos().abs()) * (h as f32 * 0.06));
                if (y as f32) >= ridge {
                    let shade = 0.85 + 0.15 * ((y - horizon) as f32 / (h - horizon) as f32);
                    (
                        (bot[0] as f32 * shade).min(255.0) as u8,
                        (bot[1] as f32 * shade).min(255.0) as u8,
                        (bot[2] as f32 * shade).min(255.0) as u8,
                    )
                } else {
                    (mid[0], mid[1], mid[2])
                }
            };
            img.put_pixel(x, y, Rgba([r, g, b, 255]));
        }
    }

    let rgb = DynamicImage::ImageRgba8(img).to_rgb8();
    let mut buf = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut buf, 86);
    enc.encode_image(&rgb).map_err(|e| e.to_string())?;
    fs::write(path, buf).map_err(|e| e.to_string())
}

pub fn create_starter_document(demo_root: &Path) -> WorkflowDocumentModel {
    let aug9 = demo_root.join("Aug 9 Shots").to_string_lossy().to_string();
    let aug11 = demo_root.join("Aug 11 Shots").to_string_lossy().to_string();
    let default_out = dirs::picture_dir()
        .or_else(dirs::desktop_dir)
        .unwrap_or_else(|| demo_root.to_path_buf())
        .join("FlowBatch Thumbnails")
        .to_string_lossy()
        .to_string();

    let read1 = WorkflowNode::new(node_type::READ_FOLDER, 34.0, 66.0)
        .with_param("folderPath", NodeParamValue::String(aug9));
    let read2 = WorkflowNode::new(node_type::READ_FOLDER, 34.0, 234.0)
        .with_param("folderPath", NodeParamValue::String(aug11));
    let watermark = WorkflowNode::new(node_type::TEXT_WATERMARK, 196.0, 150.0)
        .with_param("text", NodeParamValue::String("@ FlowBatch Sample".into()))
        .with_param("fontSize", NodeParamValue::Double(28.0))
        .with_param("opacity", NodeParamValue::Double(0.75))
        .with_param("anchor", NodeParamValue::String("bottomRight".into()));
    let scale = WorkflowNode::new(node_type::SCALE, 358.0, 66.0)
        .with_param("mode", NodeParamValue::String("Fixed Width".into()))
        .with_param("width", NodeParamValue::Int(800));
    let write = WorkflowNode::new(node_type::WRITE_IMAGES, 516.0, 66.0)
        .with_param("folderPath", NodeParamValue::String(default_out))
        .with_param("openFolderWhenFinished", NodeParamValue::Bool(true))
        .with_param("overwriteExisting", NodeParamValue::Bool(true))
        .with_param("fileNamePattern", NodeParamValue::String("[File Name]".into()))
        .with_param("format", NodeParamValue::String("PNG".into()))
        .with_param("removeAlphaIfOpaque", NodeParamValue::Bool(true))
        .with_param("makeIndexedPNG", NodeParamValue::Bool(true))
        .with_param("indexedColors", NodeParamValue::Int(256))
        .with_param("indexedSpeed", NodeParamValue::Int(1))
        .with_param("indexedDither", NodeParamValue::Bool(false));

    let edges = vec![
        WorkflowEdge::new(&read1.id, &watermark.id),
        WorkflowEdge::new(&read2.id, &watermark.id),
        WorkflowEdge::new(&watermark.id, &scale.id),
        WorkflowEdge::new(&scale.id, &write.id),
    ];

    WorkflowDocumentModel {
        schema_version: 1,
        document_title: "Watermark Images.flowbatch".into(),
        nodes: vec![read1, read2, watermark, scale, write],
        edges,
        viewport_offset: Default::default(),
        viewport_zoom: 1.0,
    }
}

pub fn list_image_files(folder: &Path, recursive: bool, filter_exts: &str) -> Vec<PathBuf> {
    if !folder.exists() {
        return vec![];
    }
    let allowed: Vec<String> = if filter_exts.trim().is_empty() {
        SUPPORTED_EXTS.iter().map(|s| s.to_string()).collect()
    } else {
        filter_exts
            .split(|c: char| c == ',' || c == ';' || c.is_whitespace())
            .map(|s| s.trim().trim_start_matches('.').to_lowercase())
            .filter(|s| !s.is_empty())
            .collect()
    };

    let walker = if recursive {
        WalkDir::new(folder).follow_links(false)
    } else {
        WalkDir::new(folder).max_depth(1).follow_links(false)
    };

    let mut files: Vec<PathBuf> = walker
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            p.extension()
                .and_then(|e| e.to_str())
                .map(|e| allowed.contains(&e.to_lowercase()))
                .unwrap_or(false)
        })
        .collect();
    files.sort();
    files
}

fn folder_leaf_name(path: &str) -> String {
    if path.trim().is_empty() {
        return "Choose Folder…".into();
    }
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
        .to_string()
}

pub fn node_subtitle(node: &WorkflowNode) -> String {
    match node.type_id.as_str() {
        node_type::READ_FOLDER => folder_leaf_name(&node.param_str("folderPath", "")),
        node_type::WRITE_IMAGES => folder_leaf_name(&node.param_str("folderPath", "")),
        node_type::TEXT_WATERMARK => node.param_str("text", "@ FlowBatch"),
        node_type::SCALE => {
            let mode = node.param_str("mode", "Fixed Width");
            match mode.as_str() {
                "Fixed Width" => format!("Fixed {} width", node.param_i64("width", 800)),
                "Fixed Height" => format!("Fixed {} height", node.param_i64("height", 600)),
                "Percentage" => format!("{}%", node.param_f64("percent", 50.0).round() as i64),
                _ => format!("Fit {}×{}", node.param_i64("width", 800), node.param_i64("height", 600)),
            }
        }
        node_type::GAUSSIAN_BLUR | node_type::BOX_BLUR => {
            format!("Radius {:.1} px", node.param_f64("radius", 10.0))
        }
        node_type::EXPOSURE => format!("{:+.2} EV", node.param_f64("ev", 0.5)),
        node_type::ROTATE => format!("{}°", node.param_f64("degrees", 90.0).round() as i64),
        node_type::FLIP => node.param_str("direction", "Horizontal"),
        node_type::PHOTO_EFFECT => node.param_str("style", "Noir"),
        node_type::MULTI_SCALE => {
            let n = node
                .parameters
                .get("scales")
                .and_then(|v| v.as_scales())
                .map(|s| s.len())
                .unwrap_or(2);
            format!("{n} scales")
        }
        node_type::RULES => {
            let n = node
                .parameters
                .get("rules")
                .and_then(|v| v.as_rules())
                .map(|r| r.len())
                .unwrap_or(1);
            format!("{n} rule(s)")
        }
        node_type::PDF_MAKER => node.param_str("fileName", "ContactSheet.pdf"),
        _ => definition_for(&node.type_id)
            .map(|d| d.category)
            .map(|c| serde_json::to_string(&c).unwrap_or_default().replace('"', ""))
            .unwrap_or_default(),
    }
}

pub fn dry_run(doc: &WorkflowDocumentModel) -> DryRunReport {
    let order = doc.topological_order();
    let node_map: HashMap<&str, &WorkflowNode> = doc.nodes.iter().map(|n| (n.id.as_str(), n)).collect();

    let mut node_assets: HashMap<String, Vec<DryRunAssetRef>> = HashMap::new();
    let mut node_counts: HashMap<String, usize> = HashMap::new();
    let mut node_subtitles: HashMap<String, String> = HashMap::new();
    let mut total_read = 0usize;
    let mut total_write = 0usize;

    for id in &order {
        let Some(node) = node_map.get(id.as_str()) else { continue };
        node_subtitles.insert(id.clone(), node_subtitle(node));

        // Gather incoming assets from upstream edges
        let mut incoming: Vec<DryRunAssetRef> = Vec::new();
        for e in &doc.edges {
            if e.target_node_id == *id {
                if let Some(src_assets) = node_assets.get(&e.source_node_id) {
                    incoming.extend(src_assets.iter().cloned());
                }
            }
        }

        let outgoing: Vec<DryRunAssetRef> = if !node.is_enabled {
            incoming
        } else {
            match node.type_id.as_str() {
                node_type::READ_FOLDER => {
                    let folder = PathBuf::from(node.param_str("folderPath", ""));
                    let rec = node.param_bool("includeSubfolders", false);
                    let exts = node.param_str("filterExtensions", "");
                    let files = list_image_files(&folder, rec, &exts);
                    let refs: Vec<DryRunAssetRef> = files
                        .into_iter()
                        .map(|p| DryRunAssetRef {
                            id: format!("{}::{}", node.id, p.display()),
                            file_name: p.file_name().and_then(|s| s.to_str()).unwrap_or("image").into(),
                            path: p.to_string_lossy().to_string(),
                            source_node_id: node.id.clone(),
                        })
                        .collect();
                    total_read += refs.len();
                    refs
                }
                node_type::READ_FILES => {
                    let raw = node.param_str("filePaths", "");
                    let refs: Vec<DryRunAssetRef> = raw
                        .split(';')
                        .map(str::trim)
                        .filter(|s| !s.is_empty() && Path::new(s).exists())
                        .map(|s| DryRunAssetRef {
                            id: format!("{}::{s}", node.id),
                            file_name: Path::new(s)
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or("image")
                                .into(),
                            path: s.to_string(),
                            source_node_id: node.id.clone(),
                        })
                        .collect();
                    total_read += refs.len();
                    refs
                }
                node_type::READ_PHOTOS_LIBRARY => {
                    let base = dirs::picture_dir().unwrap_or_default();
                    let album = node.param_str("albumName", "");
                    let folder = if album.trim().is_empty() {
                        base
                    } else {
                        base.join(album.trim())
                    };
                    let limit = node.param_i64("limit", 50).max(1) as usize;
                    let refs: Vec<DryRunAssetRef> = list_image_files(&folder, false, "")
                        .into_iter()
                        .take(limit)
                        .map(|p| DryRunAssetRef {
                            id: format!("{}::{}", node.id, p.display()),
                            file_name: p.file_name().and_then(|s| s.to_str()).unwrap_or("photo").into(),
                            path: p.to_string_lossy().to_string(),
                            source_node_id: node.id.clone(),
                        })
                        .collect();
                    total_read += refs.len();
                    refs
                }
                node_type::BLANK_IMAGE => {
                    total_read += 1;
                    vec![DryRunAssetRef {
                        id: format!("{}::blank", node.id),
                        file_name: "Blank.png".into(),
                        path: String::new(),
                        source_node_id: node.id.clone(),
                    }]
                }
                node_type::MULTI_SCALE => {
                    let mult = node
                        .parameters
                        .get("scales")
                        .and_then(|v| v.as_scales())
                        .map(|s| s.len())
                        .unwrap_or(2)
                        .max(1);
                    let mut out = Vec::with_capacity(incoming.len() * mult);
                    for asset in &incoming {
                        for k in 0..mult {
                            let mut cloned = asset.clone();
                            cloned.id = format!("{}#scale{k}", asset.id);
                            out.push(cloned);
                        }
                    }
                    out
                }
                node_type::DUPLICATE => {
                    let copies = node.param_i64("copies", 2).clamp(1, 10) as usize;
                    let mut out = Vec::with_capacity(incoming.len() * copies);
                    for asset in &incoming {
                        for k in 0..copies {
                            let mut cloned = asset.clone();
                            cloned.id = format!("{}#dup{k}", asset.id);
                            out.push(cloned);
                        }
                    }
                    out
                }
                node_type::PDF_MAKER | node_type::IMAGE_GRID | node_type::ANIMATED_IMAGE => {
                    if incoming.is_empty() {
                        vec![]
                    } else {
                        vec![incoming[0].clone()]
                    }
                }
                node_type::WRITE_IMAGES | node_type::IMPORT_TO_PHOTOS => {
                    total_write += incoming.len();
                    incoming
                }
                _ => incoming,
            }
        };

        node_counts.insert(id.clone(), outgoing.len());
        node_assets.insert(id.clone(), outgoing);
    }

    let status_summary = format!("{total_read} assets ready to read, {total_write} to write.");

    DryRunReport {
        total_to_read: total_read,
        total_to_write: total_write,
        node_counts,
        node_subtitles,
        node_assets,
        status_summary,
    }
}

pub fn load_thumbnail_data_url(path: &str, max_px: u32) -> Result<String, String> {
    let img = image::open(path).map_err(|e| format!("Thumbnail open failed: {e}"))?;
    let thumb = img.thumbnail(max_px.max(32), max_px.max(32));
    encode_image_to_jpeg_data_url(&thumb, 82)
}

fn encode_image_to_png_data_url(img: &DynamicImage) -> Result<String, String> {
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let mut buf = Vec::new();
    let encoder = PngEncoder::new(&mut buf);
    encoder
        .write_image(rgba.as_raw(), w, h, image::ExtendedColorType::Rgba8)
        .map_err(|e| format!("PNG preview encode failed: {e}"))?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);
    Ok(format!("data:image/png;base64,{b64}"))
}

fn encode_image_to_jpeg_data_url(img: &DynamicImage, quality: u8) -> Result<String, String> {
    let rgb = img.to_rgb8();
    let mut buf = Vec::new();
    let mut enc = JpegEncoder::new_with_quality(&mut buf, quality);
    enc.encode_image(&rgb)
        .map_err(|e| format!("JPEG preview encode failed: {e}"))?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);
    Ok(format!("data:image/jpeg;base64,{b64}"))
}

pub fn expand_tokens(pattern: &str, asset: &PipelineAsset, counter: usize) -> String {
    let (w, h) = asset.image.dimensions();
    let now = Local::now();
    let class_tag = asset
        .classifications
        .first()
        .cloned()
        .unwrap_or_else(|| "photo".into());

    let mut out = pattern.to_string();
    let pairs = [
        ("[File Name]", asset.base_name.clone()),
        ("[Width]", w.to_string()),
        ("[Height]", h.to_string()),
        ("[Counter]", format!("{:03}", counter)),
        ("[Date]", now.format("%Y-%m-%d").to_string()),
        ("[Year]", now.format("%Y").to_string()),
        ("[Month]", now.format("%m").to_string()),
        ("[Day]", now.format("%d").to_string()),
        ("[Author]", if asset.author.is_empty() { "FlowBatch".into() } else { asset.author.clone() }),
        ("[Classification]", class_tag),
        ("[Extension]", asset.extension.clone()),
    ];
    for (tok, val) in pairs {
        out = out.replace(tok, &val);
    }
    if !asset.scale_suffix.is_empty() {
        out.push_str(&asset.scale_suffix);
    }
    sanitize_filename(&out)
}

fn sanitize_filename(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0' => '_',
            _ => c,
        })
        .collect();
    let trimmed = cleaned.trim().trim_matches('.');
    if trimmed.is_empty() {
        "FlowBatch_Output".into()
    } else {
        trimmed.to_string()
    }
}

pub fn render_preview(
    doc: &WorkflowDocumentModel,
    target_node_id: Option<&str>,
    asset_path: Option<&str>,
) -> PreviewResponse {
    let Some(target_id) = target_node_id.or_else(|| doc.nodes.last().map(|n| n.id.as_str())) else {
        return PreviewResponse {
            processed_data_url: None,
            original_data_url: None,
            info: None,
            error_message: None,
        };
    };

    let subgraph = doc.upstream_subgraph(target_id);
    let node_map: HashMap<&str, &WorkflowNode> = doc.nodes.iter().map(|n| (n.id.as_str(), n)).collect();

    // Load original asset (or create synthetic if Blank Image is the source)
    let orig_asset = if let Some(path) = asset_path.filter(|p| !p.trim().is_empty()) {
        match PipelineAsset::from_file(Path::new(path)) {
            Ok(mut a) => {
                // Keep preview responsive on huge inputs by bounding preview working copy to 1400px
                if a.image.width() > 1400 || a.image.height() > 1400 {
                    a.image = a.image.thumbnail(1400, 1400);
                }
                a
            }
            Err(e) => {
                return PreviewResponse {
                    processed_data_url: None,
                    original_data_url: None,
                    info: None,
                    error_message: Some(e),
                };
            }
        }
    } else {
        PipelineAsset::synthetic(
            "Preview",
            DynamicImage::ImageRgba8(RgbaImage::from_pixel(640, 420, Rgba([235, 240, 248, 255]))),
        )
    };

    let orig_url = encode_image_to_png_data_url(&orig_asset.image).ok();
    let mut current = orig_asset.clone();
    let mut err_msg = None;

    for nid in subgraph {
        let Some(node) = node_map.get(nid.as_str()) else { continue };
        if !node.is_enabled {
            continue;
        }
        // Skip source & sink disk-writing steps in interactive preview
        if matches!(
            node.type_id.as_str(),
            node_type::READ_FOLDER
                | node_type::READ_FILES
                | node_type::PROMPT_FOR_FILES
                | node_type::READ_PHOTOS_LIBRARY
                | node_type::WRITE_IMAGES
                | node_type::WRITE_CLIPBOARD
                | node_type::OPEN_IN_APP
                | node_type::IMPORT_TO_PHOTOS
                | node_type::DELAY
        ) {
            continue;
        }
        match execute_single_asset_node(node, current.clone(), true) {
            Ok(mut outputs) => {
                if let Some(first) = outputs.drain(..).next() {
                    current = first;
                }
            }
            Err(e) => {
                err_msg = Some(e);
                break;
            }
        }
    }

    let (pw, ph) = current.image.dimensions();
    let proc_url = encode_image_to_png_data_url(&current.image).ok();
    let info = AssetInspectorInfo {
        file_name: format!("{}.{}", current.base_name, current.extension),
        pixel_width: pw,
        pixel_height: ph,
        dpi: current.dpi,
        bits_per_channel: current.bits_per_channel,
        color_space_name: current.color_space.clone(),
        original_byte_count: current.original_bytes,
        gps_present: current.gps_present,
        camera_model: Some("FlowBatch Studio".into()),
        classifications: current.classifications.clone(),
    };

    PreviewResponse {
        processed_data_url: proc_url,
        original_data_url: orig_url,
        info: Some(info),
        error_message: err_msg,
    }
}

pub fn run_batch(doc: &WorkflowDocumentModel) -> BatchRunResult {
    let start = Instant::now();
    let order = doc.topological_order();
    let node_map: HashMap<&str, &WorkflowNode> = doc.nodes.iter().map(|n| (n.id.as_str(), n)).collect();

    // Per-node, per-output-port asset buckets
    let mut outputs: HashMap<(String, usize), Vec<PipelineAsset>> = HashMap::new();
    let mut written_files: Vec<String> = Vec::new();
    let mut node_errors: HashMap<String, String> = HashMap::new();
    let mut logs: Vec<ExecutionLogEntry> = Vec::new();
    let mut processed_assets = 0usize;
    let mut halted = false;

    let now_str = || Local::now().format("%H:%M:%S").to_string();

    for nid in &order {
        if halted {
            break;
        }
        let Some(node) = node_map.get(nid.as_str()) else { continue };

        let mut incoming: Vec<PipelineAsset> = Vec::new();
        for e in &doc.edges {
            if e.target_node_id == *nid {
                if let Some(bucket) = outputs.get(&(e.source_node_id.clone(), e.source_port_index)) {
                    incoming.extend(bucket.iter().cloned());
                }
            }
        }

        if !node.is_enabled {
            outputs.insert((nid.clone(), 0), incoming);
            continue;
        }

        match node.type_id.as_str() {
            node_type::READ_FOLDER => {
                let folder = PathBuf::from(node.param_str("folderPath", ""));
                let rec = node.param_bool("includeSubfolders", false);
                let exts = node.param_str("filterExtensions", "");
                let files = list_image_files(&folder, rec, &exts);
                let loaded: Vec<Result<PipelineAsset, String>> = files
                    .par_iter()
                    .map(|p| PipelineAsset::from_file(p))
                    .collect();
                let mut ok_assets = Vec::new();
                for res in loaded {
                    match res {
                        Ok(a) => ok_assets.push(a),
                        Err(e) => {
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "warn".into(),
                                node_title: node.title.clone(),
                                message: e.clone(),
                            });
                            if node.error_policy == NodeErrorPolicy::HaltWorkflow {
                                node_errors.insert(nid.clone(), e);
                                halted = true;
                                break;
                            }
                        }
                    }
                }
                processed_assets += ok_assets.len();
                logs.push(ExecutionLogEntry {
                    timestamp: now_str(),
                    level: "info".into(),
                    node_title: node.title.clone(),
                    message: format!("Read {} image(s) from {}", ok_assets.len(), folder.display()),
                });
                outputs.insert((nid.clone(), 0), ok_assets);
            }
            node_type::READ_FILES => {
                let raw = node.param_str("filePaths", "");
                let mut ok_assets = Vec::new();
                for s in raw.split(';').map(str::trim).filter(|s| !s.is_empty()) {
                    match PipelineAsset::from_file(Path::new(s)) {
                        Ok(a) => ok_assets.push(a),
                        Err(e) => {
                            node_errors.insert(nid.clone(), e.clone());
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "error".into(),
                                node_title: node.title.clone(),
                                message: e,
                            });
                        }
                    }
                }
                processed_assets += ok_assets.len();
                outputs.insert((nid.clone(), 0), ok_assets);
            }
            node_type::READ_PHOTOS_LIBRARY => {
                let base = dirs::picture_dir().unwrap_or_default();
                let album = node.param_str("albumName", "");
                let folder = if album.trim().is_empty() {
                    base
                } else {
                    base.join(album.trim())
                };
                let limit = node.param_i64("limit", 50).max(1) as usize;
                let files: Vec<PathBuf> = list_image_files(&folder, false, "").into_iter().take(limit).collect();
                let ok_assets: Vec<PipelineAsset> = files
                    .par_iter()
                    .filter_map(|p| PipelineAsset::from_file(p).ok())
                    .collect();
                processed_assets += ok_assets.len();
                outputs.insert((nid.clone(), 0), ok_assets);
            }
            node_type::BLANK_IMAGE => {
                let w = node.param_i64("width", 1200).clamp(16, 4096) as u32;
                let h = node.param_i64("height", 800).clamp(16, 4096) as u32;
                let c = node.param_color("color", CodableColor::WHITE).to_rgba8();
                let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(w, h, Rgba(c)));
                processed_assets += 1;
                outputs.insert((nid.clone(), 0), vec![PipelineAsset::synthetic("Blank", img)]);
            }
            node_type::PROMPT_FOR_FILES | node_type::READ_CLIPBOARD | node_type::SCREENSHOT => {
                logs.push(ExecutionLogEntry {
                    timestamp: now_str(),
                    level: "info".into(),
                    node_title: node.title.clone(),
                    message: "Interactive/OS source node skipped in headless batch mode (0 assets).".into(),
                });
                outputs.insert((nid.clone(), 0), incoming);
            }
            node_type::RULES => {
                let match_all = node.param_bool("matchAll", true);
                let rules = node
                    .parameters
                    .get("rules")
                    .and_then(|v| v.as_rules())
                    .unwrap_or(&[]);
                let mut matched = Vec::new();
                let mut unmatched = Vec::new();
                for a in incoming {
                    if evaluate_rules(&a, rules, match_all) {
                        matched.push(a);
                    } else {
                        unmatched.push(a);
                    }
                }
                logs.push(ExecutionLogEntry {
                    timestamp: now_str(),
                    level: "info".into(),
                    node_title: node.title.clone(),
                    message: format!("Routed {} matched, {} unmatched", matched.len(), unmatched.len()),
                });
                outputs.insert((nid.clone(), 0), matched);
                outputs.insert((nid.clone(), 1), unmatched);
            }
            node_type::SORT_ORDER => {
                let by = node.param_str("sortBy", "File Name");
                let asc = node.param_bool("ascending", true);
                incoming.sort_by(|a, b| {
                    let ord = match by.as_str() {
                        "Width" => a.image.width().cmp(&b.image.width()),
                        "Height" => a.image.height().cmp(&b.image.height()),
                        "File Size" => a.original_bytes.cmp(&b.original_bytes),
                        _ => a.base_name.to_lowercase().cmp(&b.base_name.to_lowercase()),
                    };
                    if asc { ord } else { ord.reverse() }
                });
                outputs.insert((nid.clone(), 0), incoming);
            }
            node_type::PDF_MAKER => {
                if !incoming.is_empty() {
                    let margin = node.param_f64("margin", 24.0);
                    let fname = node.param_str("fileName", "ContactSheet.pdf");
                    let imgs: Vec<DynamicImage> = incoming.iter().map(|a| a.image.clone()).collect();
                    match build_multipage_pdf(&imgs, margin) {
                        Ok(pdf_bytes) => {
                            let mut out_asset = incoming[0].clone();
                            out_asset.base_name = Path::new(&fname)
                                .file_stem()
                                .and_then(|s| s.to_str())
                                .unwrap_or("ContactSheet")
                                .to_string();
                            out_asset.extension = "pdf".into();
                            out_asset.pdf_bytes = Some(pdf_bytes);
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "info".into(),
                                node_title: node.title.clone(),
                                message: format!("Built {}-page PDF ({})", imgs.len(), fname),
                            });
                            outputs.insert((nid.clone(), 0), vec![out_asset]);
                        }
                        Err(e) => {
                            node_errors.insert(nid.clone(), e.clone());
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "error".into(),
                                node_title: node.title.clone(),
                                message: e,
                            });
                        }
                    }
                } else {
                    outputs.insert((nid.clone(), 0), vec![]);
                }
            }
            node_type::IMAGE_GRID => {
                if !incoming.is_empty() {
                    let cols = node.param_i64("columns", 4).clamp(1, 12) as u32;
                    let tile = node.param_i64("tileSize", 240).clamp(32, 1024) as u32;
                    let gap = node.param_i64("spacing", 12).clamp(0, 64) as u32;
                    let bg = node.param_color("backgroundColor", CodableColor::WHITE).to_rgba8();
                    let rows = (incoming.len() as u32).div_ceil(cols);
                    let cw = cols * tile + (cols + 1) * gap;
                    let ch = rows * tile + (rows + 1) * gap;
                    let mut canvas = RgbaImage::from_pixel(cw, ch, Rgba(bg));
                    for (idx, a) in incoming.iter().enumerate() {
                        let r = idx as u32 / cols;
                        let c = idx as u32 % cols;
                        let thumb = a.image.resize_to_fill(tile, tile, FilterType::Lanczos3).to_rgba8();
                        let ox = gap + c * (tile + gap);
                        let oy = gap + r * (tile + gap);
                        image::imageops::overlay(&mut canvas, &thumb, ox as i64, oy as i64);
                    }
                    outputs.insert(
                        (nid.clone(), 0),
                        vec![PipelineAsset::synthetic("ImageGrid", DynamicImage::ImageRgba8(canvas))],
                    );
                } else {
                    outputs.insert((nid.clone(), 0), vec![]);
                }
            }
            node_type::ANIMATED_IMAGE => {
                if !incoming.is_empty() {
                    let delay_ms = (node.param_f64("frameDelay", 0.25) * 1000.0).clamp(40.0, 2000.0) as u32;
                    let fname = node.param_str("fileName", "Animation.gif");
                    let (w, h) = incoming[0].image.dimensions();
                    let mut gif_buf = Vec::new();
                    {
                        let mut enc = GifEncoder::new(&mut gif_buf);
                        let _ = enc.set_repeat(Repeat::Infinite);
                        for a in &incoming {
                            let rgba = a.image.resize_exact(w, h, FilterType::Triangle).to_rgba8();
                            let frame = Frame::from_parts(
                                rgba,
                                0,
                                0,
                                image::Delay::from_numer_denom_ms(delay_ms, 1),
                            );
                            let _ = enc.encode_frame(frame);
                        }
                    }
                    let mut out_asset = incoming[0].clone();
                    out_asset.base_name = Path::new(&fname)
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("Animation")
                        .to_string();
                    out_asset.extension = "gif".into();
                    out_asset.gif_bytes = Some(gif_buf);
                    outputs.insert((nid.clone(), 0), vec![out_asset]);
                } else {
                    outputs.insert((nid.clone(), 0), vec![]);
                }
            }
            node_type::WRITE_IMAGES => {
                let write_results: Vec<Result<String, String>> = incoming
                    .par_iter()
                    .enumerate()
                    .map(|(idx, asset)| write_asset_to_disk(node, asset, idx + 1))
                    .collect();
                let mut ok_count = 0usize;
                for res in write_results {
                    match res {
                        Ok(path) => {
                            written_files.push(path);
                            ok_count += 1;
                        }
                        Err(e) => {
                            node_errors.insert(nid.clone(), e.clone());
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "error".into(),
                                node_title: node.title.clone(),
                                message: e,
                            });
                            if node.error_policy == NodeErrorPolicy::HaltWorkflow {
                                halted = true;
                                break;
                            }
                        }
                    }
                }
                logs.push(ExecutionLogEntry {
                    timestamp: now_str(),
                    level: "info".into(),
                    node_title: node.title.clone(),
                    message: format!("Exported {ok_count} image(s) successfully."),
                });
                outputs.insert((nid.clone(), 0), incoming);
            }
            node_type::IMPORT_TO_PHOTOS => {
                let album = sanitize_filename(&node.param_str("albumName", "FlowBatch Exports"));
                let dest = dirs::picture_dir()
                    .unwrap_or_else(std::env::temp_dir)
                    .join(album);
                let mut synth_write = (*node).clone();
                synth_write
                    .parameters
                    .insert("folderPath".into(), NodeParamValue::String(dest.to_string_lossy().to_string()));
                synth_write
                    .parameters
                    .insert("format".into(), NodeParamValue::String("PNG".into()));
                synth_write
                    .parameters
                    .insert("overwriteExisting".into(), NodeParamValue::Bool(true));
                for (idx, a) in incoming.iter().enumerate() {
                    if let Ok(p) = write_asset_to_disk(&synth_write, a, idx + 1) {
                        written_files.push(p);
                    }
                }
                outputs.insert((nid.clone(), 0), incoming);
            }
            node_type::WRITE_CLIPBOARD | node_type::OPEN_IN_APP => {
                logs.push(ExecutionLogEntry {
                    timestamp: now_str(),
                    level: "info".into(),
                    node_title: node.title.clone(),
                    message: format!("Completed sink step for {} asset(s).", incoming.len()),
                });
                outputs.insert((nid.clone(), 0), incoming);
            }
            _ => {
                // Parallel per-asset execution across all CPU cores with Rayon!
                let results: Vec<(PipelineAsset, Result<Vec<PipelineAsset>, String>)> = incoming
                    .into_par_iter()
                    .map(|asset| {
                        let backup = asset.clone();
                        let res = execute_single_asset_node(node, asset, false);
                        (backup, res)
                    })
                    .collect();

                let mut next_bucket = Vec::new();
                for (backup, res) in results {
                    match res {
                        Ok(mut outs) => next_bucket.append(&mut outs),
                        Err(e) => {
                            node_errors.insert(nid.clone(), e.clone());
                            logs.push(ExecutionLogEntry {
                                timestamp: now_str(),
                                level: "error".into(),
                                node_title: node.title.clone(),
                                message: e,
                            });
                            match node.error_policy {
                                NodeErrorPolicy::SkipAsset => {}
                                NodeErrorPolicy::PassThroughOnFailure => next_bucket.push(backup),
                                NodeErrorPolicy::HaltWorkflow => {
                                    halted = true;
                                    break;
                                }
                            }
                        }
                    }
                }
                outputs.insert((nid.clone(), 0), next_bucket);
            }
        }
    }

    BatchRunResult {
        processed_assets,
        written_files,
        node_errors,
        logs,
        elapsed_ms: start.elapsed().as_millis(),
    }
}

fn write_asset_to_disk(node: &WorkflowNode, asset: &PipelineAsset, counter: usize) -> Result<String, String> {
    let write_back = node.param_bool("writeBackToOriginal", false);
    let out_dir = if write_back {
        asset
            .source_path
            .as_ref()
            .and_then(|p| p.parent())
            .map(PathBuf::from)
            .ok_or_else(|| "Write back requires an on-disk source file".to_string())?
    } else {
        let p = node.param_str("folderPath", "");
        if p.trim().is_empty() {
            return Err("Write Images requires an output folder path".into());
        }
        PathBuf::from(p)
    };
    fs::create_dir_all(&out_dir).map_err(|e| format!("Cannot create output folder: {e}"))?;

    let pattern = node.param_str("fileNamePattern", "[File Name]");
    let stem = expand_tokens(&pattern, asset, counter);
    let format = node.param_str("format", "PNG");

    // Preserve prebuilt PDF or Animated GIF bytes if upstream generated them
    if let Some(pdf_bytes) = &asset.pdf_bytes {
        if format.eq_ignore_ascii_case("PDF") || asset.extension == "pdf" {
            let dest = resolve_non_colliding_path(&out_dir, &stem, "pdf", node.param_bool("overwriteExisting", true));
            fs::write(&dest, pdf_bytes).map_err(|e| e.to_string())?;
            return Ok(dest.to_string_lossy().to_string());
        }
    }
    if let Some(gif_bytes) = &asset.gif_bytes {
        if format.eq_ignore_ascii_case("GIF") || asset.extension == "gif" {
            let dest = resolve_non_colliding_path(&out_dir, &stem, "gif", node.param_bool("overwriteExisting", true));
            fs::write(&dest, gif_bytes).map_err(|e| e.to_string())?;
            return Ok(dest.to_string_lossy().to_string());
        }
    }

    let ext = match format.to_uppercase().as_str() {
        "JPEG" | "JPG" => "jpg",
        "WEBP" => "webp",
        "TIFF" => "tiff",
        "GIF" => "gif",
        "BMP" => "bmp",
        "ICO" => "ico",
        "PDF" => "pdf",
        _ => "png",
    };

    let dest = resolve_non_colliding_path(&out_dir, &stem, ext, node.param_bool("overwriteExisting", true));

    match ext {
        "png" => {
            let make_indexed = node.param_bool("makeIndexedPNG", false);
            let crush = node.param_bool("crushPNG", false);
            let brute = node.param_bool("bruteForceCrushPNG", false);
            let strip = node.param_bool("removeColorProfile", false);
            let remove_alpha = node.param_bool("removeAlphaIfOpaque", true);
            let rgba = asset.image.to_rgba8();

            let bytes = if make_indexed {
                encode_indexed_png(
                    &rgba,
                    &IndexedPngOptions {
                        max_colors: node.param_i64("indexedColors", 256).clamp(2, 256) as usize,
                        speed: node.param_i64("indexedSpeed", 1).clamp(1, 10) as u8,
                        dither: node.param_bool("indexedDither", false),
                        remove_alpha_if_opaque: remove_alpha,
                        crush,
                        brute_force_crush: brute,
                        remove_color_profile: strip,
                    },
                )?
            } else {
                let mut raw_png = Vec::new();
                let is_opaque = rgba.as_raw().chunks_exact(4).all(|p| p[3] == 255);
                if remove_alpha && is_opaque {
                    let rgb = asset.image.to_rgb8();
                    let (w, h) = rgb.dimensions();
                    PngEncoder::new(&mut raw_png)
                        .write_image(rgb.as_raw(), w, h, image::ExtendedColorType::Rgb8)
                        .map_err(|e| e.to_string())?;
                } else {
                    let (w, h) = rgba.dimensions();
                    PngEncoder::new(&mut raw_png)
                        .write_image(rgba.as_raw(), w, h, image::ExtendedColorType::Rgba8)
                        .map_err(|e| e.to_string())?;
                }
                if crush || brute {
                    crush_standard_png(&raw_png, brute, strip)
                } else {
                    raw_png
                }
            };
            fs::write(&dest, bytes).map_err(|e| e.to_string())?;
        }
        "jpg" => {
            let q = (node.param_f64("quality", 0.88).clamp(0.1, 1.0) * 100.0).round() as u8;
            let rgb = asset.image.to_rgb8();
            let mut buf = Vec::new();
            let mut enc = JpegEncoder::new_with_quality(&mut buf, q);
            enc.encode_image(&rgb).map_err(|e| e.to_string())?;
            fs::write(&dest, buf).map_err(|e| e.to_string())?;
        }
        "pdf" => {
            let pdf = build_multipage_pdf(&[asset.image.clone()], 0.0)?;
            fs::write(&dest, pdf).map_err(|e| e.to_string())?;
        }
        "ico" => {
            let resized = asset.image.resize_exact(256, 256, FilterType::Lanczos3);
            resized
                .save_with_format(&dest, image::ImageFormat::Ico)
                .map_err(|e| e.to_string())?;
        }
        _ => {
            let fmt = match ext {
                "webp" => image::ImageFormat::WebP,
                "tiff" => image::ImageFormat::Tiff,
                "gif" => image::ImageFormat::Gif,
                "bmp" => image::ImageFormat::Bmp,
                _ => image::ImageFormat::Png,
            };
            asset
                .image
                .save_with_format(&dest, fmt)
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(dest.to_string_lossy().to_string())
}

fn resolve_non_colliding_path(dir: &Path, stem: &str, ext: &str, overwrite: bool) -> PathBuf {
    let first = dir.join(format!("{stem}.{ext}"));
    if overwrite || !first.exists() {
        return first;
    }
    for i in 2..10000 {
        let candidate = dir.join(format!("{stem}_{i}.{ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    first
}

fn evaluate_rules(asset: &PipelineAsset, rules: &[FilterRule], match_all: bool) -> bool {
    if rules.is_empty() {
        return true;
    }
    let check = |r: &FilterRule| -> bool {
        let (w, h) = asset.image.dimensions();
        match r.field {
            RuleField::FileName => match_str(&asset.base_name, &r.op, &r.value),
            RuleField::FileExtension => match_str(&asset.extension, &r.op, &r.value),
            RuleField::ColorSpace => match_str(&asset.color_space, &r.op, &r.value),
            RuleField::Classification => {
                let joined = asset.classifications.join(",");
                match_str(&joined, &r.op, &r.value)
            }
            RuleField::Width => match_num(w as f64, &r.op, r.value.parse().unwrap_or(0.0)),
            RuleField::Height => match_num(h as f64, &r.op, r.value.parse().unwrap_or(0.0)),
            RuleField::Megapixels => {
                let mp = (w as f64 * h as f64) / 1_000_000.0;
                match_num(mp, &r.op, r.value.parse().unwrap_or(0.0))
            }
            RuleField::Dpi => match_num(asset.dpi as f64, &r.op, r.value.parse().unwrap_or(72.0)),
            RuleField::HasAlpha => {
                let has_alpha = asset.image.to_rgba8().as_raw().chunks_exact(4).any(|p| p[3] < 255);
                match r.op {
                    RuleOperator::IsTrue => has_alpha,
                    RuleOperator::IsFalse => !has_alpha,
                    _ => has_alpha,
                }
            }
        }
    };
    if match_all {
        rules.iter().all(check)
    } else {
        rules.iter().any(check)
    }
}

fn match_str(actual: &str, op: &RuleOperator, expected: &str) -> bool {
    match op {
        RuleOperator::Contains => actual.to_lowercase().contains(&expected.to_lowercase()),
        RuleOperator::Equals => actual.eq_ignore_ascii_case(expected),
        RuleOperator::MatchesRegex => Regex::new(expected).map(|re| re.is_match(actual)).unwrap_or(false),
        _ => false,
    }
}

fn match_num(actual: f64, op: &RuleOperator, expected: f64) -> bool {
    match op {
        RuleOperator::GreaterThan => actual > expected,
        RuleOperator::LessThan => actual < expected,
        RuleOperator::Equals => (actual - expected).abs() < 1e-6,
        _ => false,
    }
}

fn execute_single_asset_node(
    node: &WorkflowNode,
    mut asset: PipelineAsset,
    is_preview: bool,
) -> Result<Vec<PipelineAsset>, String> {
    match node.type_id.as_str() {
        // --- Multi Scale & Duplicate ---
        node_type::MULTI_SCALE => {
            let specs = node
                .parameters
                .get("scales")
                .and_then(|v| v.as_scales())
                .map(|s| s.to_vec())
                .unwrap_or_default();
            if specs.is_empty() {
                return Ok(vec![asset]);
            }
            let (w, h) = asset.image.dimensions();
            let mut out = Vec::with_capacity(specs.len());
            for s in specs {
                let mut cloned = asset.clone();
                let nw = ((w as f64 * s.scale_factor).round() as u32).max(1);
                let nh = ((h as f64 * s.scale_factor).round() as u32).max(1);
                cloned.image = asset.image.resize_exact(nw, nh, FilterType::Lanczos3);
                cloned.scale_suffix = s.suffix;
                out.push(cloned);
            }
            return Ok(out);
        }
        node_type::DUPLICATE => {
            let copies = node.param_i64("copies", 2).clamp(1, 10) as usize;
            let mut out = Vec::with_capacity(copies);
            for i in 1..=copies {
                let mut c = asset.clone();
                if i > 1 {
                    c.scale_suffix = format!("_copy{i}");
                }
                out.push(c);
            }
            return Ok(out);
        }

        // --- Blur ---
        node_type::GAUSSIAN_BLUR => {
            let r = node.param_f64("radius", 10.0).clamp(0.1, 80.0) as f32;
            asset.image = asset.image.blur(r * 0.5);
        }
        node_type::BOX_BLUR => {
            let r = node.param_f64("radius", 8.0).clamp(1.0, 40.0) as f32;
            asset.image = asset.image.fast_blur(r * 0.5);
        }
        node_type::MOTION_BLUR => {
            let r = node.param_f64("radius", 12.0).clamp(1.0, 40.0) as i32;
            let angle = node.param_f64("angle", 0.0).to_radians();
            asset.image = DynamicImage::ImageRgba8(apply_motion_blur(&asset.image.to_rgba8(), r, angle));
        }
        node_type::NOISE_REDUCTION => {
            let level = node.param_f64("noiseLevel", 0.06).clamp(0.0, 0.5) as f32;
            if level > 0.0 {
                asset.image = asset.image.fast_blur(0.6 + level * 4.0);
            }
        }
        node_type::PIXELATE => {
            let block = node.param_f64("scale", 12.0).clamp(2.0, 80.0).round() as u32;
            let (w, h) = asset.image.dimensions();
            let sw = (w / block).max(1);
            let sh = (h / block).max(1);
            let small = asset.image.resize_exact(sw, sh, FilterType::Triangle);
            asset.image = small.resize_exact(w, h, FilterType::Nearest);
        }

        // --- Color Adjustments ---
        node_type::RAW_PROCESS => {
            let ev = node.param_f64("exposure", 0.0);
            let temp = node.param_f64("temperature", 6500.0);
            let tint = node.param_f64("tint", 0.0);
            let mut rgba = asset.image.to_rgba8();
            apply_exposure_inplace(&mut rgba, ev);
            apply_temp_tint_inplace(&mut rgba, temp, tint);
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::EXPOSURE => {
            let mut rgba = asset.image.to_rgba8();
            apply_exposure_inplace(&mut rgba, node.param_f64("ev", 0.5));
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::BRIGHTNESS_CONTRAST => {
            let b = node.param_f64("brightness", 0.0);
            let c = node.param_f64("contrast", 1.0);
            let s = node.param_f64("saturation", 1.0);
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let mut r = ((px[0] as f64 / 255.0 - 0.5) * c + 0.5 + b).clamp(0.0, 1.0);
                let mut g = ((px[1] as f64 / 255.0 - 0.5) * c + 0.5 + b).clamp(0.0, 1.0);
                let mut bl = ((px[2] as f64 / 255.0 - 0.5) * c + 0.5 + b).clamp(0.0, 1.0);
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
                r = (luma + (r - luma) * s).clamp(0.0, 1.0);
                g = (luma + (g - luma) * s).clamp(0.0, 1.0);
                bl = (luma + (bl - luma) * s).clamp(0.0, 1.0);
                px[0] = (r * 255.0).round() as u8;
                px[1] = (g * 255.0).round() as u8;
                px[2] = (bl * 255.0).round() as u8;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::VIBRANCE => {
            let amt = node.param_f64("amount", 0.35);
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let r = px[0] as f64 / 255.0;
                let g = px[1] as f64 / 255.0;
                let b = px[2] as f64 / 255.0;
                let avg = (r + g + b) / 3.0;
                let mx = r.max(g).max(b);
                let boost = ((mx - avg).abs() * -3.0 * amt + amt).clamp(-0.9, 1.5);
                px[0] = ((r + (r - avg) * boost).clamp(0.0, 1.0) * 255.0).round() as u8;
                px[1] = ((g + (g - avg) * boost).clamp(0.0, 1.0) * 255.0).round() as u8;
                px[2] = ((b + (b - avg) * boost).clamp(0.0, 1.0) * 255.0).round() as u8;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::GAMMA => {
            let inv = 1.0 / node.param_f64("power", 1.0).clamp(0.2, 3.0);
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                for c in 0..3 {
                    px[c] = ((px[c] as f64 / 255.0).powf(inv).clamp(0.0, 1.0) * 255.0).round() as u8;
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::TEMPERATURE_TINT => {
            let mut rgba = asset.image.to_rgba8();
            apply_temp_tint_inplace(
                &mut rgba,
                node.param_f64("temperature", 6500.0),
                node.param_f64("tint", 0.0),
            );
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::SHADOWS_HIGHLIGHTS => {
            let sh = node.param_f64("shadowAmount", 0.25);
            let hi = node.param_f64("highlightAmount", 0.85);
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                for c in 0..3 {
                    let v = px[c] as f64 / 255.0;
                    let shadow_lift = (1.0 - v).powi(2) * sh * 0.4;
                    let hi_scale = 1.0 - v.powi(2) * (1.0 - hi) * 0.5;
                    px[c] = (((v + shadow_lift) * hi_scale).clamp(0.0, 1.0) * 255.0).round() as u8;
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::COLOR_PROFILE => {
            let prof = node.param_str("profile", "sRGB");
            if prof == "Grayscale" {
                asset.image = DynamicImage::ImageRgba8(asset.image.grayscale().to_rgba8());
            }
            asset.color_space = prof;
        }

        // --- Color Effects ---
        node_type::PHOTO_EFFECT => {
            let style = node.param_str("style", "Noir");
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let r = px[0] as f64 / 255.0;
                let g = px[1] as f64 / 255.0;
                let b = px[2] as f64 / 255.0;
                let luma = 0.299 * r + 0.587 * g + 0.114 * b;
                let (nr, ng, nb) = match style.as_str() {
                    "Noir" => {
                        let v = ((luma - 0.5) * 1.45 + 0.48).clamp(0.0, 1.0);
                        (v, v, v)
                    }
                    "Mono" | "Tonal" => (luma, luma, luma),
                    "Fade" => (
                        (r * 0.85 + 0.12).min(1.0),
                        (g * 0.85 + 0.11).min(1.0),
                        (b * 0.85 + 0.14).min(1.0),
                    ),
                    "Chrome" => (
                        ((r - 0.5) * 1.25 + 0.5).clamp(0.0, 1.0),
                        ((g - 0.5) * 1.2 + 0.5).clamp(0.0, 1.0),
                        ((b - 0.5) * 1.15 + 0.52).clamp(0.0, 1.0),
                    ),
                    _ => (
                        (r * 1.06 + 0.02).min(1.0),
                        (g * 1.02).min(1.0),
                        (b * 0.92).min(1.0),
                    ),
                };
                px[0] = (nr * 255.0).round() as u8;
                px[1] = (ng * 255.0).round() as u8;
                px[2] = (nb * 255.0).round() as u8;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::SEPIA => {
            let amt = node.param_f64("intensity", 0.8).clamp(0.0, 1.0);
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let (r, g, b) = (px[0] as f64, px[1] as f64, px[2] as f64);
                let sr = (0.393 * r + 0.769 * g + 0.189 * b).min(255.0);
                let sg = (0.349 * r + 0.686 * g + 0.168 * b).min(255.0);
                let sb = (0.272 * r + 0.534 * g + 0.131 * b).min(255.0);
                px[0] = (r * (1.0 - amt) + sr * amt).round() as u8;
                px[1] = (g * (1.0 - amt) + sg * amt).round() as u8;
                px[2] = (b * (1.0 - amt) + sb * amt).round() as u8;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::COLOR_INVERT => {
            asset.image.invert();
        }
        node_type::COLOR_POSTERIZE => {
            let levels = node.param_f64("levels", 6.0).clamp(2.0, 32.0) - 1.0;
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                for c in 0..3 {
                    let q = ((px[c] as f64 / 255.0) * levels).round() / levels;
                    px[c] = (q * 255.0).round() as u8;
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::ONE_BIT => {
            let thresh = (node.param_f64("threshold", 0.5) * 255.0) as f32;
            let dither = node.param_bool("dither", true);
            let mut rgba = asset.image.to_rgba8();
            let (w, h) = rgba.dimensions();
            let mut luma: Vec<f32> = rgba
                .pixels()
                .map(|p| 0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32)
                .collect();
            for y in 0..h as usize {
                for x in 0..w as usize {
                    let idx = y * w as usize + x;
                    let old = luma[idx];
                    let new_v = if old >= thresh { 255.0 } else { 0.0 };
                    let err = old - new_v;
                    let v = new_v as u8;
                    let p = rgba.get_pixel_mut(x as u32, y as u32);
                    p[0] = v;
                    p[1] = v;
                    p[2] = v;
                    if dither {
                        let spread = [
                            (1isize, 0isize, 7.0 / 16.0),
                            (-1, 1, 3.0 / 16.0),
                            (0, 1, 5.0 / 16.0),
                            (1, 1, 1.0 / 16.0),
                        ];
                        for (dx, dy, f) in spread {
                            let nx = x as isize + dx;
                            let ny = y as isize + dy;
                            if nx >= 0 && nx < w as isize && ny >= 0 && ny < h as isize {
                                luma[ny as usize * w as usize + nx as usize] += err * f;
                            }
                        }
                    }
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::DITHER => {
            let intensity = node.param_f64("intensity", 0.25).clamp(0.0, 1.0) * 48.0;
            let mut rgba = asset.image.to_rgba8();
            let bayer = [[0, 2], [3, 1]];
            for (x, y, px) in rgba.enumerate_pixels_mut() {
                let offset = (bayer[(y % 2) as usize][(x % 2) as usize] as f64 / 3.0 - 0.5) * intensity;
                for c in 0..3 {
                    px[c] = (px[c] as f64 + offset).clamp(0.0, 255.0).round() as u8;
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::MATTE => {
            let bg = node.param_color("color", CodableColor::WHITE).to_rgba8();
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let a = px[3] as f32 / 255.0;
                for c in 0..3 {
                    px[c] = (px[c] as f32 * a + bg[c] as f32 * (1.0 - a)).round() as u8;
                }
                px[3] = 255;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::ADD_BORDER => {
            let bw = node.param_i64("width", 20).clamp(1, 200) as u32;
            let col = node.param_color("color", CodableColor::WHITE).to_rgba8();
            let src = asset.image.to_rgba8();
            let (w, h) = src.dimensions();
            let mut canvas = RgbaImage::from_pixel(w + bw * 2, h + bw * 2, Rgba(col));
            image::imageops::overlay(&mut canvas, &src, bw as i64, bw as i64);
            asset.image = DynamicImage::ImageRgba8(canvas);
        }
        node_type::DROP_SHADOW => {
            let rad = node.param_f64("radius", 16.0).clamp(0.0, 60.0) as u32;
            let ox = node.param_f64("offsetX", 0.0).round() as i64;
            let oy = node.param_f64("offsetY", 8.0).round() as i64;
            let opacity = node.param_f64("opacity", 0.45).clamp(0.0, 1.0);
            let col = node.param_color("color", CodableColor::BLACK).to_rgba8();
            let src = asset.image.to_rgba8();
            let (w, h) = src.dimensions();
            let pad = rad + ox.unsigned_abs().max(oy.unsigned_abs()) as u32 + 12;
            let mut shadow = RgbaImage::from_pixel(w + pad * 2, h + pad * 2, Rgba([0, 0, 0, 0]));
            let sa = (255.0 * opacity).round() as u8;
            for y in 0..h {
                for x in 0..w {
                    let sx = pad as i64 + x as i64 + ox;
                    let sy = pad as i64 + y as i64 + oy;
                    if sx >= 0 && sy >= 0 && (sx as u32) < shadow.width() && (sy as u32) < shadow.height() {
                        let a = ((src.get_pixel(x, y)[3] as u16 * sa as u16) / 255) as u8;
                        shadow.put_pixel(sx as u32, sy as u32, Rgba([col[0], col[1], col[2], a]));
                    }
                }
            }
            let mut blurred = DynamicImage::ImageRgba8(shadow).fast_blur((rad as f32 * 0.5).max(0.5)).to_rgba8();
            image::imageops::overlay(&mut blurred, &src, pad as i64, pad as i64);
            asset.image = DynamicImage::ImageRgba8(blurred);
        }
        node_type::DOCUMENT_ENHANCER | node_type::CONTRAST_STRETCH => {
            let mut rgba = asset.image.to_rgba8();
            let mut min_v = 255u8;
            let mut max_v = 0u8;
            for px in rgba.pixels() {
                let l = ((px[0] as u16 + px[1] as u16 + px[2] as u16) / 3) as u8;
                if l < min_v { min_v = l; }
                if l > max_v { max_v = l; }
            }
            let span = (max_v.saturating_sub(min_v)).max(1) as f64;
            for px in rgba.pixels_mut() {
                for c in 0..3 {
                    let norm = ((px[c].saturating_sub(min_v)) as f64 / span).clamp(0.0, 1.0);
                    px[c] = (norm * 255.0).round() as u8;
                }
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }

        // --- Metadata & Misc ---
        node_type::DELETE_METADATA => {
            asset.metadata_stripped = true;
            asset.gps_present = false;
            asset.author.clear();
            asset.copyright.clear();
        }
        node_type::REMOVE_GPS => {
            asset.gps_present = false;
        }
        node_type::SET_DPI => {
            asset.dpi = node.param_i64("dpi", 300).clamp(36, 1200) as u32;
        }
        node_type::SET_GENERAL_METADATA => {
            let author = node.param_str("author", "");
            let copy = node.param_str("copyright", "");
            if !author.is_empty() { asset.author = author; }
            if !copy.is_empty() { asset.copyright = copy; }
        }
        node_type::FIX_EXIF_ROTATION | node_type::LAYER_PAGE_SPLITTER => {}
        node_type::CHANGE_BITS_PER_CHANNEL => {
            asset.bits_per_channel = node.param_str("bits", "8").parse().unwrap_or(8);
        }
        node_type::DELAY => {
            if !is_preview {
                let secs = node.param_f64("seconds", 0.1).clamp(0.0, 2.0);
                std::thread::sleep(Duration::from_secs_f64(secs));
            }
        }
        node_type::EXTRACT_PORTRAIT_MATTE => {
            let mut rgba = asset.image.to_rgba8();
            for px in rgba.pixels_mut() {
                let l = (0.299 * px[0] as f32 + 0.587 * px[1] as f32 + 0.114 * px[2] as f32) as u8;
                let m = if l > 96 { 255 } else { 0 };
                px[0] = m;
                px[1] = m;
                px[2] = m;
            }
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::CUSTOM_CONVOLUTION => {
            let w_str = node.param_str("weights", "0,-1,0,-1,5,-1,0,-1,0");
            let vals: Vec<f32> = w_str
                .split(',')
                .filter_map(|s| s.trim().parse::<f32>().ok())
                .collect();
            if vals.len() == 9 {
                let mut kernel = [0f32; 9];
                kernel.copy_from_slice(&vals);
                asset.image = asset.image.filter3x3(&kernel);
            }
        }
        node_type::PDF_EXTRACTOR => {
            if let Some(pdf_bytes) = &asset.pdf_bytes {
                let imgs = extract_jpeg_images_from_pdf(pdf_bytes);
                if !imgs.is_empty() {
                    let mut out = Vec::with_capacity(imgs.len());
                    for (i, im) in imgs.into_iter().enumerate() {
                        let mut c = asset.clone();
                        c.image = im;
                        c.pdf_bytes = None;
                        c.extension = "jpg".into();
                        c.scale_suffix = format!("_page{}", i + 1);
                        out.push(c);
                    }
                    return Ok(out);
                }
            }
        }

        // --- Script ---
        node_type::JAVA_SCRIPT => {
            let code = node.param_str("script", "");
            // Safe zero-side-effect inline rule evaluator (supports fileName suffix & skip)
            if code.contains("asset.skip = true") {
                return Ok(vec![]);
            }
            if let Some(cap) = Regex::new(r#"asset\.fileName\s*\+=\s*["']([^"']+)["']"#)
                .ok()
                .and_then(|re| re.captures(&code))
            {
                asset.base_name.push_str(&cap[1]);
            }
        }
        node_type::SHELL_SCRIPT | node_type::APPLE_SCRIPT => {
            if !is_preview {
                let script = node.param_str("script", "");
                if !script.trim().is_empty() {
                    #[cfg(target_os = "windows")]
                    let output = Command::new("powershell")
                        .args(["-NoProfile", "-Command", &script])
                        .env("FLOWBATCH_FILE", &asset.base_name)
                        .output();
                    #[cfg(not(target_os = "windows"))]
                    let output = Command::new("/bin/sh")
                        .args(["-c", &script])
                        .env("FLOWBATCH_FILE", &asset.base_name)
                        .output();
                    if let Err(e) = output {
                        return Err(format!("Script launch failed: {e}"));
                    }
                }
            }
        }

        // --- Sharpen ---
        node_type::SHARPEN_LUMINANCE => {
            let r = node.param_f64("radius", 1.5).clamp(0.5, 5.0) as f32;
            let amt = (node.param_f64("sharpness", 0.6) * 15.0).round() as i32;
            asset.image = asset.image.unsharpen(r, amt.max(1));
        }
        node_type::UNSHARP_MASK => {
            let r = node.param_f64("radius", 2.0).clamp(0.5, 10.0) as f32;
            let amt = (node.param_f64("intensity", 0.8) * 18.0).round() as i32;
            asset.image = asset.image.unsharpen(r, amt.max(1));
        }

        // --- Classify ---
        node_type::CLASSIFY_IMAGES => {
            let max_labels = node.param_i64("maxLabels", 3).clamp(1, 10) as usize;
            asset.classifications = classify_heuristics(&asset.image, max_labels);
        }

        // --- Transform ---
        node_type::SCALE => {
            let mode = node.param_str("mode", "Fixed Width");
            let allow_up = node.param_bool("allowUpscale", true);
            let (w, h) = asset.image.dimensions();
            let (mut nw, mut nh) = match mode.as_str() {
                "Fixed Width" => {
                    let tw = node.param_i64("width", 800).max(1) as u32;
                    let th = ((h as f64 * tw as f64) / w.max(1) as f64).round().max(1.0) as u32;
                    (tw, th)
                }
                "Fixed Height" => {
                    let th = node.param_i64("height", 600).max(1) as u32;
                    let tw = ((w as f64 * th as f64) / h.max(1) as f64).round().max(1.0) as u32;
                    (tw, th)
                }
                "Percentage" => {
                    let pct = node.param_f64("percent", 50.0).clamp(1.0, 400.0) / 100.0;
                    (((w as f64 * pct).round() as u32).max(1), ((h as f64 * pct).round() as u32).max(1))
                }
                _ => {
                    let bw = node.param_i64("width", 800).max(1) as f64;
                    let bh = node.param_i64("height", 600).max(1) as f64;
                    let factor = (bw / w.max(1) as f64).min(bh / h.max(1) as f64);
                    (((w as f64 * factor).round() as u32).max(1), ((h as f64 * factor).round() as u32).max(1))
                }
            };
            if !allow_up && (nw > w || nh > h) {
                nw = w;
                nh = h;
            }
            if nw != w || nh != h {
                asset.image = asset.image.resize_exact(nw, nh, FilterType::Lanczos3);
            }
        }
        node_type::CROP => {
            let mode = node.param_str("mode", "Fixed Size");
            let anchor = node.param_str("anchor", "center");
            let (w, h) = asset.image.dimensions();
            let (cw, ch) = if mode == "Aspect Ratio" {
                let (ar_w, ar_h) = match node.param_str("aspectRatio", "1:1").as_str() {
                    "4:3" => (4.0, 3.0),
                    "16:9" => (16.0, 9.0),
                    "3:2" => (3.0, 2.0),
                    _ => (1.0, 1.0),
                };
                let target_ratio = ar_w / ar_h;
                let cur_ratio = w as f64 / h.max(1) as f64;
                if cur_ratio > target_ratio {
                    (((h as f64 * target_ratio).round() as u32).min(w), h)
                } else {
                    (w, ((w as f64 / target_ratio).round() as u32).min(h))
                }
            } else {
                (
                    (node.param_i64("width", 600).max(1) as u32).min(w),
                    (node.param_i64("height", 600).max(1) as u32).min(h),
                )
            };
            let (ox, oy) = anchor_origin(&anchor, w, h, cw, ch, 0, 0);
            asset.image = asset.image.crop_imm(ox, oy, cw.max(1), ch.max(1));
        }
        node_type::ROTATE => {
            let deg = ((node.param_f64("degrees", 90.0).round() as i32) % 360 + 360) % 360;
            asset.image = match deg {
                90 => asset.image.rotate90(),
                180 => asset.image.rotate180(),
                270 => asset.image.rotate270(),
                0 => asset.image,
                _ => {
                    let bg = node.param_color("backgroundColor", CodableColor::CLEAR).to_rgba8();
                    DynamicImage::ImageRgba8(rotate_arbitrary(&asset.image.to_rgba8(), deg as f64, bg))
                }
            };
        }
        node_type::FLIP => {
            let dir = node.param_str("direction", "Horizontal");
            asset.image = if dir == "Vertical" {
                asset.image.flipv()
            } else {
                asset.image.fliph()
            };
        }
        node_type::TRIM_TO_EDGES => {
            let thresh = (node.param_f64("alphaThreshold", 0.05) * 255.0).round() as u8;
            let rgba = asset.image.to_rgba8();
            let (w, h) = rgba.dimensions();
            let (mut min_x, mut min_y, mut max_x, mut max_y) = (w, h, 0u32, 0u32);
            for (x, y, p) in rgba.enumerate_pixels() {
                if p[3] > thresh {
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x);
                    max_y = max_y.max(y);
                }
            }
            if max_x >= min_x && max_y >= min_y {
                asset.image = asset.image.crop_imm(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1);
            }
        }
        node_type::ML_SUPER_RESOLUTION => {
            let mult: u32 = if node.param_str("multiplier", "2x") == "4x" { 4 } else { 2 };
            let sharp = node.param_f64("edgeSharpen", 0.5) as f32;
            let (w, h) = asset.image.dimensions();
            let up = asset.image.resize_exact((w * mult).min(8192), (h * mult).min(8192), FilterType::Lanczos3);
            asset.image = if sharp > 0.05 {
                up.unsharpen(1.2, (sharp * 10.0) as i32)
            } else {
                up
            };
        }

        // --- Watermark ---
        node_type::TEXT_WATERMARK => {
            let raw_text = node.param_str("text", "@ FlowBatch Sample");
            let text = expand_tokens(&raw_text, &asset, 1);
            let font_size = node.param_f64("fontSize", 28.0).clamp(8.0, 120.0);
            let color = node.param_color("color", CodableColor::WHITE).to_rgba8();
            let opacity = node.param_f64("opacity", 0.75).clamp(0.0, 1.0);
            let anchor = node.param_str("anchor", "bottomRight");
            let mx = node.param_i64("marginX", 28).max(0) as u32;
            let my = node.param_i64("marginY", 24).max(0) as u32;
            let tile = node.param_bool("tile", false);
            let mut rgba = asset.image.to_rgba8();
            draw_text_watermark(&mut rgba, &text, font_size, color, opacity, &anchor, mx, my, tile);
            asset.image = DynamicImage::ImageRgba8(rgba);
        }
        node_type::IMAGE_WATERMARK => {
            let wm_path = node.param_str("imagePath", "");
            if !wm_path.trim().is_empty() && Path::new(&wm_path).exists() {
                if let Ok(wm_img) = image::open(&wm_path) {
                    let pct = node.param_f64("scalePercent", 25.0).clamp(5.0, 100.0) / 100.0;
                    let opacity = node.param_f64("opacity", 0.8).clamp(0.0, 1.0);
                    let anchor = node.param_str("anchor", "bottomRight");
                    let mx = node.param_i64("marginX", 24).max(0) as u32;
                    let my = node.param_i64("marginY", 24).max(0) as u32;
                    let mut base = asset.image.to_rgba8();
                    let (bw, bh) = base.dimensions();
                    let tw = ((bw as f64 * pct).round() as u32).max(8);
                    let th = ((wm_img.height() as f64 * tw as f64) / wm_img.width().max(1) as f64).round().max(8.0) as u32;
                    let mut wm = wm_img.resize_exact(tw, th, FilterType::Lanczos3).to_rgba8();
                    for p in wm.pixels_mut() {
                        p[3] = (p[3] as f64 * opacity).round() as u8;
                    }
                    let (ox, oy) = anchor_origin(&anchor, bw, bh, tw, th, mx, my);
                    image::imageops::overlay(&mut base, &wm, ox as i64, oy as i64);
                    asset.image = DynamicImage::ImageRgba8(base);
                }
            }
        }
        _ => {}
    }

    Ok(vec![asset])
}

fn apply_exposure_inplace(rgba: &mut RgbaImage, ev: f64) {
    let mult = 2.0f64.powf(ev);
    for px in rgba.pixels_mut() {
        for c in 0..3 {
            px[c] = (px[c] as f64 * mult).clamp(0.0, 255.0).round() as u8;
        }
    }
}

fn apply_temp_tint_inplace(rgba: &mut RgbaImage, temp: f64, tint: f64) {
    let warm = ((temp - 6500.0) / 3500.0).clamp(-1.0, 1.0);
    let t_shift = (tint / 100.0).clamp(-1.0, 1.0);
    for px in rgba.pixels_mut() {
        let r = px[0] as f64 + warm * 28.0 + t_shift * 14.0;
        let g = px[1] as f64 - t_shift * 16.0;
        let b = px[2] as f64 - warm * 28.0 + t_shift * 10.0;
        px[0] = r.clamp(0.0, 255.0).round() as u8;
        px[1] = g.clamp(0.0, 255.0).round() as u8;
        px[2] = b.clamp(0.0, 255.0).round() as u8;
    }
}

fn apply_motion_blur(src: &RgbaImage, radius: i32, angle_rad: f64) -> RgbaImage {
    let (w, h) = src.dimensions();
    let mut out = RgbaImage::new(w, h);
    let dx = angle_rad.cos();
    let dy = angle_rad.sin();
    let steps = radius.clamp(1, 20);
    for y in 0..h {
        for x in 0..w {
            let mut sums = [0u32; 4];
            let mut count = 0u32;
            for k in -steps..=steps {
                let sx = (x as f64 + k as f64 * dx).round() as i64;
                let sy = (y as f64 + k as f64 * dy).round() as i64;
                if sx >= 0 && sy >= 0 && (sx as u32) < w && (sy as u32) < h {
                    let p = src.get_pixel(sx as u32, sy as u32);
                    for c in 0..4 { sums[c] += p[c] as u32; }
                    count += 1;
                }
            }
            let c = count.max(1);
            out.put_pixel(x, y, Rgba([(sums[0] / c) as u8, (sums[1] / c) as u8, (sums[2] / c) as u8, (sums[3] / c) as u8]));
        }
    }
    out
}

fn rotate_arbitrary(src: &RgbaImage, deg: f64, bg: [u8; 4]) -> RgbaImage {
    let (w, h) = src.dimensions();
    let mut out = RgbaImage::from_pixel(w, h, Rgba(bg));
    let rad = -deg.to_radians();
    let (sin_a, cos_a) = rad.sin_cos();
    let cx = w as f64 * 0.5;
    let cy = h as f64 * 0.5;
    for y in 0..h {
        for x in 0..w {
            let dx = x as f64 - cx;
            let dy = y as f64 - cy;
            let sx = (dx * cos_a - dy * sin_a + cx).round() as i64;
            let sy = (dx * sin_a + dy * cos_a + cy).round() as i64;
            if sx >= 0 && sy >= 0 && (sx as u32) < w && (sy as u32) < h {
                out.put_pixel(x, y, *src.get_pixel(sx as u32, sy as u32));
            }
        }
    }
    out
}

fn classify_heuristics(img: &DynamicImage, max_labels: usize) -> Vec<String> {
    let small = img.thumbnail(64, 64).to_rgba8();
    let mut sum_r = 0u64;
    let mut sum_g = 0u64;
    let mut sum_b = 0u64;
    let mut sum_sat = 0f64;
    let total = (small.width() * small.height()).max(1) as f64;
    for p in small.pixels() {
        sum_r += p[0] as u64;
        sum_g += p[1] as u64;
        sum_b += p[2] as u64;
        let mx = p[0].max(p[1]).max(p[2]) as f64;
        let mn = p[0].min(p[1]).min(p[2]) as f64;
        sum_sat += mx - mn;
    }
    let avg_r = sum_r as f64 / total;
    let avg_g = sum_g as f64 / total;
    let avg_b = sum_b as f64 / total;
    let avg_luma = 0.299 * avg_r + 0.587 * avg_g + 0.114 * avg_b;
    let avg_sat = sum_sat / total;

    let mut labels = Vec::new();
    let (w, h) = img.dimensions();
    if w > h { labels.push("landscape".into()); } else if h > w { labels.push("portrait".into()); } else { labels.push("square".into()); }
    if avg_sat < 14.0 { labels.push("monochrome".into()); }
    if avg_r > avg_b + 24.0 && avg_g > avg_b { labels.push("sunset".into()); }
    if avg_b > avg_r + 18.0 { labels.push("sky_ocean".into()); }
    if avg_luma < 75.0 { labels.push("night".into()); }
    labels.truncate(max_labels);
    labels
}

fn anchor_origin(anchor: &str, bw: u32, bh: u32, ow: u32, oh: u32, mx: u32, my: u32) -> (u32, u32) {
    let x = match anchor {
        "topLeft" | "middleLeft" | "bottomLeft" => mx.min(bw.saturating_sub(ow)),
        "topRight" | "middleRight" | "bottomRight" => bw.saturating_sub(ow + mx),
        _ => bw.saturating_sub(ow) / 2,
    };
    let y = match anchor {
        "topLeft" | "topCenter" | "topRight" => my.min(bh.saturating_sub(oh)),
        "bottomLeft" | "bottomCenter" | "bottomRight" => bh.saturating_sub(oh + my),
        _ => bh.saturating_sub(oh) / 2,
    };
    (x, y)
}

/// Crisp embedded 5×7 ASCII bitmap font renderer for zero-dependency cross-platform Text Watermark.
fn glyph_5x7(ch: char) -> [u8; 7] {
    match ch.to_ascii_uppercase() {
        'A' => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'B' => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        'C' => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        'D' => [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
        'E' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        'F' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        'G' => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
        'H' => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'I' => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        'J' => [0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0C],
        'K' => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L' => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        'M' => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N' => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
        'O' => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'P' => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        'Q' => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        'R' => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        'S' => [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
        'T' => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'V' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        'W' => [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
        'X' => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        'Y' => [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        'Z' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        '0' => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        '1' => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        '2' => [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
        '3' => [0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E],
        '4' => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        '5' => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        '6' => [0x0E, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x0E],
        '7' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        '9' => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        '@' | '©' => [0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E],
        '-' => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        '_' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
        ':' => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
        '/' => [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
        ' ' => [0x00; 7],
        _ => [0x0E, 0x11, 0x01, 0x06, 0x04, 0x00, 0x04],
    }
}

fn draw_text_watermark(
    img: &mut RgbaImage,
    text: &str,
    font_size: f64,
    color: [u8; 4],
    opacity: f64,
    anchor: &str,
    mx: u32,
    my: u32,
    tile: bool,
) {
    if text.is_empty() {
        return;
    }
    let scale = (font_size / 11.0).round().clamp(1.0, 10.0) as u32;
    let char_w = 6 * scale;
    let text_w = (text.chars().count() as u32) * char_w;
    let text_h = 7 * scale;
    let (bw, bh) = img.dimensions();

    let positions: Vec<(u32, u32)> = if tile {
        let mut pts = Vec::new();
        let step_x = (text_w + 80).max(120);
        let step_y = (text_h + 70).max(80);
        let mut y = 32;
        while y < bh {
            let mut x = 32;
            while x < bw {
                pts.push((x, y));
                x += step_x;
            }
            y += step_y;
        }
        pts
    } else {
        vec![anchor_origin(anchor, bw, bh, text_w, text_h, mx, my)]
    };

    let alpha = (opacity * (color[3] as f64 / 255.0)).clamp(0.0, 1.0) as f32;

    for (ox, oy) in positions {
        for (ci, ch) in text.chars().enumerate() {
            let rows = glyph_5x7(ch);
            for (ry, &bits) in rows.iter().enumerate() {
                for rx in 0..5u32 {
                    if (bits >> (4 - rx)) & 1 == 1 {
                        for sy in 0..scale {
                            for sx in 0..scale {
                                let px = ox + ci as u32 * char_w + rx * scale + sx;
                                let py = oy + ry as u32 * scale + sy;
                                // Subtle 1px dark drop shadow for readability
                                if px + 1 < bw && py + 1 < bh {
                                    let sp = img.get_pixel_mut(px + 1, py + 1);
                                    let sa = alpha * 0.45;
                                    for c in 0..3 {
                                        sp[c] = (sp[c] as f32 * (1.0 - sa)).round() as u8;
                                    }
                                }
                                if px < bw && py < bh {
                                    let dst = img.get_pixel_mut(px, py);
                                    for c in 0..3 {
                                        dst[c] = (color[c] as f32 * alpha + dst[c] as f32 * (1.0 - alpha)).round() as u8;
                                    }
                                    dst[3] = 255;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
