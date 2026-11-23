import React, { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Contrast, Eye, EyeOff, Info, Minus, Plus } from "lucide-react";
import { DryRunAssetRef, PreviewResponse } from "../types/workflow";

interface PreviewSplitPaneProps {
  assets: DryRunAssetRef[];
  selectedAssetIndex: number;
  preview: PreviewResponse | null;
  onSelectAsset: (index: number) => void;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

export const PreviewSplitPane: React.FC<PreviewSplitPaneProps> = ({
  assets,
  selectedAssetIndex,
  preview,
  onSelectAsset,
}) => {
  const paneRef = useRef<HTMLDivElement>(null);
  const [splitRatio, setSplitRatio] = useState(0.42);
  const [zoomPercent, setZoomPercent] = useState(100);
  const [showOriginal, setShowOriginal] = useState(false);
  const [darkBg, setDarkBg] = useState(false);
  const [showInfo, setShowInfo] = useState(false);
  const [thumbs, setThumbs] = useState<Record<string, string>>({});
  const draggingSplit = useRef(false);

  // Lazy-load 256px thumbnails from Rust backend via ImageIO-style thumbnailer
  useEffect(() => {
    let cancelled = false;
    const missing = assets.filter((a) => a.path && !thumbs[a.path]);
    if (missing.length === 0) return;

    (async () => {
      for (const a of missing.slice(0, 60)) {
        if (cancelled) return;
        try {
          const dataUrl = await invoke<string>("load_thumbnail", {
            path: a.path,
            maxPx: 256,
          });
          if (!cancelled) {
            setThumbs((prev) => ({ ...prev, [a.path]: dataUrl }));
          }
        } catch {
          // Non-fatal skip
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [assets]);

  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      if (!draggingSplit.current || !paneRef.current) return;
      const rect = paneRef.current.getBoundingClientRect();
      const ratio = (e.clientY - rect.top) / Math.max(200, rect.height - 34);
      setSplitRatio(Math.max(0.24, Math.min(0.78, ratio)));
    };
    const onUp = () => {
      draggingSplit.current = false;
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
  }, []);

  const displayUrl = showOriginal ? preview?.originalDataUrl : preview?.processedDataUrl;

  return (
    <aside ref={paneRef} className="preview-pane" aria-label="Live Preview and Contact Sheet">
      <div
        className={`preview-viewport ${darkBg ? "dark" : "light"}`}
        style={{ height: `${Math.round(splitRatio * 100)}%` }}
      >
        {displayUrl ? (
          <div
            className="preview-img-frame"
            style={{
              transform: `scale(${zoomPercent / 100})`,
              transformOrigin: "center center",
              transition: "transform 0.08s ease-out",
            }}
          >
            <img src={displayUrl} alt="Live pipeline preview" />
          </div>
        ) : (
          <span style={{ color: "var(--text-muted)", fontSize: 12 }}>
            {assets.length === 0 ? "No assets selected for preview" : "Rendering preview…"}
          </span>
        )}

        {preview?.errorMessage && (
          <div
            style={{
              position: "absolute",
              top: 10,
              left: 10,
              right: 10,
              background: "rgba(209,52,56,0.92)",
              color: "#ffffff",
              fontSize: 11.5,
              padding: "5px 10px",
              borderRadius: 6,
            }}
          >
            {preview.errorMessage}
          </div>
        )}
      </div>

      <div
        className="preview-splitter"
        onMouseDown={() => {
          draggingSplit.current = true;
        }}
        title="Drag to resize preview"
      />

      <div className="thumb-grid-wrap">
        <div className="thumb-grid">
          {assets.map((asset, idx) => (
            <button
              key={asset.id}
              className={`thumb-tile ${idx === selectedAssetIndex ? "selected" : ""}`}
              title={asset.fileName}
              onClick={() => onSelectAsset(idx)}
            >
              {thumbs[asset.path] ? (
                <img src={thumbs[asset.path]} alt={asset.fileName} />
              ) : (
                <span style={{ fontSize: 10, color: "var(--text-muted)" }}>…</span>
              )}
            </button>
          ))}
        </div>
      </div>

      {showInfo && preview?.info && (
        <div className="info-hud-popover">
          <div className="info-hud-title">Asset Information</div>
          <div className="info-hud-grid">
            <span style={{ color: "var(--text-secondary)" }}>File:</span>
            <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>{preview.info.fileName}</span>
            <span style={{ color: "var(--text-secondary)" }}>Dimensions:</span>
            <span>
              {preview.info.pixelWidth} × {preview.info.pixelHeight} px
            </span>
            <span style={{ color: "var(--text-secondary)" }}>DPI / Depth:</span>
            <span>
              {preview.info.dpi} DPI • {preview.info.bitsPerChannel}-bit
            </span>
            <span style={{ color: "var(--text-secondary)" }}>Color Space:</span>
            <span>{preview.info.colorSpaceName}</span>
            <span style={{ color: "var(--text-secondary)" }}>File Size:</span>
            <span>{formatBytes(preview.info.originalByteCount)}</span>
            <span style={{ color: "var(--text-secondary)" }}>GPS Tag:</span>
            <span>{preview.info.gpsPresent ? "Present" : "None"}</span>
            {preview.info.classifications.length > 0 && (
              <>
                <span style={{ color: "var(--text-secondary)" }}>Tags:</span>
                <span>{preview.info.classifications.join(", ")}</span>
              </>
            )}
          </div>
        </div>
      )}

      <div className="preview-footer">
        <div className="preview-zoom-group">
          <span className="preview-zoom-label">{zoomPercent}%</span>
          <button
            className="icon-btn"
            style={{ width: 22, height: 22 }}
            onClick={() => setZoomPercent((z) => Math.max(25, z - 15))}
          >
            <Minus size={11} />
          </button>
          <input
            type="range"
            min={25}
            max={300}
            value={zoomPercent}
            onChange={(e) => setZoomPercent(Number(e.target.value))}
          />
          <button
            className="icon-btn"
            style={{ width: 22, height: 22 }}
            onClick={() => setZoomPercent((z) => Math.min(300, z + 15))}
          >
            <Plus size={11} />
          </button>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
          <button
            className={`icon-btn ${showOriginal ? "active" : ""}`}
            style={{ width: 24, height: 24 }}
            title="Toggle Original vs. Processed"
            onClick={() => setShowOriginal((v) => !v)}
          >
            {showOriginal ? <EyeOff size={13} /> : <Eye size={13} />}
          </button>
          <button
            className={`icon-btn ${darkBg ? "active" : ""}`}
            style={{ width: 24, height: 24 }}
            title="Toggle Dark / Light Preview Backdrop"
            onClick={() => setDarkBg((v) => !v)}
          >
            <Contrast size={13} />
          </button>
          <button
            className={`icon-btn ${showInfo ? "active" : ""}`}
            style={{ width: 24, height: 24 }}
            title="Asset Information"
            onClick={() => setShowInfo((v) => !v)}
          >
            <Info size={13} />
          </button>
        </div>
      </div>
    </aside>
  );
};
