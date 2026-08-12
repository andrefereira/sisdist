-- ================================================================
-- SisDist — Migração: Importação da Grade por Nome (aditiva)
-- Execute no SQL Editor do Supabase Dashboard, DEPOIS de migração_trocas.sql.
--
-- Motivo: a importação original (gestor_importar_grade) casa professor
-- por e-mail, mas nem sempre o gestor já tem a lista de e-mails reais
-- na hora de carregar a grade extraída dos PDFs da coordenação. Esta
-- função casa por NOME e, se o professor ainda não existir no SisDist,
-- cria um cadastro novo com um e-mail placeholder (nunca null/duplicado,
-- pois a coluna professores.email é obrigatória e única).
--
-- IMPORTANTE: um professor criado com e-mail placeholder só consegue
-- logar de verdade depois que alguém trocar esse e-mail pelo real dele
-- na aba "Áreas & Profs" — antes disso, o login por link mágico não vai
-- encontrar o cadastro (get_or_link_profile casa pelo e-mail de login).
-- ================================================================

create extension if not exists unaccent;

create or replace function public._slug_nome(p_nome text)
returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(unaccent(trim(p_nome))), '[^a-z0-9]+', '-', 'g'))
$$;

create or replace function public.gestor_importar_grade_por_nome(
  p_semestre_id uuid,
  p_itens jsonb   -- [{nome, dia, inicio, fim, turma_codigo, turma, disciplina, sala}]
) returns json
language plpgsql security definer as $$
declare
  item jsonb; v_prof_id uuid; v_my_inst text; v_count int := 0; v_criados int := 0;
  v_erros jsonb := '[]'::jsonb; v_nome text; v_email text;
begin
  if not public.is_gestor() then raise exception 'Acesso negado.'; end if;

  select inst into v_my_inst from public.professores where auth_id = auth.uid();
  if not exists (select 1 from public.semestres where id = p_semestre_id and inst = v_my_inst) then
    raise exception 'Semestre não pertence ao seu campus.';
  end if;

  delete from public.grade_aulas where semestre_id = p_semestre_id;

  for item in select * from jsonb_array_elements(p_itens) loop
    v_nome := trim(item->>'nome');
    if v_nome is null or v_nome = '' then
      v_erros := v_erros || jsonb_build_object('nome', item->>'nome', 'erro', 'nome vazio');
      continue;
    end if;
    if (item->>'dia') not in ('Segunda','Terça','Quarta','Quinta','Sexta','Sábado') then
      v_erros := v_erros || jsonb_build_object('nome', v_nome, 'erro', 'dia inválido: '||(item->>'dia'));
      continue;
    end if;

    select id into v_prof_id from public.professores
      where inst = v_my_inst and lower(trim(nome)) = lower(v_nome);

    if v_prof_id is null then
      v_email := public._slug_nome(v_nome) || '@pendente.sisdist.local';
      if exists (select 1 from public.professores where email = v_email) then
        v_email := public._slug_nome(v_nome) || '-' || substr(md5(random()::text),1,4) || '@pendente.sisdist.local';
      end if;
      insert into public.professores (nome, email, inst, is_gestor, ch_min, ch_max)
      values (v_nome, v_email, v_my_inst, false, 0, 40)
      returning id into v_prof_id;
      v_criados := v_criados + 1;
    end if;

    insert into public.grade_aulas (prof_id, semestre_id, dia, inicio, fim, turma_codigo, turma, disciplina, sala)
    values (
      v_prof_id, p_semestre_id, item->>'dia', (item->>'inicio')::time, (item->>'fim')::time,
      upper(trim(item->>'turma_codigo')), item->>'turma', item->>'disciplina', item->>'sala'
    );
    v_count := v_count + 1;
  end loop;

  return json_build_object('importados', v_count, 'professores_criados', v_criados, 'erros', v_erros);
end;
$$;
