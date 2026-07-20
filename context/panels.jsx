/* panels.jsx — Tabs, Toolbar (nav + address bar + search), Sidebar, StatusBar.
   Presentational; all behavior comes through props. Exports to window. */
const { useState, useRef, useEffect, useLayoutEffect } = React;

/* ───────────────────────── Tabs ───────────────────────── */
function Tabs({ tabs, activeId, onSelect, onClose, onAdd }) {
  return (
    <div className="tabstrip">
      {tabs.map(t => {
        const node = window.FS.get(t.path);
        const label = node ? (node.name === '/' ? 'Этот Mac' : window.FS.locName(node.name)) : 'Без названия';
        return (
          <div key={t.id} className={'tab' + (t.id === activeId ? ' active' : '')}
               onMouseDown={() => onSelect(t.id)} title={t.path}>
            <FileGlyph node={node || { dir: true, kind: 'folder', name: '' }} size={14} />
            <span className="tab-name">{label}</span>
            {tabs.length > 1 && (
              <span className="tab-close" onMouseDown={(e) => { e.stopPropagation(); onClose(t.id); }}>
                <Icon name="close" size={12} />
              </span>
            )}
          </div>
        );
      })}
      <button className="tab-add" onClick={onAdd} title="Новая вкладка (⌘T)"><Icon name="plus" size={15} /></button>
    </div>
  );
}

/* ───────────────────────── Address bar ───────────────────────── */
function AddressBar({ path, editing, onNavigate, onBeginEdit, onCommit, onCancel }) {
  const isTag = path.startsWith('tag:');
  const segs = isTag ? [] : window.FS.segments(path);
  const inputRef = useRef(null);
  const [draft, setDraft] = useState(path);

  useEffect(() => { if (editing) { setDraft(path); requestAnimationFrame(() => { inputRef.current && inputRef.current.select(); }); } }, [editing, path]);

  // build cumulative paths
  let crumbs;
  if (isTag) {
    crumbs = [{ name: 'Этот Mac', path: '/', root: true }, { name: 'Метки', path: '/' }, { name: window.FS.TAG_NAMES[path.slice(4)] || path.slice(4), path, tag: true }];
  } else {
    crumbs = [{ name: 'Этот Mac', path: '/', root: true }];
    let acc = '';
    segs.forEach(s => { acc += '/' + s; crumbs.push({ name: window.FS.locName(s), path: acc }); });
  }

  return (
    <div className={'address' + (editing ? ' editing' : '')}
         onClick={() => { if (!editing) onBeginEdit(); }}>
      {editing ? (
        <input ref={inputRef} className="crumb-input mono" value={draft}
               onChange={e => setDraft(e.target.value)}
               onKeyDown={e => {
                 if (e.key === 'Enter') onCommit(draft);
                 else if (e.key === 'Escape') onCancel();
               }}
               onBlur={() => onCancel()} spellCheck={false} />
      ) : (
        <div className="crumbs">
          {crumbs.map((c, i) => (
            <React.Fragment key={c.path}>
              {i > 0 && <span className="crumb-sep"><Icon name="chevron-right" size={13} /></span>}
              <span className={'crumb' + (c.root ? ' root' : '')}
                    onClick={(e) => { e.stopPropagation(); onNavigate(c.path); }}
                    style={c.tag ? { textTransform: 'capitalize' } : null}>
                {c.root && <Icon name="home" size={13} />}
                {c.tag && <Icon name="tag" size={13} />}
                <span>{c.name}</span>
              </span>
            </React.Fragment>
          ))}
        </div>
      )}
      <div className="addr-right">
        {!editing && <button className="iconbtn" style={{ width: 26, height: 26 }} title="Изменить путь"
                onClick={(e) => { e.stopPropagation(); onBeginEdit(); }}><Icon name="rename" size={14} /></button>}
      </div>
    </div>
  );
}

