# Example Workflows

Five ready-to-open `.flowbatch` recipes covering common batch image pipelines. Every file in this directory is validated by automated tests on both the macOS Swift engine and the experimental Windows Rust engine.

Open any `.flowbatch` file in FlowBatch Studio, select an input folder on the `Read Folder` node, and run.

| Workflow | Pipeline | Use Case |
|---|---|---|
| [`01-web-retina-png-crush.flowbatch`](01-web-retina-png-crush.flowbatch) | `Read Folder` -> `Delete Metadata` -> `Scale (Fit 1600)` -> `Multi Scale (1x, @2x)` -> `Write Images` (256-color Indexed PNG + Crush) | Frontend & app asset generation |
| [`02-client-proofing-privacy.flowbatch`](02-client-proofing-privacy.flowbatch) | `Read Folder` -> `Fix EXIF Rotation` -> `Remove GPS` -> `Text Watermark` -> `Scale (1600px)` -> `Write Images` (JPEG 88%) | Client proofing with GPS scrubbing |
| [`03-smart-orientation-branching.flowbatch`](03-smart-orientation-branching.flowbatch) | `Read Folder` -> `Rules (Width > 1200)` -> Matched: `Crop 16:9` / Unmatched: `Crop 1:1` -> separate `Write Images` sinks | Conditional DAG routing by image geometry |
| [`04-docs-screenshot-polisher.flowbatch`](04-docs-screenshot-polisher.flowbatch) | `Read Folder` -> `Trim to Edges` -> `Add Border (16px)` -> `Drop Shadow` -> `Write Images` (128-color Indexed PNG + Crush) | Documentation screenshot framing |
| [`05-portfolio-pdf-and-contact-sheet.flowbatch`](05-portfolio-pdf-and-contact-sheet.flowbatch) | `Read Folder` -> `Sort Order` -> parallel fan-out to `Image Grid` (PNG) and `PDF Maker` (multi-page PDF) | Contact sheets and PDF portfolios from one pass |
