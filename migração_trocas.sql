-- ================================================================
-- SisDist — Migração: Trocas de Aula (feature aditiva)
-- Execute no SQL Editor do Supabase Dashboard, DEPOIS de já ter
-- rodado supabase_setup.sql e migração_multi_campus.sql.
--
-- Este script é 100% aditivo: cria tabelas e funções novas, não
-- altera nem apaga nenhuma tabela/policy/função já existente.
-- ================================================================

-- ── 1. TABELAS ───────────────────────────────────────────────────

create table if not exists public.grade_aulas (
  id           uuid primary key default gen_random_uuid(),
  prof_id      uuid not null references public.professores(id) on delete cascade,
  semestre_id  uuid not null references public.semestres(id) on delete cascade,
  dia          text not null check (dia in ('Segunda','Terça','Quarta','Quinta','Sexta','Sábado')),
  inicio       time not null,
  fim          time not null check (fim > inicio),
  turma_codigo text not null,
  turma        text,
  disciplina   text not null,
  sala         text,
  created_at   timestamptz default now()
);
comment on table public.grade_aulas is
  'Grade horária real (aulas efetivas) de cada professor, usada pela feature de Trocas de Aula. Independente do resultado de distribuicao_horarios.';
create index if not exists idx_grade_aulas_prof  on public.grade_aulas(prof_id);
create index if not exists idx_grade_aulas_sem   on public.grade_aulas(semestre_id);
create index if not exists idx_grade_aulas_turma on public.grade_aulas(turma_codigo);

create table if not exists public.trocas (
  id                      uuid primary key default gen_random_uuid(),
  semestre_id             uuid not null references public.semestres(id) on delete cascade,
  solicitante_id          uuid not null references public.professores(id) on delete cascade,
  substituto_id           uuid not null references public.professores(id) on delete cascade,
  horario_solicitante_id  uuid not null references public.grade_aulas(id) on delete cascade,
  data_ausencia           date not null,
  dia_semana              text not null check (dia_semana in ('Segunda','Terça','Quarta','Quinta','Sexta','Sábado')),
  inicio                  time not null,
  fim                     time not null,
  turma_codigo            text not null,
  turma                   text,
  disciplina              text not null,
  status                  text not null default 'proposta'
                            check (status in ('proposta','reposicao_proposta','confirmada','recusada','cancelada')),
  data_reposicao_proposta date,
  reposicao_dia           text check (reposicao_dia in ('Segunda','Terça','Quarta','Quinta','Sexta','Sábado')),
  reposicao_inicio        time,
  reposicao_fim           time,
  created_at              timestamptz default now(),
  updated_at              timestamptz default now(),
  constraint chk_troca_partes_distintas check (substituto_id <> solicitante_id)
);
comment on table public.trocas is 'Propostas de troca/reposição de aula entre professores.';
create index if not exists idx_trocas_solicitante on public.trocas(solicitante_id);
create index if not exists idx_trocas_substituto   on public.trocas(substituto_id);
create index if not exists idx_trocas_status       on public.trocas(status);

-- ── 2. RLS ───────────────────────────────────────────────────────

alter table public.grade_aulas enable row level security;
alter table public.trocas       enable row level security;

-- grade_aulas: qualquer professor autenticado do MESMO CAMPUS (inst) pode
-- ler (necessário para o algoritmo de matching enxergar colegas); só o
-- gestor do mesmo campus pode escrever.
-- (Nota: mais estrito que o padrão gestor_all_horarios pré-existente, que
-- não checa inst — não repetimos esse ponto fraco nas tabelas novas.)
drop policy if exists "read_same_inst_grade" on public.grade_aulas;
drop policy if exists "gestor_write_grade"   on public.grade_aulas;
create policy "read_same_inst_grade" on public.grade_aulas for select
  using (
    exists (
      select 1 from public.professores me
      join public.professores dono on dono.id = grade_aulas.prof_id
      where me.auth_id = auth.uid() and dono.inst = me.inst
    )
  );
create policy "gestor_write_grade" on public.grade_aulas for all
  using (
    public.is_gestor()
    and exists (
      select 1 from public.professores me
      join public.professores dono on dono.id = grade_aulas.prof_id
      where me.auth_id = auth.uid() and dono.inst = me.inst
    )
  );

