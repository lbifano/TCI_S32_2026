# Guía de desarrollo — Planta en orden

## Levantar todo

```bash
docker compose up -d --build
```

| Servicio | URL | Qué es |
|---|---|---|
| Frontend | http://localhost:5173 | SPA React 19 + Tailwind (Vite). Llama a la API por `/api`. |
| Backend | http://localhost:8000/docs | API FastAPI (Swagger). |
| Mailhog | http://localhost:8025 | Bandeja donde llegan los correos (RN-09). |
| PostgreSQL | interno (`db:5432`) | Base `planta`, usuario `planta`. |

Al arrancar, el backend aplica las migraciones de Alembic y, si la base está vacía, carga datos de demostración.

### Usuarios de demostración

Contraseña de todos: `planta123` (se cambia con `SEED_PASSWORD` antes de la primera carga).

| Usuario | Rol |
|---|---|
| `operario` | Operario de máquina |
| `mantenimiento` | Empleado de mantenimiento |
| `encargado` | Encargado de mantenimiento |
| `gerencia` | Gerencia (solo lectura) |

## Autenticación

`POST /auth/login` (form `username` + `password`) devuelve un JWT que dura un turno (8 h).
Todas las demás rutas, salvo `/health`, piden `Authorization: Bearer <token>`.
En producción definí `JWT_SECRET` en el entorno.

## Contrato OpenAPI y mock (Prism)

El contrato vive en `contrato/openapi.json` y se genera desde el código:

```bash
cd backend && uv run python -m scripts.exportar_openapi
```

Un test (`tests/test_contrato.py`) falla si el contrato quedó desactualizado.

Para trabajar el frontend contra el mock en lugar del backend real:

```bash
docker compose --profile mock up -d prism          # mock en http://localhost:4010
API_URL=http://prism:4010 docker compose up -d frontend
```

## Tests

```bash
cd backend && uv run pytest                        # backend (pytest + TestClient, SQLite en memoria)
docker compose exec frontend pnpm test             # frontend (Vitest + Testing Library)
```

El frontend usa **pnpm** (`pnpm install`, `pnpm dev`, `pnpm build`). La versión está fijada en `packageManager` (`package.json`), y `pnpm-workspace.yaml` aprueba los scripts de instalación de `esbuild`.

## Migraciones

```bash
docker compose exec backend alembic revision --autogenerate -m "descripción"
docker compose exec backend alembic upgrade head
```

Revisá siempre la migración generada: Alembic no detecta valores nuevos en enums de PostgreSQL.

## Decisiones de diseño

- **Capas:** rutas → servicios (reglas RN-01 a RN-10) → repositorios → modelos SQLModel.
- **Concurrencia (RN-01):** cada operación que cambia stock bloquea la fila del repuesto con `SELECT … FOR UPDATE`. Además, los `CHECK` de la tabla impiden que el stock quede negativo o que lo reservado supere lo físico. La decisión está en [ADR 0001](docs/adr/0001-concurrencia-del-stock.md).
- **Notificaciones (RN-09):** el puerto `Notificador` tiene tres adaptadores: `log`, `smtp` (Mailhog) y uno en memoria para los tests. Se elige con la variable `NOTIFICADOR`.
- **Reconocimiento por foto:** el puerto `Reconocedor` usa un adaptador que lee los códigos QR o de barras que aparecen en la foto (zxing-cpp). Para reconocer la pieza por su aspecto se puede sumar otro adaptador, por ejemplo un modelo de visión, sin tocar el servicio.
- **Turno:** se deriva de la hora local de planta: mañana de 06 a 14, tarde de 14 a 22 y noche de 22 a 06.
- **Lista de compras:** es una vista derivada que junta los repuestos bajo umbral y los requerimientos manuales pendientes. Un pedido de compra puede atender varios requerimientos.
- **Recepción (RN-08):** la carga un encargado o el usuario en quien la delegó. Después el encargado la verifica (estado `verificado`).
