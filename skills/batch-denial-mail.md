---
name: batch-denial-mail
description: >
  Ejecuta tareas de tipo batch-denial-mail usando el CLI de ark.
  Recolecta glosas de las facturas referenciadas, genera el Excel de devoluciones,
  lo sube a storage y lo envía por correo al destinatario configurado en el contexto.
  El agente no razona sobre el contenido — solo ejecuta el script y reporta.
  Usar cuando task_type === "batch-denial-mail".
version: "1.2"
compatibility: Requiere ark CLI instalado y configurado con api-key y url válidos.
---

# Skill: batch-denial-mail

Ejecuta tareas `batch-denial-mail` delegando al script `ark audit send-denial-mail`.
El agente no interpreta los datos de la factura ni toma decisiones sobre el contenido.
Solo ejecuta, reporta y cierra.

---

## Precondiciones

```bash
ark auth status
```

Debe retornar `"authenticated": true`. Si no, configurar primero:

```bash
ark config set url <api-url>
ark config set api-key <key>
```

---

## Flujo completo

### Paso 1 — Generar run ID e identificar la tarea

```bash
TASK_RUN_ID=$(ark gen-uuid)
TASK_ID=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].id')
TASK_TYPE=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].task_type')
```

Verificar que `TASK_TYPE` sea `batch-denial-mail`. Si no, usar el skill general `tasks-ark-execution`.

### Paso 2 — Reclamar la tarea

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

Verificar que `.data.status` sea `"in_progress"` antes de continuar.

### Paso 3 — Ejecutar el script

```bash
ARK_SCRIPTS_DIR=/ruta/al/repo/tasks-ark-cli/scripts ark audit send-denial-mail "$TASK_ID"
```

El script maneja internamente:
1. Lee el `context` de la tarea batch (prestador, task_ids, email_destino).
2. Para cada `task_id` en `context.task_ids`, descarga el output `report` desde Supabase Storage.
3. Filtra hallazgos con `hallazgo === "glosa"`.
4. Genera un Excel con dos hojas: `Devoluciones` y `Resumen`.
5. Sube el Excel a Supabase Storage y lo registra como output `artifact` de la tarea.
6. Actualiza el contexto: `excel_filename`, `total_items_glosados`.

El script **no envía el correo**. Eso es responsabilidad del agente (paso 4).

Si el script termina con exit `0`, el stdout incluye:

```json
{
  "ok": true,
  "batch_task_id": "...",
  "excel_filename": "devoluciones_<nit>_<fecha>.xlsx",
  "storage_path": "storage://task-outputs/denial-mails/..." | "local://<filename>",
  "total_items_glosados": N,
  "email_destino": "...",
  "prestador_nombre": "..."
}
```

### Paso 4 — Enviar el correo con GOG

**4a. Obtener el Excel para adjuntar**

Si `storage_path` empieza con `storage://`:

```bash
OUTPUT_ID=$(ark tasks outputs list "$TASK_ID" | jq -r '.data[] | select(.label=="artifact") | .id')
SIGNED_URL=$(ark tasks documents url "$TASK_ID" output "$OUTPUT_ID" | jq -r '.data.url')
EXCEL_PATH="/tmp/${EXCEL_FILENAME}"
curl -s -o "$EXCEL_PATH" "$SIGNED_URL"
```

Si `storage_path` empieza con `local://` (Supabase no configurado), el archivo ya existe en `/tmp/<excel_filename>`:

```bash
EXCEL_PATH="/tmp/${EXCEL_FILENAME}"
```

**4b. Enviar el correo**

```bash
FECHA=$(date '+%d/%m/%Y')
gog -a salmona@arkangel.ai send \
  --to "$EMAIL_DESTINO" \
  --subject "[Devolución] ${PRESTADOR_NOMBRE} — ${FECHA} — ${N} ítems objetados" \
  --attach "$EXCEL_PATH" \
  --body "Estimado equipo,

Por medio del presente comunicado, Arkangel AI — Auditoría Médica notifica formalmente la devolución de los ítems de la facturación presentada por ${PRESTADOR_NOMBRE}.

Se adjunta el archivo Excel con el detalle de los ${N} ítems objetados, incluyendo número de factura, código CUPS, valor facturado, valor objetado y causal de glosa.

De conformidad con la Resolución 3047 de 2008, el prestador dispone de 15 días hábiles a partir de la recepción de este comunicado para presentar la respuesta correspondiente.

Cordialmente,
Salmona — Auditoría Médica
Arkangel AI"
```

**4c. Actualizar contexto de la tarea batch**

```bash
SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ark tasks context-set "$TASK_ID" --set reply_sent=true --set sent_at="$SENT_AT"
```

### Paso 5 — Actualizar las tareas eps_audit individuales

Propagar `reply_sent` a cada tarea referenciada en `context.task_ids`:

```bash
BATCH_CTX=$(ark tasks get "$TASK_ID" | jq -c '.data.context')
SENT_AT=$(echo "$BATCH_CTX" | jq -r '.sent_at // empty')
[[ -z "$SENT_AT" ]] && SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for individual_id in $(echo "$BATCH_CTX" | jq -r '.task_ids[]'); do
  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:ctx:${individual_id}"
  ark tasks context-set "$individual_id" \
    --set reply_sent=true --set reply_sent_at="$SENT_AT" || true
done
```

Si algún PATCH individual falla, registrarlo como comentario `note` en la tarea batch y continuar — no bloquear por un fallo parcial.

### Paso 6 — Completar la tarea

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
ark tasks complete "$TASK_ID" --confidence 1.0
```

**Si exit code `1` (error recuperable):**

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:block"
ark tasks block "$TASK_ID" --reason "<pegar stderr del script>"
```

**Si exit code `2` (argumento inválido / tarea no encontrada):**

Reportar el error al humano. No reintentar sin corrección del contexto.

---

## Manejo de errores del script send-denial-mail

| Error común | Causa probable | Acción |
|---|---|---|
| `invalid_context` | `context.task_ids` vacío o ausente | Bloquear — el humano debe corregir el contexto |
| `not_found` | Una tarea en `task_ids` no existe | Bloquear — reportar qué ID no se encontró |
| `unauthenticated` | Sin API key configurada | Configurar con `ark config set api-key <key>` |
| Supabase no configurado | `SUPABASE_URL` o `SUPABASE_SERVICE_KEY` ausentes | `storage_path` será `local://` — el Excel existe en `/tmp/` — no bloquear |
| GOG falla al adjuntar | Ruta del Excel incorrecta o vacía | Verificar que el archivo exista en la ruta antes de enviar |
| Contexto sobreescrito | Usar `ark tasks context` con `--data` reemplaza todo | Usar siempre `ark tasks context-set --set key=value` para merges seguros |

---

## Invariante

El LLM **no interpreta** el contenido del Excel.
No toma decisiones sobre los datos de las facturas.
Ejecuta el script, envía el correo con GOG y reporta.
