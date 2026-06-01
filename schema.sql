-- ============================================================
-- CHUCHU ROSA — Schema Supabase (compatível com tabela existente)
-- Rode no SQL Editor: supabase.com/dashboard/project/oznpfqsgurztffwfyfec/sql
-- ============================================================

-- Verifica e adiciona colunas faltando na tabela produtos existente
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS descricao text;
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS preco_promocional numeric(10,2);
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS prazo_producao_dias integer DEFAULT 7;
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS ativo boolean DEFAULT true;
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS destaque boolean DEFAULT false;
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

-- Se a coluna created_at não existir
ALTER TABLE produtos ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

-- Fotos dos produtos (id integer para compatibilidade)
CREATE TABLE IF NOT EXISTS produto_fotos (
  id serial PRIMARY KEY,
  produto_id integer REFERENCES produtos(id) ON DELETE CASCADE,
  url text NOT NULL,
  ordem integer DEFAULT 0,
  capa boolean DEFAULT false
);

-- Clientes
CREATE TABLE IF NOT EXISTS clientes (
  id serial PRIMARY KEY,
  nome text NOT NULL,
  email text UNIQUE NOT NULL,
  telefone text,
  cpf text,
  cep text,
  logradouro text,
  numero text,
  complemento text,
  bairro text,
  cidade text,
  estado text,
  created_at timestamptz DEFAULT now()
);

-- Pedidos
CREATE TABLE IF NOT EXISTS pedidos (
  id serial PRIMARY KEY,
  cliente_id integer REFERENCES clientes(id),
  visitante_nome text,
  visitante_email text,
  visitante_telefone text,
  status text DEFAULT 'pendente',
  subtotal numeric(10,2),
  frete numeric(10,2) DEFAULT 0,
  total numeric(10,2),
  prazo_entrega_dias integer,
  observacoes text,
  mp_preference_id text,
  mp_payment_id text,
  mp_status text,
  endereco_cep text,
  endereco_logradouro text,
  endereco_numero text,
  endereco_complemento text,
  endereco_bairro text,
  endereco_cidade text,
  endereco_estado text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Itens do pedido
CREATE TABLE IF NOT EXISTS itens_pedido (
  id serial PRIMARY KEY,
  pedido_id integer REFERENCES pedidos(id) ON DELETE CASCADE,
  produto_id integer REFERENCES produtos(id),
  nome_produto text NOT NULL,
  preco_unitario numeric(10,2) NOT NULL,
  quantidade integer DEFAULT 1,
  subtotal numeric(10,2) GENERATED ALWAYS AS (preco_unitario * quantidade) STORED
);

-- RLS
ALTER TABLE produtos ENABLE ROW LEVEL SECURITY;
ALTER TABLE produto_fotos ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE itens_pedido ENABLE ROW LEVEL SECURITY;

-- Policies (ignora se já existirem)
DO $$ BEGIN
  CREATE POLICY "produtos_public_read" ON produtos FOR SELECT USING (ativo = true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "produtos_admin_all" ON produtos FOR ALL USING (auth.role() = 'authenticated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "fotos_public_read" ON produto_fotos FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "fotos_admin_all" ON produto_fotos FOR ALL USING (auth.role() = 'authenticated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "clientes_insert" ON clientes FOR INSERT WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "clientes_admin_all" ON clientes FOR ALL USING (auth.role() = 'authenticated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "pedidos_insert" ON pedidos FOR INSERT WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "pedidos_admin_all" ON pedidos FOR ALL USING (auth.role() = 'authenticated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "itens_insert" ON itens_pedido FOR INSERT WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "itens_admin_all" ON itens_pedido FOR ALL USING (auth.role() = 'authenticated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS produtos_updated_at ON produtos;
CREATE TRIGGER produtos_updated_at BEFORE UPDATE ON produtos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS pedidos_updated_at ON pedidos;
CREATE TRIGGER pedidos_updated_at BEFORE UPDATE ON pedidos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
