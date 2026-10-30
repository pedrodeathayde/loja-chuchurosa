#!/usr/bin/env python3
"""Gera o sitemap.xml com as páginas fixas e todos os produtos ativos e não ocultos.

Uso (na raiz do repositório):  python3 docs/gerar-sitemap.py
Rode de novo quando houver produtos novos e envie o sitemap.xml para a main.
Usa a mesma chave anônima pública que o index.html já carrega."""
import json, re, urllib.parse, urllib.request
from datetime import date

SITE = 'https://chuchurosa.com.br'
SB = 'https://oznpfqsgurztffwfyfec.supabase.co'
key = re.search(r"const KEY='([^']+)'", open('index.html').read()).group(1)

def produtos():
    out, off = [], 0
    while True:
        # oculto pode ser nulo: not.is.true mantém os nulos e tira só os ocultos
        url = f"{SB}/rest/v1/produtos?select=id&ativo=eq.true&oculto=not.is.true&order=id&limit=1000&offset={off}"
        req = urllib.request.Request(url, headers={'apikey': key, 'Authorization': 'Bearer ' + key})
        rows = json.load(urllib.request.urlopen(req, timeout=30))
        out += [r['id'] for r in rows]
        if len(rows) < 1000: return out
        off += 1000

hoje = date.today().isoformat()
fixas = [('/', '1.0', 'weekly'), ('/loja.html', '0.9', 'daily'), ('/sobre.html', '0.6', 'monthly')]
cats = ['Fantasias', 'Para bebês', 'Almofadas', 'Decoração', 'Educativo', 'Lembrancinhas']
linhas = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
def url(loc, prio, freq):
    linhas.append(f'  <url><loc>{loc}</loc><lastmod>{hoje}</lastmod><changefreq>{freq}</changefreq><priority>{prio}</priority></url>')
for p, pr, fr in fixas: url(SITE + p, pr, fr)
for c in cats: url(f"{SITE}/loja.html?cat={urllib.parse.quote(c)}", '0.8', 'weekly')
ids = produtos()
for i in ids: url(f"{SITE}/produto.html?id={i}", '0.7', 'weekly')
linhas.append('</urlset>')
open('sitemap.xml', 'w').write('\n'.join(linhas) + '\n')
print(f'sitemap.xml: {len(fixas)+len(cats)+len(ids)} endereços ({len(ids)} produtos)')
