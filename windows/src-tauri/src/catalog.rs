use crate::models::{
    CodableColor, FilterRule, NodeCategory, NodeDefinition, NodeParamValue, ParameterControlKind,
    ParameterDescriptor, RuleField, RuleOperator, ScaleBranchSpec,
};

pub mod node_type {
    pub const READ_FOLDER: &str = "read.folder";
    pub const READ_FILES: &str = "read.files";
    pub const PROMPT_FOR_FILES: &str = "read.prompt";
    pub const READ_CLIPBOARD: &str = "read.clipboard";
    pub const RAW_PROCESS: &str = "read.raw";

    pub const WRITE_IMAGES: &str = "write.images";
    pub const WRITE_CLIPBOARD: &str = "write.clipboard";
    pub const OPEN_IN_APP: &str = "write.openInApp";
    pub const MULTI_SCALE: &str = "write.multiScale";

    pub const GAUSSIAN_BLUR: &str = "blur.gaussian";
    pub const BOX_BLUR: &str = "blur.box";
    pub const MOTION_BLUR: &str = "blur.motion";
    pub const NOISE_REDUCTION: &str = "blur.noiseReduction";
    pub const PIXELATE: &str = "blur.pixelate";

    pub const EXPOSURE: &str = "color.exposure";
    pub const BRIGHTNESS_CONTRAST: &str = "color.brightnessContrast";
    pub const VIBRANCE: &str = "color.vibrance";
    pub const GAMMA: &str = "color.gamma";
    pub const TEMPERATURE_TINT: &str = "color.temperatureTint";
    pub const SHADOWS_HIGHLIGHTS: &str = "color.shadowsHighlights";
    pub const COLOR_PROFILE: &str = "color.profile";

    pub const PHOTO_EFFECT: &str = "effect.photoEffect";
    pub const SEPIA: &str = "effect.sepia";
    pub const COLOR_INVERT: &str = "effect.invert";
    pub const COLOR_POSTERIZE: &str = "effect.posterize";
    pub const ONE_BIT: &str = "effect.oneBit";
    pub const DITHER: &str = "effect.dither";
    pub const MATTE: &str = "effect.matte";
    pub const ADD_BORDER: &str = "effect.addBorder";
    pub const DROP_SHADOW: &str = "effect.dropShadow";
    pub const DOCUMENT_ENHANCER: &str = "effect.documentEnhancer";

    pub const BLANK_IMAGE: &str = "generator.blank";
    pub const SCREENSHOT: &str = "generator.screenshot";
    pub const IMAGE_GRID: &str = "generator.imageGrid";
    pub const ANIMATED_IMAGE: &str = "generator.animatedImage";

    pub const DELETE_METADATA: &str = "metadata.delete";
    pub const REMOVE_GPS: &str = "metadata.removeGPS";
    pub const SET_DPI: &str = "metadata.setDPI";
    pub const SET_GENERAL_METADATA: &str = "metadata.setGeneral";
    pub const FIX_EXIF_ROTATION: &str = "metadata.fixRotation";

    pub const CHANGE_BITS_PER_CHANNEL: &str = "misc.bitsPerChannel";
    pub const DUPLICATE: &str = "misc.duplicate";
    pub const DELAY: &str = "misc.delay";
    pub const LAYER_PAGE_SPLITTER: &str = "misc.splitLayers";
    pub const EXTRACT_PORTRAIT_MATTE: &str = "misc.portraitMatte";
    pub const CONTRAST_STRETCH: &str = "misc.contrastStretch";
    pub const CUSTOM_CONVOLUTION: &str = "misc.convolution";

    pub const PDF_MAKER: &str = "pdf.maker";
    pub const PDF_EXTRACTOR: &str = "pdf.extractor";

    pub const READ_PHOTOS_LIBRARY: &str = "photos.read";
    pub const IMPORT_TO_PHOTOS: &str = "photos.import";

    pub const JAVA_SCRIPT: &str = "script.javascript";
    pub const SHELL_SCRIPT: &str = "script.shell";
    pub const APPLE_SCRIPT: &str = "script.applescript";

    pub const SHARPEN_LUMINANCE: &str = "sharpen.luminance";
    pub const UNSHARP_MASK: &str = "sharpen.unsharpMask";

    pub const RULES: &str = "sort.rules";
    pub const CLASSIFY_IMAGES: &str = "sort.classify";
    pub const SORT_ORDER: &str = "sort.order";

