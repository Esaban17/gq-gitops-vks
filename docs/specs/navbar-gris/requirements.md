# Navbar en gris

## Contexto
Pedido literal: "modifica el color del navbar a gris". El "navbar" del Portal GQ es el elemento `<header>` de la página principal (hoy rojo `#e30613`, texto blanco). El HTML/CSS va inline en un f-string dentro de `index()` en `app/main.py`, por eso las llaves del CSS están duplicadas (`{{ }}`).

## Alcance / Fuera de alcance
Dentro:
- Cambiar el `background` de la regla `header` (`app/main.py:76`) de `#e30613` a `#6B6B6B`.

Fuera:
- `.msg{color:#e30613}` (línea 82): no es navbar, conserva el rojo.
- Color del texto del header (`#fff`), padding, tamaño, título "Portal GQ – Demo GitOps y VKS".
- Fondo del `body` (`#f6f6f6`), cards, tablas, endpoints JSON, Dockerfile, chart/Helm, CI.
- Introducir variables CSS, tema o configuración (YAGNI: es un valor que no varía).

## Requisitos funcionales
- RF-1: En `GET /`, el `<header>` se renderiza con fondo gris `#6B6B6B` (`rgb(107, 107, 107)`).
- RF-2: El texto del header sigue blanco y legible (contraste >= 4.5:1; #6B6B6B vs #fff ~ 5.3:1, WCAG AA).
- RF-3: Ningún otro estilo ni contenido de la página cambia.

## Requisitos no funcionales relevantes
- Accesibilidad: contraste AA se conserva. Un gris claro quedaría invisible contra el body `#f6f6f6` y sin contraste con el texto blanco; por eso se fija un gris medio.

## Reglas de negocio y casos borde
- El hex `#6B6B6B` es una elección (el pedido solo dice "gris"). Se toma como `--gq-gray-500` de la paleta extendida de marca según lo indicado por quien pide; ese token no existe en este repo y no se pudo verificar aquí.
- Invariantes de dominio / pruebas de propiedades: NO aplica. Es un cambio de un valor CSS, sin lógica ni entradas variables.
- Caso borde: el f-string exige que la regla siga escrita con `{{ }}`; no introducir `{`/`}` simples (rompería `index()` con `SyntaxError`/`ValueError` al arrancar o renderizar).

## Flujos del mapa de features que toca
`docs/feature-map.md` no existe. Flujo tocado (nombrado aquí): "ver la página principal del portal" (`GET /`). No tocan `GET /healthz` ni `GET /api/estado`.

## Archivos afectados
- `app/main.py` (línea 76, una sola regla CSS).

## Grupos de tareas

### G1 — Cambiar el color del header a gris
- Tareas: en `app/main.py:76` reemplazar `background:#e30613` por `background:#6B6B6B` en la regla `header`. Nada más.
- Archivos: `app/main.py`.
- Complejidad: trivial (1 línea). Sin pruebas automatizadas existentes en el repo; verificación manual/E2E.
- Criterios de aceptación:
  - G1-AC1 [E2E]: en `GET /`, el `background-color` computado de `header` es `rgb(107, 107, 107)`.
  - G1-AC2 [E2E]: el color computado del texto de `header h1` sigue siendo `rgb(255, 255, 255)` y el contraste contra el fondo es >= 4.5:1.
  - G1-AC3 [E2E]: el título del header sigue siendo "Portal GQ – Demo GitOps y VKS", y `.msg` conserva `color: rgb(227, 6, 19)` (`#e30613`).
  - G1-AC4: `git diff origin/main -- app/` muestra únicamente el cambio de `#e30613` a `#6B6B6B` en la línea 76 de `app/main.py` (ningún otro estilo o contenido cambia).
  - G1-AC5 [E2E]: `GET /healthz` devuelve `{"ok": true}` (200) y `GET /api/estado` devuelve 200 con las mismas claves (`app`, `version`, `ambiente`, `pod`, `secretos`, `mensaje_en_vivo`) que antes.
- Riesgo: — (no toca auth, secretos, IAM ni migraciones). Nota operativa: al fusionar a `main`, `.github/workflows/ci.yaml` (push con paths `app/**`) construye la imagen, la sube a ECR y abre un PR que cambia `image.tag` del ambiente lab; Argo CD despliega al fusionar ese PR. No hay checks sobre PRs.

## Notas para la verificación local
- Requiere Python >= 3.10 (el código usa `str | None`; el Python del sistema es 3.9). Imagen base: `python:3.12-slim`; dependencias: `fastapi==0.115.6`, `uvicorn[standard]==0.34.0`.
- Opción uv: `uv run --python 3.12 --with-requirements app/requirements.txt uvicorn main:app --app-dir app --port 8080`.
- Opción Docker: `docker build -t portal-gq app && docker run --rm -p 8080:8080 portal-gq`.
- `estado()` no falla sin secretos ni archivo montado: `os.getenv` tiene defaults (`DB_USER` -> "(no definido)", `enmascarar(None)` -> "(no definido)"), `socket.gethostname()` siempre responde y `leer_mensaje()` captura `OSError` (incluye `FileNotFoundError`) y devuelve "(sin mensaje montado)". Verificado leyendo `app/main.py:23-50`.
- Verificar en `http://localhost:8080/`.

## Decisiones
No amerita ADR: es un valor cosmético, trivialmente reversible en una línea y sin alternativas arquitectónicas. La justificación del hex queda en este documento. No existe `docs/decisions/`.

## Preguntas abiertas
- ¿Es `#6B6B6B` el gris deseado? El pedido no especifica tono; se asume gris neutro medio de marca (no verificable en el repo). Si se prefiere otro, debe conservar contraste >= 4.5:1 con blanco.
