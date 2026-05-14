#!/usr/bin/env bun
/**
 * send-preventiva-mail.ts — Genera el Excel de radicación preventiva y lo sube a storage.
 *
 * Uso: bun run scripts/send-preventiva-mail.ts <batch_task_id>
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
import { readFileSync, writeFileSync } from "fs";
import { homedir, tmpdir } from "os";
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
  console.error(`[send-preventiva-mail] ${msg}`);
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
  pagador_nombre: string;
  pagador_nit: string;
  email_destino: string;
  solicitado_por?: string;
  reply_sent?: boolean;
  sent_at?: string | null;
  excel_filename?: string | null;
  total_facturas?: number | null;
}

interface FacturaRow {
  num_factura: string;
  pagador: string;
  fecha_ingreso: string;
  fecha_egreso: string;
  diagnostico: string;
  valor_facturado: number;
  concepto: string;
  regimen: string;
}

interface PreventivaOutput {
  factura: {
    num_factura: string;
    pagador?: string;
    pagador_nombre?: string;
    paciente_alias?: string;
    diagnostico_principal: string;
    fechas?: { ingreso: string; egreso: string };
    periodo_prestacion?: { inicio: string; fin: string };
    concepto_final?: string;
    regimen?: string;
    plan_afiliado?: string;
  };
  resumen: {
    total_facturado: number;
    total_aprobado?: number;
    concepto_final?: string;
  };
  veredicto?: {
    concepto_final?: string;
  };
}

// ─── Helper: descargar output desde Supabase Storage ──────────────────────────
async function fetchOutputJson(taskId: string, outputId: string): Promise<PreventivaOutput | null> {
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
    return (await res.json()) as PreventivaOutput;
  } catch (err) {
    log(`[warn] error fetching output ${outputId}: ${(err as Error).message}`);
    return null;
  }
}

// ─── Types para el context individual ─────────────────────────────────────────
interface TaskContext {
  paciente_alias?: string | null;
  paciente_documento_alias?: string | null;
  fecha_ingreso?: string | null;
  fecha_egreso?: string | null;
  pagador_nombre?: string | null;
  pagador_nit?: string | null;
  num_factura?: string | null;
  valor_total?: number | null;
}

// ─── Seleccionar el mejor output report disponible ────────────────────────────
// Prefiere json con schema_version > json > file. Entre el mismo tipo, toma el
// primero de la lista (la API devuelve ordenado por versión desc).
function selectBestReport(
  outputs: Array<{ id: string; output_type: string; label: string; data: PreventivaOutput | null }>
): { id: string; output_type: string; label: string; data: PreventivaOutput | null } | undefined {
  const reports = outputs.filter(
    (o) => (o.output_type === "json" || o.output_type === "file") && o.label === "report"
  );
  return (
    reports.find((o) => o.output_type === "json" && (o.data as Record<string, unknown>)?.schema_version) ??
    reports.find((o) => o.output_type === "json") ??
    reports.find((o) => o.output_type === "file")
  );
}

// ─── Fase 1 & 2: Leer tarea batch y recolectar filas ─────────────────────────
async function collectFacturas(batchTaskId: string): Promise<{
  context: BatchContext;
  facturas: FacturaRow[];
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

  const facturas: FacturaRow[] = [];

  for (const taskId of context.task_ids) {
    // Leer task (context como fallback) y outputs en paralelo
    const [taskResponse, outputsResponse] = await Promise.all([
      apiRequest("GET", `/api/tasks/${taskId}`),
      apiRequest("GET", `/api/tasks/${taskId}/outputs`),
    ]);

    const taskCtx = ((taskResponse.data as { context: TaskContext }).context) ?? {} as TaskContext;

    const outputs = (outputsResponse.data ?? []) as Array<{
      id: string;
      output_type: string;
      label: string;
      data: PreventivaOutput | null;
    }>;

    const reportOutput = selectBestReport(outputs);

    if (!reportOutput) {
      log(`[warn] task ${taskId} has no report output — skipping`);
      continue;
    }

    const report: PreventivaOutput | null =
      reportOutput.data ?? (await fetchOutputJson(taskId, reportOutput.id));

    if (!report) {
      log(`[warn] task ${taskId} report could not be loaded — skipping`);
      continue;
    }

    const { factura, resumen } = report;

    // Fechas: output → context individual
    const fechaIngreso =
      factura.periodo_prestacion?.inicio ??
      factura.fechas?.ingreso ??
      taskCtx.fecha_ingreso ??
      "";

    const fechaEgreso =
      factura.periodo_prestacion?.fin ??
      factura.fechas?.egreso ??
      taskCtx.fecha_egreso ??
      "";

    // Pagador: output → context individual → context batch
    const pagador =
      factura.pagador_nombre ??
      factura.pagador ??
      taskCtx.pagador_nombre ??
      context.pagador_nombre ??
      "";

    const concepto =
      report.veredicto?.concepto_final ??
      factura.concepto_final ??
      resumen.concepto_final ??
      "";

    const regimen = factura.regimen ?? factura.plan_afiliado ?? "";

    facturas.push({
      num_factura:     factura.num_factura,
      pagador,
      fecha_ingreso:   fechaIngreso,
      fecha_egreso:    fechaEgreso,
      diagnostico:     factura.diagnostico_principal,
      valor_facturado: resumen.total_facturado,
      concepto,
      regimen,
    });
  }

  return { context, facturas };
}

// ─── Fase 3: Generar Excel ─────────────────────────────────────────────────────
async function generateExcel(
  facturas: FacturaRow[],
  pagadorNit: string,
  fecha: string
): Promise<{ buffer: Buffer; filename: string }> {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Arkangel AI — Auditoría Médica";
  workbook.created = new Date();

  // ── Paleta azul ──────────────────────────────────────────────────────────────
  const BLUE_DARK   = "1F4E79"; // header fill
  const BLUE_MID    = "2E75B6"; // border accent
  const BLUE_LIGHT  = "DEEAF1"; // fila par
  const WHITE       = "FFFFFF";

  const FONT_BASE   = { name: "Calibri", size: 11, color: { theme: 1 } } as const;
  const FONT_HEADER = { name: "Calibri", size: 11, bold: true, color: { argb: `FF${WHITE}` } } as const;
  const NUM_FMT     = "#,##0";

  const FILL_HEADER: ExcelJS.Fill = {
    type: "pattern", pattern: "solid", fgColor: { argb: `FF${BLUE_DARK}` },
  };
  const FILL_ROW_EVEN: ExcelJS.Fill = {
    type: "pattern", pattern: "solid", fgColor: { argb: `FF${BLUE_LIGHT}` },
  };
  const BORDER_CELL: Partial<ExcelJS.Borders> = {
    top:    { style: "thin", color: { argb: `FF${BLUE_MID}` } },
    bottom: { style: "thin", color: { argb: `FF${BLUE_MID}` } },
    left:   { style: "thin", color: { argb: `FF${BLUE_MID}` } },
    right:  { style: "thin", color: { argb: `FF${BLUE_MID}` } },
  };

  // ── Hoja principal ───────────────────────────────────────────────────────────
  const sheet = workbook.addWorksheet("Facturas Radicadas");
  sheet.views = [{ state: "frozen", ySplit: 1, topLeftCell: "A2" }];

  sheet.columns = [
    { header: "NUM_FACTURA",     key: "num_factura",     width: 22    },
    { header: "PAGADOR",         key: "pagador",         width: 28    },
    { header: "FECHA_INGRESO",   key: "fecha_ingreso",   width: 16    },
    { header: "FECHA_EGRESO",    key: "fecha_egreso",    width: 16    },
    { header: "DIAGNOSTICO",     key: "diagnostico",     width: 43    },
    { header: "VALOR_FACTURADO", key: "valor_facturado", width: 20    },
    { header: "CONCEPTO",        key: "concepto",        width: 24    },
    { header: "REGIMEN",         key: "regimen",         width: 16    },
  ];

  const headerRow = sheet.getRow(1);
  headerRow.height = 20;
  headerRow.eachCell((cell) => {
    cell.font      = FONT_HEADER;
    cell.fill      = FILL_HEADER;
    cell.border    = BORDER_CELL;
    cell.alignment = { horizontal: "center", vertical: "middle", wrapText: false };
  });

  facturas.forEach((row, idx) => {
    const r = sheet.addRow({
      num_factura:     row.num_factura,
      pagador:         row.pagador,
      fecha_ingreso:   row.fecha_ingreso,
      fecha_egreso:    row.fecha_egreso,
      diagnostico:     row.diagnostico,
      valor_facturado: row.valor_facturado,
      concepto:        row.concepto,
      regimen:         row.regimen,
    });
    r.font = FONT_BASE;
    r.border = BORDER_CELL;
    if (idx % 2 === 1) r.fill = FILL_ROW_EVEN;
    r.getCell("fecha_ingreso").alignment   = { horizontal: "center" };
    r.getCell("fecha_egreso").alignment    = { horizontal: "center" };
    r.getCell("valor_facturado").alignment = { horizontal: "right" };
  });

  sheet.getColumn("valor_facturado").numFmt = NUM_FMT;

  // ── Footer: fila de total ────────────────────────────────────────────────────
  const FILL_FOOTER: ExcelJS.Fill = {
    type: "pattern", pattern: "solid", fgColor: { argb: `FF${BLUE_DARK}` },
  };
  const FONT_FOOTER = { name: "Calibri", size: 11, bold: true, color: { argb: `FF${WHITE}` } } as const;
  const BORDER_FOOTER: Partial<ExcelJS.Borders> = {
    top:    { style: "medium", color: { argb: `FF${BLUE_MID}` } },
    bottom: { style: "medium", color: { argb: `FF${BLUE_MID}` } },
    left:   { style: "thin",   color: { argb: `FF${BLUE_MID}` } },
    right:  { style: "thin",   color: { argb: `FF${BLUE_MID}` } },
  };

  const totalFacturado = facturas.reduce((sum, r) => sum + r.valor_facturado, 0);
  const footerRow = sheet.addRow({
    num_factura:     "TOTAL",
    valor_facturado: totalFacturado,
  });
  footerRow.height = 20;
  footerRow.eachCell({ includeEmpty: true }, (cell) => {
    cell.font   = FONT_FOOTER;
    cell.fill   = FILL_FOOTER;
    cell.border = BORDER_FOOTER;
  });
  footerRow.getCell("num_factura").alignment     = { horizontal: "center", vertical: "middle" };
  footerRow.getCell("valor_facturado").alignment = { horizontal: "right",  vertical: "middle" };
  footerRow.getCell("valor_facturado").numFmt    = NUM_FMT;

  // ── Hoja de resumen ──────────────────────────────────────────────────────────
  const summary = workbook.addWorksheet("Resumen");
  summary.views = [{ state: "frozen", ySplit: 1, topLeftCell: "A2" }];

  summary.columns = [{ width: 28 }, { width: 22 }];

  const summaryHeader = summary.addRow(["Campo", "Valor"]);
  summaryHeader.height = 20;
  summaryHeader.eachCell((cell) => {
    cell.font      = FONT_HEADER;
    cell.fill      = FILL_HEADER;
    cell.border    = BORDER_CELL;
    cell.alignment = { horizontal: "center", vertical: "middle" };
  });

  const summaryRows = [
    ["Pagador NIT",         pagadorNit],
    ["Total facturado",     totalFacturado],
    ["Número de facturas",  facturas.length],
  ];

  summaryRows.forEach(([campo, valor], idx) => {
    const r = summary.addRow([campo, valor]);
    r.font   = FONT_BASE;
    r.border = BORDER_CELL;
    if (idx % 2 === 1) r.fill = FILL_ROW_EVEN;
  });

  summary.getColumn(2).numFmt = NUM_FMT;

  const filename = `Radicacion_${pagadorNit}_${fecha}.xlsx`;
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

  const storagePath = `preventiva-mails/${filename}`;
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

// ─── Fase 4b: Registrar output + actualizar contexto ─────────────────────────
async function submitOutput(
  batchTaskId: string,
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
          message: "Usage: send-preventiva-mail.ts <batch_task_id>",
        },
      })
    );
    process.exit(EXIT_BAD_ARG);
  }

  try {
    log(`collecting preventiva data for batch task ${batchTaskId}`);
    const { context, facturas } = await collectFacturas(batchTaskId);

    if (facturas.length === 0) {
      log("no facturas found in any task — exiting without generating Excel");
      console.log(JSON.stringify({ ok: true, batch_task_id: batchTaskId, total_facturas: 0 }));
      process.exit(EXIT_SUCCESS);
    }

    // Fecha en zona America/Bogota
    const fecha = new Date()
      .toLocaleDateString("en-CA", { timeZone: "America/Bogota" })
      .replace(/-/g, "");

    log(`generating Excel with ${facturas.length} facturas`);
    const { buffer, filename } = await generateExcel(facturas, context.pagador_nit, fecha);

    const localPath = path.join(tmpdir(), filename);
    writeFileSync(localPath, buffer);
    log(`Excel saved to ${localPath}`);

    log("uploading Excel to Supabase Storage");
    const storagePath = await uploadToStorage(buffer, filename);

    log("submitting file output");
    await submitOutput(batchTaskId, storagePath, buffer);

    log("updating batch task context");
    await updateBatchContext(batchTaskId, {
      excel_filename: filename,
      total_facturas: facturas.length,
    });

    console.log(
      JSON.stringify({
        ok: true,
        batch_task_id: batchTaskId,
        excel_filename: filename,
        storage_path: storagePath,
        local_path: localPath,
        total_facturas: facturas.length,
        email_destino: context.email_destino,
        pagador_nombre: context.pagador_nombre,
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
