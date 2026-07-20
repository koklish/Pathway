/* app.jsx — Atlas File Manager. State orchestration + composition. */
const { useState: uS, useRef: uR, useEffect: uE, useMemo, useCallback } = React;

let UID = 100;
const uid = () => ++UID;

function freshPane(path) {
  return {
    id: uid(), path, history: [path], histIndex: 0,
    selection: new Set(), lastClick: null,
    view: 'details', sort: { key: 'name', dir: 'asc' },
    query: '', filters: new Set(), addrEditing: false,
  };
}

function App() {
  const FS = window.FS;
  const [theme, setTheme] = uS('light');
  const [tabs, setTabs] = uS(() => [freshPane(FS.HOME)]);
  const [activeTabId, setActiveTabId] = uS(() => tabs[0].id);
  const [paneB, setPaneB] = uS(() => freshPane('/Users/alex/Downloads'));
  const [splitView, setSplitView] = uS(false);
  const [activePane, setActivePane] = uS('A');
  const [showPreview, setShowPreview] = uS(true);
  const [showFilters, setShowFilters] = uS(false);
  const [density, setDensity] = uS(2);
  const [striped, setStriped] = uS(false);
  const [expanded, setExpanded] = uS(() => new Set(['/', '/Users', '/Users/alex', '/Users/alex/Documents']));
  const [connectedServers, setConnectedServers] = uS([]);
  const [showConnect, setShowConnect] = uS(false);

  const [clipboard, setClipboard] = uS(null);     // {mode, items:[paths]}
  const [renaming, setRenaming] = uS(null);        // {paneId, path}
  const [ctx, setCtx] = uS(null);                  // {x,y,items}
  const [copyJob, setCopyJob] = uS(null);
  const [batch, setBatch] = uS(null);              // {paneId, items}
  const [quickLook, setQuickLook] = uS(null);      // node
  const [toast, setToast] = uS(null);

  // mutable overlays
  const [hidden, setHidden] = uS(() => new Set());
  const [renamed, setRenamed] = uS(() => new Map());
  const [extra, setExtra] = uS(() => new Map());   // parentPath -> [synthetic nodes]

  const activeTab = tabs.find(t => t.id === activeTabId) || tabs[0];
  const effActivePane = splitView ? activePane : 'A';
  const getPane = (id) => id === 'A' ? activeTab : paneB;
  const aPane = getPane(effActivePane);

  function updatePane(id, upd) {
    if (id === 'A') {
      setTabs(ts => ts.map(t => t.id === activeTabId ? { ...t, ...(typeof upd === 'function' ? upd(t) : upd) } : t));
    } else {
      setPaneB(b => ({ ...b, ...(typeof upd === 'function' ? upd(b) : upd) }));
    }
  }

  const showToast = (message, icon) => { setToast({ message, icon }); clearTimeout(showToast._t); showToast._t = setTimeout(() => setToast(null), 2200); };

  // ── display name + node cloning ──
  const dispName = (node) => renamed.get(node.path) || FS.locName(node.name);

  function rawChildren(path) {
    let base = FS.children(path).slice();
    const ex = extra.get(path);
    if (ex) base = base.concat(ex);
    return base.filter(n => !hidden.has(n.path));
  }

  function computeItems(pane) {
    let list;
    if (pane.path.startsWith('tag:')) {
      const tagName = pane.path.slice(4);
      list = [];
      FS.map.forEach((n, p) => { if (FS.TAGS[p] === tagName && !hidden.has(p)) list.push(n); });
    } else if (pane.query.trim()) {
      const q = pane.query.trim().toLowerCase();
      const base = pane.path === '/' ? '/' : pane.path + '/';
      list = [];
      FS.map.forEach((n, p) => {
        if (p === pane.path || hidden.has(p)) return;
        if (pane.path !== '/' && !p.startsWith(base)) return;
        if (dispName(n).toLowerCase().includes(q)) list.push(n);
      });
    } else {
      list = rawChildren(pane.path);
    }
    // clone with display name
    list = list.map(n => n.name === dispName(n) ? n : { ...n, name: dispName(n) });
    // filters
    if (pane.filters.size) list = list.filter(n => pane.filters.has((FS.KINDS[n.kind] || {}).group));
    // sort
    const { key, dir } = pane.sort;
    const mul = dir === 'asc' ? 1 : -1;
    list.sort((a, b) => {
      if (a.dir !== b.dir) return a.dir ? -1 : 1; // folders first
      let r = 0;
      if (key === 'name' || key === 'path') r = dispName(a).localeCompare(dispName(b), undefined, { numeric: true });
      else if (key === 'size') r = (a.size || 0) - (b.size || 0);
      else if (key === 'modified') r = (a.modified?.getTime() || 0) - (b.modified?.getTime() || 0);
      else if (key === 'kind') r = (FS.KINDS[a.kind]?.label || '').localeCompare(FS.KINDS[b.kind]?.label || '');
      return (r || dispName(a).localeCompare(dispName(b))) * mul;
    });
    return list;
  }

  // ── navigation ──
  function navTo(id, path) {
    const ok = path.startsWith('tag:') || FS.exists(path) || !!findSynthetic(path) || connectedServers.some(s => path === s.path || path.startsWith(s.path + '/'));
    if (!ok) { showToast(`Путь не найден: ${path}`, 'info'); return; }
    const norm = path.startsWith('tag:') ? path : FS.normalize(path);
    updatePane(id, p => {
      if (p.path === norm) return { addrEditing: false, query: '' };
      const hist = p.history.slice(0, p.histIndex + 1).concat(norm);
      return { path: norm, history: hist, histIndex: hist.length - 1, selection: new Set(), lastClick: null, addrEditing: false, query: '' };
    });
    if (!norm.startsWith('tag:')) {
      // auto-expand sidebar to reveal
      setExpanded(s => { const n = new Set(s); const segs = FS.segments(norm); let acc = ''; segs.forEach(seg => { acc += '/' + seg; n.add(FS.parent(acc) || '/'); }); n.add('/'); FS.segments(norm).reduce((a, seg) => { const np = a + '/' + seg; if (FS.get(np)?.dir) n.add(a || '/'); return np; }, ''); return n; });
    }
  }
  const goBack = (id) => updatePane(id, p => p.histIndex > 0 ? { histIndex: p.histIndex - 1, path: p.history[p.histIndex - 1], selection: new Set(), query: '' } : {});
  const goFwd = (id) => updatePane(id, p => p.histIndex < p.history.length - 1 ? { histIndex: p.histIndex + 1, path: p.history[p.histIndex + 1], selection: new Set(), query: '' } : {});
  const goUp = (id) => { const p = getPane(id); if (p.path !== '/' && !p.path.startsWith('tag:')) navTo(id, FS.parent(p.path)); };

  // ── selection ──
  function selectItem(id, node, e) {
    const items = computeItems(getPane(id));
    updatePane(id, p => {
      const sel = new Set(p.selection);
      if (e.shiftKey && p.lastClick) {
        const i1 = items.findIndex(n => n.path === p.lastClick);
        const i2 = items.findIndex(n => n.path === node.path);
        if (i1 >= 0 && i2 >= 0) { const [a, b] = [Math.min(i1, i2), Math.max(i1, i2)]; for (let i = a; i <= b; i++) sel.add(items[i].path); }
        return { selection: sel };
      }
      if (e.metaKey || e.ctrlKey) { sel.has(node.path) ? sel.delete(node.path) : sel.add(node.path); return { selection: sel, lastClick: node.path }; }
      return { selection: new Set([node.path]), lastClick: node.path };
    });
    setActivePane(id);
  }
  const selectAll = (id) => { const items = computeItems(getPane(id)); updatePane(id, { selection: new Set(items.map(n => n.path)) }); };
  const clearSel = (id) => updatePane(id, { selection: new Set(), lastClick: null });

  function openNode(id, node) {
    if (node.dir) navTo(id, node.path);
    else setQuickLook(node);
  }

  // ── overlays mutation helpers ──
  function addSynthetic(destPath, node, asName) {
    const newPath = (destPath === '/' ? '' : destPath) + '/' + (asName || node.name);
    const syn = { ...node, name: asName || node.name, path: newPath, synthetic: true, modified: new Date('2026-06-08T11:00:00') };
    setExtra(m => { const n = new Map(m); const arr = (n.get(destPath) || []).slice(); arr.push(syn); n.set(destPath, arr); return n; });
    return newPath;
  }

  // ── clipboard / transfer ──
  function doCopy(id, mode) {
    const p = getPane(id);
    const items = [...p.selection];
    if (!items.length) return;
    setClipboard({ mode, items });
    showToast(`${mode === 'cut' ? 'Вырезано' : 'Скопировано'}: ${items.length} ${FS.plural(items.length, ['объект', 'объекта', 'объектов'])}`, mode === 'cut' ? 'cut' : 'copy');
  }
  function doPaste(id) {
    if (!clipboard) return;
    const p = getPane(id);
    const destPath = p.path.startsWith('tag:') ? FS.HOME : p.path;
    const files = clipboard.items.map(pp => { const n = FS.get(pp) || findSynthetic(pp); return n ? { name: dispName(n), size: n.size || 0, node: n } : null; }).filter(Boolean);
    if (!files.length) return;
    startTransfer(clipboard.mode === 'cut' ? 'move' : 'copy', files, destPath, () => {
      if (clipboard.mode === 'cut') { setHidden(h => { const n = new Set(h); clipboard.items.forEach(x => n.add(x)); return n; }); setClipboard(null); }
    });
  }
  function findSynthetic(path) { let f = null; extra.forEach(arr => arr.forEach(n => { if (n.path === path) f = n; })); return f; }

  // ── network servers ──
  const REMOTE_NOW = new Date('2026-06-08T11:00:00');
  function mountServer(server) {
    const rootPath = '/Network/' + server.name;
    if (connectedServers.some(s => s.path === rootPath)) { navTo(effActivePane, rootPath); setShowConnect(false); return; }
    const additions = [];
    function walk(raw, parent) {
      const path = parent + '/' + raw.name;
      if (!raw.dir) {
        const node = { name: raw.name, path, dir: false, kind: FS.kindOf(raw.name, false), synthetic: true, remote: true,
          size: (raw.kb || 0) * 1024, modified: new Date(REMOTE_NOW.getTime() - (raw.daysAgo || 0) * 86400000), children: [] };
        additions.push({ parent, node });
        return { size: node.size, modified: node.modified };
      }
      const kids = (raw.children || []).map(c => walk(c, path));
      let total = 0, newest = 0;
      kids.forEach(k => { total += k.size; if (k.modified && k.modified.getTime() > newest) newest = k.modified.getTime(); });
      const node = { name: raw.name, path, dir: true, kind: 'folder', synthetic: true, remote: true,
        size: total, count: (raw.children || []).length, modified: newest ? new Date(newest) : REMOTE_NOW, children: [] };
      additions.push({ parent, node });
      return { size: total, modified: node.modified };
    }
    const kids = FS.REMOTE_TEMPLATE.map(c => walk(c, rootPath));
    let total = 0, newest = 0;
    kids.forEach(k => { total += k.size; if (k.modified && k.modified.getTime() > newest) newest = k.modified.getTime(); });
    const rootNode = { name: server.name, path: rootPath, dir: true, kind: 'folder', synthetic: true, remote: true,
      protocol: server.protocol, address: server.address, size: total, count: FS.REMOTE_TEMPLATE.length,
      modified: newest ? new Date(newest) : REMOTE_NOW, children: [] };
    additions.push({ parent: '/Network', node: rootNode });
    setExtra(m => {
      const n = new Map(m);
      additions.forEach(({ parent, node }) => { const arr = (n.get(parent) || []).slice(); arr.push(node); n.set(parent, arr); });
      return n;
    });
    setConnectedServers(s => [...s, { name: server.name, path: rootPath, protocol: server.protocol, address: server.address, guest: server.guest, username: server.username }]);
    setShowConnect(false);
    // navigate directly — bypasses navTo's existence guard, which would otherwise read the pre-update (stale) extra/connectedServers closure
    updatePane(effActivePane, p => {
      if (p.path === rootPath) return {};
      const hist = p.history.slice(0, p.histIndex + 1).concat(rootPath);
      return { path: rootPath, history: hist, histIndex: hist.length - 1, selection: new Set(), lastClick: null, addrEditing: false, query: '' };
    });
    showToast(`Подключено: ${server.name}`, 'server');
  }
  function disconnectServer(rootPath) {
    setExtra(m => {
      const n = new Map();
      m.forEach((arr, parent) => {
        if (parent === rootPath || parent.startsWith(rootPath + '/')) return;
        n.set(parent, arr.filter(node => node.path !== rootPath));
      });
      return n;
    });
    setConnectedServers(s => s.filter(x => x.path !== rootPath));
    ['A', 'B'].forEach(id => { const p = getPane(id); if (p.path === rootPath || p.path.startsWith(rootPath + '/')) navTo(id, FS.HOME); });
    showToast('Отключено от сервера', 'server');
  }
  function openServerContext(e, server) {
    e.preventDefault(); e.stopPropagation();
    setCtx({ x: e.clientX, y: e.clientY, items: [
      { label: 'Открыть', icon: 'open', action: () => navTo(effActivePane, server.path) },
      { label: 'Открыть в новой вкладке', icon: 'plus', action: () => addTab(server.path) },
      { label: 'Скопировать адрес', icon: 'copy', action: () => showToast('Адрес скопирован', 'copy') },
      { sep: true },
      { label: 'Отключить', icon: 'server', danger: true, action: () => disconnectServer(server.path) },
    ] });
  }

  function startTransfer(mode, files, destPath, onComplete) {
    const destNode = FS.get(destPath);
    setCopyJob({
      mode, files: files.map(f => ({ name: f.name, size: f.size })),
      destName: destNode ? (destNode.name === '/' ? 'This Mac' : destNode.name) : destPath,
      _files: files, _dest: destPath, _onComplete: onComplete,
    });
  }
  function finishTransfer() {
    const job = copyJob;
    if (job) {
      job._files.forEach(f => addSynthetic(job._dest, f.node, f.name));
      if (job.mode === 'move') setHidden(h => { const n = new Set(h); job._files.forEach(f => n.add(f.node.path)); return n; });
      job._onComplete && job._onComplete();
      showToast(`${job.mode === 'move' ? 'Перемещено' : 'Скопировано'}: ${job._files.length} ${FS.plural(job._files.length, ['объект', 'объекта', 'объектов'])} → ${job.destName}`, 'check');
    }
    setCopyJob(null);
  }

  // ── delete / new folder / rename ──
  function doDelete(id) {
    const p = getPane(id);
    const items = [...p.selection];
    if (!items.length) return;
    setHidden(h => { const n = new Set(h); items.forEach(x => n.add(x)); return n; });
    clearSel(id);
    showToast(`Перемещено в Корзину: ${items.length} ${FS.plural(items.length, ['объект', 'объекта', 'объектов'])}`, 'trash');
  }
  function newFolder(id) {
    const p = getPane(id);
    const dest = p.path.startsWith('tag:') ? FS.HOME : p.path;
    const existing = rawChildren(dest).map(n => dispName(n));
    let name = 'Новая папка', i = 2;
    while (existing.includes(name)) name = `Новая папка ${i++}`;
    const np = (dest === '/' ? '' : dest) + '/' + name;
    setExtra(m => { const n = new Map(m); const arr = (n.get(dest) || []).slice(); arr.push({ name, path: np, dir: true, kind: 'folder', size: 0, count: 0, modified: new Date('2026-06-08T11:00:00'), children: [], synthetic: true }); n.set(dest, arr); return n; });
    updatePane(id, { selection: new Set([np]), lastClick: np });
    setTimeout(() => setRenaming({ paneId: id, path: np }), 60);
  }
  function commitRename(value) {
    if (!renaming) return;
    const v = value.trim();
    if (v) setRenamed(m => { const n = new Map(m); n.set(renaming.path, v); return n; });
    setRenaming(null);
  }
  function applyBatch(previews) {
    setRenamed(m => { const n = new Map(m); previews.forEach(p => n.set(p.node.path, p.name)); return n; });
    setBatch(null);
    showToast(`Переименовано: ${previews.length} ${FS.plural(previews.length, ['объект', 'объекта', 'объектов'])}`, 'rename');
  }

  // ── tabs ──
  function addTab(path) { const t = freshPane(path || aPane.path); setTabs(ts => [...ts, t]); setActiveTabId(t.id); setActivePane('A'); }
  function closeTab(tid) {
    setTabs(ts => {
      if (ts.length === 1) return ts;
      const idx = ts.findIndex(t => t.id === tid);
      const next = ts.filter(t => t.id !== tid);
      if (tid === activeTabId) setActiveTabId(next[Math.max(0, idx - 1)].id);
      return next;
    });
  }

  // ── tags ──
  function setTag(path, tag) { FS.TAGS[path] = tag; if (!tag) delete FS.TAGS[path]; setExtra(m => new Map(m)); /* force rerender */ showToast(tag ? `Метка: ${FS.TAG_NAMES[tag]}` : 'Метка снята', 'tag'); }

  // ── drag & drop ──
  const dragRef = uR(null); // {fromPane, paths}
  const [dropTarget, setDropTarget] = uS(null); // {paneId, path}
  function onDragStart(id, node, e) {
    const p = getPane(id);
    let paths = p.selection.has(node.path) ? [...p.selection] : [node.path];
    if (!p.selection.has(node.path)) updatePane(id, { selection: new Set([node.path]) });
    dragRef.current = { fromPane: id, paths };
    e.dataTransfer.effectAllowed = 'copyMove';
    try { e.dataTransfer.setData('text/plain', paths.join('\n')); } catch (_) {}
    const ghost = document.createElement('div'); ghost.className = 'drag-ghost';
    ghost.innerHTML = `<span>${paths.length === 1 ? dispName(node) : 'items'}</span><span class="drag-count">${paths.length}</span>`;
    ghost.style.top = '-1000px'; document.body.appendChild(ghost);
    e.dataTransfer.setDragImage(ghost, 10, 10);
    setTimeout(() => ghost.remove(), 0);
  }
  function onDragOverRow(id, folderPath, e, isBlank) {
    if (!dragRef.current) return;
    if (dragRef.current.paths.includes(folderPath)) return;
    e.preventDefault();
    const crossPane = dragRef.current.fromPane !== id;
    e.dataTransfer.dropEffect = crossPane ? 'copy' : 'move';
    setDropTarget({ paneId: id, path: folderPath });
  }
  function onDropRow(id, folderPath, e, isBlank) {
    e.preventDefault(); e.stopPropagation();
    const drag = dragRef.current; setDropTarget(null);
    if (!drag) return;
    if (drag.paths.includes(folderPath)) return;
    const crossPane = drag.fromPane !== id;
    const mode = crossPane ? 'copy' : 'move';
    const files = drag.paths.map(pp => { const n = FS.get(pp) || findSynthetic(pp); return n ? { name: dispName(n), size: n.size || 0, node: n } : null; }).filter(Boolean);
    if (files.length) startTransfer(mode, files, folderPath, null);
    dragRef.current = null;
  }
  const dragLeaveRow = () => setDropTarget(null);

  // handler bag factory per pane
  function makeHandlers(id) {
    const pane = getPane(id);
    return {
      query: pane.query,
      activatePane: (pid) => setActivePane(pid),
      click: (node, e) => selectItem(id, node, e),
      dbl: (node) => openNode(id, node),
      context: (e, node) => openContext(id, node, e),
      dragStart: (node, e) => onDragStart(id, node, e),
      dragEnd: () => { dragRef.current = null; setDropTarget(null); },
      dragOverRow: (fp, e, blank) => onDragOverRow(id, fp, e, blank),
      dropRow: (fp, e, blank) => onDropRow(id, fp, e, blank),
      dragLeaveRow,
    };
  }

  // ── context menus ──
  function openContext(id, node, e) {
    e.preventDefault(); e.stopPropagation();
    const p = getPane(id);
    if (!p.selection.has(node.path)) updatePane(id, { selection: new Set([node.path]), lastClick: node.path });
    setActivePane(id);
    const selCount = p.selection.has(node.path) ? p.selection.size : 1;
    const multi = selCount > 1;
    const items = [
      { label: node.dir ? 'Open' : 'Open', icon: 'open', key: '⏎', action: () => openNode(id, node) },
      ...(node.dir ? [{ label: 'Open in New Tab', icon: 'plus', action: () => addTab(node.path) }] : [{ label: 'Quick Look', icon: 'eye', key: 'Space', action: () => setQuickLook(node) }]),
      { sep: true },
      { label: 'Copy', icon: 'copy', key: '⌘C', action: () => doCopy(id, 'copy') },
      { label: 'Cut', icon: 'cut', key: '⌘X', action: () => doCopy(id, 'cut') },
      { label: 'Paste', icon: 'paste', key: '⌘V', disabled: !clipboard, action: () => doPaste(id) },
      { sep: true },
      { label: multi ? `Rename ${selCount} items…` : 'Rename', icon: 'rename', key: 'F2', action: () => multi ? setBatch({ paneId: id, items: computeItems(p).filter(n => p.selection.has(n.path)) }) : setRenaming({ paneId: id, path: node.path }) },
      { label: 'Compress', icon: 'compress', action: () => showToast(`Compressing ${selCount} item${selCount === 1 ? '' : 's'}…`, 'compress') },
      { label: 'Add to Favorites', icon: 'star', action: () => showToast('Added to Favorites', 'star') },
      { sep: true },
      { label: 'Get Info', icon: 'info', key: '⌘I', action: () => setShowPreview(true) },
      { sep: true },
      { label: multi ? `Move ${selCount} items to Trash` : 'Move to Trash', icon: 'trash', danger: true, key: '⌫', action: () => doDelete(id) },
    ];
    setCtx({ x: e.clientX, y: e.clientY, items });
  }
  function openBlankContext(id, e) {
    e.preventDefault(); e.stopPropagation();
    setActivePane(id);
    setCtx({ x: e.clientX, y: e.clientY, items: [
      { label: 'New Folder', icon: 'new-folder', key: '⌘⇧N', action: () => newFolder(id) },
      { label: 'Paste', icon: 'paste', key: '⌘V', disabled: !clipboard, action: () => doPaste(id) },
      { sep: true },
      { label: 'Select All', icon: 'check', key: '⌘A', action: () => selectAll(id) },
      { label: 'Refresh', icon: 'refresh', action: () => showToast('Refreshed', 'refresh') },
      { sep: true },
      { label: 'Get Info', icon: 'info', action: () => setShowPreview(true) },
    ] });
  }
  function openSidebarContext(path, e) {
    e.preventDefault(); e.stopPropagation();
    setCtx({ x: e.clientX, y: e.clientY, items: [
      { label: 'Open', icon: 'open', action: () => navTo(effActivePane, path) },
      { label: 'Open in New Tab', icon: 'plus', action: () => addTab(path) },
      { sep: true },
      { label: 'Paste', icon: 'paste', disabled: !clipboard, action: () => { navTo(effActivePane, path); setTimeout(() => doPaste(effActivePane), 50); } },
      { label: 'New Folder', icon: 'new-folder', action: () => { navTo(effActivePane, path); setTimeout(() => newFolder(effActivePane), 60); } },
    ] });
  }

  // sidebar drag handlers
  const sidebarDrag = {
    dropTargetPath: dropTarget && dropTarget.paneId === 'side' ? dropTarget.path : null,
    onContext: openSidebarContext,
    row: (path) => ({
      onDragOver: (e) => { if (!dragRef.current || dragRef.current.paths.includes(path)) return; e.preventDefault(); setDropTarget({ paneId: 'side', path }); },
      onDragLeave: () => setDropTarget(null),
      onDrop: (e) => { e.preventDefault(); const drag = dragRef.current; setDropTarget(null); if (!drag) return; const files = drag.paths.map(pp => { const n = FS.get(pp) || findSynthetic(pp); return n ? { name: dispName(n), size: n.size || 0, node: n } : null; }).filter(Boolean); if (files.length) startTransfer('move', files, path, null); dragRef.current = null; },
    }),
  };

  // ── keyboard ──
  uE(() => {
    function onKey(e) {
      const tag = (e.target.tagName || '').toLowerCase();
      const typing = tag === 'input' || tag === 'select' || tag === 'textarea';
      const id = effActivePane;
      const mod = e.metaKey || e.ctrlKey;
      if (typing) {
        if (e.key === 'Escape') e.target.blur();
        return;
      }
      if (mod && e.key === 't') { e.preventDefault(); addTab(); }
      else if (mod && e.key === 'w') { e.preventDefault(); closeTab(activeTabId); }
      else if (mod && e.key === 'l') { e.preventDefault(); updatePane(id, { addrEditing: true }); }
      else if (mod && e.key === 'k') { e.preventDefault(); setShowConnect(true); }
      else if (mod && e.key === 'f') { e.preventDefault(); const s = document.querySelector('.searchbox input'); s && s.focus(); }
      else if (mod && e.key === 'a') { e.preventDefault(); selectAll(id); }
      else if (mod && e.key === 'c') { doCopy(id, 'copy'); }
      else if (mod && e.key === 'x') { doCopy(id, 'cut'); }
      else if (mod && e.key === 'v') { doPaste(id); }
      else if (mod && e.key === '[') { e.preventDefault(); goBack(id); }
      else if (mod && e.key === ']') { e.preventDefault(); goFwd(id); }
      else if (mod && e.key === 'ArrowUp') { e.preventDefault(); goUp(id); }
      else if (e.key === ' ') { const p = getPane(id); const sel = [...p.selection]; if (sel.length === 1) { e.preventDefault(); const n = FS.get(sel[0]) || findSynthetic(sel[0]); if (n && !n.dir) setQuickLook(n); } }
      else if (e.key === 'Enter') { const p = getPane(id); const sel = [...p.selection]; if (sel.length === 1) { const n = FS.get(sel[0]) || findSynthetic(sel[0]); if (n) openNode(id, n); } }
      else if (e.key === 'F2') { const p = getPane(id); const sel = [...p.selection]; if (sel.length === 1) setRenaming({ paneId: id, path: sel[0] }); else if (sel.length > 1) setBatch({ paneId: id, items: computeItems(p).filter(n => p.selection.has(n.path)) }); }
      else if (e.key === 'Backspace' || e.key === 'Delete') { doDelete(id); }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  // ── render helpers ──
  function paneStats(pane) {
    const items = pane.path.startsWith('tag:') || pane.query ? null : rawChildren(pane.path);
    const all = computeItems(pane);
    const folders = all.filter(n => n.dir).length;
    const files = all.length - folders;
    const sel = pane.selection.size;
    let selSize = 0; pane.selection.forEach(p => { const n = FS.get(p) || findSynthetic(p); if (n) selSize += n.size || 0; });
    return { total: all.length, folders, files, sel, selSize };
  }

  function renderPane(id, label) {
    const pane = getPane(id);
    const items = computeItems(pane);
    return (
      <FilePane key={id} paneId={id} isActive={splitView && effActivePane === id}
        node={FS.get(pane.path) || { path: pane.path, name: pane.path, dir: true }} items={items}
        view={pane.view} sort={pane.sort} onSort={(k, force) => updatePane(id, p => ({ sort: { key: k, dir: force ? 'asc' : (p.sort.key === k && p.sort.dir === 'asc' ? 'desc' : 'asc') } }))}
        selection={pane.selection} renaming={renaming && renaming.paneId === id ? renaming.path : null}
        onRenameChange={() => {}} onRenameCommit={commitRename} onRenameCancel={() => setRenaming(null)}
        cutSet={clipboard && clipboard.mode === 'cut' ? new Set(clipboard.items) : new Set()}
        density={density} striped={striped} showPath={pane.path.startsWith('tag:') || !!pane.query.trim()}
        dropTargetPath={dropTarget && dropTarget.paneId === id ? dropTarget.path : null}
        h={makeHandlers(id)} onBlankContext={(e) => openBlankContext(id, e)} onBlankClick={() => clearSel(id)} label={label} />
    );
  }

  const stats = paneStats(activeTab);
  // preview target = active pane single selection
  const aSel = [...aPane.selection];
  const previewNode = aSel.length === 1 ? (FS.get(aSel[0]) || findSynthetic(aSel[0])) : null;
  let previewSize = 0; aPane.selection.forEach(p => { const n = FS.get(p) || findSynthetic(p); if (n) previewSize += n.size || 0; });

  const freeLabel = '412 GB free of 1 TB';

  return (
    <div className="atlas" data-theme={theme} style={{ '--row-h': (density === 1 ? 26 : density === 3 ? 34 : 30) + 'px' }}>
      <div className="win">
        {/* Title bar */}
        <div className="titlebar">
          <div className="traffic"><span className="light r" /><span className="light y" /><span className="light g" /></div>
          <Tabs tabs={tabs} activeId={activeTabId} onSelect={(tid) => { setActiveTabId(tid); setActivePane('A'); }} onClose={closeTab} onAdd={() => addTab()} />
          <div className="winctl">
            <button className="iconbtn" onClick={() => setShowConnect(true)} title="Подключиться к серверу (⌘K)"><Icon name="server" /></button>
            <button className={'iconbtn' + (showFilters ? ' on' : '')} onClick={() => setShowFilters(s => !s)} title="Toggle filters"><Icon name="filter" /></button>
            <button className={'iconbtn' + (splitView ? ' on' : '')} onClick={() => { setSplitView(s => !s); }} title="Dual-pane view"><Icon name="split" /></button>
            <button className={'iconbtn' + (showPreview ? ' on' : '')} onClick={() => setShowPreview(s => !s)} title="Preview panel"><Icon name="panel-right" /></button>
            <button className="iconbtn" onClick={() => setTheme(t => t === 'light' ? 'dark' : 'light')} title="Toggle theme"><Icon name={theme === 'light' ? 'moon' : 'sun'} /></button>
          </div>
        </div>

        {/* Toolbar (drives active pane) */}
        <Toolbar pane={aPane}
          onBack={() => goBack(effActivePane)} onForward={() => goFwd(effActivePane)} onUp={() => goUp(effActivePane)} onRefresh={() => showToast('Refreshed', 'refresh')}
          onNavigate={(p) => navTo(effActivePane, p)} onBeginEdit={() => updatePane(effActivePane, { addrEditing: true })}
          onCommitPath={(p) => navTo(effActivePane, p)} onCancelPath={() => updatePane(effActivePane, { addrEditing: false })}
          onSearch={(q) => updatePane(effActivePane, { query: q })}
          view={aPane.view} onView={(v) => updatePane(effActivePane, { view: v })}
          onToggleFilter={() => setShowFilters(s => !s)} filterActive={showFilters || aPane.filters.size > 0} />

        {showFilters && <FilterBar filters={aPane.filters} onToggle={(g) => updatePane(effActivePane, p => { const f = new Set(p.filters); f.has(g) ? f.delete(g) : f.add(g); return { filters: f }; })}
          onClear={() => updatePane(effActivePane, { filters: new Set() })}
          sort={aPane.sort} onSort={(k, force) => updatePane(effActivePane, { sort: { key: k, dir: 'asc' } })} />}

        {(() => { const activeServer = connectedServers.find(s => aPane.path === s.path || aPane.path.startsWith(s.path + '/')); return activeServer ? <NetworkBar server={activeServer} onDisconnect={() => disconnectServer(activeServer.path)} /> : null; })()}

        {/* Body */}
        <div className="body">
          <Sidebar currentPath={aPane.path} expanded={expanded}
            onToggle={(p) => setExpanded(s => { const n = new Set(s); n.has(p) ? n.delete(p) : n.add(p); return n; })}
            onNavigate={(p) => navTo(effActivePane, p)} dragHandlers={sidebarDrag}
            connectedServers={connectedServers} onConnectClick={() => setShowConnect(true)} onServerContext={openServerContext} />
          <div className="content">
            <div className="pane-wrap">
              {renderPane('A', splitView ? (FS.get(activeTab.path)?.name || 'Pane A') : null)}
              {splitView && renderPane('B', FS.get(paneB.path)?.name || 'Pane B')}
            </div>
            <StatusBar total={stats.total} folders={stats.folders} files={stats.files} selection={stats.sel} selSize={stats.selSize}
              density={density} onDensity={setDensity} view={aPane.view} freeLabel={freeLabel} />
          </div>
          {showPreview && <PreviewPanel node={previewNode} count={aPane.selection.size} totalSize={previewSize}
            onClose={() => setShowPreview(false)} onTag={setTag}
            onAction={(a) => {
              if (a === 'quicklook' && previewNode) setQuickLook(previewNode);
              else if (a === 'rename' && previewNode) setRenaming({ paneId: effActivePane, path: previewNode.path });
              else if (a === 'batchRename') setBatch({ paneId: effActivePane, items: computeItems(aPane).filter(n => aPane.selection.has(n.path)) });
              else if (a === 'copy') doCopy(effActivePane, 'copy');
            }} />}
        </div>
      </div>

      {ctx && <ContextMenu x={ctx.x} y={ctx.y} items={ctx.items} onClose={() => setCtx(null)} />}
      {copyJob && <CopyDialog job={copyJob} onDone={finishTransfer} onCancel={() => { showToast('Transfer cancelled', 'info'); setCopyJob(null); }} />}
      {batch && <BatchRenameDialog items={batch.items} onApply={applyBatch} onClose={() => setBatch(null)} />}
      {showConnect && <ConnectServerDialog recent={FS.RECENT_SERVERS} onConnect={mountServer} onClose={() => setShowConnect(false)} />}
      {quickLook && <QuickLook node={quickLook} onClose={() => setQuickLook(null)} onOpen={(n) => { setQuickLook(null); showToast(`Opening ${dispName(n)}…`, 'open'); }} />}
      {toast && <Toast message={toast.message} icon={toast.icon} />}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
