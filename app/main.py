"""Portal GQ: app de demo para GitOps en VKS (Argo CD + Helm + External Secrets).

Muestra la versión desplegada, el pod que atiende y los valores que llegan desde
AWS Secrets Manager a través de External Secrets Operator:
  - como variables de entorno (envFrom): cambian solo cuando el pod se reinicia;
  - como archivo montado (/etc/portal/mensaje): cambia en vivo cuando ESO refresca el Secret.
"""
import html
import os
import socket
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse

APP_VERSION = os.getenv("APP_VERSION", "dev")
AMBIENTE = os.getenv("AMBIENTE", "local")
MENSAJE_FILE = Path(os.getenv("MENSAJE_FILE", "/etc/portal/mensaje"))

app = FastAPI(title="Portal GQ", version=APP_VERSION)


def enmascarar(valor: str | None) -> str:
    if not valor:
        return "(no definido)"
    if len(valor) <= 4:
        return "****"
    return "*" * (len(valor) - 4) + valor[-4:]


def leer_mensaje() -> str:
    try:
        return MENSAJE_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return "(sin mensaje montado)"


def estado() -> dict:
    return {
        "app": "portal-gq",
        "version": APP_VERSION,
        "ambiente": AMBIENTE,
        "pod": socket.gethostname(),
        "secretos": {
            "DB_USER": os.getenv("DB_USER", "(no definido)"),
            "DB_PASSWORD": enmascarar(os.getenv("DB_PASSWORD")),
            "API_KEY": enmascarar(os.getenv("API_KEY")),
        },
        "mensaje_en_vivo": leer_mensaje(),
    }


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/api/estado")
def api_estado():
    return JSONResponse(estado())


@app.get("/", response_class=HTMLResponse)
def index():
    e = estado()
    filas = "".join(
        f"<tr><td>{html.escape(k)}</td><td><code>{html.escape(v)}</code></td></tr>"
        for k, v in e["secretos"].items()
    )
    return f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Portal GQ</title>
<style>
 body{{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;background:#f6f6f6;color:#222}}
 header{{background:#e30613;color:#fff;padding:18px 24px}}
 header h1{{margin:0;font-size:22px}}
 main{{max-width:760px;margin:24px auto;padding:0 16px}}
 .card{{background:#fff;border-radius:10px;padding:18px 20px;margin-bottom:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}}
 .ver{{font-size:28px;font-weight:700}}
 table{{border-collapse:collapse;width:100%}} td{{padding:6px 4px;border-bottom:1px solid #eee}}
 .msg{{font-size:20px;color:#e30613}}
 small{{color:#666}}
</style></head><body>
<header><h1>Portal GQ &ndash; Demo GitOps y VKS</h1></header>
<main>
 <div class="card"><small>Versión desplegada (image.tag)</small>
  <div class="ver">{html.escape(e['version'])}</div>
  <small>Ambiente: {html.escape(e['ambiente'])} &middot; Pod: {html.escape(e['pod'])}</small></div>
 <div class="card"><small>Mensaje desde AWS Secrets Manager (archivo montado, cambia en vivo)</small>
  <div class="msg">{html.escape(e['mensaje_en_vivo'])}</div></div>
 <div class="card"><small>Secretos como variables de entorno (Secret nativo creado por ESO)</small>
  <table>{filas}</table></div>
</main></body></html>"""