    pub const SCALE: &str = "transform.scale";
    pub const CROP: &str = "transform.crop";
    pub const ROTATE: &str = "transform.rotate";
    pub const FLIP: &str = "transform.flip";
    pub const TRIM_TO_EDGES: &str = "transform.trim";
    pub const ML_SUPER_RESOLUTION: &str = "transform.superResolution";

    pub const TEXT_WATERMARK: &str = "watermark.text";
    pub const IMAGE_WATERMARK: &str = "watermark.image";
}

fn p_str(key: &str, label: &str, placeholder: &str, def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::Text {
            placeholder: placeholder.into(),
        },
        default_value: NodeParamValue::String(def.into()),
    }
}

fn p_code(key: &str, label: &str, lang: &str, def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::MultilineCode {
            language: lang.into(),
        },
        default_value: NodeParamValue::String(def.into()),
    }
}

fn p_folder(key: &str, label: &str, def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::FolderPath,
        default_value: NodeParamValue::String(def.into()),
    }
}

fn p_file(key: &str, label: &str, exts: &[&str]) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::FilePath {
            allowed_extensions: exts.iter().map(|s| (*s).to_string()).collect(),
        },
        default_value: NodeParamValue::String(String::new()),
    }
}

fn p_toggle(key: &str, label: &str, def: bool) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::Toggle,
        default_value: NodeParamValue::Bool(def),
    }
}

fn p_slider(key: &str, label: &str, min: f64, max: f64, step: f64, unit: &str, def: f64) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::Slider {
            min,
            max,
            step,
            unit: unit.into(),
        },
        default_value: NodeParamValue::Double(def),
    }
}

fn p_int(key: &str, label: &str, min: i64, max: i64, unit: &str, def: i64) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::IntSlider {
            min,
            max,
            unit: unit.into(),
        },
        default_value: NodeParamValue::Int(def),
    }
}

fn p_picker(key: &str, label: &str, options: &[&str], def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::Picker {
            options: options.iter().map(|s| (*s).to_string()).collect(),
        },
        default_value: NodeParamValue::String(def.into()),
    }
}

fn p_color(key: &str, label: &str, def: CodableColor) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::Color,
        default_value: NodeParamValue::Color(def),
    }
}

fn p_anchor(key: &str, label: &str, def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::AnchorGrid,
        default_value: NodeParamValue::String(def.into()),
    }
}

fn p_token(key: &str, label: &str, def: &str) -> ParameterDescriptor {
    ParameterDescriptor {
        key: key.into(),
        label: label.into(),
        control: ParameterControlKind::TokenField,
        default_value: NodeParamValue::String(def.into()),
    }
}

fn node(
    type_id: &str,
    title: &str,
    category: NodeCategory,
    summary: &str,
    params: Vec<ParameterDescriptor>,
) -> NodeDefinition {
    NodeDefinition {
        type_id: type_id.into(),
        title: title.into(),
        category,
        summary: summary.into(),
        input_port_count: 1,
        output_port_count: 1,
        output_port_labels: vec!["Output".into()],
        is_sink: false,
        is_source: false,
        is_batch_collector: false,
        parameters: params,
    }
}

fn source_node(
    type_id: &str,
    title: &str,
    category: NodeCategory,
    summary: &str,
    params: Vec<ParameterDescriptor>,
) -> NodeDefinition {
    let mut n = node(type_id, title, category, summary, params);
    n.input_port_count = 0;
    n.is_source = true;
    n
}

fn sink_node(
    type_id: &str,
    title: &str,
    category: NodeCategory,
    summary: &str,
    params: Vec<ParameterDescriptor>,
) -> NodeDefinition {
    let mut n = node(type_id, title, category, summary, params);
    n.output_port_count = 0;
    n.output_port_labels = vec![];
    n.is_sink = true;
    n
}

pub fn output_formats() -> Vec<String> {
    vec![
        "PNG", "JPEG", "WebP", "TIFF", "GIF", "BMP", "ICO", "PDF",
    ]
    .into_iter()
    .map(String::from)
    .collect()
}

