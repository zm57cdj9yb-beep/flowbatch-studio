use flowbatch_studio_windows_lib::catalog::node_type;
use flowbatch_studio_windows_lib::models::NodeParamValue;
use flowbatch_studio_windows_lib::pipeline::{create_starter_document, run_batch};
use flowbatch_studio_windows_lib::png_indexed::{encode_indexed_png, IndexedPngOptions};
use image::ImageFormat;
use std::io::Cursor;
use std::path::PathBuf;
use std::time::Instant;

fn read_ihdr(data: &[u8]) -> (u8, u8) {
    if data.len() >= 26 {
        (data[24], data[25])
    } else {
        (0, 0)
    }
}

fn median_ms<F: Fn() -> Vec<u8>>(runs: usize, f: F) -> (Vec<u8>, f64) {
    let mut times = Vec::with_capacity(runs);
    let mut last = Vec::new();
    for _ in 0..runs {
        let t0 = Instant::now();
        last = f();
        times.push(t0.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (last, times[times.len() / 2])
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage:\n  bench_png png <inputPath> [outCrushedPath]\n  bench_png batch <demoAssetsRoot> <outputDir>");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "png" => {
            let input = PathBuf::from(&args[2]);
            let out_path = args.get(3).map(PathBuf::from);
            let img = image::open(&input).expect("open input image");
            let rgba = img.to_rgba8();

            let (base, base_ms) = median_ms(3, || {
                let mut cur = Cursor::new(Vec::new());
                img.write_to(&mut cur, ImageFormat::Png).expect("encode baseline png");
                cur.into_inner()
            });
            let (bd, ct) = read_ihdr(&base);
            println!("rust|baseline_png|{}|{:.1}|{}|{}", base.len(), base_ms, bd, ct);

            let configs: [(&str, IndexedPngOptions); 4] = [
                (
                    "indexed_256_fast",
                    IndexedPngOptions {
                        max_colors: 256,
                        speed: 5,
                        dither: false,
                        remove_alpha_if_opaque: true,
                        crush: false,
                        brute_force_crush: false,
                        remove_color_profile: false,
                    },
                ),
                (
                    "indexed_256_dither",
                    IndexedPngOptions {
                        max_colors: 256,
                        speed: 3,
                        dither: true,
                        remove_alpha_if_opaque: true,
                        crush: false,
                        brute_force_crush: false,
                        remove_color_profile: false,
                    },
                ),
                (
                    "indexed_256_oxipng_crush",
                    IndexedPngOptions {
                        max_colors: 256,
                        speed: 3,
                        dither: true,
                        remove_alpha_if_opaque: true,
                        crush: true,
                        brute_force_crush: false,
                        remove_color_profile: false,
                    },
                ),
                (
                    "indexed_256_oxipng_bruteforce",
                    IndexedPngOptions {
                        max_colors: 256,
                        speed: 1,
                        dither: true,
                        remove_alpha_if_opaque: true,
                        crush: true,
                        brute_force_crush: true,
                        remove_color_profile: false,
                    },
                ),
            ];

            for (label, opts) in configs {
                let (data, ms) = median_ms(3, || {
                    encode_indexed_png(&rgba, &opts).expect("encode indexed png")
                });
                let (bd, ct) = read_ihdr(&data);
                println!("rust|{}|{}|{:.1}|{}|{}", label, data.len(), ms, bd, ct);
                if label == "indexed_256_oxipng_crush" {
                    if let Some(ref p) = out_path {
                        std::fs::write(p, &data).expect("write crushed output");
                    }
                }
            }
        }
        "batch" => {
            if args.len() < 4 {
                std::process::exit(1);
            }
            let demo_root = PathBuf::from(&args[2]);
            let out_dir = PathBuf::from(&args[3]);
            std::fs::create_dir_all(&out_dir).expect("mkdir out");

            let mut doc = create_starter_document(&demo_root);
            for n in &mut doc.nodes {
                if n.type_id == node_type::WRITE_IMAGES {
                    n.parameters.insert("folderPath".into(), NodeParamValue::String(out_dir.to_string_lossy().to_string()));
                    n.parameters.insert("openFolderWhenFinished".into(), NodeParamValue::Bool(false));
                    n.parameters.insert("overwriteExisting".into(), NodeParamValue::Bool(true));
                }
            }

            let t0 = Instant::now();
            let res = run_batch(&doc);
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            let total_bytes: u64 = res
                .written_files
                .iter()
                .filter_map(|p| std::fs::metadata(p).ok().map(|m| m.len()))
                .sum();
            println!(
                "rust|batch_30_indexed_png|{}|{:.1}|{}",
                res.written_files.len(),
                ms,
                total_bytes
            );
        }
        _ => std::process::exit(1),
    }
}
