#!/usr/bin/env python3
"""Padroniza brilho, cor, contraste e saturação das fotos de produto da loja.

As fotos vêm de celulares e lugares diferentes (luz amarela, sombra, fundo
esverdeado, foto lavada...). Este programa corrige cada uma *em relação a ela
mesma* para chegar no mesmo "jeito" de foto: neutra, clara, com contraste e cor
na medida, num toque levemente quente que combina com a página.

Uso (na raiz do repositório; precisa de Pillow e numpy: pip install pillow numpy):

  1. python3 docs/padronizar-fotos.py baixar
       Baixa todas as fotos da tabela `fotos` para fotos-padronizacao/originais/.

  2. python3 docs/padronizar-fotos.py processar
       Gera as versões padronizadas em fotos-padronizacao/padronizadas/ e a
       página fotos-padronizacao/comparacao.html (antes × depois) para revisar.
       --forca 0.6     corrige menos (0 = nada, 1 = padrão, até 1.5)
       Foto que ficou pior: ponha o nome do arquivo (como aparece na página de
       comparação) em fotos-padronizacao/ignorar.txt, um por linha. Ela continua
       como está no site.

  3. SUPABASE_SERVICE_ROLE_KEY=... python3 docs/padronizar-fotos.py enviar
       Envia as padronizadas para Fotos/padronizadas/ no Storage e aponta a
       tabela `fotos` para elas. As originais NÃO são apagadas; cada troca fica
       registrada em fotos-padronizacao/log-envio.json.
       A chave service_role fica no painel do Supabase (Project Settings → API).
       Nunca coloque essa chave em arquivo do repositório.

  Para voltar atrás: SUPABASE_SERVICE_ROLE_KEY=... python3 docs/padronizar-fotos.py desfazer

Fotos novas: o admin já aplica a mesma correção ao enviar (padronizarFotoAdmin
em admin.html), então só é preciso rodar isto de novo para fotos antigas ou
enviadas por outro caminho. Rodar de novo é seguro: o que já está em
padronizadas/ é pulado.
"""
import html, json, os, re, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps

SB = 'https://oznpfqsgurztffwfyfec.supabase.co'
PUB = SB + '/storage/v1/object/public/Fotos/'
PASTA_NOVA = 'padronizadas/'
DIR = Path('fotos-padronizacao')
ORIG, PAD = DIR / 'originais', DIR / 'padronizadas'
LADO_MAX = 1200

# ── Alvo do "jeito" das fotos ─────────────────────────────────────────
# Os mesmos números estão em padronizarFotoAdmin (admin.html): mude nos dois.
ALVO_MEDIANA = 0.56      # luminosidade mediana (0..1): fotos claras, sem estourar
ALVO_DESVIO = 0.21       # contraste (desvio da luminosidade)
ALVO_SATURACAO = 0.30    # saturação média
CALOR = 0.012            # leve toque quente (+vermelho, −azul)


def luminancia(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def padronizar(im, forca=1.0):
    """Recebe e devolve PIL.Image RGB. Cada etapa mede a foto e corrige só o
    que falta para chegar no alvo, com limites para não exagerar."""
    a = np.asarray(im, dtype=np.float32) / 255.0
    f = forca

    # 1. Balanço de branco: pixels quase neutros (cinzas/brancos do fundo,
    #    pano, parede) deveriam ser cinza. Se a foto não tem neutros o
    #    bastante (ex.: fundo rosa de propósito), não mexe na cor. O branco
    #    estourado fica branco (a correção some nos tons mais claros).
    Y = luminancia(a)
    croma = (a.max(2) - a.min(2)) / np.maximum(a.max(2), 1e-3)
    neutros = (croma < 0.14) & (Y > 0.25) & (Y < 0.93)
    if neutros.mean() > 0.05:
        m = a[neutros].mean(0)
        ganho = np.clip(m.mean() / np.maximum(m, 1e-3), 0.88, 1.12)
        protege = np.clip((0.97 - Y) / 0.15, 0, 1)[..., None]
        a = a * (1 + (ganho - 1) * 0.75 * f * protege)

    # 2. Níveis: preto perto de preto e branco perto de branco, sem cortar.
    Y = luminancia(a)
    lo, hi = np.percentile(Y, [0.5, 99.5])
    preto = min(lo, 0.10) * f
    branco = 1 - (1 - max(hi, 0.80)) * f
    a = (a - preto) / max(branco - preto, 0.3)

    # 3. Exposição: curva gama leva a mediana ao alvo (clareia meio-tons sem
    #    estourar o branco).
    a = np.clip(a, 0, 1)
    Y = luminancia(a)
    med = float(np.clip(np.median(Y), 0.05, 0.95))
    # (escurecer só um pouco: foto clara de propósito, fundo branco, continua clara)
    g = np.clip(np.log(ALVO_MEDIANA) / np.log(med), 0.6, 1.12)
    g = 1 + (g - 1) * f
    Yn = np.power(np.clip(Y, 1e-4, 1), g)
    a = a * (Yn / np.maximum(Y, 1e-4))[..., None]
    # cor estourando acima de 1 vira branco suave em vez de mudar de tom
    excesso = np.maximum(a.max(2, keepdims=True), 1)
    a = a / excesso + (1 - 1 / excesso) * 0.5

    # 4. Contraste: curva S em torno da mediana, mais forte nos meio-tons e
    #    nula no preto e no branco (não empapa sombra nem estoura luz).
    a = np.clip(a, 0, 1)
    Y = luminancia(a)
    k = np.clip(ALVO_DESVIO / max(float(Y.std()), 0.05), 0.85, 1.25)
    k = 1 + (k - 1) * f
    if abs(k - 1) > 0.01:
        c = float(np.median(Y))
        Ys = np.clip(Y + (k - 1) * (Y - c) * 4 * Y * (1 - Y), 0, 1)
        a = a + (Ys - Y)[..., None]

    # 5. Saturação tipo "vibrance": puxa mais as cores apagadas e quase não
    #    mexe nas que já são fortes (rosa choque continua rosa choque).
    a = np.clip(a, 0, 1)
    Y = luminancia(a)[..., None]
    mx, mn = a.max(2, keepdims=True), a.min(2, keepdims=True)
    sat = (mx - mn) / np.maximum(mx, 1e-3)
    fator = np.clip(ALVO_SATURACAO / max(float(sat.mean()), 0.05), 0.8, 1.4)
    fator = 1 + (fator - 1) * f
    if fator > 1:
        fator = 1 + (fator - 1) * (1 - sat)
    a = Y + (a - Y) * fator

    # 6. Toque da casa: levemente quente.
    a = a + np.array([CALOR, CALOR * 0.3, -CALOR], dtype=np.float32) * f

    out = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8))
    return out.filter(ImageFilter.UnsharpMask(radius=1.2, percent=int(35 * f), threshold=3))


