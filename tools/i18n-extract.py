# Строки интерфейса для перевода: python3 tools/i18n-extract.py . КАТАЛОГ N
# В КАТАЛОГ/all.json попадают ещё не переведённые строки (ключи для lang/en.lng, значения → %s),
# в chunk-K.json они же частями, в every.json все ключи, которые сейчас есть в коде.
# Ищет вызовы ui_* / _hc_* / ui_menu и ui_checklist (с вариантами), строки «уровень|текст» и
# превращает каждую в ключ, каким его увидит t(): без оформления в начале, значения → %s.
# Пишет OUTDIR/chunk-K.json (N частей) и OUTDIR/all.json.
import re, glob, json, os, sys
sys.stdout.reconfigure(encoding='utf-8')
repo, outdir, nparts = sys.argv[1], sys.argv[2], int(sys.argv[3])
BS = chr(92)

CALL = re.compile(r'\b(?:ui_(?:info|warn|success|error|step|confirm|header|box_top|box_line|input|input_validated|password)|_hc_(?:ok|warn|fail|info)|t|_upd_run)\s+"')
LIST = re.compile(r'\bui_(?:menu|checklist)\b')
ECHO = re.compile(r'echo\s+"(?:ok|warn|info|note)\|')

def read_dq(s, i):
    """s[i] сразу после открывающей кавычки; вернуть (сырое содержимое, индекс после закрывающей)."""
    out = []; depth = 0
    while i < len(s):
        c = s[i]
        if c == BS and i + 1 < len(s):
            out.append(s[i:i+2]); i += 2; continue
        if c == '$' and s[i+1:i+2] == '(':
            # подстановка команды: до парной скобки, кавычки внутри не закрывают строку
            j = i + 2; d = 1
            while j < len(s) and d:
                if s[j] == '(': d += 1
                elif s[j] == ')': d -= 1
                elif s[j] == '"':
                    k = j + 1
                    while k < len(s) and s[k] != '"':
                        k += 2 if s[k] == BS else 1
                    j = k
                j += 1
            out.append(s[i:j]); i = j; continue
        if c == '"':
            return ''.join(out), i + 1
        out.append(c); i += 1
    return None, i

def to_key(raw):
    """Сырое содержимое "..." → (ключ, сколько %s); None, если переводить нечего."""
    # 1) убрать оформление в начале, как это делает t(): пробелы, ${UI_*}, значки
    r = raw
    while True:
        r2 = re.sub(r'^(\s+|\$\{UI_[A-Z]+\}|\$UI_[A-Z]+|(?:[✓✗!•→i]|\[[^]]{1,2}\])(?=\s|\$\{UI_|\$UI_))', '', r)
        if r2 == r: break
        r = r2
    # 2) подстановки → %s; ${x:+ТЕКСТ} с русским текстом даёт два варианта: с текстом и без
    keys = []
    for k in variants(r):
        if re.search('[А-Яа-яЁё]', k.replace('%s', '')): keys.append((k, k.count('%s')))
    return keys

def variants(r):
    """Строка с подстановками → список возможных ключей (%s на месте значений)."""
    alts = [['']]   # последовательность кусков, у каждого куска варианты
    i = 0
    def lit(t): alts.append([t])
    while i < len(r):
        c = r[i]
        if c == BS and i + 1 < len(r):
            n = r[i+1]
            lit(n if n in '"$' + BS + '`' else c + n); i += 2; continue
        if c == '$':
            if r[i+1:i+2] == '(':
                j = i + 2; d = 1
                while j < len(r) and d:
                    if r[j] == '(': d += 1
                    elif r[j] == ')': d -= 1
                    j += 1
                lit('%s'); i = j; continue
            if r[i+1:i+2] == '{':
                j = i + 2; d = 1
                while j < len(r) and d:
                    if r[j] == '{': d += 1
                    elif r[j] == '}': d -= 1
                    j += 1
                inner = r[i+2:j-1]
                m = re.match(r'[A-Za-z_][A-Za-z0-9_]*:\+(.*)$', inner, re.S)
                if m and re.search('[А-Яа-яЁё]', m.group(1)):
                    alts.append(variants(m.group(1)) + [''])
                else:
                    lit('%s')
                i = j; continue
            m = re.match(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])', r[i:])
            if m:
                lit('%s'); i += len(m.group(0)); continue
        lit(c); i += 1
    res = ['']
    for a in alts:
        res = [x + y for x in res for y in a]
        if len(res) > 16: res = res[:16]
    return list(dict.fromkeys(res))

items = {}
def add(key, ref, ctx):
    for k in (to_key(key) or []):
        e = items.setdefault(k[0], {'key': k[0], 'placeholders': k[1], 'refs': [], 'context': ctx.strip()[:200]})
        if len(e['refs']) < 3: e['refs'].append(ref)

files = sorted(glob.glob(os.path.join(repo, 'lib', '*.sh'))) + [os.path.join(repo, 'server-setup.sh')]
for f in files:
    src = open(f, encoding='utf-8').read()
    lines = src.split('\n')
    rel = os.path.relpath(f, repo).replace(BS, '/')
    offs = [0]
    for l in lines: offs.append(offs[-1] + len(l) + 1)
    def lineno(pos):
        lo, hi = 0, len(offs) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if offs[mid] <= pos: lo = mid
            else: hi = mid - 1
        return lo + 1
    for m in CALL.finditer(src):
        raw, _ = read_dq(src, m.end())
        if raw is not None:
            ln = lineno(m.start()); add(raw, f'{rel}:{ln}', lines[ln-1])
    for m in ECHO.finditer(src):
        raw, _ = read_dq(src, m.end())
        if raw is not None:
            ln = lineno(m.start()); add(raw, f'{rel}:{ln}', lines[ln-1])
    # варианты меню и списков: строки в кавычках до конца вызова (продолжение через \)
    for m in LIST.finditer(src):
        ln = lineno(m.start()); j = ln - 1
        while j < len(lines):
            for mm in re.finditer(r'"', lines[j]):
                pass
            seg = lines[j]
            k = 0
            while True:
                q = seg.find('"', k)
                if q < 0: break
                raw, end = read_dq(seg, q + 1)
                if raw is None: break
                add(raw, f'{rel}:{j+1}', seg)
                k = end
            if not seg.rstrip().endswith(BS): break
            j += 1

# уже переведённое не трогаем
have = set()
lng = open(os.path.join(repo, 'lang', 'en.lng'), encoding='utf-8').read()
for m in re.finditer(r'_I18N\["((?:[^"' + BS + BS + r']|' + BS + BS + r'.)*)"\]', lng):
    have.add(re.sub(BS + BS + r'(.)', r'\1', m.group(1)))
todo = [e for k, e in sorted(items.items()) if k not in have]
os.makedirs(outdir, exist_ok=True)
json.dump(todo, open(os.path.join(outdir, 'all.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
size = (len(todo) + nparts - 1) // nparts
for p in range(nparts):
    json.dump(todo[p*size:(p+1)*size], open(os.path.join(outdir, f'chunk-{p+1}.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('строк всего:', len(items), 'уже переведено:', len(items) - len(todo), 'к переводу:', len(todo), 'частей:', nparts, 'по', size)
print('с %s:', sum(1 for e in todo if e['placeholders']))
json.dump(sorted(items), open(os.path.join(outdir, 'every.json'), 'w', encoding='utf-8'), ensure_ascii=False)