-- trocas: SELECT apenas para as partes envolvidas ou o gestor do campus.
-- Deliberadamente SEM policies de insert/update/delete diretas: toda
-- mutação passa pelas funções RPC abaixo (security definer), cada uma
-- fazendo a checagem de estado + escrita em UMA instrução SQL (guard
-- repetido na cláusula WHERE), para eliminar o tipo de race condition
-- (check-then-write em duas escritas separadas) já identificado e
-- corrigido no protótipo Firestore que deu origem a esta feature.
drop policy if exists "read_own_trocas" on public.trocas;
create policy "read_own_trocas" on public.trocas for select
  using (
    solicitante_id = (select id from public.professores where auth_id = auth.uid())
    or substituto_id = (select id from public.professores where auth_id = auth.uid())
    or public.is_gestor()
  );

-- ── 3. FUNÇÕES RPC ───────────────────────────────────────────────

create or replace function public._dow_dia(p_dia text)
returns int language sql immutable as $$
  select case p_dia
    when 'Domingo' then 0 when 'Segunda' then 1 when 'Terça' then 2
    when 'Quarta'  then 3 when 'Quinta'  then 4 when 'Sexta'  then 5
    when 'Sábado'  then 6 end
$$;

-- Importação em lote pelo gestor (substitui a grade do semestre inteiro).
-- Espelha o padrão de salvar_distribuicao_horarios (delete + insert
-- dentro da mesma função). Casa professor por e-mail.
-- p_itens: [{email, dia, inicio, fim, turma_codigo, turma, disciplina, sala}]
create or replace function public.gestor_importar_grade(
  p_semestre_id uuid,
  p_itens jsonb
) returns json
language plpgsql security definer as $$
declare
  item jsonb; v_prof_id uuid; v_my_inst text; v_count int := 0; v_erros jsonb := '[]'::jsonb;
begin
  if not public.is_gestor() then raise exception 'Acesso negado.'; end if;

  select inst into v_my_inst from public.professores where auth_id = auth.uid();
  if not exists (select 1 from public.semestres where id = p_semestre_id and inst = v_my_inst) then
    raise exception 'Semestre não pertence ao seu campus.';
  end if;

  delete from public.grade_aulas where semestre_id = p_semestre_id;

  for item in select * from jsonb_array_elements(p_itens) loop
    select id into v_prof_id from public.professores
      where email = lower(trim(item->>'email')) and inst = v_my_inst;
    if v_prof_id is null then
      v_erros := v_erros || jsonb_build_object('email', item->>'email', 'erro', 'professor não encontrado neste campus');
      continue;
    end if;
    if (item->>'dia') not in ('Segunda','Terça','Quarta','Quinta','Sexta','Sábado') then
      v_erros := v_erros || jsonb_build_object('email', item->>'email', 'erro', 'dia inválido: '||(item->>'dia'));
      continue;
    end if;
    insert into public.grade_aulas (prof_id, semestre_id, dia, inicio, fim, turma_codigo, turma, disciplina, sala)
    values (
      v_prof_id, p_semestre_id, item->>'dia', (item->>'inicio')::time, (item->>'fim')::time,
      upper(trim(item->>'turma_codigo')), item->>'turma', item->>'disciplina', item->>'sala'
    );
    v_count := v_count + 1;
  end loop;

  return json_build_object('importados', v_count, 'erros', v_erros);
end;
$$;

-- Solicitante propõe uma troca.
create or replace function public.trocas_propor(
  p_horario_id uuid, p_substituto_id uuid, p_data_ausencia date
) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_h public.grade_aulas%rowtype; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  if v_prof_id is null then raise exception 'Perfil não encontrado.'; end if;

  select * into v_h from public.grade_aulas where id = p_horario_id;
  if not found or v_h.prof_id <> v_prof_id then
    raise exception 'Aula não encontrada ou não pertence a você.';
  end if;
  if p_substituto_id = v_prof_id then raise exception 'Você não pode propor troca consigo mesmo.'; end if;
  if extract(dow from p_data_ausencia)::int <> public._dow_dia(v_h.dia) then
    raise exception 'A data de ausência não cai no dia da semana da aula (%).', v_h.dia;
  end if;
  if not exists (select 1 from public.grade_aulas g
                 where g.prof_id = p_substituto_id and g.turma_codigo = v_h.turma_codigo) then
    raise exception 'O colega selecionado não leciona essa turma.';
  end if;
  if exists (select 1 from public.grade_aulas g
             where g.prof_id = p_substituto_id and g.semestre_id = v_h.semestre_id and g.dia = v_h.dia
               and g.inicio < v_h.fim and v_h.inicio < g.fim) then
    raise exception 'O colega selecionado já tem aula nesse horário.';
  end if;

  insert into public.trocas (semestre_id, solicitante_id, substituto_id, horario_solicitante_id,
    data_ausencia, dia_semana, inicio, fim, turma_codigo, turma, disciplina, status)
  values (v_h.semestre_id, v_prof_id, p_substituto_id, v_h.id,
    p_data_ausencia, v_h.dia, v_h.inicio, v_h.fim, v_h.turma_codigo, v_h.turma, v_h.disciplina, 'proposta')
  returning * into v_row;
  return v_row;
