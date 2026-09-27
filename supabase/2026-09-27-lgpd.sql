-- ════════════════════════════════════════════════════════════════════
-- CHUCHU ROSA — Correções de LGPD (dados pessoais de clientes)
-- Rode inteiro no SQL Editor do Supabase:
--   supabase.com/dashboard/project/oznpfqsgurztffwfyfec/sql
--
-- • Tudo roda numa transação: se qualquer coluna presumida aqui não
--   existir no banco, NADA é aplicado e o erro mostra qual é.
-- • Pode rodar de novo sem problema (idempotente).
-- • As páginas do site já chamam as funções novas e, enquanto este script
--   não rodar, continuam no caminho antigo. Depois de rodar, o caminho
--   antigo fica bloqueado.
--
-- O que muda:
--  1. rastreio: consulta pelo número do pedido passa a exigir o e-mail da
--     compra, e a resposta não traz mais nome/e-mail/telefone/endereço.
--  2. avaliação: o link precisa do token secreto do pedido
--     (avaliar.html?pedido=ID&token=UUID); o e-mail do cliente é gravado
--     pelo servidor, nunca vem do navegador.
--  3. avaliações públicas: a loja lê uma view sem cliente_email.
--  4. checkout: pedido é criado por função no servidor; o visitante
--     anônimo não lê mais as tabelas pedidos/clientes/itens_pedido.
--  5. conta do cliente: só enxerga os próprios pedidos, endereço,
--     favoritos e cadastro — rede de segurança por cima das regras atuais.
-- ════════════════════════════════════════════════════════════════════

begin;

-- ── 0. quem é admin (mesmo UID que admin.html confere) ────────────────
create or replace function public.cr_is_admin()
returns boolean language sql stable
as $$ select auth.uid() = 'd54fff6f-1775-4510-a5d4-405d1ea7ba56'::uuid $$;

-- e-mail da sessão atual, minúsculo (null para visitante anônimo)
create or replace function public.cr_email_sessao()
returns text language sql stable
as $$ select nullif(lower(auth.jwt() ->> 'email'), '') $$;


-- o pedido pertence a quem está logado? (conta, e-mail da compra ou cadastro)
create or replace function public.cr_pedido_da_sessao(p_user_id uuid, p_visitante_email text, p_cliente_id bigint)
returns boolean language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null and (
       p_user_id = auth.uid()
    or lower(p_visitante_email) = cr_email_sessao()
    or exists (select 1 from clientes c where c.id = p_cliente_id and lower(c.email) = cr_email_sessao())
  )
$$;

-- ── 1. token secreto por pedido para o link de avaliação ──────────────
alter table public.pedidos
  add column if not exists avaliacao_token uuid not null default gen_random_uuid();
create unique index if not exists pedidos_avaliacao_token_key on public.pedidos (avaliacao_token);
-- a coluna pode já existir como text: garante valor em todos os pedidos
update public.pedidos set avaliacao_token = gen_random_uuid()
 where avaliacao_token is null or btrim(avaliacao_token::text) = '';
alter table public.pedidos alter column avaliacao_token set default gen_random_uuid();


-- ── 2. rastreio público sem dados pessoais ────────────────────────────
-- Por código de rastreio: basta o código.
-- Por número do pedido (#42): exige o e-mail usado na compra.
create or replace function public.rastrear_pedido_publico(p_codigo text, p_email text default null)
returns table (id bigint, status text, updated_at timestamptz, tracking_code text)
language sql stable security definer set search_path = public
as $$
  select p.id::bigint, p.status::text, p.updated_at, p.tracking_code::text
  from pedidos p
  left join clientes c on c.id = p.cliente_id
  where
    (
      nullif(trim(p_codigo), '') is not null
      and upper(trim(p.tracking_code::text)) = upper(trim(p_codigo))
    )
    or (
      trim(p_codigo) ~ '^#?[0-9]{1,9}$'
      and p.id = case when trim(p_codigo) ~ '^#?[0-9]{1,9}$'
                      then ltrim(trim(p_codigo), '#')::bigint end
      and nullif(trim(p_email), '') is not null
      and lower(trim(p_email)) in (lower(p.visitante_email), lower(c.email))
    )
  limit 1
$$;


-- ── 3. avaliação por link com token ───────────────────────────────────
-- contexto do formulário: só primeiro nome e itens, e só com token válido
create or replace function public.avaliacao_contexto(p_pedido_id bigint, p_token uuid)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'primeiro_nome', split_part(coalesce(p.visitante_nome, c.nome, ''), ' ', 1),
    'ja_avaliado',   exists (select 1 from avaliacoes a where a.pedido_id = p.id),
    'itens', coalesce((
        select json_agg(json_build_object('nome_produto', i.nome_produto, 'quantidade', i.quantidade) order by i.id)
        from itens_pedido i where i.pedido_id = p.id
      ), '[]'::json)
  )
  from pedidos p
  left join clientes c on c.id = p.cliente_id
  where p.id = p_pedido_id and p.avaliacao_token::text = p_token::text
