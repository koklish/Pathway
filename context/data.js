/* data.js — Virtual filesystem for the Atlas file manager prototype.
   Builds an in-memory tree of folders/files with realistic metadata,
   plus path-based lookup + formatting helpers. Attaches FS to window. */
(function () {
  // kind → { label, color, group }  (color used for the type badge)
  const KINDS = {
    folder:   { label: 'Папка',              color: '#2A6FDB', group: 'folder' },
    pdf:      { label: 'Документ PDF',        color: '#E0533D', group: 'doc' },
    doc:      { label: 'Документ Word',       color: '#2A6FDB', group: 'doc' },
    sheet:    { label: 'Таблица',             color: '#1F8A5B', group: 'doc' },
    slides:   { label: 'Презентация Keynote', color: '#D98A2B', group: 'doc' },
    txt:      { label: 'Простой текст',       color: '#7A8290', group: 'doc' },
    md:       { label: 'Markdown',            color: '#4A5563', group: 'doc' },
    jpg:      { label: 'Изображение JPEG',    color: '#1F8A5B', group: 'image' },
    png:      { label: 'Изображение PNG',     color: '#1F8A5B', group: 'image' },
    svg:      { label: 'Изображение SVG',     color: '#D98A2B', group: 'image' },
    mp4:      { label: 'Фильм MPEG-4',        color: '#C2497E', group: 'video' },
    mov:      { label: 'Фильм QuickTime',     color: '#C2497E', group: 'video' },
    mp3:      { label: 'Аудио MP3',           color: '#1AA1A6', group: 'audio' },
    wav:      { label: 'Аудио WAV',           color: '#1AA1A6', group: 'audio' },
    zip:      { label: 'Архив ZIP',           color: '#C99A2E', group: 'archive' },
    dmg:      { label: 'Образ диска',         color: '#8A6FD1', group: 'archive' },
    js:       { label: 'JavaScript',          color: '#C99A2E', group: 'code' },
    jsx:      { label: 'Исходник React',      color: '#1AA1A6', group: 'code' },
    css:      { label: 'Таблица стилей',      color: '#2A6FDB', group: 'code' },
    html:     { label: 'Документ HTML',       color: '#E0533D', group: 'code' },
    json:     { label: 'Файл JSON',           color: '#7A8290', group: 'code' },
    py:       { label: 'Исходник Python',     color: '#2A6FDB', group: 'code' },
    sketch:   { label: 'Файл Sketch',         color: '#D98A2B', group: 'design' },
    fig:      { label: 'Файл Figma',          color: '#C2497E', group: 'design' },
    app:      { label: 'Программа',           color: '#2A6FDB', group: 'app' },
  };

  // Localized display names for standard folders (paths stay in English, like real macOS)
  const LOCAL = {
    'Applications': 'Программы', 'Users': 'Пользователи',
    'Desktop': 'Рабочий стол', 'Documents': 'Документы', 'Downloads': 'Загрузки',
    'Pictures': 'Изображения', 'Music': 'Музыка', 'Movies': 'Фильмы',
    'Screenshots': 'Снимки экрана', 'Vacation 2025': 'Отпуск 2025',
    'Projects': 'Проекты', 'Research': 'Исследования', 'Website': 'Веб-сайт',
    'Reports': 'Отчёты', 'Invoices': 'Счета', 'Inbox': 'Входящие',
    'Shared': 'Общие', 'Backup SSD': 'Резервный SSD', 'Network': 'Сеть',
  };
  function locName(name) { return LOCAL[name] || name; }
  const TAG_NAMES = { red: 'Красный', orange: 'Оранжевый', green: 'Зелёный', blue: 'Синий', purple: 'Фиолетовый' };

  // ext → kind
  const EXT = {
    pdf:'pdf', doc:'doc', docx:'doc', xls:'sheet', xlsx:'sheet', csv:'sheet',
    key:'slides', ppt:'slides', pptx:'slides', txt:'txt', md:'md', rtf:'txt',
    jpg:'jpg', jpeg:'jpg', png:'png', gif:'png', webp:'png', svg:'svg',
    mp4:'mp4', mov:'mov', avi:'mp4', mkv:'mp4', mp3:'mp3', wav:'wav', flac:'wav',
    zip:'zip', tar:'zip', gz:'zip', dmg:'dmg', iso:'dmg',
    js:'js', mjs:'js', jsx:'jsx', tsx:'jsx', ts:'js', css:'css', scss:'css',
    html:'html', htm:'html', json:'json', py:'py', sketch:'sketch', fig:'fig',
    app:'app',
  };

  function kindOf(name, isFolder) {
    if (isFolder) return 'folder';
    const m = name.toLowerCase().match(/\.([a-z0-9]+)$/);
    const ext = m ? m[1] : '';
    return EXT[ext] || 'txt';
  }

  // ── tree definition (compact shorthand) ───────────────────────────
  // folder: [name, [children...]]   file: [name, sizeKB, daysAgo]
  function f(name, kb, daysAgo) { return { name, kb, daysAgo, dir: false }; }
  function d(name, children) { return { name, children: children || [], dir: true }; }

  const TREE = d('/', [
    d('Applications', [
      f('Atlas.app', 184320, 12), f('Safari.app', 256000, 40),
      f('Xcode.app', 12800000, 5), f('Figma.app', 612000, 8),
      f('Spotify.app', 358000, 22), f('Notion.app', 248000, 16),
    ]),
    d('Users', [
      d('alex', [
        d('Desktop', [
          f('Screenshot 2026-06-07 at 14.22.png', 2840, 1),
          f('Screenshot 2026-06-06 at 09.11.png', 1920, 2),
          f('todo.txt', 3, 0),
          f('contract-final-v3.pdf', 880, 4),
          d('Inbox', [
            f('scan_001.pdf', 1240, 3), f('scan_002.pdf', 1180, 3),
            f('voice-memo.m4a', 4200, 6),
          ]),
        ]),
        d('Documents', [
          d('Projects', [
            d('Atlas', [
              f('README.md', 12, 1), f('package.json', 4, 1),
              f('index.html', 28, 0), f('app.jsx', 64, 0),
              f('data.js', 31, 0), f('styles.css', 22, 1),
              d('src', [
                f('Sidebar.jsx', 18, 1), f('Toolbar.jsx', 24, 0),
                f('FileTable.jsx', 41, 0), f('PreviewPanel.jsx', 16, 2),
                f('icons.jsx', 38, 1),
              ]),
              d('assets', [
                f('logo.svg', 8, 5), f('icon-1024.png', 420, 5),
                f('cover.jpg', 1840, 7),
              ]),
            ]),
            d('Website', [
              f('home.html', 36, 3), f('about.html', 18, 3),
              f('main.css', 44, 2), f('hero.jpg', 2200, 9),
              f('deploy.sh', 2, 10),
            ]),
            d('Research', [
              f('competitive-analysis.xlsx', 248, 6),
              f('user-interviews.docx', 96, 8),
              f('findings.md', 22, 4),
            ]),
          ]),
          d('Invoices', [
            f('invoice-2026-001.pdf', 142, 30), f('invoice-2026-002.pdf', 138, 24),
            f('invoice-2026-003.pdf', 151, 12), f('invoice-2026-004.pdf', 147, 3),
            f('tax-summary-2025.xlsx', 412, 60),
          ]),
          d('Reports', [
            f('Q1-2026-report.pdf', 2240, 45), f('Q2-2026-draft.docx', 184, 2),
            f('metrics.xlsx', 320, 5), f('board-deck.key', 8400, 7),
          ]),
          f('resume.pdf', 220, 90), f('notes.md', 9, 1),
          f('budget-2026.xlsx', 188, 11),
        ]),
        d('Downloads', [
          f('node-v22.4.0.pkg', 78000, 14), f('Figma-arm64.dmg', 612000, 8),
          f('dataset.zip', 154000, 3), f('invoice-template.docx', 64, 5),
          f('wallpaper-4k.jpg', 6400, 2), f('podcast-ep-142.mp3', 58000, 1),
          f('report-draft.pdf', 1240, 4), f('archive-old.zip', 248000, 33),
        ]),
        d('Pictures', [
          d('Screenshots', [
            f('Screenshot 2026-06-05.png', 1640, 3),
            f('Screenshot 2026-06-01.png', 1820, 7),
            f('Screenshot 2026-05-28.png', 980, 11),
          ]),
          d('Vacation 2025', [
            f('IMG_4821.jpg', 4200, 220), f('IMG_4822.jpg', 3980, 220),
            f('IMG_4830.jpg', 4410, 219), f('IMG_4855.jpg', 3760, 218),
            f('sunset.jpg', 5120, 218), f('beach-pano.jpg', 9800, 217),
          ]),
          f('profile.jpg', 880, 50), f('logo-export.png', 240, 20),
          f('diagram.svg', 36, 9),
        ]),
        d('Music', [
          f('demo-track-01.wav', 42000, 18), f('demo-track-02.wav', 38000, 16),
          f('mix-master.mp3', 9600, 4), f('field-recording.wav', 124000, 25),
        ]),
        d('Movies', [
          f('product-demo.mp4', 184000, 6), f('screen-recording.mov', 96000, 2),
          f('intro-anim.mov', 42000, 9),
        ]),
      ]),
    ]),
    d('iCloud Drive', [
      d('Shared', [
        f('team-roadmap.key', 6200, 4), f('design-system.fig', 18400, 2),
        f('meeting-notes.md', 14, 1),
      ]),
      f('passwords-backup.txt', 6, 70), f('scan-passport.pdf', 320, 120),
    ]),
    d('Backup SSD', [
      d('Time Machine', [
        f('backup-2026-06-01.dmg', 4200000, 7),
        f('backup-2026-05-01.dmg', 4100000, 38),
      ]),
      f('archive-2024.zip', 8200000, 400),
    ]),
    d('Network', []),
  ]);

  // ── flatten into a path-keyed map ─────────────────────────────────
  const NOW = new Date('2026-06-08T11:00:00');
  const byPath = new Map();

  function build(node, parentPath) {
    const path = parentPath === '/' ? '/' + node.name
               : parentPath === null ? '/' : parentPath + '/' + node.name;
    const isRoot = parentPath === null;
    const kind = node.dir ? 'folder' : kindOf(node.name, false);
    const rec = {
      name: isRoot ? '/' : node.name,
      path: isRoot ? '/' : path,
      dir: node.dir,
      kind,
      children: [],
      modified: node.dir ? null : new Date(NOW.getTime() - (node.daysAgo || 0) * 86400000
                  - (node.daysAgo === 0 ? (Math.random() * 5 * 3600000) : 0)),
      size: node.dir ? 0 : (node.kb || 0) * 1024,
    };
    byPath.set(rec.path, rec);
    if (node.dir) {
      for (const c of node.children) {
        const childPath = build(c, rec.path);
        rec.children.push(childPath);
      }
      // folder modified = newest child; size = sum
      let newest = 0, total = 0;
      for (const cp of rec.children) {
        const cn = byPath.get(cp);
        total += cn.size;
        if (cn.modified && cn.modified.getTime() > newest) newest = cn.modified.getTime();
      }
      rec.size = total;
      rec.modified = newest ? new Date(newest) : new Date(NOW.getTime() - 86400000 * 30);
      rec.count = rec.children.length;
    }
    return rec.path;
  }
  build(TREE, null);

  // ── remote servers (Network) demo data ────────────────────────────
  const PROTOCOL_LABELS = { smb: 'SMB', ftp: 'FTP', afp: 'AFP', webdav: 'WebDAV', https: 'WebDAV', nfs: 'NFS' };
  const RECENT_SERVERS = [
    { name: 'Общие (nas-office.local)', protocol: 'smb', address: 'smb://nas-office.local/Общие' },
    { name: 'archive (backup.company.ru)', protocol: 'ftp', address: 'ftp://backup.company.ru/archive' },
    { name: 'Docs (cloud.company.ru)', protocol: 'webdav', address: 'https://cloud.company.ru/webdav/Docs' },
  ];
  const REMOTE_TEMPLATE = [
    d('Общие материалы', [
      f('Брендбук.pdf', 4200, 12),
      f('Презентация Q2.pptx', 8800, 5),
      d('Логотипы', [f('logo-main.svg', 24, 40), f('logo-white.png', 180, 40)]),
    ]),
    d('Архив 2025', [f('contracts-2025.zip', 184000, 90)]),
    f('readme.txt', 2, 1),
  ];

  // ── helpers ───────────────────────────────────────────────────────
  function get(path) { return byPath.get(normalize(path)); }
  function children(path) {
    const n = get(path);
    if (!n || !n.dir) return [];
    return n.children.map(p => byPath.get(p)).filter(Boolean);
  }
  function normalize(p) {
    if (!p || p === '/') return '/';
    p = p.replace(/\/+$/, '');
    if (!p.startsWith('/')) p = '/' + p;
    return p;
  }
  function exists(p) { return byPath.has(normalize(p)); }
  function segments(path) {
    const n = normalize(path);
    if (n === '/') return [];
    return n.slice(1).split('/');
  }
  function parent(path) {
    const segs = segments(path);
    if (segs.length <= 1) return '/';
    return '/' + segs.slice(0, -1).join('/');
  }

  // Russian plural: forms = [one, few, many]  (1 файл, 2 файла, 5 файлов)
  function plural(n, forms) {
    const n10 = n % 10, n100 = n % 100;
    if (n10 === 1 && n100 !== 11) return forms[0];
    if (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20)) return forms[1];
    return forms[2];
  }

  function fmtSize(bytes, isDir, count) {
    if (isDir) return count != null ? `${count} ${plural(count, ['объект', 'объекта', 'объектов'])}` : '—';
    if (bytes < 1024) return bytes + ' Б';
    const u = ['КБ', 'МБ', 'ГБ', 'ТБ'];
    let v = bytes / 1024, i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2)) + ' ' + u[i];
  }

  function fmtDate(date) {
    if (!date) return '—';
    const diff = NOW - date;
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return 'Только что';
    if (mins < 60) return `${mins} ${plural(mins, ['минуту', 'минуты', 'минут'])} назад`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24 && date.toDateString() === NOW.toDateString())
      return `Сегодня, ${date.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`;
    const days = Math.floor(diff / 86400000);
    if (days === 1) return `Вчера, ${date.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}`;
    return date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short', year: 'numeric' });
  }

  // Sidebar tree roots & favorites
  const ROOTS = ['/Applications', '/Users', '/iCloud Drive', '/Backup SSD'];
  const FAVORITES = [
    { path: '/Users/alex/Desktop', name: 'Рабочий стол' },
    { path: '/Users/alex/Documents', name: 'Документы' },
    { path: '/Users/alex/Downloads', name: 'Загрузки' },
    { path: '/Users/alex/Pictures', name: 'Изображения' },
    { path: '/Users/alex/Documents/Projects', name: 'Проекты' },
  ];
  const HOME = '/Users/alex';

  // Color tags assigned to a few files (path → tag)
  const TAGS = {
    '/Users/alex/Desktop/contract-final-v3.pdf': 'red',
    '/Users/alex/Documents/Reports/board-deck.key': 'orange',
    '/Users/alex/Documents/Projects/Atlas': 'blue',
    '/Users/alex/Documents/budget-2026.xlsx': 'green',
    '/Users/alex/Pictures/Vacation 2025': 'purple',
  };
  const TAG_COLORS = { red:'#E0533D', orange:'#D98A2B', green:'#1F8A5B', blue:'#2A6FDB', purple:'#8A6FD1' };

  window.FS = {
    KINDS, get, children, exists, segments, parent, normalize, kindOf,
    fmtSize, fmtDate, plural, ROOTS, FAVORITES, HOME, TAGS, TAG_COLORS, TAG_NAMES,
    LOCAL, locName, map: byPath, PROTOCOL_LABELS, RECENT_SERVERS, REMOTE_TEMPLATE,
  };
})();
