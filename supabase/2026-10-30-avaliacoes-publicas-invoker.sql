-- ── avaliacoes_publicas sem SECURITY DEFINER ─────────────────────────
-- O linter do Supabase acusa "Security Definer View": a view rodava com as
-- permissões do dono e ignorava a RLS. Agora ela roda com as permissões de
-- quem consulta (security_invoker), e o que é público fica nas regras da
-- própria tabela:
--   • RLS: visitante só enxerga linhas com aprovada = true
--   • grant por coluna: visitante só lê as colunas seguras (nada de e-mail)
--   • produtos_do_pedido vem de uma função que devolve só os ids dos
--     produtos do pedido, sem abrir itens_pedido para o visitante
-- O site continua consultando /rest/v1/avaliacoes_publicas igual.

-- 1. ids dos produtos de um pedido (único acesso a itens_pedido)
create or replace function public.produtos_do_pedido(p_pedido_id bigint)
returns bigint[]
language sql stable security definer set search_path = public
as $$
  select coalesce(array_agg(distinct i.produto_id::bigint), '{}')
  from itens_pedido i
  where i.pedido_id = p_pedido_id and i.produto_id is not null;
$$;
revoke all on function public.produtos_do_pedido(bigint) from public;
grant execute on function public.produtos_do_pedido(bigint) to anon, authenticated;

-- 2. visitante lê só as colunas seguras de avaliacoes
alter table public.avaliacoes enable row level security;
revoke select on public.avaliacoes from anon;
grant select (id, pedido_id, produto_id, cliente_nome, estrelas, comentario, foto_url, created_at, aprovada)
  on public.avaliacoes to anon;

-- 3. e só as linhas aprovadas
drop policy if exists "avaliacoes aprovadas sao publicas" on public.avaliacoes;
create policy "avaliacoes aprovadas sao publicas" on public.avaliacoes
  for select to anon using (aprovada is true);

-- 4. a view, agora com as permissões de quem consulta
create or replace view public.avaliacoes_publicas
with (security_invoker = true) as
  select a.id, a.pedido_id, a.produto_id, a.cliente_nome, a.estrelas, a.comentario, a.foto_url, a.created_at,
         public.produtos_do_pedido(a.pedido_id) as produtos_do_pedido
  from public.avaliacoes a
  where a.aprovada is true;
grant select on public.avaliacoes_publicas to anon, authenticated;
