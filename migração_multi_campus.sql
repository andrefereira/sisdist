-- ================================================================
-- SisDist — Migração: Suporte Multi-Campus
-- Execute no SQL Editor do Supabase Dashboard
-- (Database → SQL Editor → New query → Cole e execute)
-- ================================================================

-- 1. Adiciona coluna 'inst' na tabela professores
ALTER TABLE public.professores
  ADD COLUMN IF NOT EXISTS inst text DEFAULT '';

-- 2. Preenche 'inst' dos registros existentes a partir do semestre ativo
--    (garante que os dados atuais não fiquem sem inst)
UPDATE public.professores p
SET inst = (
  SELECT s.inst FROM public.semestres s
  ORDER BY s.created_at LIMIT 1
)
WHERE p.inst IS NULL OR p.inst = '';

-- 3. Substitui setup_initial_gestor:
--    - Remove restrição de gestor único global
--    - Permite múltiplos campi (um gestor por inst)
CREATE OR REPLACE FUNCTION public.setup_initial_gestor(
  p_nome      text,
  p_inst      text,
  p_semestre  text,
  p_hrs_faixa numeric DEFAULT 2
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  sem_id     uuid;
  user_email text;
BEGIN
  -- Bloqueia apenas se já existe gestor NESTA MESMA instituição
  IF EXISTS (
    SELECT 1 FROM public.professores
    WHERE is_gestor = true AND inst = p_inst
  ) THEN
    RAISE EXCEPTION 'Um gestor já está configurado para esta instituição. Entre em contato com o gestor atual.';
  END IF;

  -- Impede re-cadastro do mesmo usuário
  IF EXISTS (
    SELECT 1 FROM public.professores WHERE auth_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Este usuário já está cadastrado no sistema.';
  END IF;

  SELECT email INTO user_email FROM auth.users WHERE id = auth.uid();

  INSERT INTO public.semestres (nome, inst, ativo, hrs_por_faixa)
  VALUES (p_semestre, p_inst, true, p_hrs_faixa)
  RETURNING id INTO sem_id;

  INSERT INTO public.professores (auth_id, nome, email, is_gestor, ch_min, ch_max, inst)
  VALUES (auth.uid(), p_nome, user_email, true, 0, 40, p_inst);

  RETURN json_build_object('ok', true, 'semestre_id', sem_id);
END;
$$;
