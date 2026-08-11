-- ================================================================
-- SisDist — Schema Supabase
-- Execute este script no SQL Editor do Supabase Dashboard
-- (Database → SQL Editor → New query → Cole e execute)
-- ================================================================

-- ── 1. TABELAS ───────────────────────────────────────────────────

create table if not exists public.semestres (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  inst         text not null default 'IFTM-Ituiutaba',
  ativo        boolean default true,
  hrs_por_faixa numeric default 2,
  created_at   timestamptz default now()
);
comment on table public.semestres is 'Semestres/períodos letivos';

create table if not exists public.areas (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  semestre_id  uuid references public.semestres(id) on delete cascade,
  created_at   timestamptz default now()
);
comment on table public.areas is 'Áreas de conhecimento (ex: Matemática, Física)';

create table if not exists public.professores (
  id           uuid primary key default gen_random_uuid(),
  auth_id      uuid unique references auth.users(id) on delete set null,
  nome         text not null,
  email        text not null unique,
  area_id      uuid references public.areas(id) on delete set null,
  ch_min       numeric default 8,
  ch_max       numeric default 20,
  is_gestor    boolean default false,
  confirmado_em timestamptz,
  created_at   timestamptz default now()
);
comment on table public.professores is 'Docentes e gestores';

create table if not exists public.horarios (
  id           uuid primary key default gen_random_uuid(),
  dia          text not null,
  inicio       text not null,
  fim          text not null,
  turno        text check (turno in ('diurno','noturno')) default 'diurno',
  semestre_id  uuid references public.semestres(id) on delete cascade,
  created_at   timestamptz default now(),
  unique (dia, inicio, semestre_id)
);
comment on table public.horarios is 'Faixas horárias disponíveis no semestre';

create table if not exists public.disciplinas (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  turma        text,
  ch_semanal   numeric not null,
  turno        text check (turno in ('diurno','noturno','ambos')) default 'diurno',
  area_id      uuid references public.areas(id) on delete cascade,
  semestre_id  uuid references public.semestres(id) on delete cascade,
  created_at   timestamptz default now()
);
comment on table public.disciplinas is 'Disciplinas/turmas a serem distribuídas';

create table if not exists public.preferencias_disciplinas (
  id           uuid primary key default gen_random_uuid(),
  prof_id      uuid not null references public.professores(id) on delete cascade,
  disc_id      uuid not null references public.disciplinas(id) on delete cascade,
  nota         integer default 3 check (nota >= 0 and nota <= 5),
  updated_at   timestamptz default now(),
  unique (prof_id, disc_id)
);
comment on table public.preferencias_disciplinas is 'Notas de preferência (0–5) por disciplina';

create table if not exists public.preferencias_horarios (
  id           uuid primary key default gen_random_uuid(),
  prof_id      uuid not null references public.professores(id) on delete cascade,
  horario_id   uuid not null references public.horarios(id) on delete cascade,
  nota         integer default 3 check (nota >= 0 and nota <= 5),
  updated_at   timestamptz default now(),
  unique (prof_id, horario_id)
);
comment on table public.preferencias_horarios is 'Notas de preferência (0–5) por faixa horária';

create table if not exists public.distribuicao_disciplinas (
  id           uuid primary key default gen_random_uuid(),
  disc_id      uuid unique references public.disciplinas(id) on delete cascade,
  prof_id      uuid references public.professores(id) on delete set null,
  semestre_id  uuid references public.semestres(id),
  satisfacao   numeric,
  criado_em    timestamptz default now()
);
comment on table public.distribuicao_disciplinas is 'Resultado do Módulo 1: disciplina → professor';

create table if not exists public.distribuicao_horarios (
  id           uuid primary key default gen_random_uuid(),
  disc_id      uuid references public.disciplinas(id) on delete cascade,
  horario_id   uuid references public.horarios(id) on delete cascade,
  semestre_id  uuid references public.semestres(id),
  unique (disc_id, horario_id)
);
comment on table public.distribuicao_horarios is 'Resultado do Módulo 2: disciplina → horários';

-- ── 2. RLS ───────────────────────────────────────────────────────

