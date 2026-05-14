#!/usr/bin/env bun
/**
 * send-denial-mail.ts — Genera y envía el reporte de devoluciones al prestador.
 *
 * Uso: bun run scripts/send-denial-mail.ts <batch_task_id>
 *
 * Variables de entorno requeridas:
 *   ARK_API_URL          URL base de la API (default: valor en ~/.config/ark/config)
 *   ARK_API_KEY          API key (default: valor en ~/.config/ark/config)
 *   SUPABASE_URL         URL del proyecto Supabase
 *   SUPABASE_SERVICE_KEY Service role key de Supabase
 *   SUPABASE_STORAGE_BUCKET  Bucket de almacenamiento (default: "task-outputs")
 *
 * Exit codes:
 *   0  Éxito
 *   1  Error recuperable (harness marca la tarea como blocked)
 *   2  Error de argumento / tarea no encontrada
 */

import ExcelJS from "exceljs";
import { readFileSync } from "fs";
import { homedir } from "os";
import path from "path";

// ─── Exit codes ────────────────────────────────────────────────────────────────
const EXIT_SUCCESS = 0;
const EXIT_ERROR = 1;
const EXIT_BAD_ARG = 2;

// ─── Config ────────────────────────────────────────────────────────────────────
function readArkConfig(): Record<string, string> {
  const configPath = path.join(homedir(), ".config", "ark", "config");
  try {
    const content = readFileSync(configPath, "utf-8");
    return Object.fromEntries(
      content
        .split("\n")
        .filter((line) => line.includes("="))
        .map((line) => {
          const idx = line.indexOf("=");
          return [line.slice(0, idx).trim(), line.slice(idx + 1).trim()];
        })
    );
  } catch {
    return {};
  }
}

const arkConfig = readArkConfig();

function getApiUrl(): string {
  return process.env.ARK_API_URL ?? arkConfig["url"] ?? "http://localhost:3000";
}

function getApiKey(): string {
  const key = process.env.ARK_API_KEY ?? arkConfig["api-key"] ?? "";
  if (!key) {
    fatal("unauthenticated", "No API key configured. Run: ark config set api-key <key>", EXIT_ERROR);
  }
  return key;
}

// ─── Logging ───────────────────────────────────────────────────────────────────
function log(msg: string): void {
  console.error(`[send-denial-mail] ${msg}`);
}

function fatal(code: string, message: string, exitCode: number = EXIT_ERROR): never {
  console.error(JSON.stringify({ ok: false, error: { code, message } }));
  process.exit(exitCode);
}

