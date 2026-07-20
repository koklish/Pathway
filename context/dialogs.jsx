/* dialogs.jsx — ContextMenu, CopyDialog (progress), BatchRenameDialog, FilterBar, Toast. */

/* ───────────────────────── Context menu ───────────────────────── */
function ContextMenu({ x, y, items, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ x, y });
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const r = el.getBoundingClientRect();
    let nx = x, ny = y;
    if (x + r.width > window.innerWidth - 8) nx = window.innerWidth - r.width - 8;
    if (y + r.height > window.innerHeight - 8) ny = window.innerHeight - r.height - 8;
    setPos({ x: nx, y: ny });
  }, []);
  useEffect(() => {
    const close = () => onClose();
    window.addEventListener('mousedown', close);
    window.addEventListener('blur', close);
    const esc = e => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', esc);
    return () => { window.removeEventListener('mousedown', close); window.removeEventListener('blur', close); window.removeEventListener('keydown', esc); };
  }, []);
  return (
    <div className="ctx" ref={ref} style={{ left: pos.x, top: pos.y }} onMouseDown={e => e.stopPropagation()}>
      {items.map((it, i) => it.sep ? <div key={i} className="ctx-sep" /> : (
        <div key={i} className={'ctx-item' + (it.danger ? ' danger' : '') + (it.disabled ? ' disabled' : '')}
             onClick={() => { if (!it.disabled) { onClose(); it.action && it.action(); } }}>
          <span className="ci-icon">{it.icon && <Icon name={it.icon} size={15} />}</span>
          <span>{it.label}</span>
          {it.key && <span className="ci-key">{it.key}</span>}
        </div>
      ))}
    </div>
  );
}

