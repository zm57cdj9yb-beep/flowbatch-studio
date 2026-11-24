import Foundation

/// Canonical string identifiers for every built-in node type across all 15 categories.
public enum NodeTypeID {
    // Read Images
    public static let readFolder = "read.folder"
    public static let readFiles = "read.files"
    public static let promptForFiles = "read.prompt"
    public static let readClipboard = "read.clipboard"
    public static let rawProcess = "read.raw"

    // Write Images
    public static let writeImages = "write.images"
    public static let writeClipboard = "write.clipboard"
    public static let openInApp = "write.openInApp"
    public static let multiScale = "write.multiScale"

    // Blur
    public static let gaussianBlur = "blur.gaussian"
    public static let boxBlur = "blur.box"
    public static let motionBlur = "blur.motion"
    public static let noiseReduction = "blur.noiseReduction"
    public static let pixelate = "blur.pixelate"

    // Color Adjustment
    public static let exposure = "color.exposure"
    public static let brightnessContrast = "color.brightnessContrast"
    public static let vibrance = "color.vibrance"
    public static let gamma = "color.gamma"
    public static let temperatureTint = "color.temperatureTint"
    public static let shadowsHighlights = "color.shadowsHighlights"
    public static let colorProfile = "color.profile"

    // Color Effect
    public static let photoEffect = "effect.photoEffect"
    public static let sepia = "effect.sepia"
    public static let colorInvert = "effect.invert"
    public static let colorPosterize = "effect.posterize"
    public static let oneBit = "effect.oneBit"
    public static let dither = "effect.dither"
    public static let matte = "effect.matte"
    public static let addBorder = "effect.addBorder"
    public static let dropShadow = "effect.dropShadow"
    public static let documentEnhancer = "effect.documentEnhancer"

    // Generator
    public static let blankImage = "generator.blank"
    public static let screenshot = "generator.screenshot"
    public static let imageGrid = "generator.imageGrid"
    public static let animatedImage = "generator.animatedImage"

    // Metadata
    public static let deleteMetadata = "metadata.delete"
    public static let removeGPS = "metadata.removeGPS"
    public static let setDPI = "metadata.setDPI"
    public static let setGeneralMetadata = "metadata.setGeneral"
    public static let fixExifRotation = "metadata.fixRotation"

    // Misc
    public static let changeBitsPerChannel = "misc.bitsPerChannel"
    public static let duplicate = "misc.duplicate"
    public static let delay = "misc.delay"
    public static let layerPageSplitter = "misc.splitLayers"
    public static let extractPortraitMatte = "misc.portraitMatte"
    public static let contrastStretch = "misc.contrastStretch"
    public static let customConvolution = "misc.convolution"

    // PDF
    public static let pdfMaker = "pdf.maker"
    public static let pdfExtractor = "pdf.extractor"

    // Photos Library
    public static let readPhotosLibrary = "photos.read"
    public static let importToPhotos = "photos.import"

    // Script
    public static let javaScript = "script.javascript"
    public static let shellScript = "script.shell"
    public static let appleScript = "script.applescript"

    // Sharpen
    public static let sharpenLuminance = "sharpen.luminance"
    public static let unsharpMask = "sharpen.unsharpMask"

    // Sort
    public static let rules = "sort.rules"
    public static let classifyImages = "sort.classify"
    public static let sortOrder = "sort.order"

    // Transform
    public static let scale = "transform.scale"
    public static let crop = "transform.crop"
    public static let rotate = "transform.rotate"
    public static let flip = "transform.flip"
    public static let trimToEdges = "transform.trim"
    public static let mlSuperResolution = "transform.superResolution"

    // Watermark
    public static let textWatermark = "watermark.text"
    public static let imageWatermark = "watermark.image"
}

/// Complete static catalog of all nodes organized into 15 categories.
public enum NodeCatalog {
    public static let blendModes: [String] = [
        "Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten",
        "Color Dodge", "Color Burn", "Soft Light", "Hard Light",
        "Difference", "Exclusion", "Hue", "Saturation", "Color", "Luminosity",
        "Plus Darker", "Plus Lighter", "Pin Light", "Divide"
    ]

    public static let outputFormats: [String] = [
        "Original", "PNG", "JPEG", "HEIC", "AVIF", "TIFF", "GIF", "JPEG 2000", "BMP", "PDF"
    ]