/* ───────────────────────── Toolbar ───────────────────────── */
function Toolbar({ pane, onBack, onForward, onUp, onRefresh, onNavigate, onBeginEdit, onCommitPath, onCancelPath,
                   onSearch, view, onView, onToggleFilter, filterActive }) {
  const canBack = pane.histIndex > 0;
  const canFwd = pane.histIndex < pane.history.length - 1;
  const canUp = pane.path !== '/' && !pane.path.startsWith('tag:');
  return (
    <div className="toolbar">
      <div className="nav-group">
        <button className="iconbtn" disabled={!canBack} onClick={onBack} title="Назад (⌘[)"><Icon name="back" /></button>
        <button className="iconbtn" disabled={!canFwd} onClick={onForward} title="Вперёд (⌘])"><Icon name="forward" /></button>
        <button className="iconbtn" disabled={!canUp} onClick={onUp} title="Вверх (⌘↑)"><Icon name="up" /></button>
        <button className="iconbtn" onClick={onRefresh} title="Обновить"><Icon name="refresh" /></button>
      </div>
      <AddressBar path={pane.path} editing={pane.addrEditing}
                  onNavigate={onNavigate} onBeginEdit={onBeginEdit}
                  onCommit={onCommitPath} onCancel={onCancelPath} />
      <button className={'iconbtn' + (filterActive ? ' on' : '')} onClick={onToggleFilter} title="Фильтры"><Icon name="filter" /></button>
      <div className="searchbox">
        <Icon name="search" size={15} />
        <input placeholder={'Поиск: ' + (window.FS.get(pane.path)?.name === '/' ? 'Этот Mac' : window.FS.locName(window.FS.get(pane.path)?.name || ''))}
               value={pane.query} onChange={e => onSearch(e.target.value)} />
        {pane.query && <span className="search-scope">во вложенных</span>}
      </div>
      <div className="tb-sep" />
      <div className="seg">
        <button className={view === 'details' ? 'on' : ''} onClick={() => onView('details')} title="Таблица"><Icon name="details" size={15} /></button>
        <button className={view === 'grid' ? 'on' : ''} onClick={() => onView('grid')} title="Значки"><Icon name="grid" size={15} /></button>
        <button className={view === 'compact' ? 'on' : ''} onClick={() => onView('compact')} title="Список"><Icon name="list" size={15} /></button>
      </div>
    </div>
  );
}

/* ───────────────────────── Sidebar ───────────────────────── */
function SideRow({ node, depth, expanded, selected, hasChildren, onToggle, onNavigate, dropTarget, dragHandlers, tag }) {
  return (
    <div className={'side-item' + (selected ? ' sel' : '') + (dropTarget ? ' drop' : '')}
         style={{ paddingLeft: 8 + depth * 16 }}
         onClick={() => onNavigate(node.path)}
         onContextMenu={(e) => dragHandlers.onContext && dragHandlers.onContext(e, node.path)}
         {...dragHandlers.row(node.path)}>
      <span className={'twist' + (hasChildren ? '' : ' leaf')}
            onClick={(e) => { e.stopPropagation(); if (hasChildren) onToggle(node.path); }}>
        {hasChildren && <Icon name={expanded ? 'chevron-down' : 'chevron-right'} size={13} />}
      </span>
      <span className="si-icon"><FileGlyph node={node} size={16} /></span>
      <span className="si-name">{node.name === '/' ? 'Этот Mac' : window.FS.locName(node.name)}</span>
      {tag && <span className="side-tag" style={{ background: window.FS.TAG_COLORS[tag] }} />}
    </div>
  );
}