// ─── API client ────────────────────────────────────────────────────────────────
async function apiRequest(
  method: string,
  endpoint: string,
  body?: unknown
): Promise<Record<string, unknown>> {
  const url = `${getApiUrl()}${endpoint}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${getApiKey()}`,
      "Content-Type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  const data = (await res.json()) as Record<string, unknown>;

  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}: ${method} ${endpoint}`) as Error & {
      status: number;
      data: unknown;
    };
    err.status = res.status;
    err.data = data;
    throw err;
  }

  return data;
}

// ─── Types ─────────────────────────────────────────────────────────────────────
interface BatchContext {
  task_ids: string[];
  prestador_nombre: string;
  prestador_nit: string;
  email_destino: string;
  solicitado_por?: string;
  reply_sent?: boolean;
  sent_at?: string | null;
  excel_filename?: string | null;
  total_items_glosados?: number | null;
}

interface GlosaRow {
  num_factura: string;
  prestador: string;
  fecha_atencion: string;
  codigo_cups: string;
  descripcion: string;
  valor_facturado: number;
  valor_glosado: number;
  causal: string;
  capa: string;
  regla_aplicada: string;
}

interface Hallazgo {
  codigo_cups: string;
  descripcion: string;
  valor_facturado: number;
  valor_glosado: number;
  glosa_sugerida?: { causal_nombre: string };
  capa: string;
  regla_aplicada: string;
  hallazgo: string;
}

interface AuditReport {
  factura: {
    num_factura: string;
    prestador_nombre: string;
    fecha_atencion: string;
  };
  hallazgos: Hallazgo[];
}

// ─── Helper: descargar output desde Supabase Storage ──────────────────────────
async function fetchOutputJson(taskId: string, outputId: string): Promise<AuditReport | null> {
  try {
    const urlResponse = await apiRequest(
      "GET",
      `/api/tasks/${taskId}/documents/output/${outputId}/url`
    );
    const signedUrl = (urlResponse.data as { url: string }).url;
    const res = await fetch(signedUrl);
    if (!res.ok) {
      log(`[warn] failed to download output ${outputId} from storage: ${res.status}`);
      return null;
    }
    return (await res.json()) as AuditReport;
  } catch (err) {
    log(`[warn] error fetching output ${outputId}: ${(err as Error).message}`);
    return null;
  }
}

// ─── Fase 1 & 2: Leer tarea batch y recolectar glosas ─────────────────────────
async function collectGlosas(batchTaskId: string): Promise<{
  context: BatchContext;
  glosas: GlosaRow[];
}> {
  const batchResponse = await apiRequest("GET", `/api/tasks/${batchTaskId}`);
  const taskData = batchResponse.data as { context: BatchContext };
  const context = taskData.context;

  if (!Array.isArray(context?.task_ids) || context.task_ids.length === 0) {
    fatal(
      "invalid_context",
      `Batch task ${batchTaskId} does not have task_ids in context`,
      EXIT_BAD_ARG
    );
  }

  const glosas: GlosaRow[] = [];

  for (const taskId of context.task_ids) {
    const outputsResponse = await apiRequest("GET", `/api/tasks/${taskId}/outputs`);
    const outputs = (outputsResponse.data ?? []) as Array<{
      id: string;
      output_type: string;
      label: string;
      data: AuditReport | null;
    }>;

    const reportOutput = outputs.find(
      (o) => (o.output_type === "json" || o.output_type === "file") && o.label === "report"
    );

    if (!reportOutput) {
      log(`[warn] task ${taskId} has no report output — skipping`);
      continue;
    }

    const audit: AuditReport | null = reportOutput.data ?? await fetchOutputJson(taskId, reportOutput.id);
    if (!audit) {
      log(`[warn] task ${taskId} report could not be loaded — skipping`);
      continue;
    }

    for (const h of audit.hallazgos ?? []) {
      if (h.hallazgo === "glosa") {
        glosas.push({
          num_factura: audit.factura.num_factura,
          prestador: audit.factura.prestador_nombre,
          fecha_atencion: audit.factura.fecha_atencion,
          codigo_cups: h.codigo_cups,
          descripcion: h.descripcion,
          valor_facturado: h.valor_facturado,
          valor_glosado: h.valor_glosado,
          causal: h.glosa_sugerida?.causal_nombre ?? "",
          capa: h.capa,
          regla_aplicada: h.regla_aplicada,
        });
      }
    }
  }

  return { context, glosas };
}

// ─── Fase 3: Generar Excel ─────────────────────────────────────────────────────
async function generateExcel(
  glosas: GlosaRow[],
  prestadorNit: string,
  fecha: string
): Promise<{ buffer: Buffer; filename: string }> {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Arkangel AI — Auditoría Médica";
  workbook.created = new Date();

  // Hoja principal
  const sheet = workbook.addWorksheet("Devoluciones");

  const columns = [
    { header: "Nº Factura", key: "num_factura", width: 16 },
    { header: "Prestador", key: "prestador", width: 30 },
    { header: "Fecha atención", key: "fecha_atencion", width: 16 },
    { header: "Código CUPS", key: "codigo_cups", width: 14 },
    { header: "Descripción", key: "descripcion", width: 40 },
    { header: "Valor facturado", key: "valor_facturado", width: 18 },
    { header: "Valor objetado", key: "valor_glosado", width: 18 },
    { header: "Causal", key: "causal", width: 40 },
    { header: "Capa", key: "capa", width: 18 },
    { header: "Regla aplicada", key: "regla_aplicada", width: 30 },
  ];

  sheet.columns = columns;

  // Header styling
  sheet.getRow(1).font = { bold: true };
  sheet.getRow(1).fill = {
    type: "pattern",
    pattern: "solid",
    fgColor: { argb: "FFE8E8E8" },
  };

  for (const row of glosas) {
    sheet.addRow({
      num_factura: row.num_factura,
      prestador: row.prestador,
      fecha_atencion: row.fecha_atencion,
      codigo_cups: row.codigo_cups,
      descripcion: row.descripcion,
      valor_facturado: row.valor_facturado,
      valor_glosado: row.valor_glosado,
      causal: row.causal,
      capa: row.capa,
      regla_aplicada: row.regla_aplicada,
    });
  }

  // Formato de moneda para columnas de valor
  ["F", "G"].forEach((col) => {
    sheet.getColumn(col).numFmt = '#,##0.00';
  });

  // Hoja de resumen
  const summary = workbook.addWorksheet("Resumen");
  const totalFacturado = glosas.reduce((sum, r) => sum + r.valor_facturado, 0);
  const totalObjetado = glosas.reduce((sum, r) => sum + r.valor_glosado, 0);
  const tasaObjecion =
    totalFacturado > 0 ? ((totalObjetado / totalFacturado) * 100).toFixed(2) : "0.00";

  summary.columns = [{ width: 28 }, { width: 22 }];
  summary.addRow(["Campo", "Valor"]);
  summary.getRow(1).font = { bold: true };
  summary.getRow(1).fill = {
    type: "pattern",
    pattern: "solid",
    fgColor: { argb: "FFE8E8E8" },
  };
  summary.addRow(["Prestador NIT", prestadorNit]);
  summary.addRow(["Total facturado", totalFacturado]);
  summary.addRow(["Total objetado", totalObjetado]);
  summary.addRow(["Número de ítems glosados", glosas.length]);
  summary.addRow(["Tasa de objeción (%)", tasaObjecion]);
  summary.getColumn(2).numFmt = '#,##0.00';

  const filename = `devoluciones_${prestadorNit}_${fecha}.xlsx`;
  const rawBuffer = await workbook.xlsx.writeBuffer();
  const buffer = Buffer.from(rawBuffer);

  return { buffer, filename };
}

// ─── Fase 4: Subir Excel a Supabase Storage ───────────────────────────────────
async function uploadToStorage(buffer: Buffer, filename: string): Promise<string> {
  const supabaseUrl = process.env.SUPABASE_URL ?? "";
  const supabaseKey = process.env.SUPABASE_SERVICE_KEY ?? "";
  const bucket = process.env.SUPABASE_STORAGE_BUCKET ?? "task-outputs";

  if (!supabaseUrl || !supabaseKey) {
    log("[warn] SUPABASE_URL or SUPABASE_SERVICE_KEY not set — skipping storage upload");
    return `local://${filename}`;
  }

  const storagePath = `denial-mails/${filename}`;
  const uploadUrl = `${supabaseUrl}/storage/v1/object/${bucket}/${storagePath}`;

  const res = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${supabaseKey}`,
      "Content-Type":
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "x-upsert": "true",
    },
    body: buffer,
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Supabase Storage upload failed: ${res.status} ${body}`);
  }

  return `storage://${bucket}/${storagePath}`;
}