alter table public.semestres              enable row level security;
alter table public.areas                  enable row level security;
alter table public.professores            enable row level security;
alter table public.horarios               enable row level security;
alter table public.disciplinas            enable row level security;
alter table public.preferencias_disciplinas enable row level security;
alter table public.preferencias_horarios  enable row level security;
alter table public.distribuicao_disciplinas enable row level security;
alter table public.distribuicao_horarios  enable row level security;

-- Função auxiliar: usuário atual é gestor?
create or replace function public.is_gestor()
returns boolean
language sql
security definer
stable
as $$
  select coalesce(
    (select is_gestor from public.professores where auth_id = auth.uid()),
    false
  )
$$;

-- semestres
drop policy if exists "auth_read_semestres" on public.semestres;
drop policy if exists "gestor_all_semestres" on public.semestres;
create policy "auth_read_semestres"   on public.semestres for select using (auth.uid() is not null);
create policy "gestor_all_semestres"  on public.semestres for all    using (public.is_gestor());

-- areas
drop policy if exists "auth_read_areas" on public.areas;
drop policy if exists "gestor_all_areas" on public.areas;
create policy "auth_read_areas"   on public.areas for select using (auth.uid() is not null);
create policy "gestor_all_areas"  on public.areas for all    using (public.is_gestor());

-- professores
drop policy if exists "read_own_or_gestor"   on public.professores;
drop policy if exists "gestor_write_profs"   on public.professores;
drop policy if exists "first_gestor_setup"   on public.professores;
create policy "read_own_or_gestor"   on public.professores for select
  using (auth_id = auth.uid() or public.is_gestor());
create policy "gestor_write_profs"   on public.professores for all
  using (public.is_gestor());
-- Permite criar o primeiro gestor sem auth pré-existente (bootstrap via RPC)
create policy "first_gestor_setup"   on public.professores for insert
  with check (not exists (select 1 from public.professores where is_gestor = true));

-- horarios
drop policy if exists "auth_read_horarios" on public.horarios;
drop policy if exists "gestor_all_horarios" on public.horarios;
create policy "auth_read_horarios"   on public.horarios for select using (auth.uid() is not null);
create policy "gestor_all_horarios"  on public.horarios for all    using (public.is_gestor());

-- disciplinas
drop policy if exists "auth_read_disciplinas" on public.disciplinas;
drop policy if exists "gestor_all_disciplinas" on public.disciplinas;
create policy "auth_read_disciplinas"   on public.disciplinas for select using (auth.uid() is not null);
create policy "gestor_all_disciplinas"  on public.disciplinas for all    using (public.is_gestor());

-- preferencias_disciplinas
drop policy if exists "own_disc_prefs" on public.preferencias_disciplinas;
create policy "own_disc_prefs" on public.preferencias_disciplinas for all
  using (
    prof_id = (select id from public.professores where auth_id = auth.uid())
    or public.is_gestor()
  );

-- preferencias_horarios
drop policy if exists "own_slot_prefs" on public.preferencias_horarios;
create policy "own_slot_prefs" on public.preferencias_horarios for all
  using (
    prof_id = (select id from public.professores where auth_id = auth.uid())
    or public.is_gestor()
  );

-- distribuicao_disciplinas
drop policy if exists "auth_read_dist_disc"  on public.distribuicao_disciplinas;
drop policy if exists "gestor_write_dist_disc" on public.distribuicao_disciplinas;
create policy "auth_read_dist_disc"    on public.distribuicao_disciplinas for select using (auth.uid() is not null);
create policy "gestor_write_dist_disc" on public.distribuicao_disciplinas for all    using (public.is_gestor());

-- distribuicao_horarios
drop policy if exists "auth_read_dist_hor"  on public.distribuicao_horarios;
drop policy if exists "gestor_write_dist_hor" on public.distribuicao_horarios;
create policy "auth_read_dist_hor"    on public.distribuicao_horarios for select using (auth.uid() is not null);
create policy "gestor_write_dist_hor" on public.distribuicao_horarios for all    using (public.is_gestor());

-- ── 3. FUNÇÕES RPC ───────────────────────────────────────────────

-- Retorna (ou vincula) o perfil do professor ao auth.uid()
-- Chamada logo após o login bem-sucedido
create or replace function public.get_or_link_profile()
returns json
language plpgsql
security definer
as $$
declare
  result public.professores%ROWTYPE;