pub fn all_definitions() -> Vec<NodeDefinition> {
    let blend_modes = &[
        "Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "Difference",
    ];
    let photo_styles = &[
        "Chrome", "Fade", "Instant", "Mono", "Noir", "Process", "Tonal", "Transfer",
    ];

    let mut rules_node = node(
        node_type::RULES,
        "Rules",
        NodeCategory::Sort,
        "Branch assets into Matched and Unmatched output ports based on metadata or dimensions.",
        vec![
            p_toggle("matchAll", "Match all rules", true),
            ParameterDescriptor {
                key: "rules".into(),
                label: "Rules".into(),
                control: ParameterControlKind::Text {
                    placeholder: "Configured in Rules inspector".into(),
                },
                default_value: NodeParamValue::Rules(vec![FilterRule {
                    id: "DEFAULT-RULE-1".into(),
                    field: RuleField::Width,
                    op: RuleOperator::GreaterThan,
                    value: "800".into(),
                }]),
            },
        ],
    );
    rules_node.output_port_count = 2;
    rules_node.output_port_labels = vec!["Matched".into(), "Unmatched".into()];

    let mut multi_scale = node(
        node_type::MULTI_SCALE,
        "Multi Scale",
        NodeCategory::WriteImages,
        "Emit multiple scaled variants (@1x, @2x, @3x) simultaneously for responsive assets.",
        vec![ParameterDescriptor {
            key: "scales".into(),
            label: "Scale Branches".into(),
            control: ParameterControlKind::Text {
                placeholder: "Configured in Multi Scale inspector".into(),
            },
            default_value: NodeParamValue::Scales(vec![
                ScaleBranchSpec {
                    id: "SCALE-1X".into(),
                    label: "1x".into(),
                    scale_factor: 1.0,
                    suffix: "".into(),
                },
                ScaleBranchSpec {
                    id: "SCALE-2X".into(),
                    label: "2x".into(),
                    scale_factor: 2.0,
                    suffix: "@2x".into(),
                },
            ]),
        }],
    );
    multi_scale.is_sink = false;

    let mut image_grid = node(
        node_type::IMAGE_GRID,
        "Image Grid",
        NodeCategory::Generator,
        "Combine all incoming images into a single contact-sheet grid.",
        vec![
            p_int("columns", "Columns", 1, 12, "", 4),
            p_int("tileSize", "Tile Size", 64, 1024, "px", 240),
            p_int("spacing", "Spacing", 0, 64, "px", 12),
            p_color("backgroundColor", "Background", CodableColor::WHITE),
        ],
    );
    image_grid.is_batch_collector = true;

    let mut animated_img = node(
        node_type::ANIMATED_IMAGE,
        "Animated Image",
        NodeCategory::Generator,
        "Combine incoming images into an animated GIF.",
        vec![
            p_slider("frameDelay", "Frame Delay", 0.05, 2.0, 0.05, "s", 0.25),
            p_int("loopCount", "Loop Count", 0, 100, "", 0),
            p_str("fileName", "File Name", "Animation.gif", "Animation.gif"),
        ],
    );
    animated_img.is_batch_collector = true;

    let mut pdf_maker = node(
        node_type::PDF_MAKER,
        "PDF Maker",
        NodeCategory::Pdf,
        "Assemble all incoming images into a valid multi-page PDF document.",
        vec![
            p_str("fileName", "File Name", "ContactSheet.pdf", "ContactSheet.pdf"),
            p_slider("margin", "Margin", 0.0, 144.0, 1.0, "pt", 24.0),
        ],
    );
    pdf_maker.is_batch_collector = true;

    let mut sort_order = node(
        node_type::SORT_ORDER,
        "Sort Order",
        NodeCategory::Sort,
        "Reorder the batch stream by filename, width, height, or file size.",
        vec![
            p_picker(
                "sortBy",
                "Sort By",
                &["File Name", "Width", "Height", "File Size"],
                "File Name",
            ),
            p_toggle("ascending", "Ascending", true),
        ],
    );
    sort_order.is_batch_collector = true;

    vec![
        // 1. Read Images (5)
        source_node(
            node_type::READ_FOLDER,
            "Read Folder",
            NodeCategory::ReadImages,
            "Read all supported images from a local folder.",
            vec![
                p_folder("folderPath", "Folder", ""),
                p_toggle("includeSubfolders", "Include subfolders", false),
                p_str("filterExtensions", "Extensions", "jpg,png,webp", ""),
            ],
        ),
        source_node(
            node_type::READ_FILES,
            "Read Individual Files",
            NodeCategory::ReadImages,
            "Read one or more explicitly chosen image files.",
            vec![p_file("filePaths", "Files", &["png", "jpg", "jpeg", "webp", "bmp", "tiff", "gif"])],
        ),
        source_node(
            node_type::PROMPT_FOR_FILES,
            "Prompt for Files",
            NodeCategory::ReadImages,
            "Prompt the user for image files when running the workflow.",
            vec![p_toggle("allowMultiple", "Allow multiple", true)],
        ),
        source_node(
            node_type::READ_CLIPBOARD,
            "Clipboard",
            NodeCategory::ReadImages,
            "Read an image from the system clipboard (falls back cleanly when empty).",
            vec![],
        ),
        node(
            node_type::RAW_PROCESS,
            "RAW Process",
            NodeCategory::ReadImages,
            "Apply tonal exposure, white balance, and noise reduction adjustments.",
            vec![
                p_slider("exposure", "Exposure", -3.0, 3.0, 0.05, "EV", 0.0),
                p_slider("temperature", "Temperature", 2000.0, 10000.0, 50.0, "K", 6500.0),
                p_slider("tint", "Tint", -100.0, 100.0, 1.0, "", 0.0),
                p_slider("luminanceNoiseReduction", "Noise Reduction", 0.0, 1.0, 0.02, "", 0.1),
                p_toggle("draftMode", "Fast Draft Mode", false),
            ],
        ),
        // 2. Write Images (4)
        sink_node(
            node_type::WRITE_IMAGES,
            "Write Images",
            NodeCategory::WriteImages,
            "Export processed images to disk with format conversion, token naming & Indexed PNG.",
            vec![
                p_folder("folderPath", "Folder", ""),
                p_toggle("openFolderWhenFinished", "Open folder when export finishes", true),
                p_toggle("overwriteExisting", "Overwrite existing images", true),
                p_toggle("writeBackToOriginal", "Write back to original images", false),
                p_toggle("askForOutputFolder", "Ask for output folder when run", false),
                p_toggle("readBackEncoded", "Read back encoded image", false),
                p_toggle("keepOriginalDates", "Keep original and modified dates", false),
                p_token("fileNamePattern", "File name", "[File Name]"),
                p_picker(
                    "format",
                    "Convert to",
                    &["PNG", "JPEG", "WebP", "TIFF", "GIF", "BMP", "ICO", "PDF"],
                    "PNG",
                ),
                p_slider("quality", "Quality", 0.1, 1.0, 0.01, "", 0.88),
                p_toggle("removeAlphaIfOpaque", "Remove alpha channel if opaque", true),
                p_toggle("crushPNG", "Crush (slow)", false),
                p_toggle("bruteForceCrushPNG", "Brute force crush (very slow)", false),
                p_toggle("removeColorProfile", "Remove color profile", false),
                p_toggle("makeIndexedPNG", "Make indexed PNG", true),
                p_int("indexedColors", "Colors", 2, 256, "", 256),
                p_int("indexedSpeed", "Speed", 1, 10, "", 1),
                p_toggle("indexedDither", "Dither", false),
            ],
        ),
        sink_node(
            node_type::WRITE_CLIPBOARD,
            "Write to Clipboard",
            NodeCategory::WriteImages,
            "Stage the processed image to clipboard buffer.",
            vec![],
        ),
        sink_node(
            node_type::OPEN_IN_APP,
            "Open in Another App",
            NodeCategory::WriteImages,
            "Export to a temporary folder and open with an external Windows application.",
            vec![p_str("applicationPath", "Application", "mspaint.exe", "")],
        ),
        multi_scale,
        // 3. Blur (5)
        node(
            node_type::GAUSSIAN_BLUR,
            "Gaussian Blur",
            NodeCategory::Blur,
            "Smooth images with a Gaussian blur kernel.",
            vec![p_slider("radius", "Radius", 0.0, 80.0, 0.5, "px", 10.0)],
        ),
        node(
            node_type::BOX_BLUR,
            "Box Blur",
            NodeCategory::Blur,
            "Apply a fast uniform box blur.",
            vec![p_slider("radius", "Radius", 1.0, 60.0, 1.0, "px", 8.0)],
        ),
        node(
            node_type::MOTION_BLUR,
            "Motion Blur",
            NodeCategory::Blur,
            "Simulate directional linear camera motion blur.",
            vec![
                p_slider("radius", "Radius", 1.0, 60.0, 1.0, "px", 12.0),
                p_slider("angle", "Angle", 0.0, 360.0, 1.0, "°", 0.0),
            ],
        ),
        node(
            node_type::NOISE_REDUCTION,
            "Noise Reduction",
            NodeCategory::Blur,
            "Reduce sensor chroma and luminance noise while preserving edges.",
            vec![
                p_slider("noiseLevel", "Noise Level", 0.0, 0.5, 0.01, "", 0.06),
                p_slider("sharpness", "Sharpness", 0.0, 2.0, 0.05, "", 0.4),
            ],
        ),
        node(
            node_type::PIXELATE,
            "Pixelate",
            NodeCategory::Blur,
            "Render a mosaic pixelation block filter.",
            vec![p_slider("scale", "Scale", 2.0, 80.0, 1.0, "px", 12.0)],
        ),
        // 4. Color Adjustment (7)
        node(
            node_type::EXPOSURE,
            "Exposure",
            NodeCategory::ColorAdjustment,
            "Adjust image exposure in stops (EV).",
            vec![p_slider("ev", "EV", -4.0, 4.0, 0.05, "EV", 0.5)],
        ),
        node(
            node_type::BRIGHTNESS_CONTRAST,
            "Brightness & Contrast",
            NodeCategory::ColorAdjustment,
            "Tune brightness, contrast, and saturation.",
            vec![
                p_slider("brightness", "Brightness", -1.0, 1.0, 0.02, "", 0.0),
                p_slider("contrast", "Contrast", 0.25, 2.5, 0.02, "", 1.0),
                p_slider("saturation", "Saturation", 0.0, 2.0, 0.02, "", 1.0),
            ],
        ),
        node(
            node_type::VIBRANCE,
            "Vibrance",
            NodeCategory::ColorAdjustment,
            "Boost muted colors without oversaturating skin tones.",
            vec![p_slider("amount", "Amount", -1.0, 1.0, 0.02, "", 0.35)],
        ),
        node(
            node_type::GAMMA,
            "Gamma",
            NodeCategory::ColorAdjustment,
            "Apply midtone gamma transfer curve.",
            vec![p_slider("power", "Power", 0.2, 3.0, 0.05, "", 1.0)],
        ),
        node(
            node_type::TEMPERATURE_TINT,
            "Temperature & Tint",
            NodeCategory::ColorAdjustment,
            "Warm or cool color temperature and green/magenta tint.",
            vec![
                p_slider("temperature", "Temperature", 2000.0, 10000.0, 50.0, "K", 6500.0),
                p_slider("tint", "Tint", -100.0, 100.0, 1.0, "", 0.0),
            ],
        ),
        node(
            node_type::SHADOWS_HIGHLIGHTS,
            "Shadows & Highlights",
            NodeCategory::ColorAdjustment,
            "Lift dark shadow detail and recover bright highlights.",
            vec![
                p_slider("shadowAmount", "Shadows", -1.0, 1.0, 0.02, "", 0.25),
                p_slider("highlightAmount", "Highlights", 0.0, 1.0, 0.02, "", 0.85),
            ],
        ),
        node(
            node_type::COLOR_PROFILE,
            "Color Profile",
            NodeCategory::ColorAdjustment,
            "Tag or convert target color space profile.",
            vec![p_picker(
                "profile",
                "Profile",
                &["sRGB", "Display P3", "Adobe RGB", "Grayscale"],
                "sRGB",
            )],
        ),
        // 5. Color Effect (10)
        node(
            node_type::PHOTO_EFFECT,
            "Photo Effect",
            NodeCategory::ColorEffect,
            "Apply classic film & monochrome photo looks.",
            vec![p_picker("style", "Style", photo_styles, "Noir")],
        ),
        node(
            node_type::SEPIA,
            "Sepia",
            NodeCategory::ColorEffect,
            "Warm vintage sepia tone filter.",
            vec![p_slider("intensity", "Intensity", 0.0, 1.0, 0.02, "", 0.8)],
        ),
        node(
            node_type::COLOR_INVERT,
            "Color Invert",
            NodeCategory::ColorEffect,
            "Invert RGB channels to produce a negative image.",
            vec![],
        ),
        node(
            node_type::COLOR_POSTERIZE,
            "Color Posterize",
            NodeCategory::ColorEffect,
            "Quantize each color channel into discrete tonal steps.",
            vec![p_slider("levels", "Levels", 2.0, 32.0, 1.0, "", 6.0)],
        ),
        node(
            node_type::ONE_BIT,
            "1-Bit",
            NodeCategory::ColorEffect,
            "Convert image to pure black and white with optional dithering.",
            vec![
                p_slider("threshold", "Threshold", 0.0, 1.0, 0.01, "", 0.5),
                p_toggle("dither", "Floyd-Steinberg Dither", true),
            ],
        ),
        node(
            node_type::DITHER,
            "Dither",
            NodeCategory::ColorEffect,
            "Apply ordered noise dithering.",
            vec![p_slider("intensity", "Intensity", 0.0, 1.0, 0.02, "", 0.25)],
        ),
        node(
            node_type::MATTE,
            "Matte",
            NodeCategory::ColorEffect,
            "Fill transparent pixels with a solid matte color.",
            vec![p_color("color", "Matte Color", CodableColor::WHITE)],
        ),
        node(
            node_type::ADD_BORDER,
            "Add Border",
            NodeCategory::ColorEffect,
            "Expand canvas and draw a solid frame around the image.",
            vec![
                p_int("width", "Width", 1, 200, "px", 20),
                p_color("color", "Border Color", CodableColor::WHITE),
            ],
        ),
        node(
            node_type::DROP_SHADOW,
            "Drop Shadow",
            NodeCategory::ColorEffect,
            "Add a soft drop shadow around the image.",
            vec![
                p_slider("radius", "Blur Radius", 0.0, 80.0, 1.0, "px", 16.0),
                p_slider("offsetX", "Offset X", -60.0, 60.0, 1.0, "px", 0.0),
                p_slider("offsetY", "Offset Y", -60.0, 60.0, 1.0, "px", 8.0),
                p_slider("opacity", "Opacity", 0.0, 1.0, 0.02, "", 0.45),
                p_color("color", "Shadow Color", CodableColor::BLACK),
            ],
        ),
        node(
            node_type::DOCUMENT_ENHANCER,
            "Document Enhancer",
            NodeCategory::ColorEffect,
            "Increase text readability and flatten paper background.",
            vec![],
        ),
        // 6. Generator (4)
        source_node(
            node_type::BLANK_IMAGE,
            "Blank Image",
            NodeCategory::Generator,
            "Generate a solid-color image canvas of custom dimensions.",
            vec![
                p_int("width", "Width", 16, 4096, "px", 1200),
                p_int("height", "Height", 16, 4096, "px", 800),
                p_color("color", "Fill Color", CodableColor::WHITE),
            ],
        ),
        source_node(
            node_type::SCREENSHOT,
            "Screenshot",
            NodeCategory::Generator,
            "Capture desktop snapshot (Windows Screen Capture hook).",
            vec![],
        ),
        image_grid,
        animated_img,
        // 7. Metadata (5)
        node(
            node_type::DELETE_METADATA,
            "Delete Metadata",
            NodeCategory::Metadata,
            "Strip EXIF, IPTC, XMP, and GPS tags on export.",
            vec![p_toggle("keepOrientation", "Keep orientation tag", true)],
        ),
        node(
            node_type::REMOVE_GPS,
            "Remove GPS",
            NodeCategory::Metadata,
            "Strip GPS location coordinates while preserving camera metadata.",
            vec![],
        ),
        node(
            node_type::SET_DPI,
            "Set DPI",
            NodeCategory::Metadata,
            "Override target print resolution metadata (DPI).",
            vec![p_int("dpi", "DPI", 36, 1200, "DPI", 300)],
        ),
        node(
            node_type::SET_GENERAL_METADATA,
            "Set General Metadata",
            NodeCategory::Metadata,
            "Set Author, Copyright, Title, and Description tags.",
            vec![
                p_str("author", "Author", "Your Name", ""),
                p_str("copyright", "Copyright", "© 2026", ""),
                p_str("title", "Title", "", ""),
                p_str("description", "Description", "", ""),
            ],
        ),
        node(
            node_type::FIX_EXIF_ROTATION,
            "Fix EXIF Rotation",
            NodeCategory::Metadata,
            "Bake EXIF orientation into pixel data and reset orientation to 1.",
            vec![],
        ),
        // 8. Misc (7)
        node(
            node_type::CHANGE_BITS_PER_CHANNEL,
            "Change Bits Per Channel",
            NodeCategory::Misc,
            "Tag target channel bit depth (8-bit / 16-bit).",
            vec![p_picker("bits", "Bits", &["8", "16"], "8")],
        ),
        node(
            node_type::DUPLICATE,
            "Duplicate",
            NodeCategory::Misc,
            "Duplicate each incoming asset into N independent copies.",
            vec![p_int("copies", "Copies", 1, 10, "", 2)],
        ),
        node(
            node_type::DELAY,
            "Delay",
            NodeCategory::Misc,
            "Pause pipeline processing briefly per asset.",
            vec![p_slider("seconds", "Seconds", 0.0, 5.0, 0.05, "s", 0.1)],
        ),
        node(
            node_type::LAYER_PAGE_SPLITTER,
            "Layer & Page Splitter",
            NodeCategory::Misc,
            "Split multi-frame GIF or multi-page inputs into separate assets.",
            vec![],
        ),
        node(
            node_type::EXTRACT_PORTRAIT_MATTE,
            "Extract Portrait Matte",
            NodeCategory::Misc,
            "Generate a high-contrast foreground/subject luminance matte.",
            vec![],
        ),
        node(
            node_type::CONTRAST_STRETCH,
            "Contrast Stretch",
            NodeCategory::Misc,
            "Auto-normalize histogram min/max luminance across the full 0–255 range.",
            vec![],
        ),
        node(
            node_type::CUSTOM_CONVOLUTION,
            "Custom Convolution",
            NodeCategory::Misc,
            "Apply a custom 3×3 convolution kernel (9 comma-separated weights).",
            vec![p_str(
                "weights",
                "3×3 Kernel",
                "0,-1,0,-1,5,-1,0,-1,0",
                "0,-1,0,-1,5,-1,0,-1,0",
            )],
        ),
        // 9. PDF (2)
        pdf_maker,
        node(
            node_type::PDF_EXTRACTOR,
            "PDF Image Extractor",
            NodeCategory::Pdf,
            "Extract embedded JPEG images from PDF files.",
            vec![p_int("dpi", "Render DPI", 72, 600, "DPI", 150)],
        ),
        // 10. Photos Library (2 — Windows Pictures Library mapping with full macOS typeID parity)
        source_node(
            node_type::READ_PHOTOS_LIBRARY,
            "Read Pictures Library",
            NodeCategory::PhotosLibrary,
            "Read photos from your Windows Pictures folder (or album subfolder).",
            vec![
                p_str("albumName", "Album / Subfolder", "Camera Roll", ""),
                p_int("limit", "Max Photos", 1, 500, "", 50),
            ],
        ),
        sink_node(
            node_type::IMPORT_TO_PHOTOS,
            "Import to Pictures",
            NodeCategory::PhotosLibrary,
            "Save processed images into a Windows Pictures album folder.",
            vec![p_str("albumName", "Album Folder", "FlowBatch Exports", "FlowBatch Exports")],
        ),
        // 11. Script (3 — JavaScript, Shell, PowerShell/AppleScript parity)
        node(
            node_type::JAVA_SCRIPT,
            "JavaScript",
            NodeCategory::Script,
            "Transform asset filename, tags, or skip flag with safe inline rules.",
            vec![p_code(
                "script",
                "Script",
                "javascript",
                "// Example: rename or tag asset\n// asset.fileName = asset.fileName + '_edited';\n",
            )],
        ),
        node(
            node_type::SHELL_SCRIPT,
            "Shell Script",
            NodeCategory::Script,
            "Run a local command/script (PowerShell on Windows, zsh on macOS).",
            vec![p_code("script", "Command", "shell", "echo \"$FLOWBATCH_FILE\"")],
        ),
        node(
            node_type::APPLE_SCRIPT,
            "PowerShell / Script",
            NodeCategory::Script,
            "Windows PowerShell automation node (maps to AppleScript on macOS).",
            vec![p_code(
                "script",
                "PowerShell",
                "powershell",
                "Write-Output \"Processed $env:FLOWBATCH_FILE\"",
            )],
        ),
        // 12. Sharpen (2)
        node(
            node_type::SHARPEN_LUMINANCE,
            "Sharpen Luminance",
            NodeCategory::Sharpen,
            "Crisp detail sharpening across luminance.",
            vec![
                p_slider("sharpness", "Sharpness", 0.0, 3.0, 0.05, "", 0.6),
                p_slider("radius", "Radius", 0.5, 5.0, 0.1, "px", 1.5),
            ],
        ),
        node(
            node_type::UNSHARP_MASK,
            "Unsharp Mask",
            NodeCategory::Sharpen,
            "Classic radius & intensity unsharp mask sharpening.",
            vec![
                p_slider("radius", "Radius", 0.5, 10.0, 0.1, "px", 2.0),
                p_slider("intensity", "Intensity", 0.0, 3.0, 0.05, "", 0.8),
            ],
        ),
        // 13. Sort (3)
        rules_node,
        node(
            node_type::CLASSIFY_IMAGES,
            "Classify Images",
            NodeCategory::Sort,
            "Tag assets by visual scene heuristics (sunset, night, monochrome, portrait, landscape).",
            vec![
                p_slider("minConfidence", "Min Confidence", 0.1, 0.99, 0.05, "", 0.4),
                p_int("maxLabels", "Max Labels", 1, 10, "", 3),
            ],
        ),
        sort_order,
        // 14. Transform (6)
        node(
            node_type::SCALE,
            "Scale",
            NodeCategory::Transform,
            "Resize images by fixed width, fixed height, percentage, or fit box.",
            vec![
                p_picker(
                    "mode",
                    "Mode",
                    &["Fixed Width", "Fixed Height", "Percentage", "Fit Box"],
                    "Fixed Width",
                ),
                p_int("width", "Width", 16, 8192, "px", 800),
                p_int("height", "Height", 16, 8192, "px", 600),
                p_slider("percent", "Percent", 5.0, 400.0, 1.0, "%", 50.0),
                p_toggle("allowUpscale", "Allow upscale", true),
            ],
        ),
        node(
            node_type::CROP,
            "Crop",
            NodeCategory::Transform,
            "Crop images to fixed pixel dimensions or aspect ratio around an anchor.",
            vec![
                p_picker("mode", "Mode", &["Fixed Size", "Aspect Ratio"], "Fixed Size"),
                p_int("width", "Width", 16, 8192, "px", 600),
                p_int("height", "Height", 16, 8192, "px", 600),
                p_picker("aspectRatio", "Aspect Ratio", &["1:1", "4:3", "16:9", "3:2"], "1:1"),
                p_anchor("anchor", "Anchor", "center"),
            ],
        ),
        node(
            node_type::ROTATE,
            "Rotate",
            NodeCategory::Transform,
            "Rotate image clockwise (fast exact 90/180/270° or arbitrary angle).",
            vec![
                p_slider("degrees", "Degrees", -180.0, 180.0, 1.0, "°", 90.0),
                p_color("backgroundColor", "Background", CodableColor::CLEAR),
            ],
        ),
        node(
            node_type::FLIP,
            "Flip",
            NodeCategory::Transform,
            "Mirror image horizontally or vertically.",
            vec![p_picker("direction", "Direction", &["Horizontal", "Vertical"], "Horizontal")],
        ),
        node(
            node_type::TRIM_TO_EDGES,
            "Trim to Edges",
            NodeCategory::Transform,
            "Trim transparent border pixels automatically.",
            vec![p_slider("alphaThreshold", "Alpha Threshold", 0.0, 1.0, 0.01, "", 0.05)],
        ),
        node(
            node_type::ML_SUPER_RESOLUTION,
            "ML Super Resolution",
            NodeCategory::Transform,
            "High-quality Lanczos 2×/4× upscaling with adaptive edge sharpening.",
            vec![
                p_picker("multiplier", "Scale Factor", &["2x", "4x"], "2x"),
                p_slider("edgeSharpen", "Edge Sharpen", 0.0, 2.0, 0.05, "", 0.5),
            ],
        ),
        // 15. Watermark (2)
        node(
            node_type::TEXT_WATERMARK,
            "Text Watermark",
            NodeCategory::Watermark,
            "Overlay crisp anti-aliased text or dynamic tokens onto images.",
            vec![
                p_token("text", "Text", "@ FlowBatch Sample"),
                p_slider("fontSize", "Font Size", 8.0, 120.0, 1.0, "pt", 28.0),
                p_color("color", "Text Color", CodableColor::WHITE),
                p_slider("opacity", "Opacity", 0.0, 1.0, 0.01, "", 0.75),
                p_anchor("anchor", "Position", "bottomRight"),
                p_int("marginX", "Margin X", 0, 400, "px", 28),
                p_int("marginY", "Margin Y", 0, 400, "px", 24),
                p_slider("rotation", "Rotation", -180.0, 180.0, 1.0, "°", 0.0),
                p_toggle("tile", "Tile across image", false),
                p_picker("blendMode", "Blend Mode", blend_modes, "Normal"),
            ],
        ),
        node(
            node_type::IMAGE_WATERMARK,
            "Image Watermark",
            NodeCategory::Watermark,
            "Composite a PNG/JPEG logo watermark onto incoming images.",
            vec![
                p_file("imagePath", "Watermark Image", &["png", "jpg", "jpeg", "webp"]),
                p_slider("scalePercent", "Scale %", 5.0, 100.0, 1.0, "%", 25.0),
                p_slider("opacity", "Opacity", 0.0, 1.0, 0.01, "", 0.8),
                p_anchor("anchor", "Position", "bottomRight"),
                p_int("marginX", "Margin X", 0, 400, "px", 24),
                p_int("marginY", "Margin Y", 0, 400, "px", 24),
                p_toggle("tile", "Tile across image", false),
                p_picker("blendMode", "Blend Mode", blend_modes, "Normal"),
            ],
        ),
    ]
}

pub fn definition_for(type_id: &str) -> Option<NodeDefinition> {
    all_definitions().into_iter().find(|d| d.type_id == type_id)
}