    public static let allDefinitions: [NodeDefinition] = [
        // MARK: - 1. Read Images
        NodeDefinition(
            typeID: NodeTypeID.readFolder,
            title: "Read Folder",
            category: .readImages,
            summary: "Read all images from a folder",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true,
            parameters: [
                ParameterDescriptor(key: "folderPath", label: "Folder", kind: .folderPath, defaultValue: .string("")),
                ParameterDescriptor(key: "includeSubfolders", label: "Include subfolders", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "filterExtensions", label: "Extensions", kind: .text(placeholder: "jpg,png,heic,raw"), defaultValue: .string(""))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.readFiles,
            title: "Read Individual Files",
            category: .readImages,
            summary: "Read specific selected image files",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true,
            parameters: [
                ParameterDescriptor(key: "filePaths", label: "Files", kind: .text(placeholder: "Semicolon-separated paths"), defaultValue: .string(""))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.promptForFiles,
            title: "Prompt for Files",
            category: .readImages,
            summary: "Ask user to select files on run",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true,
            parameters: [
                ParameterDescriptor(key: "allowMultiple", label: "Allow multiple selection", kind: .toggle, defaultValue: .bool(true))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.readClipboard,
            title: "Clipboard",
            category: .readImages,
            summary: "Read image currently on the pasteboard",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true
        ),
        NodeDefinition(
            typeID: NodeTypeID.rawProcess,
            title: "RAW Process",
            category: .readImages,
            summary: "Develop camera RAW files with CIRAWFilter",
            inputPortCount: 1,
            outputPortCount: 1,
            parameters: [
                ParameterDescriptor(key: "exposure", label: "Exposure", kind: .slider(min: -4, max: 4, step: 0.05, unit: "EV"), defaultValue: .double(0)),
                ParameterDescriptor(key: "temperature", label: "Temperature", kind: .slider(min: 2000, max: 12000, step: 50, unit: "K"), defaultValue: .double(6500)),
                ParameterDescriptor(key: "tint", label: "Tint", kind: .slider(min: -150, max: 150, step: 1, unit: ""), defaultValue: .double(0)),
                ParameterDescriptor(key: "luminanceNoiseReduction", label: "Noise Reduction", kind: .slider(min: 0, max: 1, step: 0.02, unit: ""), defaultValue: .double(0.25)),
                ParameterDescriptor(key: "draftMode", label: "Draft mode", kind: .toggle, defaultValue: .bool(false))
            ]
        ),

        // MARK: - 2. Write Images
        NodeDefinition(
            typeID: NodeTypeID.writeImages,
            title: "Write Images",
            category: .writeImages,
            summary: "Export processed images to disk",
            inputPortCount: 1,
            outputPortCount: 0,
            isSink: true,
            parameters: [
                ParameterDescriptor(key: "folderPath", label: "Folder", kind: .folderPath, defaultValue: .string("")),
                ParameterDescriptor(key: "openFolderWhenFinished", label: "Open folder when export finishes", kind: .toggle, defaultValue: .bool(true)),
                ParameterDescriptor(key: "overwriteExisting", label: "Overwrite existing images", kind: .toggle, defaultValue: .bool(true)),
                ParameterDescriptor(key: "writeBackToOriginal", label: "Write back to original images", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "askForOutputFolder", label: "Ask for output folder when run", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "readBackEncoded", label: "Read back encoded image", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "keepOriginalDates", label: "Keep original and modified dates", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "fileNamePattern", label: "File name", kind: .tokenField, defaultValue: .string("[File Name]")),
                ParameterDescriptor(key: "format", label: "Convert to", kind: .picker(options: outputFormats), defaultValue: .string("PNG")),
                ParameterDescriptor(key: "quality", label: "Quality", kind: .slider(min: 0.1, max: 1.0, step: 0.01, unit: "%"), defaultValue: .double(0.88)),
                ParameterDescriptor(key: "removeAlphaIfOpaque", label: "Remove alpha channel if opaque", kind: .toggle, defaultValue: .bool(true)),
                ParameterDescriptor(key: "crushPNG", label: "Crush (slow)", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "bruteForceCrushPNG", label: "Brute force crush (very slow)", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "removeColorProfile", label: "Remove color profile", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "makeIndexedPNG", label: "Make indexed PNG", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "indexedColors", label: "Colors", kind: .intSlider(min: 2, max: 256, unit: ""), defaultValue: .int(256)),
                ParameterDescriptor(key: "indexedSpeed", label: "Speed", kind: .intSlider(min: 1, max: 10, unit: ""), defaultValue: .int(1)),
                ParameterDescriptor(key: "indexedDither", label: "Dither", kind: .toggle, defaultValue: .bool(false))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.writeClipboard,
            title: "Write to Clipboard",
            category: .writeImages,
            summary: "Copy processed image to system clipboard",
            inputPortCount: 1,
            outputPortCount: 0,
            isSink: true
        ),
        NodeDefinition(
            typeID: NodeTypeID.openInApp,
            title: "Open in Another App",
            category: .writeImages,
            summary: "Write temp files and open in target application",
            inputPortCount: 1,
            outputPortCount: 0,
            isSink: true,
            parameters: [
                ParameterDescriptor(key: "applicationPath", label: "Application", kind: .filePath(allowedExtensions: ["app"]), defaultValue: .string("/System/Applications/Preview.app"))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.multiScale,
            title: "Multi Scale",
            category: .writeImages,
            summary: "Generate multiple resolution variants (@1x, @2x, @3x)",
            inputPortCount: 1,
            outputPortCount: 1,
            parameters: [
                ParameterDescriptor(
                    key: "scales",
                    label: "Scales",
                    kind: .text(placeholder: ""),
                    defaultValue: .scales([
                        ScaleBranchSpec(label: "1x", scaleFactor: 0.5, suffix: ""),
                        ScaleBranchSpec(label: "2x", scaleFactor: 1.0, suffix: "@2x")
                    ])
                )
            ]
        ),

        // MARK: - 3. Blur
        NodeDefinition(
            typeID: NodeTypeID.gaussianBlur,
            title: "Gaussian Blur",
            category: .blur,
            summary: "Smooth Gaussian blur",
            parameters: [ParameterDescriptor(key: "radius", label: "Radius", kind: .slider(min: 0, max: 100, step: 0.5, unit: "px"), defaultValue: .double(10))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.boxBlur,
            title: "Box Blur",
            category: .blur,
            summary: "Uniform kernel box blur",
            parameters: [ParameterDescriptor(key: "radius", label: "Radius", kind: .slider(min: 1, max: 100, step: 0.5, unit: "px"), defaultValue: .double(10))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.motionBlur,
            title: "Motion Blur",
            category: .blur,
            summary: "Directional motion blur",
            parameters: [
                ParameterDescriptor(key: "radius", label: "Radius", kind: .slider(min: 0, max: 100, step: 0.5, unit: "px"), defaultValue: .double(20)),
                ParameterDescriptor(key: "angle", label: "Angle", kind: .slider(min: 0, max: 360, step: 1, unit: "°"), defaultValue: .double(0))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.noiseReduction,
            title: "Noise Reduction",
            category: .blur,
            summary: "Reduce chroma and luminance noise",
            parameters: [
                ParameterDescriptor(key: "noiseLevel", label: "Noise Level", kind: .slider(min: 0, max: 0.2, step: 0.005, unit: ""), defaultValue: .double(0.02)),
                ParameterDescriptor(key: "sharpness", label: "Sharpness", kind: .slider(min: 0, max: 2, step: 0.05, unit: ""), defaultValue: .double(0.4))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.pixelate,
            title: "Pixelate",
            category: .blur,
            summary: "Mosaic pixelation filter",
            parameters: [ParameterDescriptor(key: "scale", label: "Scale", kind: .slider(min: 1, max: 100, step: 1, unit: "px"), defaultValue: .double(12))]
        ),

        // MARK: - 4. Color Adjustment
        NodeDefinition(
            typeID: NodeTypeID.exposure,
            title: "Exposure",
            category: .colorAdjustment,
            summary: "Adjust exposure in EV stops",
            parameters: [ParameterDescriptor(key: "ev", label: "EV", kind: .slider(min: -5, max: 5, step: 0.05, unit: "EV"), defaultValue: .double(0.5))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.brightnessContrast,
            title: "Brightness & Contrast",
            category: .colorAdjustment,
            summary: "Adjust brightness, contrast, and saturation",
            parameters: [
                ParameterDescriptor(key: "brightness", label: "Brightness", kind: .slider(min: -1, max: 1, step: 0.01, unit: ""), defaultValue: .double(0)),
                ParameterDescriptor(key: "contrast", label: "Contrast", kind: .slider(min: 0.25, max: 4, step: 0.01, unit: ""), defaultValue: .double(1)),
                ParameterDescriptor(key: "saturation", label: "Saturation", kind: .slider(min: 0, max: 2, step: 0.01, unit: ""), defaultValue: .double(1))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.vibrance,
            title: "Vibrance",
            category: .colorAdjustment,
            summary: "Boost muted colors selectively",
            parameters: [ParameterDescriptor(key: "amount", label: "Amount", kind: .slider(min: -1, max: 1, step: 0.02, unit: ""), defaultValue: .double(0.35))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.gamma,
            title: "Gamma",
            category: .colorAdjustment,
            summary: "Midtone gamma power adjustment",
            parameters: [ParameterDescriptor(key: "power", label: "Gamma", kind: .slider(min: 0.2, max: 3.0, step: 0.02, unit: ""), defaultValue: .double(1.0))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.temperatureTint,
            title: "Temperature & Tint",
            category: .colorAdjustment,
            summary: "Adjust white balance temperature and tint",
            parameters: [
                ParameterDescriptor(key: "temperature", label: "Temperature", kind: .slider(min: 2000, max: 12000, step: 50, unit: "K"), defaultValue: .double(6500)),
                ParameterDescriptor(key: "tint", label: "Tint", kind: .slider(min: -150, max: 150, step: 1, unit: ""), defaultValue: .double(0))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.shadowsHighlights,
            title: "Shadows & Highlights",
            category: .colorAdjustment,
            summary: "Recover shadow detail and tame highlights",
            parameters: [
                ParameterDescriptor(key: "shadowAmount", label: "Shadows", kind: .slider(min: -1, max: 1, step: 0.02, unit: ""), defaultValue: .double(0.25)),
                ParameterDescriptor(key: "highlightAmount", label: "Highlights", kind: .slider(min: 0, max: 1, step: 0.02, unit: ""), defaultValue: .double(1.0))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.colorProfile,
            title: "Color Profile",
            category: .colorAdjustment,
            summary: "Convert image color space profile",
            parameters: [
                ParameterDescriptor(key: "profile", label: "Profile", kind: .picker(options: ["sRGB", "Display P3", "Adobe RGB (1998)", "Generic Gray", "Generic CMYK"]), defaultValue: .string("sRGB"))
            ]
        ),

        // MARK: - 5. Color Effect
        NodeDefinition(
            typeID: NodeTypeID.photoEffect,
            title: "Photo Effect",
            category: .colorEffect,
            summary: "Apply stylized photographic looks",
            parameters: [
                ParameterDescriptor(key: "style", label: "Effect", kind: .picker(options: ["Chrome", "Fade", "Instant", "Mono", "Noir", "Process", "Tonal", "Transfer"]), defaultValue: .string("Noir"))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.sepia,
            title: "Sepia",
            category: .colorEffect,
            summary: "Warm sepia tone filter",
            parameters: [ParameterDescriptor(key: "intensity", label: "Intensity", kind: .slider(min: 0, max: 1, step: 0.02, unit: ""), defaultValue: .double(0.8))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.colorInvert,
            title: "Color Invert",
            category: .colorEffect,
            summary: "Invert RGB channels"
        ),
        NodeDefinition(
            typeID: NodeTypeID.colorPosterize,
            title: "Color Posterize",
            category: .colorEffect,
            summary: "Quantize tonal levels per channel",
            parameters: [ParameterDescriptor(key: "levels", label: "Levels", kind: .intSlider(min: 2, max: 30, unit: ""), defaultValue: .int(6))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.oneBit,
            title: "1-Bit",
            category: .colorEffect,
            summary: "Convert image to 1-bit black & white",
            parameters: [
                ParameterDescriptor(key: "threshold", label: "Threshold", kind: .slider(min: 0, max: 1, step: 0.01, unit: ""), defaultValue: .double(0.5)),
                ParameterDescriptor(key: "dither", label: "Floyd-Steinberg Dither", kind: .toggle, defaultValue: .bool(true))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.dither,
            title: "Dither",
            category: .colorEffect,
            summary: "Apply ordered dithering",
            parameters: [ParameterDescriptor(key: "intensity", label: "Intensity", kind: .slider(min: 0, max: 5, step: 0.05, unit: ""), defaultValue: .double(0.5))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.matte,
            title: "Matte",
            category: .colorEffect,
            summary: "Composite solid background behind alpha",
            parameters: [ParameterDescriptor(key: "color", label: "Matte Color", kind: .color, defaultValue: .color(.white))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.addBorder,
            title: "Add Border",
            category: .colorEffect,
            summary: "Expand canvas with solid border",
            parameters: [
                ParameterDescriptor(key: "width", label: "Border Width", kind: .intSlider(min: 1, max: 300, unit: "px"), defaultValue: .int(20)),
                ParameterDescriptor(key: "color", label: "Border Color", kind: .color, defaultValue: .color(.white))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.dropShadow,
            title: "Drop Shadow",
            category: .colorEffect,
            summary: "Add soft outer drop shadow",
            parameters: [
                ParameterDescriptor(key: "radius", label: "Blur Radius", kind: .slider(min: 0, max: 80, step: 1, unit: "px"), defaultValue: .double(16)),
                ParameterDescriptor(key: "offsetX", label: "Offset X", kind: .slider(min: -80, max: 80, step: 1, unit: "px"), defaultValue: .double(0)),
                ParameterDescriptor(key: "offsetY", label: "Offset Y", kind: .slider(min: -80, max: 80, step: 1, unit: "px"), defaultValue: .double(10)),
                ParameterDescriptor(key: "opacity", label: "Opacity", kind: .slider(min: 0, max: 1, step: 0.02, unit: ""), defaultValue: .double(0.45)),
                ParameterDescriptor(key: "color", label: "Shadow Color", kind: .color, defaultValue: .color(.black))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.documentEnhancer,
            title: "Document Enhancer",
            category: .colorEffect,
            summary: "Increase contrast and readability of scanned documents"
        ),

        // MARK: - 6. Generator
        NodeDefinition(
            typeID: NodeTypeID.blankImage,
            title: "Blank Image",
            category: .generator,
            summary: "Generate a solid or transparent canvas",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true,
            parameters: [
                ParameterDescriptor(key: "width", label: "Width", kind: .intSlider(min: 16, max: 8192, unit: "px"), defaultValue: .int(1200)),
                ParameterDescriptor(key: "height", label: "Height", kind: .intSlider(min: 16, max: 8192, unit: "px"), defaultValue: .int(800)),
                ParameterDescriptor(key: "color", label: "Fill Color", kind: .color, defaultValue: .color(.white))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.screenshot,
            title: "Screenshot",
            category: .generator,
            summary: "Capture main display via ScreenCaptureKit",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true
        ),
        NodeDefinition(
            typeID: NodeTypeID.imageGrid,
            title: "Image Grid",
            category: .generator,
            summary: "Assemble incoming images into a contact sheet",
            inputPortCount: 1,
            outputPortCount: 1,
            isBatchCollector: true,
            parameters: [
                ParameterDescriptor(key: "columns", label: "Columns", kind: .intSlider(min: 1, max: 12, unit: ""), defaultValue: .int(4)),
                ParameterDescriptor(key: "tileSize", label: "Tile Size", kind: .intSlider(min: 64, max: 1024, unit: "px"), defaultValue: .int(256)),
                ParameterDescriptor(key: "spacing", label: "Spacing", kind: .intSlider(min: 0, max: 100, unit: "px"), defaultValue: .int(12)),
                ParameterDescriptor(key: "backgroundColor", label: "Background", kind: .color, defaultValue: .color(.white))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.animatedImage,
            title: "Animated Image",
            category: .generator,
            summary: "Combine frames into an animated GIF",
            inputPortCount: 1,
            outputPortCount: 1,
            isBatchCollector: true,
            parameters: [
                ParameterDescriptor(key: "frameDelay", label: "Frame Delay", kind: .slider(min: 0.02, max: 5.0, step: 0.02, unit: "s"), defaultValue: .double(0.25)),
                ParameterDescriptor(key: "loopCount", label: "Loop Count (0 = infinite)", kind: .intSlider(min: 0, max: 50, unit: ""), defaultValue: .int(0)),
                ParameterDescriptor(key: "fileName", label: "Output Name", kind: .text(placeholder: "Animated"), defaultValue: .string("Animated"))
            ]
        ),

        // MARK: - 7. Metadata
        NodeDefinition(
            typeID: NodeTypeID.deleteMetadata,
            title: "Delete Metadata",
            category: .metadata,
            summary: "Strip EXIF, IPTC, XMP and GPS tags",
            parameters: [ParameterDescriptor(key: "keepOrientation", label: "Keep orientation tag", kind: .toggle, defaultValue: .bool(true))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.removeGPS,
            title: "Remove GPS",
            category: .metadata,
            summary: "Scrub GPS location coordinates only"
        ),
        NodeDefinition(
            typeID: NodeTypeID.setDPI,
            title: "Set DPI",
            category: .metadata,
            summary: "Set image DPI metadata",
            parameters: [ParameterDescriptor(key: "dpi", label: "DPI", kind: .intSlider(min: 36, max: 1200, unit: "DPI"), defaultValue: .int(300))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.setGeneralMetadata,
            title: "Set General Metadata",
            category: .metadata,
            summary: "Set author, copyright, title, and description",
            parameters: [
                ParameterDescriptor(key: "author", label: "Author", kind: .text(placeholder: "Author"), defaultValue: .string("")),
                ParameterDescriptor(key: "copyright", label: "Copyright", kind: .text(placeholder: "© 2026"), defaultValue: .string("")),
                ParameterDescriptor(key: "title", label: "Title", kind: .text(placeholder: "Title"), defaultValue: .string("")),
                ParameterDescriptor(key: "description", label: "Description", kind: .text(placeholder: "Description"), defaultValue: .string(""))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.fixExifRotation,
            title: "Fix EXIF Rotation",
            category: .metadata,
            summary: "Bake EXIF orientation into pixels and reset tag"
        ),

        // MARK: - 8. Misc
        NodeDefinition(
            typeID: NodeTypeID.changeBitsPerChannel,
            title: "Change Bits Per Channel",
            category: .misc,
            summary: "Convert pixel bit depth (8, 16, or 32 bpc)",
            parameters: [ParameterDescriptor(key: "bits", label: "Bits / Channel", kind: .picker(options: ["8", "16", "32"]), defaultValue: .string("8"))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.duplicate,
            title: "Duplicate",
            category: .misc,
            summary: "Clone each incoming asset N times",
            parameters: [ParameterDescriptor(key: "copies", label: "Copies", kind: .intSlider(min: 1, max: 10, unit: "x"), defaultValue: .int(2))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.delay,
            title: "Delay",
            category: .misc,
            summary: "Pause pipeline execution per asset",
            parameters: [ParameterDescriptor(key: "seconds", label: "Delay", kind: .slider(min: 0.05, max: 10.0, step: 0.05, unit: "s"), defaultValue: .double(0.5))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.layerPageSplitter,
            title: "Layer & Page Splitter",
            category: .misc,
            summary: "Split multi-page PDF, TIFF or GIF into frames"
        ),
        NodeDefinition(
            typeID: NodeTypeID.extractPortraitMatte,
            title: "Extract Portrait Matte",
            category: .misc,
            summary: "Extract embedded portrait matte auxiliary data"
        ),
        NodeDefinition(
            typeID: NodeTypeID.contrastStretch,
            title: "Contrast Stretch",
            category: .misc,
            summary: "Normalize tonal range via histogram stretch"
        ),
        NodeDefinition(
            typeID: NodeTypeID.customConvolution,
            title: "Custom Convolution",
            category: .misc,
            summary: "Apply a 3x3 custom convolution kernel",
            parameters: [
                ParameterDescriptor(key: "weights", label: "3x3 Weights", kind: .text(placeholder: "0,-1,0,-1,5,-1,0,-1,0"), defaultValue: .string("0,-1,0,-1,5,-1,0,-1,0"))
            ]
        ),

        // MARK: - 9. PDF
        NodeDefinition(
            typeID: NodeTypeID.pdfMaker,
            title: "PDF Maker",
            category: .pdf,
            summary: "Combine incoming images into a multi-page PDF",
            inputPortCount: 1,
            outputPortCount: 1,
            isBatchCollector: true,
            parameters: [
                ParameterDescriptor(key: "fileName", label: "PDF Name", kind: .text(placeholder: "Combined"), defaultValue: .string("Combined")),
                ParameterDescriptor(key: "margin", label: "Margin", kind: .intSlider(min: 0, max: 120, unit: "pt"), defaultValue: .int(0))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.pdfExtractor,
            title: "PDF Image Extractor",
            category: .pdf,
            summary: "Render pages out of incoming PDF documents",
            parameters: [ParameterDescriptor(key: "dpi", label: "Render DPI", kind: .intSlider(min: 72, max: 600, unit: "DPI"), defaultValue: .int(150))]
        ),

        // MARK: - 10. Photos Library
        NodeDefinition(
            typeID: NodeTypeID.readPhotosLibrary,
            title: "Read Photos Library",
            category: .photosLibrary,
            summary: "Read recent assets or an album from Apple Photos",
            inputPortCount: 0,
            outputPortCount: 1,
            isSource: true,
            parameters: [
                ParameterDescriptor(key: "albumName", label: "Album (blank = Recents)", kind: .text(placeholder: "Favorites"), defaultValue: .string("")),
                ParameterDescriptor(key: "limit", label: "Max Assets", kind: .intSlider(min: 1, max: 500, unit: ""), defaultValue: .int(25))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.importToPhotos,
            title: "Import to Photos",
            category: .photosLibrary,
            summary: "Save processed assets into Apple Photos",
            inputPortCount: 1,
            outputPortCount: 0,
            isSink: true,
            parameters: [
                ParameterDescriptor(key: "albumName", label: "Target Album", kind: .text(placeholder: "FlowBatch Exports"), defaultValue: .string(""))
            ]
        ),

        // MARK: - 11. Script
        NodeDefinition(
            typeID: NodeTypeID.javaScript,
            title: "JavaScript",
            category: .script,
            summary: "Run sandboxed JavaScript with asset metadata hook",
            parameters: [
                ParameterDescriptor(
                    key: "code",
                    label: "Script",
                    kind: .multilineCode(language: "javascript"),
                    defaultValue: .string("function processAsset(asset) {\n  // asset.setOutputName(asset.fileName + '_edited');\n  return asset;\n}")
                )
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.shellScript,
            title: "Shell Script",
            category: .script,
            summary: "Execute /bin/zsh script on staged asset file",
            parameters: [
                ParameterDescriptor(key: "script", label: "Shell Command", kind: .multilineCode(language: "zsh"), defaultValue: .string("# $1 holds the staged image path\necho \"Processing $1\""))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.appleScript,
            title: "AppleScript",
            category: .script,
            summary: "Execute NSAppleScript automation",
            parameters: [
                ParameterDescriptor(key: "script", label: "AppleScript", kind: .multilineCode(language: "applescript"), defaultValue: .string("-- Runs on workflow completion or asset"))
            ]
        ),

        // MARK: - 12. Sharpen
        NodeDefinition(
            typeID: NodeTypeID.sharpenLuminance,
            title: "Sharpen Luminance",
            category: .sharpen,
            summary: "Sharpen luminance detail cleanly",
            parameters: [
                ParameterDescriptor(key: "sharpness", label: "Sharpness", kind: .slider(min: 0, max: 2, step: 0.05, unit: ""), defaultValue: .double(0.6)),
                ParameterDescriptor(key: "radius", label: "Radius", kind: .slider(min: 0.5, max: 10, step: 0.1, unit: "px"), defaultValue: .double(1.69))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.unsharpMask,
            title: "Unsharp Mask",
            category: .sharpen,
            summary: "Classic radius/intensity unsharp mask",
            parameters: [
                ParameterDescriptor(key: "radius", label: "Radius", kind: .slider(min: 0.5, max: 25, step: 0.1, unit: "px"), defaultValue: .double(2.5)),
                ParameterDescriptor(key: "intensity", label: "Intensity", kind: .slider(min: 0, max: 2, step: 0.05, unit: ""), defaultValue: .double(0.75))
            ]
        ),

        // MARK: - 13. Sort
        NodeDefinition(
            typeID: NodeTypeID.rules,
            title: "Rules",
            category: .sort,
            summary: "Filter or route assets using predicate rules",
            inputPortCount: 1,
            outputPortCount: 2,
            outputPortLabels: ["Matched", "Unmatched"],
            parameters: [
                ParameterDescriptor(key: "matchAll", label: "Match All Rules", kind: .toggle, defaultValue: .bool(true)),
                ParameterDescriptor(key: "rules", label: "Rules", kind: .text(placeholder: ""), defaultValue: .rules([FilterRule()]))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.classifyImages,
            title: "Classify Images",
            category: .sort,
            summary: "Tag assets using Vision VNClassifyImageRequest",
            parameters: [
                ParameterDescriptor(key: "minConfidence", label: "Min Confidence", kind: .slider(min: 0.05, max: 0.99, step: 0.05, unit: ""), defaultValue: .double(0.35)),
                ParameterDescriptor(key: "maxLabels", label: "Max Tags", kind: .intSlider(min: 1, max: 10, unit: ""), defaultValue: .int(5))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.sortOrder,
            title: "Sort Order",
            category: .sort,
            summary: "Reorder incoming asset stream",
            isBatchCollector: true,
            parameters: [
                ParameterDescriptor(key: "sortBy", label: "Sort By", kind: .picker(options: ["File Name", "Width", "Height", "File Size", "Reverse"]), defaultValue: .string("File Name")),
                ParameterDescriptor(key: "ascending", label: "Ascending", kind: .toggle, defaultValue: .bool(true))
            ]
        ),

        // MARK: - 14. Transform
        NodeDefinition(
            typeID: NodeTypeID.scale,
            title: "Scale",
            category: .transform,
            summary: "Resize images by width, height, or percentage",
            parameters: [
                ParameterDescriptor(key: "mode", label: "Scale Mode", kind: .picker(options: ["Fixed Width", "Fixed Height", "Percentage", "Fit Inside", "Exact Size"]), defaultValue: .string("Fixed Width")),
                ParameterDescriptor(key: "width", label: "Width", kind: .intSlider(min: 16, max: 12000, unit: "px"), defaultValue: .int(800)),
                ParameterDescriptor(key: "height", label: "Height", kind: .intSlider(min: 16, max: 12000, unit: "px"), defaultValue: .int(600)),
                ParameterDescriptor(key: "percent", label: "Percent", kind: .slider(min: 1, max: 400, step: 1, unit: "%"), defaultValue: .double(50)),
                ParameterDescriptor(key: "allowUpscale", label: "Allow upscaling", kind: .toggle, defaultValue: .bool(true))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.crop,
            title: "Crop",
            category: .transform,
            summary: "Crop to pixel dimensions or aspect ratio",
            parameters: [
                ParameterDescriptor(key: "mode", label: "Crop Mode", kind: .picker(options: ["Pixels", "Aspect Ratio"]), defaultValue: .string("Aspect Ratio")),
                ParameterDescriptor(key: "width", label: "Width", kind: .intSlider(min: 16, max: 12000, unit: "px"), defaultValue: .int(800)),
                ParameterDescriptor(key: "height", label: "Height", kind: .intSlider(min: 16, max: 12000, unit: "px"), defaultValue: .int(800)),
                ParameterDescriptor(key: "aspectRatio", label: "Aspect Ratio", kind: .picker(options: ["1:1", "4:3", "16:9", "3:2", "9:16"]), defaultValue: .string("1:1")),
                ParameterDescriptor(key: "anchor", label: "Anchor", kind: .anchorGrid, defaultValue: .string("center"))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.rotate,
            title: "Rotate",
            category: .transform,
            summary: "Rotate image by arbitrary angle",
            parameters: [
                ParameterDescriptor(key: "degrees", label: "Angle", kind: .slider(min: -180, max: 180, step: 1, unit: "°"), defaultValue: .double(90)),
                ParameterDescriptor(key: "backgroundColor", label: "Background", kind: .color, defaultValue: .color(.clear))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.flip,
            title: "Flip",
            category: .transform,
            summary: "Mirror horizontally or vertically",
            parameters: [
                ParameterDescriptor(key: "direction", label: "Direction", kind: .picker(options: ["Horizontal", "Vertical", "Both"]), defaultValue: .string("Horizontal"))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.trimToEdges,
            title: "Trim to Edges",
            category: .transform,
            summary: "Remove outer transparent padding",
            parameters: [ParameterDescriptor(key: "alphaThreshold", label: "Alpha Threshold", kind: .slider(min: 0.01, max: 0.5, step: 0.01, unit: ""), defaultValue: .double(0.02))]
        ),
        NodeDefinition(
            typeID: NodeTypeID.mlSuperResolution,
            title: "Upscale & Sharpen",
            category: .transform,
            summary: "2x/4x Lanczos upscale with luminance edge sharpening",
            parameters: [
                ParameterDescriptor(key: "multiplier", label: "Factor", kind: .picker(options: ["2x", "4x"]), defaultValue: .string("2x")),
                ParameterDescriptor(key: "edgeSharpen", label: "Edge Detail", kind: .slider(min: 0, max: 1, step: 0.05, unit: ""), defaultValue: .double(0.45))
            ]
        ),

        // MARK: - 15. Watermark
        NodeDefinition(
            typeID: NodeTypeID.textWatermark,
            title: "Text Watermark",
            category: .watermark,
            summary: "Overlay dynamic tokenized text watermark",
            parameters: [
                ParameterDescriptor(key: "text", label: "Text", kind: .tokenField, defaultValue: .string("@ FlowBatch Sample")),
                ParameterDescriptor(key: "fontSize", label: "Font Size", kind: .slider(min: 8, max: 240, step: 1, unit: "pt"), defaultValue: .double(28)),
                ParameterDescriptor(key: "color", label: "Text Color", kind: .color, defaultValue: .color(.white)),
                ParameterDescriptor(key: "opacity", label: "Opacity", kind: .slider(min: 0.05, max: 1.0, step: 0.02, unit: ""), defaultValue: .double(0.75)),
                ParameterDescriptor(key: "anchor", label: "Position", kind: .anchorGrid, defaultValue: .string("bottomRight")),
                ParameterDescriptor(key: "marginX", label: "Margin X", kind: .intSlider(min: 0, max: 400, unit: "px"), defaultValue: .int(28)),
                ParameterDescriptor(key: "marginY", label: "Margin Y", kind: .intSlider(min: 0, max: 400, unit: "px"), defaultValue: .int(24)),
                ParameterDescriptor(key: "rotation", label: "Rotation", kind: .slider(min: -180, max: 180, step: 1, unit: "°"), defaultValue: .double(0)),
                ParameterDescriptor(key: "tile", label: "Tile across image", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "blendMode", label: "Blend Mode", kind: .picker(options: blendModes), defaultValue: .string("Normal"))
            ]
        ),
        NodeDefinition(
            typeID: NodeTypeID.imageWatermark,
            title: "Image Watermark",
            category: .watermark,
            summary: "Overlay badge or logo image",
            parameters: [
                ParameterDescriptor(key: "imagePath", label: "Watermark Image", kind: .filePath(allowedExtensions: ["png", "jpg", "jpeg", "tiff", "pdf"]), defaultValue: .string("")),
                ParameterDescriptor(key: "scalePercent", label: "Scale", kind: .slider(min: 2, max: 100, step: 1, unit: "%"), defaultValue: .double(20)),
                ParameterDescriptor(key: "opacity", label: "Opacity", kind: .slider(min: 0.05, max: 1.0, step: 0.02, unit: ""), defaultValue: .double(0.8)),
                ParameterDescriptor(key: "anchor", label: "Position", kind: .anchorGrid, defaultValue: .string("bottomRight")),
                ParameterDescriptor(key: "marginX", label: "Margin X", kind: .intSlider(min: 0, max: 400, unit: "px"), defaultValue: .int(24)),
                ParameterDescriptor(key: "marginY", label: "Margin Y", kind: .intSlider(min: 0, max: 400, unit: "px"), defaultValue: .int(24)),
                ParameterDescriptor(key: "tile", label: "Tile across image", kind: .toggle, defaultValue: .bool(false)),
                ParameterDescriptor(key: "blendMode", label: "Blend Mode", kind: .picker(options: blendModes), defaultValue: .string("Normal"))
            ]
        )
    ]

    public static let definitionsByID: [String: NodeDefinition] = {
        Dictionary(uniqueKeysWithValues: allDefinitions.map { ($0.typeID, $0) })
    }()

    public static func definition(for typeID: String) -> NodeDefinition? {
        definitionsByID[typeID]
    }

    public static func nodes(in category: NodeCategory, matching query: String = "") -> [NodeDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allDefinitions.filter { def in
            guard def.category == category else { return false }
            if trimmed.isEmpty { return true }
            return def.title.lowercased().contains(trimmed)
                || def.summary.lowercased().contains(trimmed)
                || category.rawValue.lowercased().contains(trimmed)
        }
    }
}