begin
  -- Já está vinculado?
  select * into result from public.professores where auth_id = auth.uid();
  if found then return row_to_json(result); end if;

  -- Vincula pelo e-mail (professor foi cadastrado pelo gestor sem auth_id)
  update public.professores
  set auth_id = auth.uid()
  where email = (select email from auth.users where id = auth.uid())
    and auth_id is null
  returning * into result;

  if found then return row_to_json(result); end if;

  -- E-mail não está na lista de professores nem gestores
  return null;
end;
$$;

-- Configura o primeiro gestor e o primeiro semestre (bootstrap)
create or replace function public.setup_initial_gestor(
  p_nome        text,
  p_inst        text,
  p_semestre    text,
  p_hrs_faixa   numeric default 2
)
returns json
language plpgsql
security definer
as $$
declare
  sem_id    uuid;
  user_email text;
begin
  if exists (select 1 from public.professores where is_gestor = true) then
    raise exception 'Um gestor já está configurado.';
  end if;

  select email into user_email from auth.users where id = auth.uid();

  insert into public.semestres (nome, inst, ativo, hrs_por_faixa)
  values (p_semestre, p_inst, true, p_hrs_faixa)
  returning id into sem_id;

  insert into public.professores (auth_id, nome, email, is_gestor, ch_min, ch_max)
  values (auth.uid(), p_nome, user_email, true, 0, 40);

  return json_build_object('ok', true, 'semestre_id', sem_id);
end;
$$;

-- Marca as preferências do professor como confirmadas
create or replace function public.confirmar_submissao()
returns void
language plpgsql
security definer
as $$
begin
  update public.professores
  set confirmado_em = now()
  where auth_id = auth.uid();
end;
$$;

-- Salva o resultado do Módulo 1 em lote (chamada pelo gestor)
create or replace function public.salvar_distribuicao_disciplinas(
  p_semestre_id uuid,
  p_itens jsonb   -- [{disc_id, prof_id, satisfacao}]
)
returns void
language plpgsql
security definer
as $$
declare
  item jsonb;
begin
  if not public.is_gestor() then raise exception 'Acesso negado.'; end if;

  delete from public.distribuicao_disciplinas where semestre_id = p_semestre_id;

  for item in select * from jsonb_array_elements(p_itens)
  loop
    insert into public.distribuicao_disciplinas (disc_id, prof_id, semestre_id, satisfacao)
    values (
      (item->>'disc_id')::uuid,
      (item->>'prof_id')::uuid,
      p_semestre_id,
      (item->>'satisfacao')::numeric
    );
  end loop;
end;
$$;

-- Salva o resultado do Módulo 2 em lote (chamada pelo gestor)
create or replace function public.salvar_distribuicao_horarios(
  p_semestre_id uuid,
  p_itens jsonb   -- [{disc_id, horario_id}]
)
returns void
language plpgsql
security definer
as $$
declare
  item jsonb;
begin
  if not public.is_gestor() then raise exception 'Acesso negado.'; end if;

  delete from public.distribuicao_horarios where semestre_id = p_semestre_id;

  for item in select * from jsonb_array_elements(p_itens)
  loop
    insert into public.distribuicao_horarios (disc_id, horario_id, semestre_id)
    values (
      (item->>'disc_id')::uuid,
      (item->>'horario_id')::uuid,
      p_semestre_id
    );
  end loop;
end;
$$;

-- ── 4. FAIXAS HORÁRIAS PADRÃO ────────────────────────────────────
-- Execute esta parte separadamente após criar o primeiro semestre,
-- substituindo 'SEU_SEMESTRE_ID' pelo UUID gerado no setup.
--
-- insert into public.horarios (dia, inicio, fim, turno, semestre_id) values
--   ('Segunda','07:30','09:10','diurno','SEU_SEMESTRE_ID'),
--   ('Segunda','09:30','11:10','diurno','SEU_SEMESTRE_ID'),
--   ('Segunda','13:30','15:10','diurno','SEU_SEMESTRE_ID'),
--   ('Segunda','15:30','17:10','diurno','SEU_SEMESTRE_ID'),
--   ('Segunda','19:00','20:40','noturno','SEU_SEMESTRE_ID'),
--   ('Segunda','20:50','22:30','noturno','SEU_SEMESTRE_ID'),
--   -- repita para Terça, Quarta, Quinta, Sexta...
-- ;
-- (O aplicativo tem botão "Carregar Padrão" que faz isso automaticamente)