function Sidebar({ currentPath, expanded, onToggle, onNavigate, dragHandlers, connectedServers, onConnectClick, onServerContext }) {
  const FS = window.FS;
  // recursive tree render (folders only)
  function renderTree(path, depth) {
    const node = FS.get(path);
    if (!node) return null;
    const subFolders = FS.children(path).filter(c => c.dir && !(path === '/' && c.path === '/Network'));
    const isExpanded = expanded.has(path);
    return (
      <React.Fragment key={path}>
        <SideRow node={node} depth={depth} expanded={isExpanded}
                 selected={currentPath === path} hasChildren={subFolders.length > 0}
                 onToggle={onToggle} onNavigate={onNavigate}
                 dropTarget={dragHandlers.dropTargetPath === path}
                 dragHandlers={dragHandlers} tag={FS.TAGS[path]} />
        {isExpanded && subFolders.map(c => renderTree(c.path, depth + 1))}
      </React.Fragment>
    );
  }
  return (
    <div className="sidebar scroll">
      <div className="side-group">
        <div className="side-head">Избранное</div>
        {FS.FAVORITES.map(f => {
          const node = FS.get(f.path);
          if (!node) return null;
          return (
            <div key={f.path} className={'side-item' + (currentPath === f.path ? ' sel' : '') + (dragHandlers.dropTargetPath === f.path ? ' drop' : '')}
                 onClick={() => onNavigate(f.path)} {...dragHandlers.row(f.path)}
                 onContextMenu={(e) => dragHandlers.onContext && dragHandlers.onContext(e, f.path)}>
              <span className="twist leaf" />
              <span className="si-icon"><Icon name={f.path.endsWith('Projects') ? 'star' : 'pin'} size={15} /></span>
              <span className="si-name">{f.name}</span>
              {FS.TAGS[f.path] && <span className="side-tag" style={{ background: FS.TAG_COLORS[FS.TAGS[f.path]] }} />}
            </div>
          );
        })}
      </div>
      <div className="side-group">
        <div className="side-head">Места</div>
        {renderTree('/', 0)}
      </div>
      <div className="side-group">
        <div className="side-head">Сеть</div>
        {(connectedServers || []).map(s => (
          <div key={s.path} className={'side-item' + (currentPath === s.path || currentPath.startsWith(s.path + '/') ? ' sel' : '') + (dragHandlers.dropTargetPath === s.path ? ' drop' : '')}
               onClick={() => onNavigate(s.path)} {...dragHandlers.row(s.path)}
               onContextMenu={(e) => onServerContext && onServerContext(e, s)}>
            <span className="twist leaf" />
            <span className="si-icon"><Icon name="server" size={15} /></span>
            <span className="si-name">{s.name}</span>
            <span className="proto-chip">{FS.PROTOCOL_LABELS[s.protocol] || (s.protocol || '').toUpperCase()}</span>
          </div>
        ))}
        <div className="side-item side-connect" onClick={onConnectClick}>
          <span className="twist leaf" />
          <span className="si-icon"><Icon name="plus" size={15} /></span>
          <span className="si-name">Подключиться к серверу…</span>
        </div>
      </div>
      <div className="side-group">
        <div className="side-head">Метки</div>
        {Object.entries(FS.TAG_COLORS).map(([name, color]) => (
          <div key={name} className="side-item" onClick={() => onNavigate('tag:' + name)}>
            <span className="twist leaf" />
            <span className="side-tag" style={{ background: color, marginLeft: 2 }} />
            <span className="si-name">{FS.TAG_NAMES[name] || name}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ───────────────────────── Status bar ───────────────────────── */
function StatusBar({ total, folders, files, selection, selSize, density, onDensity, view, freeLabel }) {
  const FS = window.FS;
  let left;
  if (selection > 0) {
    left = `Выбрано ${selection} из ${total}` + (selSize ? `  ·  ${FS.fmtSize(selSize)}` : '');
  } else {
    const parts = [];
    if (folders) parts.push(`${folders} ${FS.plural(folders, ['папка', 'папки', 'папок'])}`);
    if (files) parts.push(`${files} ${FS.plural(files, ['файл', 'файла', 'файлов'])}`);
    left = parts.join(', ') || 'Пустая папка';
  }
  return (
    <div className="statusbar">
      <span className="pill">{left}</span>
      <span className="sb-sep" />
      <span className="pill" style={{ color: 'var(--text-3)' }}><Icon name="drive" size={13} /> {freeLabel}</span>
      {view !== 'details' && (
        <span className="zoom">
          <Icon name="grid" size={13} />
          <input type="range" min="1" max="3" step="1" value={density} onChange={e => onDensity(+e.target.value)} title="Icon size" />
        </span>
      )}
    </div>
  );
}

function NetworkBar({ server, onDisconnect }) {
  return (
    <div className="netbar">
      <Icon name="server" size={14} />
      <span>Сетевой диск · {server.address}{server.guest ? ' · Гость' : server.username ? ' · ' + server.username : ''}</span>
      <button className="btn ghost" style={{ height: 24, padding: '0 10px', fontSize: 11.5 }} onClick={onDisconnect}>Отключить</button>
    </div>
  );
}

Object.assign(window, { Tabs, Toolbar, AddressBar, Sidebar, StatusBar, NetworkBar });
