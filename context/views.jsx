/* views.jsx — FilePane (details/grid/compact), PreviewPanel, QuickLook, EmptyState. */

function colTag(node) {
  const t = window.FS.TAGS[node.path];
  return t ? <span className="row-tag" style={{ background: window.FS.TAG_COLORS[t] }} /> : null;
}

function NameCell({ node, renaming, onRenameChange, onRenameCommit, onRenameCancel, showPath }) {
  const inputRef = useRef(null);
  useEffect(() => { if (renaming) { requestAnimationFrame(() => { if (inputRef.current) { inputRef.current.focus(); const dot = node.dir ? node.name.length : node.name.lastIndexOf('.'); inputRef.current.setSelectionRange(0, dot > 0 ? dot : node.name.length); } }); } }, [renaming]);
  return (
    <div className="cell-name">
      <FileGlyph node={node} size={18} />
      {renaming ? (
        <input ref={inputRef} className="rename-input" defaultValue={node.name}
               onClick={e => e.stopPropagation()} onMouseDown={e => e.stopPropagation()}
               onKeyDown={e => { if (e.key === 'Enter') onRenameCommit(e.target.value); else if (e.key === 'Escape') onRenameCancel(); }}
               onBlur={e => onRenameCommit(e.target.value)} />
      ) : showPath ? (
        <span className="nm" style={{ display: 'flex', flexDirection: 'column', flex: 1, minWidth: 0 }}>
          <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{node.name}</span>
          <span style={{ fontSize: 10.5, color: 'var(--text-3)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} className="mono">{window.FS.parent(node.path)}</span>
        </span>
      ) : (
        <span className="nm">{node.name}</span>
      )}
      {!renaming && colTag(node)}
    </div>
  );
}

function DetailsView({ items, sort, onSort, selection, renaming, onRenameChange, onRenameCommit, onRenameCancel,
                       cutSet, dropTargetPath, h, striped, showPath }) {
  const FS = window.FS;
  const Th = ({ k, label, cls }) => (
    <th className={cls} onClick={() => onSort(k)}>
      <div className="th-in" style={{ justifyContent: cls === 'num' ? 'flex-end' : 'flex-start' }}>
        <span>{label}</span>
        {sort.key === k && <Icon name={sort.dir === 'asc' ? 'sort-asc' : 'sort-desc'} size={13} />}
      </div>
    </th>
  );
  return (
    <table className={'files' + (striped ? ' striped' : '')} style={{ tableLayout: 'fixed' }}>
      <colgroup>
        <col />
        {showPath && <col style={{ width: 180 }} />}
        <col style={{ width: 168 }} />
        <col style={{ width: 96 }} />
        <col style={{ width: 150 }} />
      </colgroup>
      <thead>
        <tr>
          <Th k="name" label="Имя" />
          {showPath && <Th k="path" label="Расположение" />}
          <Th k="modified" label="Дата изменения" />
          <Th k="size" label="Размер" cls="num" />
          <Th k="kind" label="Тип" />
        </tr>
      </thead>
      <tbody>
        {items.map(node => {
          const sel = selection.has(node.path);
          const isRenaming = renaming === node.path;
          return (
            <tr key={node.path}
                className={(sel ? 'sel ' : '') + (cutSet.has(node.path) ? 'cut ' : '') + (dropTargetPath === node.path ? 'drop-into' : '')}
                onClick={e => h.click(node, e)} onDoubleClick={() => h.dbl(node)}
                onContextMenu={e => h.context(e, node)}
                draggable={!isRenaming} onDragStart={e => h.dragStart(node, e)} onDragEnd={h.dragEnd}
                onDragOver={e => node.dir && h.dragOverRow(node.path, e)}
                onDrop={e => node.dir && h.dropRow(node.path, e)}
                onDragLeave={() => h.dragLeaveRow()}>
              <td className="name"><NameCell node={node} renaming={isRenaming}
                    onRenameChange={onRenameChange} onRenameCommit={onRenameCommit} onRenameCancel={onRenameCancel} /></td>
              {showPath && <td className="mono" style={{ fontSize: 11, color: 'var(--text-3)' }}>{FS.parent(node.path)}</td>}
              <td>{FS.fmtDate(node.modified)}</td>
              <td className="num tnum">{FS.fmtSize(node.size, node.dir, node.count)}</td>
              <td><span className="kindcell"><span style={{ width: 8, height: 8, borderRadius: 2, background: (FS.KINDS[node.kind] || {}).color }} />{(FS.KINDS[node.kind] || {}).label}</span></td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function GridView({ items, selection, cutSet, density, h, dropTargetPath }) {
  const FS = window.FS;
  const sizes = { 1: 48, 2: 64, 3: 92 };
  const cols = { 1: 92, 2: 116, 3: 150 };
  const ic = sizes[density] || 64;
  return (
    <div className="grid" style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${cols[density] || 116}px, 1fr))` }}>
      {items.map(node => {
        const sel = selection.has(node.path);
        const isImg = ['image'].includes((FS.KINDS[node.kind] || {}).group);
        return (
          <div key={node.path} className={'gcell' + (sel ? ' sel' : '') + (cutSet.has(node.path) ? ' cut' : '') + (dropTargetPath === node.path ? ' drop-into' : '')}
               onClick={e => h.click(node, e)} onDoubleClick={() => h.dbl(node)} onContextMenu={e => h.context(e, node)}
               draggable onDragStart={e => h.dragStart(node, e)} onDragEnd={h.dragEnd}
               onDragOver={e => node.dir && h.dragOverRow(node.path, e)} onDrop={e => node.dir && h.dropRow(node.path, e)} onDragLeave={() => h.dragLeaveRow()}
               style={dropTargetPath === node.path ? { boxShadow: 'inset 0 0 0 2px var(--accent)' } : null}>
            <div className="gthumb">
              {isImg ? (
                <div className="ph" style={{ width: ic * 0.85, height: ic }}><span className="ph-label" style={{ width: '100%', textAlign: 'center', paddingBottom: 4 }}>{node.name.split('.').pop().toUpperCase()}</span></div>
              ) : (
                <FileGlyph node={node} size={ic} />
              )}
              {colTag(node) && <span style={{ position: 'absolute', top: 2, right: 8 }}>{colTag(node)}</span>}
            </div>
            <span className="gname">{node.name}</span>
          </div>
        );
      })}
    </div>
  );
}

function CompactView({ items, selection, cutSet, h, dropTargetPath }) {
  const FS = window.FS;
  return (
    <div className="complist">
      {items.map(node => (
        <div key={node.path} className={'crow' + (selection.has(node.path) ? ' sel' : '') + (cutSet.has(node.path) ? ' cut' : '')}
             onClick={e => h.click(node, e)} onDoubleClick={() => h.dbl(node)} onContextMenu={e => h.context(e, node)}
             draggable onDragStart={e => h.dragStart(node, e)} onDragEnd={h.dragEnd}
             onDragOver={e => node.dir && h.dragOverRow(node.path, e)} onDrop={e => node.dir && h.dropRow(node.path, e)} onDragLeave={() => h.dragLeaveRow()}
             style={dropTargetPath === node.path ? { boxShadow: 'inset 0 0 0 2px var(--accent)' } : null}>
          <FileGlyph node={node} size={16} />
          <span className="cn">{node.name}</span>
          {colTag(node)}
        </div>
      ))}
    </div>
  );
}

function EmptyState({ query }) {
  return (
    <div className="empty">
      <div className="e-icon"><Icon name={query ? 'search' : 'new-folder'} size={26} /></div>
      <div>
        <div style={{ fontWeight: 600, color: 'var(--text-2)', fontSize: 14 }}>{query ? 'Ничего не найдено' : 'Папка пуста'}</div>
        <div style={{ fontSize: 12.5, marginTop: 4 }}>{query ? `Нет объектов по запросу «${query}».` : 'Перетащите файлы сюда или создайте новый объект.'}</div>
      </div>
    </div>
  );
}

function FilePane({ paneId, isActive, node, items, view, sort, onSort, selection, renaming,
                    onRenameChange, onRenameCommit, onRenameCancel, cutSet, density, striped,
                    showPath, dropTargetPath, h, onBlankContext, onBlankClick, label }) {
  const empty = items.length === 0;
  return (
    <div className={'pane' + (isActive ? ' active-pane' : '')}
         onMouseDown={() => h.activatePane && h.activatePane(paneId)}>
      {label && <div className="pane-head">{label}</div>}
      <div className="scroll" onContextMenu={e => { if (e.target.closest('tr,.gcell,.crow')) return; onBlankContext(e); }}
           onClick={e => { if (e.target.closest('tr,.gcell,.crow,.rename-input')) return; onBlankClick(); }}
           onDragOver={e => h.dragOverRow(node.path, e, true)} onDrop={e => h.dropRow(node.path, e, true)}>
        {empty ? <EmptyState query={h.query} /> :
          view === 'details' ? <DetailsView {...{ items, sort, onSort, selection, renaming, onRenameChange, onRenameCommit, onRenameCancel, cutSet, dropTargetPath, h, striped, showPath }} /> :
          view === 'grid' ? <GridView {...{ items, selection, cutSet, density, h, dropTargetPath }} /> :
          <CompactView {...{ items, selection, cutSet, h, dropTargetPath }} />}
      </div>
    </div>
  );
}

/* ───────────────────────── Preview panel ───────────────────────── */
function PreviewPanel({ node, count, totalSize, onClose, onTag, onAction }) {
  const FS = window.FS;
  if (!node && count === 0) {
    return (
      <div className="preview">
        <div className="pv-hero" style={{ paddingTop: 40 }}>
          <div className="pv-thumb"><div className="e-icon" style={{ width: 64, height: 64 }}><Icon name="eye" size={26} /></div></div>
          <div className="pv-title" style={{ fontSize: 13, color: 'var(--text-3)', fontWeight: 500 }}>Выберите объект для просмотра</div>
        </div>
      </div>
    );
  }
  if (count > 1) {
    return (
      <div className="preview">
        <div className="pv-hero">
          <div className="pv-thumb"><div className="e-icon" style={{ width: 88, height: 88, fontSize: 28 }}><b style={{ fontSize: 30, color: 'var(--accent)' }}>{count}</b></div></div>
          <div className="pv-title">Выбрано {count} {FS.plural(count, ['объект', 'объекта', 'объектов'])}</div>
          <div className="pv-sub">{FS.fmtSize(totalSize)} всего</div>
        </div>
        <div className="pv-actions">
          <button className="btn" onClick={() => onAction('batchRename')}><Icon name="rename" size={14} /> Переименовать</button>
          <button className="btn" onClick={() => onAction('copy')}><Icon name="copy" size={14} /> Копировать</button>
        </div>
      </div>
    );
  }
  const k = FS.KINDS[node.kind] || {};
  const isImg = k.group === 'image';
  const tag = FS.TAGS[node.path];
  return (
    <div className="preview">
      <div className="pv-hero">
        <div className="pv-thumb">
          {isImg ? <div className="ph"><span className="ph-label">{node.name.split('.').pop().toUpperCase()} · предпросмотр</span></div>
                 : <FileGlyph node={node} size={108} />}
        </div>
        <div className="pv-title">{node.name}</div>
        <div className="pv-sub">{k.label} · {FS.fmtSize(node.size, node.dir, node.count)}</div>
      </div>
      <div className="pv-section">
        <h4>Информация</h4>
        <div className="pv-kv"><span className="k">Тип</span><span className="v">{k.label}</span></div>
        <div className="pv-kv"><span className="k">Размер</span><span className="v">{node.dir ? `${FS.fmtSize(node.size)} · ${node.count} ${FS.plural(node.count, ['объект', 'объекта', 'объектов'])}` : FS.fmtSize(node.size)}</span></div>
        <div className="pv-kv"><span className="k">Где</span><span className="v mono" style={{ fontSize: 11 }}>{FS.parent(node.path)}</span></div>
        <div className="pv-kv"><span className="k">Изменён</span><span className="v">{FS.fmtDate(node.modified)}</span></div>
        <div className="pv-kv"><span className="k">Создан</span><span className="v">{FS.fmtDate(new Date(node.modified.getTime() - 86400000 * 9))}</span></div>
      </div>
      <div className="pv-section">
        <h4>Метки</h4>
        <div className="tag-row">
          {Object.entries(FS.TAG_COLORS).map(([name, color]) => (
            <button key={name} className={'tag-pick' + (tag === name ? ' on' : '')} style={{ background: color }} title={FS.TAG_NAMES[name]} onClick={() => onTag(node.path, tag === name ? null : name)} />
          ))}
        </div>
      </div>
      <div className="pv-actions">
        <button className="btn primary" onClick={() => onAction('quicklook')}><Icon name="eye" size={14} /> Просмотр</button>
        <button className="btn" onClick={() => onAction('rename')}><Icon name="rename" size={14} /></button>
      </div>
    </div>
  );
}

/* ───────────────────────── Quick Look ───────────────────────── */
function QuickLook({ node, onClose, onOpen }) {
  const FS = window.FS;
  useEffect(() => {
    const fn = e => { if (e.key === 'Escape' || e.key === ' ') { e.preventDefault(); onClose(); } };
    window.addEventListener('keydown', fn); return () => window.removeEventListener('keydown', fn);
  }, []);
  const k = FS.KINDS[node.kind] || {};
  return (
    <div className="ql" onClick={onClose}>
      <div className="ql-card" onClick={e => e.stopPropagation()}>
        <div className="ql-head">
          <FileGlyph node={node} size={20} />
          <span className="ql-title">{node.name}</span>
          <button className="btn ghost" onClick={() => onOpen(node)}><Icon name="open" size={14} /> Открыть</button>
          <button className="iconbtn" onClick={onClose}><Icon name="close" /></button>
        </div>
        <div className="ql-stage">
          <div className="ql-ph"><span className="ph-label">{k.label} — предпросмотр</span></div>
        </div>
        <div className="ql-foot">
          <span><b style={{ color: 'var(--text)' }}>Тип</b> · {k.label}</span>
          <span><b style={{ color: 'var(--text)' }}>Размер</b> · {FS.fmtSize(node.size, node.dir, node.count)}</span>
          <span><b style={{ color: 'var(--text)' }}>Изменён</b> · {FS.fmtDate(node.modified)}</span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { FilePane, PreviewPanel, QuickLook, EmptyState });
