// Edge Function: busca a grade de horários direto do site oficial do IFTM
// Campus Ituiutaba (https://www.iftmitb.com.br/horarios/professores/),
// parseia o HTML e importa via a RPC gestor_importar_grade_por_nome já
// existente (mesma função usada pela importação manual de JSON por nome).
//
// Existe porque o navegador NÃO consegue buscar essa página diretamente
// (o site não libera CORS) — o fetch precisa rodar aqui, fora do browser.
// Repassa o JWT de quem chamou para a RPC, então is_gestor() e o escopo
// por instituição continuam sendo aplicados normalmente (nenhuma regra
// de segurança nova, nenhuma mudança de schema).
import { createClient } from "npm:@supabase/supabase-js@2";
import * as cheerio from "npm:cheerio@1";

const DIAS = ["Segunda", "Terça", "Quarta", "Quinta", "Sexta"];
const FONTE_URL = "https://www.iftmitb.com.br/horarios/professores/";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function toMin(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}
function toHHMM(min: number): string {
  const h = String(Math.floor(min / 60)).padStart(2, "0");
  const m = String(min % 60).padStart(2, "0");
  return `${h}:${m}`;
}
// Remove sufixos como "*" ou "'" no fim do nome — o site do IFTM às vezes
// marca a mesma pessoa duas vezes com um símbolo extra (ex.: "Romeu*").
function normalizarNome(nome: string): string {
  return nome.replace(/[*'’]+\s*$/, "").trim();
}

interface SlotBruto {
  professor: string; dia: string; ini: number; fim: number;
  turma_codigo: string; turma: string; disciplina: string; sala: string;
}

function parseGrade(html: string) {
  const $ = cheerio.load(html);
  const brutos: SlotBruto[] = [];

  $(".prof-container").each((_i, container) => {
    const professor = normalizarNome($(container).attr("data-prof-nome")?.trim() || "");
    if (!professor) return;
    $(container).find("table tbody tr").each((_j, row) => {
      const cells = $(row).find("td");
      if (cells.length < 6) return;
      const timeText = $(cells[0]).text().trim();
      const m = timeText.match(/(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})/);
      if (!m) return;
      const ini = toMin(m[1]);
      const fim = toMin(m[2]);
      DIAS.forEach((dia, i) => {
        const cell = $(cells[i + 1]);
        const content = cell.find(".cell-content");
        if (!content.length) return;
        const turmaBadge = content.find(".badge-turma");
        const salaBadge = content.find(".badge-sala");
        const discBadge = content.find(".badge").not(".badge-turma").not(".badge-sala");
        const turma_codigo = turmaBadge.text().trim();
        const turma = (turmaBadge.attr("title") || "").replace(/^Turma:\s*/, "").trim();
        const disciplina = discBadge.text().trim();
        const sala = salaBadge.text().trim();
        if (!turma_codigo || !disciplina) return;
        brutos.push({ professor, dia, ini, fim, turma_codigo, turma, disciplina, sala });
      });
    });
  });

  // Agrupa por (professor, dia) e mescla períodos consecutivos com o mesmo
  // conteúdo quando o intervalo entre eles é <=30min (cobre o intervalo
  // oficial de 20min dentro do mesmo turno; não mescla através do
  // almoço/janta, que são intervalos bem maiores).
  const porGrupo = new Map<string, SlotBruto[]>();
  for (const b of brutos) {
    const key = b.professor + "|" + b.dia;
    if (!porGrupo.has(key)) porGrupo.set(key, []);
    porGrupo.get(key)!.push(b);
  }

  type Bloco = { professor: string; dia: string; ini: number; fim: number; sig: string; turma_codigo: string; turma: string; disciplina: string; sala: string };
  const finais: Bloco[] = [];
  for (const [, slots] of porGrupo) {
    slots.sort((a, b) => a.ini - b.ini);
    let atual: Bloco | null = null;
    for (const s of slots) {
      const sig = s.turma_codigo + "|" + s.disciplina + "|" + s.sala;
      if (atual && atual.sig === sig && (s.ini - atual.fim) <= 30) {
        atual.fim = s.fim;
      } else {
        if (atual) finais.push(atual);
        atual = { professor: s.professor, dia: s.dia, ini: s.ini, fim: s.fim, sig, turma_codigo: s.turma_codigo, turma: s.turma, disciplina: s.disciplina, sala: s.sala };
      }
    }
    if (atual) finais.push(atual);
  }

  return finais.map((f) => ({
    nome: f.professor,
    dia: f.dia,
    inicio: toHHMM(f.ini),
    fim: toHHMM(f.fim),
    turma_codigo: f.turma_codigo,
    turma: f.turma,
    disciplina: f.disciplina,
    sala: f.sala,
  }));
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Não autenticado." }, 401);

    const { semestre_id } = await req.json();
    if (!semestre_id) return jsonResponse({ error: "semestre_id é obrigatório." }, 400);

    const resp = await fetch(FONTE_URL);
    if (!resp.ok) {
      return jsonResponse({ error: `Falha ao buscar a grade oficial (HTTP ${resp.status}).` }, 502);
    }
    const html = await resp.text();

    const itens = parseGrade(html);
    if (!itens.length) {
      return jsonResponse({ error: "Nenhum horário encontrado na página — o layout do site pode ter mudado." }, 502);
    }

    // Cliente com o JWT de quem chamou: a RPC decide permissão via
    // auth.uid() -> is_gestor()/inst, igual à importação manual.
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data, error } = await supabase.rpc("gestor_importar_grade_por_nome", {
      p_semestre_id: semestre_id,
      p_itens: itens,
    });
    if (error) return jsonResponse({ error: error.message }, 400);

    return jsonResponse({ ...data, fonte: FONTE_URL, buscados: itens.length });
  } catch (e) {
    return jsonResponse({ error: String((e as Error)?.message || e) }, 500);
  }
});
