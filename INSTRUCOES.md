# SisDist — Instruções de Instalação

## Visão Geral

- **Frontend**: `index.html` hospedado no GitHub Pages  
- **Backend**: Supabase (banco de dados PostgreSQL + autenticação por magic link)

Nenhum servidor próprio é necessário.

---

## Passo 1 — Criar o projeto no Supabase

1. Acesse [supabase.com](https://supabase.com) e crie uma conta gratuita.
2. Clique em **New project** e preencha nome e senha do banco.
3. Aguarde o projeto iniciar (~2 minutos).

---

## Passo 2 — Executar o schema SQL

1. No painel do Supabase, acesse **SQL Editor → New query**.
2. Cole o conteúdo do arquivo `supabase_setup.sql` e clique em **Run**.
3. Verifique se aparece "Success" sem erros.

---

## Passo 3 — Obter as credenciais

1. Acesse **Project Settings → API**.
2. Copie:
   - **Project URL** (algo como `https://xyzabc.supabase.co`)
   - **anon/public key** (começa com `eyJ...`)

---

## Passo 4 — Configurar o index.html

Abra o `index.html` e substitua as linhas:

```javascript
const SUPABASE_URL  = 'https://SEU_PROJETO.supabase.co';
const SUPABASE_ANON = 'sua_anon_key_aqui';
```

pelas suas credenciais reais.

---

## Passo 5 — Publicar no GitHub Pages

1. Crie um repositório no GitHub (pode ser privado).
2. Faça upload do `index.html` (e este README se quiser).
3. Acesse **Settings → Pages → Source → main / root**.
4. O site estará disponível em `https://seu-usuario.github.io/nome-do-repo/`.

---

## Passo 6 — Configurar a URL no Supabase Auth

Para o magic link funcionar corretamente:

1. No Supabase, acesse **Authentication → URL Configuration**.
2. Em **Site URL**, coloque a URL do seu GitHub Pages (ex: `https://seu-usuario.github.io/sisdist/`).
3. Em **Redirect URLs**, adicione a mesma URL.
4. Clique em **Save**.

---

## Passo 7 — Primeiro acesso (gestor)

1. Acesse o site pelo GitHub Pages.
2. Digite o **seu e-mail** e clique em **Enviar link de acesso**.
3. Clique no link no e-mail recebido.
4. O sistema detecta que nenhum gestor existe e exibe a tela de configuração inicial.
5. Preencha seu nome, instituição e semestre. Clique em **Criar configuração inicial**.
6. Você entra automaticamente como gestor.

---

## Fluxo de uso

### Gestor

1. **Áreas & Profs**: Crie áreas (ex: "Matemática") e adicione professores com nome, e-mail, área e limites de carga horária.
2. **Disciplinas**: Adicione as disciplinas de cada área com CH semanal e turno (diurno/noturno).
3. **Faixas Horárias**: Clique em "Carregar Padrão" (Segunda–Sexta, 6 períodos) ou adicione manualmente.
4. Informe os professores para acessarem o site com o e-mail cadastrado.
5. Acompanhe o preenchimento em **Status**.
6. Quando todos confirmarem, execute **Módulo 1** (distribuição de disciplinas).
7. Execute **Módulo 2** (distribuição de horários).

### Professor

1. Acessa o site, digita o e-mail institucional → recebe link automático.
2. Clica no link → entra direto.
3. Avalia cada disciplina de sua área de 0 a 5 (salvo automaticamente).
4. Avalia cada faixa horária de 0 a 5 (salvo automaticamente).
5. Confirma o preenchimento.

---

## Escala de preferências

| Nota | Significado |
|------|-------------|
| 0    | Não quero / Não posso |
| 1–2  | Prefiro evitar |
| 3    | Neutro |
| 4–5  | Prefiro |

---

## Modelos Matemáticos

### Módulo 1 — Distribuição de Disciplinas

**Maximizar:** Σᵢⱼ cᵢⱼ · xᵢⱼ

**Sujeito a:**  
- Σᵢ xᵢⱼ = 1 ∀j (cada disciplina tem exatamente 1 professor)  
- CHmín_i ≤ Σⱼ hⱼ·xᵢⱼ ≤ CHmáx_i ∀i (limites de carga horária)  
- xᵢⱼ ∈ {0,1}

Resolvido por **Branch-and-Bound** rodando no navegador do gestor (com solução greedy como lower bound). Limite de 14 segundos com melhor solução encontrada.

### Módulo 2 — Distribuição de Horários

**Maximizar:** Σ eₚₕ · xₜₕₚ

**Sujeito a:**  
- Σₕ xₜₕₚ = CHₚₜ/faixa ∀p,t (carga horária cumprida)  
- Σₜ xₜₕₚ ≤ 1 ∀h,p (professor não ministra em dois lugares ao mesmo tempo)  
- Σₚ xₜₕₚ ≤ 1 ∀h,t (cada turma tem no máximo um professor por faixa)  
- xₜₕₚ ∈ {0,1}

Turno da disciplina (diurno/noturno) filtra as faixas elegíveis. Resolvido por greedy de preferência por professor.
