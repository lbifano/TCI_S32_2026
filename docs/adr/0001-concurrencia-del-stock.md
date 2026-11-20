# ADR 0001 — Concurrencia en el descuento de stock

- **Estado:** aceptada
- **Fecha:** 2026-11-20
- **Reglas involucradas:** RN-01 (descuento por uso), RN-05 (reserva), RN-08 (carga de compra), RN-10 (consumo de reserva)
- **Hueco del dominio que resuelve:** sección 7, hueco deliberado 2 (requisito explícito de M4)

## Contexto

La planta trabaja en tres turnos y varios empleados de mantenimiento escanean repuestos al mismo tiempo desde el celular. Si dos personas registran el uso de **la última unidad** casi en simultáneo, una implementación ingenua hace esto:

1. A lee `stock_fisico = 1`.
2. B lee `stock_fisico = 1`.
3. A valida `1 ≥ 1`, escribe `0` y confirma.
4. B valida `1 ≥ 1` con el dato viejo, escribe `0` y confirma.

Resultado: se registran **dos usos de una sola unidad**. El stock no queda negativo (las dos transacciones escriben `0`), pero la trazabilidad (RN-06) miente y la planta cree tener repuestos que no existen. Con reservas el problema es peor, porque el disponible es `físico − reservado` y un uso concurrente podría tomar unidades apartadas para un preventivo (RN-05).

El dominio exige que el stock físico nunca quede negativo, que lo reservado no se use en otra incidencia y que la decisión se documente.

## Opciones consideradas

### 1. Solo `CHECK` en la base

`CHECK (stock_fisico >= 0)` y `CHECK (stock_reservado <= stock_fisico)`, con un `UPDATE … SET stock_fisico = stock_fisico - :cantidad`.

- ✅ Garantía absoluta a nivel de datos y simple de implementar.
- ❌ Funciona solo si el descuento se hace como `UPDATE` relativo. El servicio lee, valida y después escribe, así que el caso de arriba no viola ningún `CHECK`: las dos transacciones escriben `0`.
- ❌ La violación se ve como un error de integridad genérico y no como el mensaje de negocio "stock insuficiente, podés generar un pedido de compra" (RN-03).

### 2. Bloqueo pesimista: `SELECT … FOR UPDATE`

El servicio lee el repuesto bloqueando su fila hasta el `COMMIT`. Una segunda transacción sobre el **mismo** repuesto espera y después lee el valor ya actualizado.

- ✅ Serializa solo las operaciones sobre el mismo repuesto: los usos de repuestos distintos siguen en paralelo.
- ✅ La validación de negocio corre con datos frescos y devuelve el error correcto (`409` con el mensaje de RN-03).
- ✅ No hace falta reintentar: la segunda transacción espera unos milisegundos.
- ❌ Si muchas transacciones esperan la misma fila pueden encolarse. Con el volumen de una planta (decenas de usos por turno) eso no es un riesgo.
- ❌ Si una operación bloquea varias filas en distinto orden puede haber deadlocks. Hoy las operaciones bloquean un solo repuesto por paso, y PostgreSQL detecta y aborta los deadlocks.

### 3. Bloqueo optimista con versionado

Una columna `version` en el repuesto: `UPDATE … WHERE id = :id AND version = :leida`. Si no se actualizó ninguna fila, otro escribió antes y hay que reintentar.

- ✅ No bloquea mientras se lee y escala bien cuando hay pocos conflictos.
- ❌ Hay que manejar el conflicto: reintentar la transacción o devolverle un error al usuario que escaneó. Es lógica extra en cada operación de stock (uso, reserva, liberación, recepción, consumo).
- ❌ Justo en el caso que importa, la última unidad muy disputada, es cuando más conflictos y reintentos genera.

## Decisión

Usar **bloqueo pesimista (`SELECT … FOR UPDATE`) en la capa de servicio** y dejar los **`CHECK` en la base** como última barrera.

- Toda operación que cambia stock (registrar uso, reservar, liberar, recibir un pedido, ingreso manual, consumir reservas al finalizar un preventivo) obtiene el repuesto con `with_for_update()` antes de validar. Ver `backend/app/servicios.py` y `backend/app/repositorios.py`.
- La validación usa el **stock disponible** (`físico − reservado`), así un uso concurrente nunca toma unidades reservadas (RN-05).
- La tabla `repuesto` tiene `ck_repuesto_fisico_no_negativo` (`stock_fisico >= 0`) y `ck_repuesto_reservado_valido` (`0 <= stock_reservado <= stock_fisico`). Si un error de código salteara el bloqueo, la base rechaza el dato inválido.
- RN-10 se cumple en una sola transacción: al finalizar el preventivo se bloquean sus reservas y cada repuesto, se descuentan físico y reservado y se marca la reserva como consumida antes del `COMMIT`.

## Consecuencias

- **Positivas:** el stock y la trazabilidad quedan consistentes bajo concurrencia, el usuario ve el mensaje de negocio correcto y el código del servicio sigue siendo lineal, sin reintentos.
- **Negativas:** las operaciones sobre un mismo repuesto se ejecutan de a una. Si en el futuro una operación tuviera que bloquear varios repuestos, conviene bloquearlos en orden de `id` para evitar deadlocks.
- **Limitación de los tests unitarios:** corren sobre SQLite, que ignora `FOR UPDATE`. La serialización se verificó contra PostgreSQL con 5 usos simultáneos de 1 unidad sobre un repuesto con 2 disponibles: 2 respuestas `201` y 3 respuestas `409`, el stock físico bajó exactamente 2 y las unidades reservadas quedaron intactas.

## Cómo reproducir la verificación

Con `docker compose up -d` y un token de un usuario de mantenimiento en `$T` (ver `DESARROLLO.md`):

```bash
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "%{http_code} " -X POST http://localhost:8000/reparaciones/1/usos \
    -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
    -d '{"repuesto_codigo":"RP-2048","cantidad":1}' &
done; wait
```

Con los datos de demostración, RP-2048 tiene 4 unidades físicas, 2 reservadas y 2 disponibles: tiene que haber exactamente dos `201`.
