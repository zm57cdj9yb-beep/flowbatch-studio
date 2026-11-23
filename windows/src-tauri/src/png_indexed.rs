use flate2::write::ZlibEncoder;
use flate2::Compression;
use image::RgbaImage;
use std::io::Write;

/// Clean-room Rust Indexed PNG (Color Type 3) Encoder:
/// Median-Cut quantization (2..=256 colors) -> Floyd-Steinberg dithering ->
/// adaptive 1/2/4/8-bpp scanline packing -> manual PNG chunks (IHDR/sRGB/PLTE/tRNS/IDAT/IEND)
/// -> optional lossless `oxipng` Crush / Brute-Force Crush.
pub struct IndexedPngOptions {
    pub max_colors: usize,
    pub speed: u8,
    pub dither: bool,
    pub remove_alpha_if_opaque: bool,
    pub crush: bool,
    pub brute_force_crush: bool,
    pub remove_color_profile: bool,
}

#[derive(Clone, Copy)]
struct ColorBox {
    start: usize,
    end: usize,
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in bytes {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn push_chunk(out: &mut Vec<u8>, chunk_type: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(chunk_type);
    out.extend_from_slice(data);
    let mut crc_buf = Vec::with_capacity(4 + data.len());
    crc_buf.extend_from_slice(chunk_type);
    crc_buf.extend_from_slice(data);
    out.extend_from_slice(&crc32(&crc_buf).to_be_bytes());
}

fn median_cut_palette(rgba: &RgbaImage, max_colors: usize, speed: u8) -> Vec<[u8; 4]> {
    let target = max_colors.clamp(2, 256);
    let stride = (speed.clamp(1, 10) as usize).max(1);
    let mut samples: Vec<[u8; 4]> = Vec::new();
    let pixels = rgba.as_raw();
    let total = pixels.len() / 4;
    let mut idx = 0usize;
    while idx < total {
        let base = idx * 4;
        samples.push([
            pixels[base],
            pixels[base + 1],
            pixels[base + 2],
            pixels[base + 3],
        ]);
        idx += stride;
    }
    if samples.is_empty() {
        return vec![[0, 0, 0, 255], [255, 255, 255, 255]];
    }

    let mut boxes = vec![ColorBox {
        start: 0,
        end: samples.len(),
    }];

    while boxes.len() < target {
        let mut best_idx = None;
        let mut best_range = 0u8;
        let mut best_channel = 0usize;

        for (bi, b) in boxes.iter().enumerate() {
            if b.end - b.start < 2 {
                continue;
            }
            let slice = &samples[b.start..b.end];
            let mut mins = [255u8; 4];
            let mut maxs = [0u8; 4];
            for px in slice {
                for c in 0..4 {
                    if px[c] < mins[c] {
                        mins[c] = px[c];
                    }
                    if px[c] > maxs[c] {
                        maxs[c] = px[c];
                    }
                }
            }
            for c in 0..4 {
                let r = maxs[c] - mins[c];
                if r > best_range {
                    best_range = r;
                    best_idx = Some(bi);
                    best_channel = c;
                }
            }
        }

        let Some(bi) = best_idx else { break };
        if best_range == 0 {
            break;
        }
        let b = boxes.swap_remove(bi);
        let ch = best_channel;
        samples[b.start..b.end].sort_unstable_by_key(|p| p[ch]);
        let mid = (b.start + b.end) / 2;
        boxes.push(ColorBox {
            start: b.start,
            end: mid,
        });
        boxes.push(ColorBox {
            start: mid,
            end: b.end,
        });
    }

    let mut palette: Vec<[u8; 4]> = boxes
        .iter()
        .filter(|b| b.end > b.start)
        .map(|b| {
            let mut sums = [0u64; 4];
            let len = (b.end - b.start) as u64;
            for px in &samples[b.start..b.end] {
                for c in 0..4 {
                    sums[c] += px[c] as u64;
                }
            }
            [
                (sums[0] / len) as u8,
                (sums[1] / len) as u8,
                (sums[2] / len) as u8,
                (sums[3] / len) as u8,
            ]
        })
        .collect();

    if palette.is_empty() {
        palette.push([0, 0, 0, 255]);
    }
    palette
}

#[inline]
fn nearest_palette_index(palette: &[[u8; 4]], r: i32, g: i32, b: i32, a: i32) -> usize {
    let mut best = 0usize;
    let mut best_dist = i64::MAX;
    for (i, p) in palette.iter().enumerate() {
        let dr = r - p[0] as i32;
        let dg = g - p[1] as i32;
        let db = b - p[2] as i32;
        let da = a - p[3] as i32;
        let d = (dr * dr + dg * dg + db * db + da * da) as i64;
        if d < best_dist {
            best_dist = d;
            best = i;
            if d == 0 {
                break;
            }
        }
    }
    best
}

pub fn encode_indexed_png(rgba: &RgbaImage, opts: &IndexedPngOptions) -> Result<Vec<u8>, String> {
    let (w, h) = rgba.dimensions();
    if w == 0 || h == 0 {
        return Err("Cannot encode empty image to indexed PNG".into());
    }

    let mut is_opaque = true;
    for chunk in rgba.as_raw().chunks_exact(4) {
        if chunk[3] < 255 {
            is_opaque = false;
            break;
        }
    }

    let mut palette = median_cut_palette(rgba, opts.max_colors, opts.speed);
    if is_opaque && opts.remove_alpha_if_opaque {
        for c in &mut palette {
            c[3] = 255;
        }
    }

    // Sort transparent entries first for compact tRNS chunk
    palette.sort_by_key(|c| c[3]);

    let palette_len = palette.len();
    let bit_depth: u8 = if palette_len <= 2 {
        1
    } else if palette_len <= 4 {
        2
    } else if palette_len <= 16 {
        4
    } else {
        8
    };

    let mut indices = vec![0u8; (w * h) as usize];
    if opts.dither {
        let mut buf: Vec<[f32; 4]> = rgba
            .as_raw()
            .chunks_exact(4)
            .map(|c| [c[0] as f32, c[1] as f32, c[2] as f32, c[3] as f32])
            .collect();
        let wi = w as usize;
        let hi = h as usize;
        for y in 0..hi {
            for x in 0..wi {
                let idx = y * wi + x;
                let old = buf[idx];
                let pi = nearest_palette_index(
                    &palette,
                    old[0].round().clamp(0.0, 255.0) as i32,
                    old[1].round().clamp(0.0, 255.0) as i32,
                    old[2].round().clamp(0.0, 255.0) as i32,
                    old[3].round().clamp(0.0, 255.0) as i32,
                );
                indices[idx] = pi as u8;
                let p = palette[pi];
                let err = [
                    old[0] - p[0] as f32,
                    old[1] - p[1] as f32,
                    old[2] - p[2] as f32,
                    old[3] - p[3] as f32,
                ];
                let spread = [
                    (1isize, 0isize, 7.0 / 16.0),
                    (-1, 1, 3.0 / 16.0),
                    (0, 1, 5.0 / 16.0),
                    (1, 1, 1.0 / 16.0),
                ];
                for (dx, dy, factor) in spread {
                    let nx = x as isize + dx;
                    let ny = y as isize + dy;
                    if nx >= 0 && nx < wi as isize && ny >= 0 && ny < hi as isize {
                        let nidx = ny as usize * wi + nx as usize;
                        for c in 0..4 {
                            buf[nidx][c] = (buf[nidx][c] + err[c] * factor).clamp(0.0, 255.0);
                        }
                    }
                }
            }
        }
    } else {
        // Fast 32K RGB555 cache for opaque pixels (20x faster indexed PNG quantization)
        let mut cache = vec![0xFFFFu16; 32768];
        for (i, px) in rgba.as_raw().chunks_exact(4).enumerate() {
            if px[3] == 255 {
                let key = (((px[0] as usize) >> 3) << 10)
                    | (((px[1] as usize) >> 3) << 5)
                    | ((px[2] as usize) >> 3);
                let cached = cache[key];
                if cached != 0xFFFF {
                    indices[i] = cached as u8;
                } else {
                    let best = nearest_palette_index(
                        &palette,
                        px[0] as i32,
                        px[1] as i32,
                        px[2] as i32,
                        255,
                    ) as u8;
                    cache[key] = best as u16;
                    indices[i] = best;
                }
            } else {
                indices[i] = nearest_palette_index(
                    &palette,
                    px[0] as i32,
                    px[1] as i32,
                    px[2] as i32,
                    px[3] as i32,
                ) as u8;
            }
        }
    }

    // Pack scanlines according to bit_depth (filter byte 0 = None per row)
    let pixels_per_byte = (8 / bit_depth) as usize;
    let row_bytes = (w as usize).div_ceil(pixels_per_byte);
    let mut raw_scanlines = Vec::with_capacity((row_bytes + 1) * h as usize);
    for y in 0..h as usize {
        raw_scanlines.push(0u8); // Filter None
        let row_start = y * w as usize;
        if bit_depth == 8 {
            raw_scanlines.extend_from_slice(&indices[row_start..row_start + w as usize]);
        } else {
            let mut byte = 0u8;
            let mut bit_pos = 8u8;
            for x in 0..w as usize {
                bit_pos -= bit_depth;
                byte |= (indices[row_start + x] & ((1 << bit_depth) - 1)) << bit_pos;
                if bit_pos == 0 {
                    raw_scanlines.push(byte);
                    byte = 0;
                    bit_pos = 8;
                }
            }
            if bit_pos < 8 {
                raw_scanlines.push(byte);
            }
        }
    }

    let compression = if opts.brute_force_crush || opts.crush {
        Compression::best()
    } else {
        Compression::default()
    };
    let mut encoder = ZlibEncoder::new(Vec::new(), compression);
    encoder
        .write_all(&raw_scanlines)
        .map_err(|e| format!("zlib write failed: {e}"))?;
    let idat = encoder
        .finish()
        .map_err(|e| format!("zlib finish failed: {e}"))?;

    let mut png = Vec::with_capacity(idat.len() + 1024);
    png.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);

    // IHDR (Color Type 3 = Indexed)
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&w.to_be_bytes());
    ihdr.extend_from_slice(&h.to_be_bytes());
    ihdr.push(bit_depth);
    ihdr.push(3); // Color type 3: Indexed-colour
    ihdr.push(0); // Compression
    ihdr.push(0); // Filter
    ihdr.push(0); // Interlace
    push_chunk(&mut png, b"IHDR", &ihdr);