/* ───────────────────────── Copy / Move progress ───────────────────────── */
function CopyDialog({ job, onDone, onCancel }) {
  const FS = window.FS;
  const [idx, setIdx] = useState(0);          // current file index
  const [filePct, setFilePct] = useState(0);  // % of current file
  const [doneBytes, setDoneBytes] = useState(0);
  const [paused, setPaused] = useState(false);
  const cancelled = useRef(false);
  const total = job.files.reduce((s, f) => s + f.size, 0);
  const speed = 92 * 1024 * 1024; // 92 MB/s simulated

  useEffect(() => {
    let raf, last = performance.now();
    const tick = (t) => {
      const dt = (t - last) / 1000; last = t;
      if (!paused && !cancelled.current) {
        setIdx(curIdx => {
          if (curIdx >= job.files.length) return curIdx;
          const f = job.files[curIdx];
          const bytesThisFrame = speed * dt;
          setFilePct(pct => {
            const np = pct + (bytesThisFrame / Math.max(f.size, 1)) * 100;
            if (np >= 100) {
              setDoneBytes(d => d + f.size);
              setTimeout(() => setIdx(i => i + 1), 0);
              return 0;
            }
            return np;
          });
          return curIdx;
        });
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [paused]);

  useEffect(() => { if (idx >= job.files.length) { const t = setTimeout(() => onDone(), 480); return () => clearTimeout(t); } }, [idx]);

  const finished = idx >= job.files.length;
  const overallBytes = Math.min(total, doneBytes + (job.files[idx] ? job.files[idx].size * filePct / 100 : 0));
  const overallPct = total ? (overallBytes / total) * 100 : 100;
  const remBytes = total - overallBytes;
  const eta = remBytes > 0 ? Math.ceil(remBytes / speed) : 0;
  const cur = job.files[Math.min(idx, job.files.length - 1)];

  return (
    <div className="overlay" onMouseDown={e => e.stopPropagation()}>
      <div className="modal">
        <div className="modal-head">
          <h3>{finished ? (job.mode === 'move' ? 'Перемещено' : 'Скопировано') + ` ${job.files.length} ${FS.plural(job.files.length, ['объект', 'объекта', 'объектов'])}` : (job.mode === 'move' ? 'Перемещение' : 'Копирование') + `…`}</h3>
          <p>{job.mode === 'move' ? 'Перемещение в' : 'Копирование в'} <b style={{ color: 'var(--text)' }}>{job.destName}</b></p>
        </div>
        <div className="modal-body">
          <div className="cp-row">
            <div className="cp-icon"><Icon name={finished ? 'check' : (job.mode === 'move' ? 'cut' : 'copy')} size={22} /></div>
            <div className="cp-info">
              <div className="cp-file">{finished ? 'Все объекты перенесены' : cur.name}</div>
              <div className="cp-meta">{finished ? `${FS.fmtSize(total)} · ${job.destName}` : `Объект ${idx + 1} из ${job.files.length} · ${FS.fmtSize(cur.size)}`}</div>
            </div>
          </div>
          <div className="bar"><i style={{ width: overallPct.toFixed(1) + '%' }} /></div>
          <div className="cp-stats">
            <span>{FS.fmtSize(overallBytes)} из {FS.fmtSize(total)}</span>
            <span>{finished ? 'Готово' : paused ? 'Пауза' : `${(speed / 1024 / 1024).toFixed(0)} МБ/с · осталось ~${eta} с`}</span>
          </div>
          {job.files.length > 1 && (
            <div className="cp-list scroll">
              {job.files.map((f, i) => (
                <div className="cpl" key={i}>
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{f.name}</span>
                  <span className="tnum" style={{ color: 'var(--text-3)', marginLeft: 'auto', marginRight: 10 }}>{FS.fmtSize(f.size)}</span>
                  {i < idx || finished ? <span className="done"><Icon name="check" size={15} /></span> : i === idx ? <span style={{ color: 'var(--accent)', fontSize: 11 }}>{filePct.toFixed(0)}%</span> : <span style={{ width: 15 }} />}
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="modal-foot">
          {!finished && <button className="btn ghost" onClick={() => setPaused(p => !p)}>{paused ? 'Продолжить' : 'Пауза'}</button>}
          {!finished
            ? <button className="btn" onClick={() => { cancelled.current = true; onCancel(); }}>Отмена</button>
            : <button className="btn primary" onClick={onDone}>Готово</button>}
        </div>
      </div>
    </div>
  );
}

/* ───────────────────────── Batch rename ───────────────────────── */
function BatchRenameDialog({ items, onApply, onClose }) {
  const [mode, setMode] = useState('replace');
  const [find, setFind] = useState('');
  const [replace, setReplace] = useState('');
  const [base, setBase] = useState('Файл');
  const [start, setStart] = useState(1);
  const [pad, setPad] = useState(2);
  const [affix, setAffix] = useState('prefix');
  const [affixText, setAffixText] = useState('');

  function splitExt(name, dir) {
    if (dir) return [name, ''];
    const i = name.lastIndexOf('.');
    return i > 0 ? [name.slice(0, i), name.slice(i)] : [name, ''];
  }
  function newName(node, i) {
    const [stem, ext] = splitExt(node.name, node.dir);
    if (mode === 'replace') {
      if (!find) return node.name;
      return stem.split(find).join(replace) + ext;
    }
    if (mode === 'number') {
      const num = String(start + i).padStart(pad, '0');
      return `${base} ${num}${ext}`;
    }
    if (mode === 'affix') {
      return affix === 'prefix' ? affixText + stem + ext : stem + affixText + ext;
    }
    return node.name;
  }
  const previews = items.map((n, i) => ({ node: n, name: newName(n, i) }));

  return (
    <div className="overlay" onMouseDown={onClose}>
      <div className="modal wide" onMouseDown={e => e.stopPropagation()}>
        <div className="modal-head">
          <h3>Переименовать {items.length} {window.FS.plural(items.length, ['объект', 'объекта', 'объектов'])}</h3>
          <p>Применить правило именования ко всем выбранным файлам сразу.</p>
        </div>
        <div className="modal-body">
          <div className="field">
            <label>Правило</label>
            <div className="seg" style={{ width: 'fit-content', height: 34 }}>
              {[['replace', 'Найти и заменить'], ['number', 'Нумерация'], ['affix', 'Добавить текст']].map(([v, l]) => (
                <button key={v} className={mode === v ? 'on' : ''} style={{ width: 'auto', padding: '0 14px', height: 26 }} onClick={() => setMode(v)}>{l}</button>
              ))}
            </div>
          </div>
          {mode === 'replace' && (
            <div className="field-row">
              <div className="field"><label>Найти</label><input value={find} onChange={e => setFind(e.target.value)} placeholder="что искать" /></div>
              <div className="field"><label>Заменить на</label><input value={replace} onChange={e => setReplace(e.target.value)} placeholder="новый текст" /></div>
            </div>
          )}
          {mode === 'number' && (
            <div className="field-row">
              <div className="field"><label>Имя</label><input value={base} onChange={e => setBase(e.target.value)} /></div>
              <div className="field"><label>Начать с</label><input type="number" value={start} onChange={e => setStart(+e.target.value || 0)} /></div>
              <div className="field"><label>Цифр</label><input type="number" min="1" max="5" value={pad} onChange={e => setPad(Math.max(1, +e.target.value || 1))} /></div>
            </div>
          )}
          {mode === 'affix' && (
            <div className="field-row">
              <div className="field"><label>Позиция</label><select value={affix} onChange={e => setAffix(e.target.value)}><option value="prefix">Префикс (в начале)</option><option value="suffix">Суффикс (в конце)</option></select></div>
              <div className="field"><label>Текст</label><input value={affixText} onChange={e => setAffixText(e.target.value)} placeholder="напр. 2026_" /></div>
            </div>
          )}
          <div className="field" style={{ marginBottom: 0 }}>
            <label>Предпросмотр</label>
            <div className="br-preview scroll">
              {previews.map((p, i) => (
                <div className="br-line" key={i}>
                  <span className="br-old">{p.node.name}</span>
                  <span className="br-arrow"><Icon name="arrow-right" size={14} /></span>
                  <span className="br-new">{p.name}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn ghost" onClick={onClose}>Отмена</button>
          <button className="btn primary" onClick={() => onApply(previews)}>Переименовать {items.length}</button>
        </div>
      </div>
    </div>
  );
}

/* ───────────────────────── Filter bar ───────────────────────── */
function FilterBar({ filters, onToggle, onClear, sort, onSort }) {
  const groups = [
    ['folder', 'Папки'], ['doc', 'Документы'], ['image', 'Изображения'],
    ['video', 'Видео'], ['audio', 'Аудио'], ['archive', 'Архивы'], ['code', 'Код'],
  ];
  return (
    <div className="filterbar">
      <span className="filter-label">Тип</span>
      {groups.map(([g, l]) => (
        <button key={g} className={'chip' + (filters.has(g) ? ' on' : '')} onClick={() => onToggle(g)}>{l}</button>
      ))}
      <span style={{ width: 8 }} />
      <span className="filter-label">Сортировка</span>
      <select className="field" style={{ height: 28, width: 'auto', padding: '0 28px 0 10px', fontSize: 12 }}
              value={sort.key} onChange={e => onSort(e.target.value, true)}>
        <option value="name">Имя</option><option value="modified">Дата изменения</option>
        <option value="size">Размер</option><option value="kind">Тип</option>
      </select>
      {filters.size > 0 && <button className="chip" onClick={onClear} style={{ marginLeft: 'auto' }}><Icon name="close" size={12} /> Сбросить</button>}
    </div>
  );
}

/* ───────────────────────── Connect to server ───────────────────────── */
function ConnectServerDialog({ recent, onConnect, onClose }) {
  const [step, setStep] = useState('address');
  const [address, setAddress] = useState('');
  const [authMode, setAuthMode] = useState('guest');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPw, setShowPw] = useState(false);
  const [remember, setRemember] = useState(true);
  const [error, setError] = useState('');

  function parseAddress(raw) {
    let s = raw.trim();
    let protocol = 'smb';
    const m = s.match(/^([a-z]+):\/\//i);
    if (m) { protocol = m[1].toLowerCase(); s = s.slice(m[0].length); }
    s = s.replace(/\/+$/, '');
    const parts = s.split('/').filter(Boolean);
    const host = parts[0] || s || 'server';
    const name = parts.length > 1 ? parts[parts.length - 1] : host;
    return { protocol, host, name, address: protocol + '://' + (s || host) };
  }
  const parsed = address.trim() ? parseAddress(address) : null;
  const protoLabel = parsed ? (window.FS.PROTOCOL_LABELS[parsed.protocol] || parsed.protocol.toUpperCase()) : null;

  function goAuth() {
    if (!address.trim()) { setError('Введите адрес сервера'); return; }
    setError(''); setStep('auth');
  }
  function connect() {
    setStep('connecting');
    setTimeout(() => {
      const p = parseAddress(address);
      onConnect({ name: p.name, protocol: p.protocol, address: p.address, guest: authMode === 'guest', username: authMode === 'user' ? (username || 'user') : null });
    }, 900);
  }
  function pickRecent(r) { setAddress(r.address); setError(''); }

  return (
    <div className="overlay" onMouseDown={onClose}>
      <div className="modal" onMouseDown={e => e.stopPropagation()}>
        <div className="modal-head">
          <h3>Подключение к серверу</h3>
          <p>{step === 'auth' ? `Авторизация на ${parsed ? parsed.host : ''}` : 'Введите адрес сервера, чтобы подключить сетевой диск'}</p>
        </div>
        <div className="modal-body">
          {step === 'address' && (
            <React.Fragment>
              <div className="field">
                <label>Адрес сервера</label>
                <div className="addr-input-row">
                  <input autoFocus value={address} onChange={e => { setAddress(e.target.value); setError(''); }}
                         placeholder="smb://server/share или ftp://host/path"
                         onKeyDown={e => { if (e.key === 'Enter') goAuth(); }} />
                  {protoLabel && <span className="proto-chip">{protoLabel}</span>}
                </div>
                {error && <div className="field-error">{error}</div>}
              </div>
              {recent.length > 0 && (
                <div className="field" style={{ marginBottom: 0 }}>
                  <label>Избранные серверы</label>
                  <div className="recent-servers">
                    {recent.map(r => (
                      <div key={r.address} className="recent-row" onClick={() => pickRecent(r)}>
                        <Icon name="server" size={15} />
                        <span className="rr-name">{r.name}</span>
                        <span className="rr-addr mono">{r.address}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </React.Fragment>
          )}
          {step === 'auth' && (
            <React.Fragment>
              <div className="field">
                <label>Вход</label>
                <div className="seg" style={{ width: 'fit-content', height: 34 }}>
                  {[['guest', 'Гость'], ['user', 'Зарегистрированный пользователь']].map(([v, l]) => (
                    <button key={v} className={authMode === v ? 'on' : ''} style={{ width: 'auto', padding: '0 14px', height: 26, whiteSpace: 'nowrap' }} onClick={() => setAuthMode(v)}>{l}</button>
                  ))}
                </div>
              </div>
              {authMode === 'user' && (
                <React.Fragment>
                  <div className="field"><label>Имя пользователя</label><input value={username} onChange={e => setUsername(e.target.value)} placeholder="имя пользователя" /></div>
                  <div className="field">
                    <label>Пароль</label>
                    <div className="addr-input-row">
                      <input type={showPw ? 'text' : 'password'} value={password} onChange={e => setPassword(e.target.value)} placeholder="пароль" />
                      <button className="iconbtn" style={{ width: 30, height: 30 }} onClick={() => setShowPw(s => !s)}><Icon name={showPw ? 'eye' : 'eye-off'} size={15} /></button>
                    </div>
                  </div>
                  <label className="check-row"><input type="checkbox" checked={remember} onChange={e => setRemember(e.target.checked)} /> Запомнить пароль в Связке ключей</label>
                </React.Fragment>
              )}
            </React.Fragment>
          )}
          {step === 'connecting' && (
            <div className="connecting-row">
              <span className="spinner" />
              <span>Подключение к {parsed ? parsed.host : ''}…</span>
            </div>
          )}
        </div>
        <div className="modal-foot">
          {step === 'address' && <React.Fragment><button className="btn ghost" onClick={onClose}>Отмена</button><button className="btn primary" onClick={goAuth}>Подключиться</button></React.Fragment>}
          {step === 'auth' && <React.Fragment><button className="btn ghost" onClick={() => setStep('address')}>Назад</button><button className="btn primary" onClick={connect}>Подключиться</button></React.Fragment>}
        </div>
      </div>
    </div>
  );
}

/* ───────────────────────── Toast ───────────────────────── */
function Toast({ message, icon }) {
  return <div className="toast"><Icon name={icon || 'check'} size={16} color="var(--accent)" />{message}</div>;
}

Object.assign(window, { ContextMenu, CopyDialog, BatchRenameDialog, FilterBar, Toast, ConnectServerDialog });