end;
$$;

-- Substituto aceita + propõe reposição, atomicamente.
create or replace function public.trocas_aceitar_com_reposicao(
  p_troca_id uuid, p_reposicao_dia text, p_reposicao_inicio time,
  p_reposicao_fim time, p_data_reposicao date
) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  select * into v_row from public.trocas where id = p_troca_id;
  if not found then raise exception 'Troca não encontrada.'; end if;
  if v_row.substituto_id <> v_prof_id then raise exception 'Você não é o substituto desta troca.'; end if;
  if v_row.status <> 'proposta' then raise exception 'Proposta não está mais disponível (status: %).', v_row.status; end if;
  if extract(dow from p_data_reposicao)::int <> public._dow_dia(p_reposicao_dia) then
    raise exception 'A data de reposição não cai no dia da semana informado.';
  end if;
  if not exists (select 1 from public.grade_aulas g
                 where g.prof_id = v_prof_id and g.turma_codigo = v_row.turma_codigo
                   and g.dia = p_reposicao_dia and g.inicio = p_reposicao_inicio and g.fim = p_reposicao_fim) then
    raise exception 'Você só pode propor reposição em um horário em que já leciona essa turma.';
  end if;

  update public.trocas set status = 'reposicao_proposta', reposicao_dia = p_reposicao_dia,
    reposicao_inicio = p_reposicao_inicio, reposicao_fim = p_reposicao_fim,
    data_reposicao_proposta = p_data_reposicao, updated_at = now()
  where id = p_troca_id and status = 'proposta' and substituto_id = v_prof_id
  returning * into v_row;
  if not found then raise exception 'A proposta foi alterada em paralelo. Recarregue e tente novamente.'; end if;
  return v_row;
end;
$$;

create or replace function public.trocas_recusar(p_troca_id uuid) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  update public.trocas set status = 'recusada', updated_at = now()
  where id = p_troca_id and status = 'proposta' and substituto_id = v_prof_id
  returning * into v_row;
  if not found then raise exception 'Ação inválida: a proposta não existe mais ou você não é o substituto.'; end if;
  return v_row;
end;
$$;

create or replace function public.trocas_confirmar(p_troca_id uuid) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  update public.trocas set status = 'confirmada', updated_at = now()
  where id = p_troca_id and status = 'reposicao_proposta' and solicitante_id = v_prof_id
  returning * into v_row;
  if not found then raise exception 'Ação inválida: não há reposição proposta pendente, ou você não é o solicitante.'; end if;
  return v_row;
end;
$$;

create or replace function public.trocas_pedir_nova_data(p_troca_id uuid) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  update public.trocas set status = 'proposta', reposicao_dia = null, reposicao_inicio = null,
    reposicao_fim = null, data_reposicao_proposta = null, updated_at = now()
  where id = p_troca_id and status = 'reposicao_proposta' and solicitante_id = v_prof_id
  returning * into v_row;
  if not found then raise exception 'Ação inválida.'; end if;
  return v_row;
end;
$$;

create or replace function public.trocas_cancelar(p_troca_id uuid) returns public.trocas
language plpgsql security definer as $$
declare v_prof_id uuid; v_row public.trocas;
begin
  select id into v_prof_id from public.professores where auth_id = auth.uid();
  update public.trocas set status = 'cancelada', updated_at = now()
  where id = p_troca_id and status in ('proposta','reposicao_proposta')
    and (solicitante_id = v_prof_id or substituto_id = v_prof_id)
  returning * into v_row;
  if not found then raise exception 'Ação inválida: já confirmada/recusada/cancelada, ou você não é parte da troca.'; end if;
  return v_row;
end;
$$;
