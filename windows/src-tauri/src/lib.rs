pub mod catalog;
pub mod models;
pub mod pdf_writer;
pub mod pipeline;
pub mod png_indexed;

use crate::models::{
    BatchRunResult, DryRunReport, NodeDefinition, PreviewResponse, WorkflowDocumentModel,
};
use std::fs;
use std::path::PathBuf;
use tauri::Manager;

#[tauri::command]
fn get_catalog() -> Vec<NodeDefinition> {
    catalog::all_definitions()
}

#[tauri::command]
fn get_output_formats() -> Vec<String> {
    catalog::output_formats()
}

#[tauri::command]
fn create_starter_workflow(app: tauri::AppHandle) -> Result<WorkflowDocumentModel, String> {
    let base = app
        .path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("FlowBatchStudio"));
    let demo_root = pipeline::ensure_demo_assets(&base)?;
    Ok(pipeline::create_starter_document(&demo_root))
}

#[tauri::command]
fn dry_run_workflow(document: WorkflowDocumentModel) -> DryRunReport {
    pipeline::dry_run(&document)
}

#[tauri::command]
fn load_thumbnail(path: String, max_px: Option<u32>) -> Result<String, String> {
    pipeline::load_thumbnail_data_url(&path, max_px.unwrap_or(256))
}

#[tauri::command]
fn render_preview(
    document: WorkflowDocumentModel,
    target_node_id: Option<String>,
    asset_path: Option<String>,
) -> PreviewResponse {
    pipeline::render_preview(
        &document,
        target_node_id.as_deref(),
        asset_path.as_deref(),
    )
}

#[tauri::command]
fn run_batch_workflow(document: WorkflowDocumentModel) -> BatchRunResult {
    pipeline::run_batch(&document)
}

#[tauri::command]
fn save_workflow_file(path: String, document: WorkflowDocumentModel) -> Result<(), String> {
    let json = serde_json::to_string_pretty(&document).map_err(|e| e.to_string())?;
    fs::write(&path, json).map_err(|e| format!("Failed to save workflow: {e}"))
}