// ─── Fase 5b: Registrar output + actualizar contexto ──────────────────────────
async function submitOutput(
  batchTaskId: string,
  filename: string,
  storagePath: string,
  buffer: Buffer
): Promise<void> {
  await apiRequest("POST", `/api/tasks/${batchTaskId}/outputs`, {
    output_type: "file",
    label: "artifact",
    storage_path: storagePath,
    size_bytes: buffer.length,
  });
}

async function updateBatchContext(
  batchTaskId: string,
  update: Partial<BatchContext>
): Promise<void> {
  const taskResponse = await apiRequest("GET", `/api/tasks/${batchTaskId}`);
  const currentCtx = ((taskResponse.data as { context: BatchContext }).context) ?? {};
  await apiRequest("PATCH", `/api/tasks/${batchTaskId}`, {
    context: { ...currentCtx, ...update },
  });
}

// ─── Main ──────────────────────────────────────────────────────────────────────
async function main(): Promise<void> {
  const batchTaskId = process.argv[2];
  if (!batchTaskId) {
    console.error(
      JSON.stringify({
        ok: false,
        error: {
          code: "missing_argument",
          message: "Usage: send-denial-mail.ts <batch_task_id>",
        },
      })
    );
    process.exit(EXIT_BAD_ARG);
  }

  try {
    // Fases 1 & 2
    log(`collecting glosa data for batch task ${batchTaskId}`);
    const { context, glosas } = await collectGlosas(batchTaskId);

    if (glosas.length === 0) {
      log("no glosa items found in any task — exiting without sending");
      console.log(JSON.stringify({ ok: true, batch_task_id: batchTaskId, total_items_glosados: 0 }));
      process.exit(EXIT_SUCCESS);
    }

    const fecha = new Date().toISOString().slice(0, 10).replace(/-/g, "");

    // Fase 3
    log(`generating Excel with ${glosas.length} glosa items`);
    const { buffer, filename } = await generateExcel(
      glosas,
      context.prestador_nit,
      fecha
    );

    // Fase 4
    log("uploading Excel to Supabase Storage");
    const storagePath = await uploadToStorage(buffer, filename);

    log("submitting file output");
    await submitOutput(batchTaskId, filename, storagePath, buffer);

    log("updating batch task context");
    await updateBatchContext(batchTaskId, {
      excel_filename: filename,
      total_items_glosados: glosas.length,
    });

    console.log(
      JSON.stringify({
        ok: true,
        batch_task_id: batchTaskId,
        excel_filename: filename,
        storage_path: storagePath,
        total_items_glosados: glosas.length,
        email_destino: context.email_destino,
        prestador_nombre: context.prestador_nombre,
      })
    );

    process.exit(EXIT_SUCCESS);
  } catch (err: unknown) {
    const e = err as { status?: number; message?: string; exitCode?: number };
    const isNotFound = e?.status === 404;
    const isBadArg = e?.exitCode === EXIT_BAD_ARG;

    console.error(
      JSON.stringify({
        ok: false,
        error: {
          code: isNotFound ? "not_found" : "execution_error",
          message: e?.message ?? String(err),
        },
      })
    );

    process.exit(isNotFound || isBadArg ? EXIT_BAD_ARG : EXIT_ERROR);
  }
}

main();