$$;

-- inserção comum (não exposta: só as duas funções abaixo chamam)
create or replace function public.cr_inserir_avaliacao(
  p_pedido_id bigint, p_nome text, p_email text,
  p_estrelas int, p_comentario text, p_foto_url text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if exists (select 1 from avaliacoes where pedido_id = p_pedido_id) then
    raise exception 'ja_avaliado' using errcode = 'P0001';
  end if;
  if p_estrelas is null or p_estrelas not between 1 and 5 then
    raise exception 'estrelas_invalidas' using errcode = 'P0001';
  end if;
  if length(trim(coalesce(p_nome, ''))) = 0 or length(p_nome) > 80 then
    raise exception 'nome_invalido' using errcode = 'P0001';
  end if;
  if p_comentario is not null and length(p_comentario) > 2000 then
    raise exception 'comentario_longo' using errcode = 'P0001';
  end if;
  if p_foto_url is not null
     and p_foto_url !~ '^https://oznpfqsgurztffwfyfec\.supabase\.co/storage/v1/object/public/avaliacoes/[A-Za-z0-9._-]+$' then
    raise exception 'foto_invalida' using errcode = 'P0001';
  end if;

  insert into avaliacoes (pedido_id, produto_id, cliente_nome, cliente_email, estrelas, comentario, foto_url, aprovada)
  values (p_pedido_id, null, trim(p_nome), p_email, p_estrelas, nullif(trim(p_comentario), ''), p_foto_url, false);
end
$$;

-- pelo link do e-mail (visitante)
create or replace function public.enviar_avaliacao(
  p_pedido_id bigint, p_token uuid, p_nome text, p_estrelas int,
  p_comentario text default null, p_foto_url text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_email text;
begin
  select coalesce(p.visitante_email, c.email) into v_email
  from pedidos p left join clientes c on c.id = p.cliente_id
  where p.id = p_pedido_id and p.avaliacao_token::text = p_token::text;
  if not found then
    raise exception 'link_invalido' using errcode = 'P0001';
  end if;
  perform cr_inserir_avaliacao(p_pedido_id, p_nome, v_email, p_estrelas, p_comentario, p_foto_url);
end
$$;

-- pela área "Minha conta" (cliente logado, só pedidos dele)
create or replace function public.enviar_avaliacao_conta(
  p_pedido_id bigint, p_nome text, p_estrelas int,
  p_comentario text default null, p_foto_url text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'nao_autenticado' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from pedidos p
    where p.id = p_pedido_id and cr_pedido_da_sessao(p.user_id, p.visitante_email, p.cliente_id)
  ) then
    raise exception 'pedido_nao_encontrado' using errcode = 'P0001';
  end if;
  perform cr_inserir_avaliacao(p_pedido_id, p_nome, cr_email_sessao(), p_estrelas, p_comentario, p_foto_url);
end
$$;


-- ── 4. avaliações públicas sem e-mail ─────────────────────────────────
-- produtos_do_pedido: permite mostrar a avaliação geral do pedido na página
-- de cada produto comprado, sem o visitante precisar ler itens_pedido
create or replace view public.avaliacoes_publicas as
  select a.id, a.pedido_id, a.produto_id, a.cliente_nome, a.estrelas, a.comentario, a.foto_url, a.created_at,
         coalesce((select array_agg(distinct i.produto_id::bigint) from public.itens_pedido i
                   where i.pedido_id = a.pedido_id and i.produto_id is not null), '{}') as produtos_do_pedido
  from public.avaliacoes a
  where a.aprovada is true;
grant select on public.avaliacoes_publicas to anon, authenticated;


-- ── 5. checkout: pedido criado no servidor ────────────────────────────
-- O preço NUNCA vem do navegador: cada item é precificado aqui a partir de
-- produtos (preço promocional, se houver, senão o normal) + preco_extra da
-- variação escolhida. Subtotal, desconto do PIX (5%) e total também.
-- p_pedido: endereço, observações, forma de pagamento (mp_status), frete
-- p_itens:  [{produto_id, tamanho, cor, quantidade}]
-- p_cliente: cadastro completo quando a pessoa escolhe "criar conta" (opcional)
-- Devolve {id, subtotal, desconto, total}.
drop function if exists public.criar_pedido(jsonb, jsonb, jsonb);
create function public.criar_pedido(p_pedido jsonb, p_itens jsonb, p_cliente jsonb default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_cliente_id bigint;
  v_pedido_id  bigint;
  v_item       jsonb;
  v_prod       record;
  v_qtd        int;
  v_tam        text;
  v_cor        text;
  v_extra      numeric;
  v_preco      numeric;
  v_subtotal   numeric := 0;
  v_desconto   numeric := 0;
  v_frete      numeric;
  v_total      numeric;
begin
  if jsonb_typeof(p_itens) is distinct from 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'pedido_sem_itens' using errcode = 'P0001';
  end if;

  if p_cliente is not null then
    begin
      insert into clientes (nome, email, telefone, cpf, cep, logradouro, numero, complemento, bairro, cidade, estado)
      values (p_cliente->>'nome', lower(trim(p_cliente->>'email')), p_cliente->>'telefone', nullif(p_cliente->>'cpf', ''),
              p_cliente->>'cep', p_cliente->>'logradouro', p_cliente->>'numero', nullif(p_cliente->>'complemento', ''),
              p_cliente->>'bairro', p_cliente->>'cidade', p_cliente->>'estado')
      returning id into v_cliente_id;
    exception when unique_violation then
      v_cliente_id := null;   -- e-mail já cadastrado: segue como visitante, igual ao fluxo anterior
    end;
  end if;

  -- totais são preenchidos depois de precificar os itens (tudo na mesma transação)
  insert into pedidos (
    status, subtotal, frete, total, prazo_entrega_dias, observacoes, mp_status,
    endereco_cep, endereco_logradouro, endereco_numero, endereco_complemento,
    endereco_bairro, endereco_cidade, endereco_estado,
    cliente_id, visitante_nome, visitante_email, visitante_telefone)
  values (
    'pendente', 0, 0, 0,
    5,   -- prazo de produção fixo da marca: 3 a 5 dias úteis (grava o teto)
    nullif(p_pedido->>'observacoes', ''), p_pedido->>'mp_status',
    p_pedido->>'endereco_cep', p_pedido->>'endereco_logradouro', p_pedido->>'endereco_numero',
    nullif(p_pedido->>'endereco_complemento', ''), p_pedido->>'endereco_bairro',
    p_pedido->>'endereco_cidade', p_pedido->>'endereco_estado',
    v_cliente_id,
    case when v_cliente_id is null then coalesce(p_pedido->>'visitante_nome',  p_cliente->>'nome') end,
    case when v_cliente_id is null then lower(trim(coalesce(p_pedido->>'visitante_email', p_cliente->>'email'))) end,
    case when v_cliente_id is null then coalesce(p_pedido->>'visitante_telefone', p_cliente->>'telefone') end)
  returning id into v_pedido_id;

  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_qtd := coalesce((v_item->>'quantidade')::int, 0);
    if v_qtd not between 1 and 99 then
      raise exception 'item_invalido' using errcode = 'P0001';
    end if;

    select p.id, p.name, p.price, p.preco_promocional into v_prod
    from produtos p
    where p.id = nullif(v_item->>'produto_id', '')::bigint
      and p.ativo is not false and p.oculto is not true and p.esgotado is not true;
    if not found then
      raise exception 'produto_indisponivel' using errcode = 'P0001';
    end if;

    v_preco := coalesce(nullif(v_prod.preco_promocional, 0), v_prod.price);
    if v_preco is null or v_preco <= 0 then
      raise exception 'produto_sem_preco' using errcode = 'P0001';   -- itens "sob consulta" não são vendidos pelo checkout
    end if;

    v_tam := nullif(trim(v_item->>'tamanho'), '');
    v_cor := nullif(trim(v_item->>'cor'), '');
    v_extra := null;
    if v_tam is not null then
      select v.preco_extra into v_extra
      from produto_variacoes v
      where v.produto_id = v_prod.id and v.ativo is not false and v.tamanho = v_tam
        and (v_cor is null or v.cor = v_cor)
      order by v.id limit 1;
    end if;
    v_preco := v_preco + coalesce(v_extra, 0);

    insert into itens_pedido (pedido_id, produto_id, nome_produto, preco_unitario, quantidade)
    values (v_pedido_id, v_prod.id,
            v_prod.name || case when v_tam is not null or v_cor is not null
                                then ' (' || concat_ws(' / ', v_tam, v_cor) || ')' else '' end,
            v_preco, v_qtd);
    v_subtotal := v_subtotal + v_preco * v_qtd;
  end loop;

  if p_pedido->>'mp_status' = 'pix' then
    v_desconto := round(v_subtotal * 0.05, 2);
  end if;
  v_frete := greatest(coalesce((p_pedido->>'frete')::numeric, 0), 0);
  v_total := v_subtotal - v_desconto + v_frete;

  update pedidos set subtotal = v_subtotal, frete = v_frete, total = v_total
  where id = v_pedido_id;

  return json_build_object('id', v_pedido_id, 'subtotal', v_subtotal, 'desconto', v_desconto, 'total', v_total);
end
$$;

-- vincula pedidos feitos como visitante à conta com o mesmo e-mail
create or replace function public.vincular_meus_pedidos()
returns integer
language plpgsql security definer set search_path = public
as $$
declare n integer;
begin
  if auth.uid() is null or cr_email_sessao() is null then return 0; end if;
  update pedidos p set user_id = auth.uid()
  where p.user_id is null and cr_pedido_da_sessao(null, p.visitante_email, p.cliente_id);
  get diagnostics n = row_count;
  return n;
end
$$;


-- ── 6. permissões das funções ─────────────────────────────────────────
revoke all on function public.cr_inserir_avaliacao(bigint, text, text, int, text, text) from public, anon, authenticated;
revoke all on function public.rastrear_pedido_publico(text, text)                   from public;
revoke all on function public.avaliacao_contexto(bigint, uuid)                      from public;
revoke all on function public.enviar_avaliacao(bigint, uuid, text, int, text, text) from public;
revoke all on function public.enviar_avaliacao_conta(bigint, text, int, text, text) from public;
revoke all on function public.criar_pedido(jsonb, jsonb, jsonb)                     from public;
revoke all on function public.vincular_meus_pedidos()                               from public;
revoke all on function public.cr_pedido_da_sessao(uuid, text, bigint)              from public, anon;

grant execute on function public.rastrear_pedido_publico(text, text)                   to anon, authenticated;
grant execute on function public.avaliacao_contexto(bigint, uuid)                      to anon, authenticated;
grant execute on function public.enviar_avaliacao(bigint, uuid, text, int, text, text) to anon, authenticated;
grant execute on function public.enviar_avaliacao_conta(bigint, text, int, text, text) to authenticated;
grant execute on function public.criar_pedido(jsonb, jsonb, jsonb)                     to anon, authenticated;
grant execute on function public.vincular_meus_pedidos()                               to authenticated;
grant execute on function public.cr_pedido_da_sessao(uuid, text, bigint)              to authenticated;

-- funções antigas que devolviam o pedido inteiro a partir só do número
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('rastrear_pedido', 'itens_do_pedido')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end
$$;


-- ── 7. visitante anônimo: sem acesso direto a dados pessoais ──────────
revoke all on public.pedidos, public.clientes, public.itens_pedido from anon;
revoke all on public.avaliacoes                                      from anon;
revoke all on public.favoritos, public.enderecos_salvos              from anon;
revoke select, update, delete on public.alertas_estoque             from anon;   -- "avise-me" continua gravando
revoke select, update, delete on public.page_views                  from anon;   -- métricas continuam gravando


-- ── 8. cliente logado: só os próprios dados ───────────────────────────
-- Políticas RESTRICTIVE só estreitam o acesso: somam-se (com E) às regras
-- que já existem. Nada que hoje é negado passa a ser permitido.

-- pedidos: lê os seus; escrever é só admin (checkout e vínculo usam funções)
drop policy if exists cr_lgpd_pedidos_select on public.pedidos;
create policy cr_lgpd_pedidos_select on public.pedidos as restrictive for select to authenticated
  using (cr_is_admin() or cr_pedido_da_sessao(user_id, visitante_email, cliente_id));
drop policy if exists cr_lgpd_pedidos_insert on public.pedidos;
create policy cr_lgpd_pedidos_insert on public.pedidos as restrictive for insert to authenticated
  with check (cr_is_admin());
drop policy if exists cr_lgpd_pedidos_update on public.pedidos;
create policy cr_lgpd_pedidos_update on public.pedidos as restrictive for update to authenticated
  using (cr_is_admin()) with check (cr_is_admin());
drop policy if exists cr_lgpd_pedidos_delete on public.pedidos;
create policy cr_lgpd_pedidos_delete on public.pedidos as restrictive for delete to authenticated
  using (cr_is_admin());

-- itens do pedido: lê os dos seus pedidos; escrever é só admin
drop policy if exists cr_lgpd_itens_select on public.itens_pedido;
create policy cr_lgpd_itens_select on public.itens_pedido as restrictive for select to authenticated
  using (cr_is_admin() or exists (
    select 1 from public.pedidos p
    where p.id = itens_pedido.pedido_id
      and cr_pedido_da_sessao(p.user_id, p.visitante_email, p.cliente_id)));
drop policy if exists cr_lgpd_itens_write on public.itens_pedido;
create policy cr_lgpd_itens_write on public.itens_pedido as restrictive for insert to authenticated
  with check (cr_is_admin());
drop policy if exists cr_lgpd_itens_update on public.itens_pedido;
create policy cr_lgpd_itens_update on public.itens_pedido as restrictive for update to authenticated
  using (cr_is_admin()) with check (cr_is_admin());
drop policy if exists cr_lgpd_itens_delete on public.itens_pedido;
create policy cr_lgpd_itens_delete on public.itens_pedido as restrictive for delete to authenticated
  using (cr_is_admin());

-- clientes: só o próprio cadastro (pelo e-mail da sessão)
drop policy if exists cr_lgpd_clientes on public.clientes;
create policy cr_lgpd_clientes on public.clientes as restrictive for all to authenticated
  using (cr_is_admin() or lower(email) = cr_email_sessao())
  with check (cr_is_admin() or lower(email) = cr_email_sessao());

-- avaliações: tabela completa (com e-mail) só para o admin; o público lê a view
drop policy if exists cr_lgpd_avaliacoes on public.avaliacoes;
create policy cr_lgpd_avaliacoes on public.avaliacoes as restrictive for all to authenticated
  using (cr_is_admin()) with check (cr_is_admin());

-- favoritos e endereços salvos: só os do próprio usuário
drop policy if exists cr_lgpd_favoritos on public.favoritos;
create policy cr_lgpd_favoritos on public.favoritos as restrictive for all to authenticated
  using (cr_is_admin() or user_id = auth.uid()) with check (cr_is_admin() or user_id = auth.uid());
drop policy if exists cr_lgpd_enderecos on public.enderecos_salvos;
create policy cr_lgpd_enderecos on public.enderecos_salvos as restrictive for all to authenticated
  using (cr_is_admin() or user_id = auth.uid()) with check (cr_is_admin() or user_id = auth.uid());

-- e-mails do "avise-me" e métricas: leitura só do admin
drop policy if exists cr_lgpd_alertas_select on public.alertas_estoque;
create policy cr_lgpd_alertas_select on public.alertas_estoque as restrictive for select to authenticated
  using (cr_is_admin());
drop policy if exists cr_lgpd_alertas_update on public.alertas_estoque;
create policy cr_lgpd_alertas_update on public.alertas_estoque as restrictive for update to authenticated
  using (cr_is_admin()) with check (cr_is_admin());
drop policy if exists cr_lgpd_alertas_delete on public.alertas_estoque;
create policy cr_lgpd_alertas_delete on public.alertas_estoque as restrictive for delete to authenticated
  using (cr_is_admin());
drop policy if exists cr_lgpd_pageviews_select on public.page_views;
create policy cr_lgpd_pageviews_select on public.page_views as restrictive for select to authenticated
  using (cr_is_admin());

commit;


-- ════════════════════════════════════════════════════════════════════
-- VERIFICAÇÃO — rode depois e confira (ou cole o resultado para revisão)
-- ════════════════════════════════════════════════════════════════════
-- Políticas de cada tabela:
--   select tablename, policyname, permissive, roles, cmd, qual, with_check
--   from pg_policies where schemaname = 'public' order by 1, 2;
--
-- O que o visitante anônimo ainda pode fazer em cada tabela:
--   select table_name, string_agg(privilege_type, ', ' order by privilege_type)
--   from information_schema.role_table_grants
--   where table_schema = 'public' and grantee = 'anon'
--   group by 1 order by 1;