#[tauri::command]
fn load_workflow_file(path: String) -> Result<WorkflowDocumentModel, String> {
    let raw = fs::read_to_string(&path).map_err(|e| format!("Failed to read workflow: {e}"))?;
    let mut doc: WorkflowDocumentModel =
        serde_json::from_str(&raw).map_err(|e| format!("Invalid .flowbatch JSON: {e}"))?;
    if doc.document_title.trim().is_empty() {
        doc.document_title = PathBuf::from(&path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Workflow.flowbatch")
            .to_string();
    }
    Ok(doc)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_catalog,
            get_output_formats,
            create_starter_workflow,
            dry_run_workflow,
            load_thumbnail,
            render_preview,
            run_batch_workflow,
            save_workflow_file,
            load_workflow_file
        ])
        .run(tauri::generate_context!())
        .expect("error while running FlowBatch Studio");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::node_type;
    use crate::models::{
        FilterRule, NodeCategory, NodeParamValue, RuleField, RuleOperator, ScaleBranchSpec,
        WorkflowEdge, WorkflowNode,
    };
    use crate::pdf_writer::{build_multipage_pdf, extract_jpeg_images_from_pdf};
    use crate::png_indexed::{encode_indexed_png, IndexedPngOptions};
    use image::{DynamicImage, Rgba, RgbaImage};
    use std::collections::HashSet;

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flowbatch_win_test_{name}_{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn test_catalog_has_all_67_nodes_across_15_categories() {
        let defs = catalog::all_definitions();
        assert_eq!(defs.len(), 67, "Expected exactly 67 built-in nodes");
        let unique_ids: HashSet<&str> = defs.iter().map(|d| d.type_id.as_str()).collect();
        assert_eq!(unique_ids.len(), 67, "Duplicate node typeIDs found");
        let cats: HashSet<NodeCategory> = defs.iter().map(|d| d.category).collect();
        assert_eq!(cats.len(), 15, "Expected all 15 categories");
    }

    #[test]
    fn test_swift_codable_flowbatch_json_roundtrip() {
        // Exact Swift Codable JSON format emitted by macOS FlowBatch Studio
        let swift_json = r#"{
            "schemaVersion": 1,
            "documentTitle": "Watermark Images.flowbatch",
            "nodes": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "typeID": "watermark.text",
                    "title": "Text Watermark",
                    "position": { "x": 196, "y": 150 },
                    "isEnabled": true,
                    "errorPolicy": "Skip Asset",
                    "parameters": {
                        "text": { "string": { "_0": "@ FlowBatch Sample" } },
                        "fontSize": { "double": { "_0": 28.0 } },
                        "marginX": { "int": { "_0": 28 } },
                        "tile": { "bool": { "_0": false } }
                    }
                }
            ],
            "edges": [],
            "viewportOffset": { "x": 0, "y": 0 },
            "viewportZoom": 1.0
        }"#;

        let parsed: WorkflowDocumentModel = serde_json::from_str(swift_json).expect("Parse Swift JSON");
        assert_eq!(parsed.document_title, "Watermark Images.flowbatch");
        assert_eq!(parsed.nodes[0].param_str("text", ""), "@ FlowBatch Sample");
        assert_eq!(parsed.nodes[0].param_i64("marginX", 0), 28);
        assert_eq!(parsed.nodes[0].param_f64("fontSize", 0.0), 28.0);
        assert!(!parsed.nodes[0].param_bool("tile", true));

        // Re-serialize and confirm Swift-tagged `_0` wrapper is preserved!
        let re_json = serde_json::to_string(&parsed).unwrap();
        assert!(re_json.contains("\"_0\":\"@ FlowBatch Sample\""));
        let reparsed: WorkflowDocumentModel = serde_json::from_str(&re_json).unwrap();
        assert_eq!(parsed, reparsed);
    }

    #[test]
    fn test_cycle_detection_and_multi_scale_60_writes() {
        let dir = temp_test_dir("multiscale");
        let demo = pipeline::ensure_demo_assets(&dir).unwrap();
        let mut doc = pipeline::create_starter_document(&demo);

        // Starter graph must read 30 and write 30
        let dr = pipeline::dry_run(&doc);
        assert_eq!(dr.total_to_read, 30);
        assert_eq!(dr.total_to_write, 30);
        assert_eq!(dr.status_summary, "30 assets ready to read, 30 to write.");

        // Cycle prevention: Write -> Read1 must be rejected
        let read1_id = doc.nodes[0].id.clone();
        let write_id = doc.nodes[4].id.clone();
        assert!(!doc.can_connect(&write_id, &read1_id));
        assert!(!doc.can_connect(&read1_id, &read1_id));

        // Insert Multi Scale (1x + 2x) between Scale and Write -> 60 to write!
        let scale_id = doc.nodes[3].id.clone();
        let ms = WorkflowNode::new(node_type::MULTI_SCALE, 440.0, 66.0).with_param(
            "scales",
            NodeParamValue::Scales(vec![
                ScaleBranchSpec { id: "1".into(), label: "1x".into(), scale_factor: 1.0, suffix: "".into() },
                ScaleBranchSpec { id: "2".into(), label: "2x".into(), scale_factor: 2.0, suffix: "@2x".into() },
            ]),
        );
        let ms_id = ms.id.clone();
        doc.edges.retain(|e| !(e.source_node_id == scale_id && e.target_node_id == write_id));
        doc.nodes.push(ms);
        doc.edges.push(WorkflowEdge::new(&scale_id, &ms_id));
        doc.edges.push(WorkflowEdge::new(&ms_id, &write_id));

        let dr2 = pipeline::dry_run(&doc);
        assert_eq!(dr2.total_to_read, 30);
        assert_eq!(dr2.total_to_write, 60);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_indexed_png_color_type_3_and_oxipng_crush() {
        let mut rgba = RgbaImage::new(128, 96);
        for (x, y, px) in rgba.enumerate_pixels_mut() {
            *px = Rgba([(x * 2) as u8, (y * 2) as u8, ((x + y) % 255) as u8, if x < 16 { 128 } else { 255 }]);
        }
        let bytes = encode_indexed_png(
            &rgba,
            &IndexedPngOptions {
                max_colors: 64,
                speed: 1,
                dither: true,
                remove_alpha_if_opaque: true,
                crush: true,
                brute_force_crush: false,
                remove_color_profile: false,
            },
        )
        .expect("Indexed PNG encoding should succeed");

        assert_eq!(&bytes[0..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        assert_eq!(bytes[25], 3, "IHDR color type must be 3 (Indexed)");
        assert!(bytes.windows(4).any(|w| w == b"PLTE"), "PLTE chunk missing");
        assert!(bytes.windows(4).any(|w| w == b"tRNS"), "tRNS chunk missing for semi-transparent pixels");
        assert!(image::load_from_memory(&bytes).is_ok(), "Decoded back cleanly by image crate");
    }

    #[test]
    fn test_pdf_maker_and_extractor_roundtrip() {
        let img1 = DynamicImage::ImageRgba8(RgbaImage::from_pixel(200, 120, Rgba([240, 120, 40, 255])));
        let img2 = DynamicImage::ImageRgba8(RgbaImage::from_pixel(160, 160, Rgba([40, 140, 220, 255])));
        let pdf = build_multipage_pdf(&[img1, img2], 18.0).expect("PDF build failed");
        assert!(pdf.starts_with(b"%PDF-1.4"));
        assert!(pdf.windows(5).any(|w| w == b"%%EOF"));
        let extracted = extract_jpeg_images_from_pdf(&pdf);
        assert_eq!(extracted.len(), 2);
        assert_eq!(extracted[0].width(), 200);
        assert_eq!(extracted[1].width(), 160);
    }

    #[test]
    fn test_rules_dual_port_routing_and_full_30_asset_export() {
        let dir = temp_test_dir("export30");
        let demo = pipeline::ensure_demo_assets(&dir).unwrap();
        let out_dir = dir.join("out");
        let mut doc = pipeline::create_starter_document(&demo);

        // Redirect Write Images to temp out_dir & disable openFolderWhenFinished
        if let Some(w) = doc.nodes.iter_mut().find(|n| n.type_id == node_type::WRITE_IMAGES) {
            w.parameters.insert("folderPath".into(), NodeParamValue::String(out_dir.to_string_lossy().to_string()));
            w.parameters.insert("openFolderWhenFinished".into(), NodeParamValue::Bool(false));
        }

        let res = pipeline::run_batch(&doc);
        assert_eq!(res.processed_assets, 30);
        assert_eq!(res.written_files.len(), 30);
        assert!(res.node_errors.is_empty());

        // Verify first output is scaled to 800px wide & valid PNG
        let first_img = image::open(&res.written_files[0]).unwrap();
        assert_eq!(first_img.width(), 800);

        // Verify Rules dual-port routing
        let read_only = WorkflowNode::new(node_type::READ_FOLDER, 0.0, 0.0)
            .with_param("folderPath", NodeParamValue::String(demo.join("Aug 9 Shots").to_string_lossy().to_string()));
        let rules = WorkflowNode::new(node_type::RULES, 180.0, 0.0).with_param(
            "rules",
            NodeParamValue::Rules(vec![FilterRule {
                id: "r1".into(),
                field: RuleField::FileName,
                op: RuleOperator::Contains,
                value: "01".into(),
            }]),
        );
        let out_matched = dir.join("matched");
        let out_other = dir.join("other");
        let wm = WorkflowNode::new(node_type::WRITE_IMAGES, 360.0, 0.0)
            .with_param("folderPath", NodeParamValue::String(out_matched.to_string_lossy().to_string()))
            .with_param("openFolderWhenFinished", NodeParamValue::Bool(false));
        let wo = WorkflowNode::new(node_type::WRITE_IMAGES, 360.0, 120.0)
            .with_param("folderPath", NodeParamValue::String(out_other.to_string_lossy().to_string()))
            .with_param("openFolderWhenFinished", NodeParamValue::Bool(false));

        let rdoc = WorkflowDocumentModel {
            schema_version: 1,
            document_title: "RulesTest.flowbatch".into(),
            edges: vec![
                WorkflowEdge::new(&read_only.id, &rules.id),
                WorkflowEdge::new(&rules.id, &wm.id).with_source_port(0),
                WorkflowEdge::new(&rules.id, &wo.id).with_source_port(1),
            ],
            nodes: vec![read_only, rules, wm, wo],
            viewport_offset: Default::default(),
            viewport_zoom: 1.0,
        };
        let rres = pipeline::run_batch(&rdoc);
        assert_eq!(rres.written_files.len(), 16);
        assert_eq!(pipeline::list_image_files(&out_matched, false, "").len(), 1);
        assert_eq!(pipeline::list_image_files(&out_other, false, "").len(), 15);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_all_67_catalog_nodes_smoke_executed() {
        let dir = temp_test_dir("smoke67");
        let defs = catalog::all_definitions();
        let mut covered = HashSet::new();

        for def in &defs {
            covered.insert(def.type_id.clone());
            let blank = WorkflowNode::new(node_type::BLANK_IMAGE, 0.0, 0.0)
                .with_param("width", NodeParamValue::Int(64))
                .with_param("height", NodeParamValue::Int(48));
            let mut target = WorkflowNode::new(&def.type_id, 180.0, 0.0);
            if def.type_id == node_type::WRITE_IMAGES {
                target.parameters.insert(
                    "folderPath".into(),
                    NodeParamValue::String(dir.join("out").to_string_lossy().to_string()),
                );
                target.parameters.insert("openFolderWhenFinished".into(), NodeParamValue::Bool(false));
            }
            if def.type_id == node_type::DELAY {
                target.parameters.insert("seconds".into(), NodeParamValue::Double(0.0));
            }
            if def.type_id == node_type::SHELL_SCRIPT || def.type_id == node_type::APPLE_SCRIPT {
                target.parameters.insert("script".into(), NodeParamValue::String(String::new()));
            }
            let doc = if def.is_source {
                WorkflowDocumentModel {
                    schema_version: 1,
                    document_title: "Smoke.flowbatch".into(),
                    nodes: vec![target],
                    edges: vec![],
                    viewport_offset: Default::default(),
                    viewport_zoom: 1.0,
                }
            } else {
                let edges = vec![WorkflowEdge::new(&blank.id, &target.id)];
                WorkflowDocumentModel {
                    schema_version: 1,
                    document_title: "Smoke.flowbatch".into(),
                    nodes: vec![blank, target],
                    edges,
                    viewport_offset: Default::default(),
                    viewport_zoom: 1.0,
                }
            };
            let res = pipeline::run_batch(&doc);
            assert!(
                res.node_errors.is_empty(),
                "Node {} produced unexpected error: {:?}",
                def.type_id,
                res.node_errors
            );
        }

        assert_eq!(covered.len(), 67);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_all_example_flowbatch_recipes_parse_and_dry_run() {
        let examples_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("examples");
        let mut count = 0usize;
        for entry in fs::read_dir(&examples_dir).expect("read examples dir") {
            let path = entry.expect("dir entry").path();
            if path.extension().and_then(|s| s.to_str()) == Some("flowbatch") {
                let raw = fs::read_to_string(&path).expect("read example .flowbatch");
                let doc: WorkflowDocumentModel = serde_json::from_str(&raw)
                    .unwrap_or_else(|e| panic!("Failed to parse {}: {}", path.display(), e));
                assert!(!doc.nodes.is_empty(), "Empty nodes in {}", path.display());
                assert_eq!(
                    doc.topological_order().len(),
                    doc.nodes.len(),
                    "Cycle detected in {}",
                    path.display()
                );
                let report = pipeline::dry_run(&doc);
                assert!(!report.status_summary.is_empty());
                count += 1;
            }
        }
        assert!(count >= 5, "Expected at least 5 example .flowbatch workflows");
    }
}