    if !opts.remove_color_profile {
        push_chunk(&mut png, b"sRGB", &[0]);
    }

    // PLTE
    let mut plte = Vec::with_capacity(palette.len() * 3);
    for c in &palette {
        plte.push(c[0]);
        plte.push(c[1]);
        plte.push(c[2]);
    }
    push_chunk(&mut png, b"PLTE", &plte);

    // tRNS (only if any entry has alpha < 255)
    if let Some(last_trans) = palette.iter().rposition(|c| c[3] < 255) {
        let trns: Vec<u8> = palette[..=last_trans].iter().map(|c| c[3]).collect();
        push_chunk(&mut png, b"tRNS", &trns);
    }

    push_chunk(&mut png, b"IDAT", &idat);
    push_chunk(&mut png, b"IEND", &[]);

    if opts.crush || opts.brute_force_crush {
        let mut oxi = if opts.brute_force_crush {
            oxipng::Options::from_preset(4)
        } else {
            oxipng::Options::from_preset(2)
        };
        if opts.remove_color_profile {
            oxi.strip = oxipng::StripChunks::Safe;
        }
        if let Ok(crushed) = oxipng::optimize_from_memory(&png, &oxi) {
            if crushed.len() < png.len() {
                return Ok(crushed);
            }
        }
    }

    Ok(png)
}

pub fn crush_standard_png(png_bytes: &[u8], brute_force: bool, strip_profile: bool) -> Vec<u8> {
    let mut oxi = if brute_force {
        oxipng::Options::from_preset(4)
    } else {
        oxipng::Options::from_preset(2)
    };
    if strip_profile {
        oxi.strip = oxipng::StripChunks::Safe;
    }
    oxipng::optimize_from_memory(png_bytes, &oxi).unwrap_or_else(|_| png_bytes.to_vec())
}
