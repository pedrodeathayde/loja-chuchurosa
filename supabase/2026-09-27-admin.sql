-- Chuchu Rosa — admin: contagem de pedidos por cliente no banco e
-- normalização da caixa das categorias dos produtos.
-- Rodar DEPOIS de 2026-09-27-lgpd.sql (usa public.cr_is_admin()).
-- Idempotente: pode rodar mais de uma vez.

-- 1) Pedidos por cliente (substitui o download de todos os pedidos no navegador)
create or replace function public.admin_pedidos_por_cliente()
returns table(cliente_id bigint, pedidos bigint, total_gasto numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.cr_is_admin() then
    raise exception 'acesso negado' using errcode = '42501';
  end if;
  return query
    select p.cliente_id::bigint, count(*)::bigint,
           coalesce(sum(p.total) filter (where p.status is distinct from 'cancelado'), 0)::numeric
      from public.pedidos p
     where p.cliente_id is not null
     group by p.cliente_id;
end $$;
revoke all on function public.admin_pedidos_por_cliente() from public, anon;
grant execute on function public.admin_pedidos_por_cliente() to authenticated;

-- 2) Categorias: "almofadas" e "Almofadas" viram o nome cadastrado em
--    `categorias` (sem repetir). Nomes sem correspondência ficam como estão.
--    Não muda a taxonomia (quais categorias existem) — só a caixa/duplicatas.
update public.produtos pr
   set collections = sub.novas
  from (
    select p.id,
           array(
             select d.nome from (
               select distinct on (lower(btrim(x.c))) coalesce(cat.nome, btrim(x.c)) as nome, x.ord
                 from unnest(p.collections) with ordinality as x(c, ord)
                 left join public.categorias cat on lower(cat.nome) = lower(btrim(x.c))
                where btrim(coalesce(x.c, '')) <> ''
                order by lower(btrim(x.c)), x.ord
             ) d order by d.ord
           ) as novas
      from public.produtos p
     where p.collections is not null
  ) sub
 where pr.id = sub.id
   and pr.collections is distinct from sub.novas;
