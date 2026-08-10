---
name: hospital-preventiva-batch-mail
description: >
  Ejecuta tareas de tipo hospital_preventiva_batch_mail usando el CLI de ark.
  Recolecta outputs de las facturas preventiva referenciadas, genera el Excel de
  radicación, lo sube a storage y lo envía por correo al destinatario configurado
  en el contexto. El agente no razona sobre el contenido — solo ejecuta el script
  y reporta. Usar cuando task_type === "hospital_preventiva_batch_mail".
version: "1.0"
compatibility: Requiere ark CLI instalado y configurado con api-key y url válidos.
---

# Skill: hospital-preventiva-batch-mail

Ejecuta tareas `hospital_preventiva_batch_mail` delegando al script `ark audit send-preventiva-mail`.
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

Verificar que `TASK_TYPE` sea `hospital_preventiva_batch_mail`. Si no, usar el skill general `tasks-ark-execution`.

### Paso 2 — Reclamar la tarea

```bash
export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"
```

Verificar que `.data.status` sea `"in_progress"` antes de continuar.

### Paso 3 — Ejecutar el script

```bash
ARK_SCRIPTS_DIR=/ruta/al/repo/tasks-ark-cli/scripts ark audit send-preventiva-mail "$TASK_ID"
```

El script maneja internamente:
1. Lee el `context` de la tarea batch (`pagador_nit`, `pagador_nombre`, `task_ids`, `email_destino`).
2. Para cada `task_id` en `context.task_ids`, descarga el output `report` desde Supabase Storage.
3. Extrae los campos de `factura` y `resumen` de cada `PreventivaOutput`.
4. Genera un Excel con una hoja `Facturas Radicadas` y 8 columnas.
5. Sube el Excel a Supabase Storage y lo registra como output `artifact` de la tarea.
6. Actualiza el contexto: `excel_filename`, `total_facturas`.

El script **no envía el correo**. Eso es responsabilidad del agente (paso 4).

Si el script termina con exit `0`, el stdout incluye:

```json
{
  "ok": true,
  "batch_task_id": "...",
  "excel_filename": "Radicacion_<nit>_<fecha>.xlsx",
  "storage_path": "storage://task-outputs/preventiva-mails/..." | "local://<filename>",
  "local_path": "/tmp/Radicacion_<nit>_<fecha>.xlsx",
  "total_facturas": N,
  "email_destino": "...",
  "pagador_nombre": "..."
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
  --subject "Radicación de facturas — ${PAGADOR_NOMBRE} — ${FECHA}" \
  --attach "$EXCEL_PATH" \
  --body "Estimado equipo,

Por medio del presente comunicado, Arkangel AI — Auditoría Médica remite el consolidado de facturas auditadas y aprobadas para radicación ante ${PAGADOR_NOMBRE}.

Se adjunta el archivo Excel con el detalle de las ${N} facturas, incluyendo número de factura, paciente, fechas de atención, diagnóstico, valor facturado y total aprobado.

Cordialmente,
Salmona — Auditoría Médica
Arkangel AI"
```

**4c. Actualizar contexto de la tarea batch**

```bash
SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ark tasks context-set "$TASK_ID" --set reply_sent=true --set sent_at="$SENT_AT"
```

### Paso 5 — Propagar reply_sent a las tareas preventiva individuales

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

Si algún `context-set` individual falla, registrarlo como comentario `note` en la tarea batch y continuar — no bloquear por un fallo parcial.

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

## Manejo de errores del script send-preventiva-mail

| Error común | Causa probable | Acción |
|---|---|---|
| `invalid_context` | `context.task_ids` vacío o ausente | Bloquear — el humano debe corregir el contexto |
| `not_found` | Una tarea en `task_ids` no existe | Bloquear — reportar qué ID no se encontró |
| `unauthenticated` | Sin API key configurada | Configurar con `ark config set api-key <key>` |
| Supabase no configurado | `SUPABASE_URL` o `SUPABASE_SERVICE_KEY` ausentes | `storage_path` será `local://` — el Excel existe en `/tmp/` — no bloquear |
| GOG falla al adjuntar | Ruta del Excel incorrecta o vacía | Verificar que el archivo exista en la ruta antes de enviar |

---

## Shell Script Harness