def abrir(caminho):
    im = Image.open(caminho)
    im = ImageOps.exif_transpose(im)  # foto de celular "deitada"
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        fundo = Image.new('RGBA', im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(fundo, im)
    im = im.convert('RGB')
    if max(im.size) > LADO_MAX:
        im.thumbnail((LADO_MAX, LADO_MAX), Image.LANCZOS)
    return im


# ── Supabase ──────────────────────────────────────────────────────────
def chave_anonima():
    return re.search(r"const KEY='([^']+)'", open('index.html').read()).group(1)


def chave_servico():
    k = os.environ.get('SUPABASE_SERVICE_ROLE_KEY')
    if not k:
        sys.exit('Defina SUPABASE_SERVICE_ROLE_KEY (painel do Supabase → Project Settings → API → service_role).')
    return k


def req(url, chave, metodo='GET', corpo=None, extra=None):
    h = {'apikey': chave, 'Authorization': 'Bearer ' + chave}
    h.update(extra or {})
    r = urllib.request.Request(url, data=corpo, headers=h, method=metodo)
    with urllib.request.urlopen(r, timeout=60) as resp:
        return resp.read()


def linhas_fotos(chave):
    out, off = [], 0
    while True:
        rows = json.loads(req(f'{SB}/rest/v1/fotos?select=id,produto_id,url,ordem&order=id&limit=1000&offset={off}', chave))
        out += rows
        if len(rows) < 1000:
            return out
        off += 1000


def nome_local(url):
    """Caminho dentro do bucket → nome de arquivo local único e legível."""
    caminho = urllib.parse.unquote(url[len(PUB):]) if url.startswith(PUB) else None
    return caminho.replace('/', '__') if caminho else None


def nome_padronizada(n):
    """foto.jpg → foto.jpg; foto.webp → foto-webp.jpg (há produtos com os dois)."""
    p = Path(n)
    return p.stem + ('' if p.suffix.lower() in ('.jpg', '.jpeg') else '-' + p.suffix[1:].lower()) + '.jpg'


def url_segura(url):
    return urllib.parse.quote(urllib.parse.unquote(url), safe=':/')


# ── Comandos ──────────────────────────────────────────────────────────
def baixar():
    ORIG.mkdir(parents=True, exist_ok=True)
    rows = linhas_fotos(chave_anonima())
    (DIR / 'fotos.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    alvos = {}
    for r in rows:
        n = nome_local(r['url'])
        if n and not r['url'].startswith(PUB + PASTA_NOVA) and not (ORIG / n).exists():
            alvos[n] = r['url']

    def um(item):
        n, url = item
        for tentativa in range(5):
            try:
                (ORIG / n).write_bytes(urllib.request.urlopen(url_segura(url), timeout=60).read())
                return
            except Exception as e:
                erro = e
                time.sleep(2 ** tentativa)  # 429 = muitas requisições: espera e tenta de novo
        print('  falhou', n, erro, '(rode "baixar" de novo para tentar só as que faltam)')

    print(f'{len(rows)} fotos na tabela; baixando {len(alvos)} novas...')
    with ThreadPoolExecutor(8) as ex:
        list(ex.map(um, alvos.items()))
    print('ok →', ORIG)


def ignoradas():
    p = DIR / 'ignorar.txt'
    return {l.strip() for l in p.read_text().splitlines() if l.strip()} if p.exists() else set()


def processar(forca):
    PAD.mkdir(parents=True, exist_ok=True)
    ign = ignoradas()
    arquivos = sorted(p for p in ORIG.iterdir() if p.is_file())
    if not arquivos:
        sys.exit('Nada em ' + str(ORIG) + ' — rode "baixar" primeiro.')

    def um(p):
        destino = PAD / nome_padronizada(p.name)
        if p.name in ign:
            destino.unlink(missing_ok=True)
            return None
        try:
            padronizar(abrir(p), forca).save(destino, 'JPEG', quality=86, optimize=True, progressive=True)
            return p.name
        except Exception as e:
            print('  falhou', p.name, e)

    with ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        feitos = [n for n in ex.map(um, arquivos) if n]
    print(f'{len(feitos)} padronizadas, {len(ign)} ignoradas → {PAD}')

    cards = ''.join(
        f'<figure><div><img loading="lazy" src="originais/{urllib.parse.quote(n)}">'
        f'<img loading="lazy" src="padronizadas/{urllib.parse.quote(nome_padronizada(n))}"></div>'
        f'<figcaption>{html.escape(n)}</figcaption></figure>' for n in feitos)
    (DIR / 'comparacao.html').write_text(f'''<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Antes × depois</title>
<style>body{{font:14px system-ui;margin:16px;background:#faf6f4;color:#222}}
main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}}
figure{{margin:0;background:#fff;border-radius:10px;padding:8px;box-shadow:0 1px 3px #0002}}
figure div{{display:grid;grid-template-columns:1fr 1fr;gap:6px}}
img{{width:100%;aspect-ratio:4/5;object-fit:cover;border-radius:6px}}
figcaption{{font-size:12px;margin-top:6px;word-break:break-all;user-select:all;color:#666}}</style>
<h1>Antes × depois ({len(feitos)} fotos)</h1>
<p>Esquerda: original. Direita: padronizada. Para manter uma foto como está,
copie o nome dela para <code>ignorar.txt</code> e rode <code>processar</code> de novo.</p>
<main>{cards}</main>''')
    print('revise →', DIR / 'comparacao.html')


def enviar():
    chave = chave_servico()
    rows = json.loads((DIR / 'fotos.json').read_text())
    log_path = DIR / 'log-envio.json'
    log = json.loads(log_path.read_text()) if log_path.exists() else []
    feitos = {e['id'] for e in log}
    enviados = {}
    for r in rows:
        n = nome_local(r['url'])
        if not n or r['id'] in feitos or r['url'].startswith(PUB + PASTA_NOVA):
            continue
        arq = PAD / nome_padronizada(n)
        if not arq.exists():
            continue
        destino = PASTA_NOVA + re.sub(r'[^A-Za-z0-9._-]+', '-', arq.name)
        if enviados.get(destino, arq) != arq:  # nomes diferentes que viraram o mesmo
            destino = destino[:-4] + f'-{r["id"]}.jpg'
        try:
            if destino not in enviados:
                req(f'{SB}/storage/v1/object/Fotos/{destino}', chave, 'POST', arq.read_bytes(),
                    {'Content-Type': 'image/jpeg', 'x-upsert': 'true', 'cache-control': 'max-age=31536000'})
                enviados[destino] = arq
            nova = PUB + destino
            req(f'{SB}/rest/v1/fotos?id=eq.{r["id"]}', chave, 'PATCH', json.dumps({'url': nova}).encode(),
                {'Content-Type': 'application/json', 'Prefer': 'return=minimal'})
            log.append({'id': r['id'], 'antes': r['url'], 'depois': nova})
            log_path.write_text(json.dumps(log, ensure_ascii=False, indent=1))
            print('ok', r['id'], destino)
        except Exception as e:
            print('  falhou', r['id'], n, e)
    print(f'{len(log)} fotos apontando para as padronizadas (registro em {log_path})')


def desfazer():
    chave = chave_servico()
    log_path = DIR / 'log-envio.json'
    log = json.loads(log_path.read_text())
    resta = []
    for e in log:
        try:
            req(f'{SB}/rest/v1/fotos?id=eq.{e["id"]}', chave, 'PATCH', json.dumps({'url': e['antes']}).encode(),
                {'Content-Type': 'application/json', 'Prefer': 'return=minimal'})
        except Exception as err:
            print('  falhou', e['id'], err)
            resta.append(e)
    log_path.write_text(json.dumps(resta, ensure_ascii=False, indent=1))
    print(f'{len(log) - len(resta)} fotos voltaram para a original')


if __name__ == '__main__':
    args = sys.argv[1:]
    cmd = args[0] if args else ''
    if cmd == 'baixar':
        baixar()
    elif cmd == 'processar':
        forca = float(args[args.index('--forca') + 1]) if '--forca' in args else 1.0
        processar(max(0.0, min(forca, 1.5)))
    elif cmd == 'enviar':
        enviar()
    elif cmd == 'desfazer':
        desfazer()
    else:
        sys.exit(__doc__)
