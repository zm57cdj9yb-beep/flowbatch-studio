import React, { useMemo, useState } from "react";
import { ChevronDown, ChevronRight, Plus, Search, X } from "lucide-react";
import { ALL_CATEGORIES, NodeCategory, NodeDefinition } from "../types/workflow";

interface NodeLibrarySidebarProps {
  catalog: NodeDefinition[];
  onInsertNode: (typeID: string) => void;
}

export const NodeLibrarySidebar: React.FC<NodeLibrarySidebarProps> = ({
  catalog,
  onInsertNode,
}) => {
  const [query, setQuery] = useState("");
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  const grouped = useMemo(() => {
    const q = query.trim().toLowerCase();
    const map = new Map<NodeCategory, NodeDefinition[]>();
    for (const cat of ALL_CATEGORIES) {
      const items = catalog.filter(
        (d) =>
          d.category === cat &&
          (!q ||
            d.title.toLowerCase().includes(q) ||
            d.summary.toLowerCase().includes(q) ||
            d.category.toLowerCase().includes(q))
      );
      if (items.length > 0) {
        map.set(cat, items);
      }
    }
    return map;
  }, [catalog, query]);

  const toggleCategory = (cat: string) => {
    setExpanded((prev) => ({ ...prev, [cat]: !prev[cat] }));
  };

  const isSearching = query.trim().length > 0;

  return (
    <aside className="sidebar" aria-label="Node Library">
      <div className="sidebar-search-wrap">
        <div className="sidebar-search">
          <Search size={13} color="#6b7280" />
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search"
            aria-label="Search nodes"
          />
          {query && (
            <button
              className="icon-btn"
              style={{ width: 18, height: 18 }}
              onClick={() => setQuery("")}
              title="Clear search"
            >
              <X size={12} />
            </button>
          )}
        </div>
      </div>

      <div className="sidebar-list">
        {Array.from(grouped.entries()).map(([cat, items]) => {
          const isOpen = isSearching || !!expanded[cat];
          return (
            <div key={cat}>
              <button className="cat-header" onClick={() => toggleCategory(cat)}>
                {isOpen ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
                <span>{cat}</span>
              </button>
              {isOpen && (
                <div className="cat-items">
                  {items.map((def) => (
                    <div
                      key={def.typeID}
                      className="node-lib-item"
                      draggable
                      onDragStart={(e) => {
                        e.dataTransfer.setData("application/x-flowbatch-node", def.typeID);
                        e.dataTransfer.effectAllowed = "copy";
                      }}
                      onDoubleClick={() => onInsertNode(def.typeID)}
                      title={`${def.summary} (Double-click or drag onto canvas)`}
                    >
                      <span>{def.title}</span>
                      <Plus size={12} opacity={0.65} />
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </aside>
  );
};