```bash
TASK_RUN_ID=$(ark gen-uuid)

TASK_ID=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].id')
TASK_TYPE=$(ark tasks list --status queued --limit 1 | jq -r '.data[0].task_type')

if [[ "$TASK_TYPE" != "hospital_preventiva_batch_mail" ]]; then
  echo '{"ok":false,"error":"task_type no es hospital_preventiva_batch_mail"}' >&2; exit 1
fi

export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:claim"
ark tasks claim "$TASK_ID"

STDERR_FILE=$(mktemp)
SCRIPT_OUT=$(mktemp)

if ARK_SCRIPTS_DIR=/ruta/al/repo/tasks-ark-cli/scripts \
   ark audit send-preventiva-mail "$TASK_ID" >"$SCRIPT_OUT" 2>"$STDERR_FILE"; then

  EXCEL_FILENAME=$(jq -r '.excel_filename' "$SCRIPT_OUT")
  STORAGE_PATH=$(jq -r '.storage_path' "$SCRIPT_OUT")
  EMAIL_DESTINO=$(jq -r '.email_destino' "$SCRIPT_OUT")
  PAGADOR_NOMBRE=$(jq -r '.pagador_nombre' "$SCRIPT_OUT")
  N=$(jq -r '.total_facturas' "$SCRIPT_OUT")

  # Obtener Excel
  if [[ "$STORAGE_PATH" == storage://* ]]; then
    OUTPUT_ID=$(ark tasks outputs list "$TASK_ID" | jq -r '.data[] | select(.label=="artifact") | .id')
    SIGNED_URL=$(ark tasks documents url "$TASK_ID" output "$OUTPUT_ID" | jq -r '.data.url')
    curl -s -o "/tmp/${EXCEL_FILENAME}" "$SIGNED_URL"
  fi

  FECHA=$(date '+%d/%m/%Y')
  gog -a salmona@arkangel.ai send \
    --to "$EMAIL_DESTINO" \
    --subject "Radicación de facturas — ${PAGADOR_NOMBRE} — ${FECHA}" \
    --attach "/tmp/${EXCEL_FILENAME}" \
    --body "Estimado equipo,

Por medio del presente comunicado, Arkangel AI — Auditoría Médica remite el consolidado de facturas auditadas y aprobadas para radicación ante ${PAGADOR_NOMBRE}.

Se adjunta el archivo Excel con el detalle de las ${N} facturas, incluyendo número de factura, paciente, fechas de atención, diagnóstico, valor facturado y total aprobado.

Cordialmente,
Salmona — Auditoría Médica
Arkangel AI"

  SENT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ark tasks context-set "$TASK_ID" --set reply_sent=true --set sent_at="$SENT_AT"

  # Propagar reply_sent a tareas individuales
  BATCH_CTX=$(ark tasks get "$TASK_ID" | jq -c '.data.context')
  PATCH_ERRORS=()
  for individual_id in $(echo "$BATCH_CTX" | jq -r '.task_ids[]'); do
    export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:ctx:${individual_id}"
    if ! ark tasks context-set "$individual_id" \
        --set reply_sent=true --set reply_sent_at="$SENT_AT" 2>/dev/null; then
      PATCH_ERRORS+=("$individual_id")
    fi
  done

  if [[ ${#PATCH_ERRORS[@]} -gt 0 ]]; then
    export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note:patch-errors"
    ark tasks comments post "$TASK_ID" --label note \
      --body "context-set reply_sent falló para las siguientes tareas: ${PATCH_ERRORS[*]}"
  fi

  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:complete"
  ark tasks complete "$TASK_ID" --confidence 1.0

else
  EXIT_CODE=$?
  STDERR_CONTENT=$(cat "$STDERR_FILE")
  FIRST_LINE=$(head -n1 "$STDERR_FILE")

  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:note"
  ark tasks comments post "$TASK_ID" --label note --body "$STDERR_CONTENT"

  export ARK_IDEMPOTENCY_KEY="${TASK_RUN_ID}:block"
  ark tasks block "$TASK_ID" \
    --reason "script send-preventiva-mail falló con exit code ${EXIT_CODE}: ${FIRST_LINE}"
fi

rm -f "$STDERR_FILE" "$SCRIPT_OUT"
```

---

## Invariante

El LLM **no interpreta** el contenido del Excel.
No toma decisiones sobre los datos de las facturas.
Ejecuta el script, envía el correo con GOG y reporta.
