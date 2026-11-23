use image::codecs::jpeg::JpegEncoder;
use image::{DynamicImage, GenericImageView};
use std::io::Write;

/// Pure-Rust valid PDF 1.4 multi-page document builder embedding DCTDecode (JPEG) image streams.
/// Zero native C/pdfium DLL dependency — works identically on Windows 11, macOS, and Linux.
pub fn build_multipage_pdf(images: &[DynamicImage], margin_pt: f64) -> Result<Vec<u8>, String> {
    if images.is_empty() {
        return Err("PDF Maker requires at least one input image".into());
    }
    let margin = margin_pt.clamp(0.0, 144.0);
    let mut out = Vec::new();
    let mut offsets: Vec<usize> = vec![0]; // Object 0 is free

    out.extend_from_slice(b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Pre-encode each page image as baseline RGB JPEG
    let mut encoded_pages: Vec<(u32, u32, Vec<u8>)> = Vec::with_capacity(images.len());
    for img in images {
        let rgb = img.to_rgb8();
        let (w, h) = img.dimensions();
        let mut jpeg_buf = Vec::new();
        let mut enc = JpegEncoder::new_with_quality(&mut jpeg_buf, 88);
        enc.encode_image(&rgb)
            .map_err(|e| format!("PDF JPEG encode failed: {e}"))?;
        encoded_pages.push((w.max(1), h.max(1), jpeg_buf));
    }

    let page_count = encoded_pages.len();
    // Object IDs:
    // 1 = Catalog
    // 2 = Pages
    // For each page i in 0..page_count:
    //   page_obj  = 3 + i * 3
    //   img_obj   = 4 + i * 3
    //   cont_obj  = 5 + i * 3
    let total_objs = 2 + page_count * 3;
    offsets.resize(total_objs + 1, 0);

    // 1: Catalog
    offsets[1] = out.len();
    write!(out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n").unwrap();

    // 2: Pages
    offsets[2] = out.len();
    let kids: String = (0..page_count)
        .map(|i| format!("{} 0 R", 3 + i * 3))
        .collect::<Vec<_>>()
        .join(" ");
    write!(
        out,
        "2 0 obj\n<< /Type /Pages /Kids [ {kids} ] /Count {page_count} >>\nendobj\n"
    )
    .unwrap();

    for (i, (w, h, jpeg)) in encoded_pages.iter().enumerate() {
        let page_id = 3 + i * 3;
        let img_id = 4 + i * 3;
        let cont_id = 5 + i * 3;

        let page_w = *w as f64 + margin * 2.0;
        let page_h = *h as f64 + margin * 2.0;

        offsets[page_id] = out.len();
        write!(
            out,
            "{page_id} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_w:.2} {page_h:.2}] /Resources << /XObject << /Im0 {img_id} 0 R >> >> /Contents {cont_id} 0 R >>\nendobj\n"
        )
        .unwrap();

        offsets[img_id] = out.len();
        write!(
            out,
            "{img_id} 0 obj\n<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {} >>\nstream\n",
            jpeg.len()
        )
        .unwrap();
        out.extend_from_slice(jpeg);
        out.extend_from_slice(b"\nendstream\nendobj\n");

        let stream = format!("q\n{w} 0 0 {h} {margin:.2} {margin:.2} cm\n/Im0 Do\nQ\n");
        offsets[cont_id] = out.len();
        write!(
            out,
            "{cont_id} 0 obj\n<< /Length {} >>\nstream\n{stream}endstream\nendobj\n",
            stream.len()
        )
        .unwrap();
    }

    let xref_offset = out.len();
    write!(out, "xref\n0 {}\n0000000000 65535 f \n", total_objs + 1).unwrap();
    for off in offsets.iter().skip(1) {
        write!(out, "{:010} 00000 n \n", off).unwrap();
    }
    write!(
        out,
        "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n",
        total_objs + 1
    )
    .unwrap();

    Ok(out)
}

/// Extracts embedded JPEG (`FF D8 .. FF D9`) image streams from a PDF byte buffer.
pub fn extract_jpeg_images_from_pdf(pdf_bytes: &[u8]) -> Vec<DynamicImage> {
    let mut results = Vec::new();
    let mut i = 0usize;
    while i + 3 < pdf_bytes.len() {
        if pdf_bytes[i] == 0xFF && pdf_bytes[i + 1] == 0xD8 && pdf_bytes[i + 2] == 0xFF {
            // Find matching EOI (FF D9)
            let mut j = i + 3;
            while j + 1 < pdf_bytes.len() {
                if pdf_bytes[j] == 0xFF && pdf_bytes[j + 1] == 0xD9 {
                    let candidate = &pdf_bytes[i..=j + 1];
                    if let Ok(img) = image::load_from_memory_with_format(
                        candidate,
                        image::ImageFormat::Jpeg,
                    ) {
                        results.push(img);
                        i = j + 2;
                        break;
                    }
                }
                j += 1;
            }
            if j + 1 >= pdf_bytes.len() {
                break;
            }
        } else {
            i += 1;
        }
    }
    results
}
