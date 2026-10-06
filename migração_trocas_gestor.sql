-- ================================================================
-- SisDist — Migração: Gestor propõe troca em nome de qualquer professor
-- Execute no SQL Editor do Supabase Dashboard, DEPOIS de migração_trocas.sql.
--
-- Aditiva: adiciona uma coluna opcional em trocas e uma função nova.
-- Não altera trocas_propor nem nenhuma policy existente.
-- ================================================================

-- Auditoria: quando a proposta é registrada pelo gestor em nome de outro
-- professor, guarda quem registrou (fica NULL nas propostas normais).
alter table public.trocas
  add column if not exists criada_por_id uuid references public.professores(id) on delete set null;
comment on column public.trocas.criada_por_id is
  'Gestor que registrou a proposta em nome do solicitante (NULL = o próprio solicitante propôs).';

-- Gestor propõe uma troca em nome de p_solicitante_id.
-- Mesmas validações de trocas_propor, mais: o gestor precisa ser da mesma
-- instituição do solicitante e do substituto.
create or replace function public.gestor_trocas_propor(
  p_solicitante_id uuid, p_horario_id uuid, p_substituto_id uuid, p_data_ausencia date
) returns public.trocas
language plpgsql security definer as $$
declare
  v_gestor public.professores%rowtype;
  v_sol    public.professores%rowtype;
  v_sub    public.professores%rowtype;
  v_h      public.grade_aulas%rowtype;
  v_row    public.trocas;
begin
  if not public.is_gestor() then raise exception 'Acesso negado.'; end if;

  select * into v_gestor from public.professores where auth_id = auth.uid();
  select * into v_sol from public.professores where id = p_solicitante_id;
  select * into v_sub from public.professores where id = p_substituto_id;

  if v_sol.id is null or v_sol.inst is distinct from v_gestor.inst then
    raise exception 'Professor solicitante não encontrado no seu campus.';
  end if;
  if v_sub.id is null or v_sub.inst is distinct from v_gestor.inst then
    raise exception 'Professor substituto não encontrado no seu campus.';
  end if;
  if p_solicitante_id = p_substituto_id then
    raise exception 'O solicitante e o substituto não podem ser a mesma pessoa.';
  end if;

  select * into v_h from public.grade_aulas where id = p_horario_id;
  if not found or v_h.prof_id <> p_solicitante_id then
    raise exception 'Aula não encontrada ou não pertence ao professor solicitante.';
  end if;
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
    data_ausencia, dia_semana, inicio, fim, turma_codigo, turma, disciplina, status, criada_por_id)
  values (v_h.semestre_id, p_solicitante_id, p_substituto_id, v_h.id,
    p_data_ausencia, v_h.dia, v_h.inicio, v_h.fim, v_h.turma_codigo, v_h.turma, v_h.disciplina, 'proposta',
    case when v_gestor.id = p_solicitante_id then null else v_gestor.id end)
  returning * into v_row;
  return v_row;
end;
$$;
