#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Uso: ./subir_multi_repos.sh <VISIBILIDAD> <ANIOS>
#   <VISIBILIDAD>: 0 = privado, 1 = público
#   <ANIOS>: años atrás para la PRIMERA carpeta; cada carpeta suma +1 semana
#
# Requisitos: gh (autenticado), git, GNU date (o gdate en macOS),
#             helper de credenciales para HTTPS (PAT con scope repo).
#
# Modo SEGURO: NO borra archivos, NO hace 'git rm', NO usa '--orphan'.
# Crea un commit sintético con commit-tree y empuja a main por HTTPS.
# ─────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "Uso: $0 <VISIBILIDAD 0|1> <ANIOS>"
  exit 1
fi

VIS_FLAG="$1"
BASE_YEARS="$2"

case "$VIS_FLAG" in
  0) VISIBILITY_STR="private"; VIS_TXT="privado" ;;
  1) VISIBILITY_STR="public";  VIS_TXT="público" ;;
  *) echo "❌ VISIBILIDAD inválida: usa 0 (privado) o 1 (público)"; exit 1 ;;
esac

DEFAULT_BRANCH="main"

# Desactivar paginadores
export GIT_PAGER=cat
export PAGER=cat
export LESS=F

# GitHub CLI y usuario
command -v gh >/dev/null 2>&1 || { echo "❌ Falta GitHub CLI. Ejecuta 'gh auth login'."; exit 1; }
OWNER="$(gh api user -q .login 2>/dev/null || true)"
[[ -n "$OWNER" ]] || { echo "❌ Autentícate con 'gh auth login'."; exit 1; }

# GNU date / gdate (macOS)
DATE_CMD="date"
if ! ${DATE_CMD} -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1 || ! ${DATE_CMD} -d "yesterday" +%s >/dev/null 2>&1; then
  if command -v gdate >/dev/null 2>&1; then DATE_CMD="gdate"; else
    echo "❌ Necesitas GNU date. En macOS: 'brew install coreutils' (gdate)."
    exit 1
  fi
fi

# ───────────────── helpers ─────────────────
slugify() {
  # minúsculas, espacios→-, caracteres seguros
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]._-'
}

repo_exists() {
  gh repo view "${OWNER}/$1" >/dev/null 2>&1
}

create_repo_via_api() {
  local slug="$1" vis="$2"  # vis: "private"|"public"
  local priv="false"
  [[ "$vis" == "private" ]] && priv="true"
  gh api -X POST -H "Accept: application/vnd.github+json" /user/repos \
    -f name="$slug" -F private="$priv" >/dev/null
}

ensure_origin_https() {
  local slug="$1"
  local url="https://github.com/${OWNER}/${slug}.git"
  local cur="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$cur" ]]; then
    git remote add origin "$url"
  elif [[ "$cur" != "$url" ]]; then
    if git remote | grep -qx "upstream"; then
      git remote set-url origin "$url"
    else
      git remote rename origin upstream
      git remote add origin "$url"
    fi
  fi
}

push_https_with_retry() {
  local refspec="$1"  # ej: "<sha>:refs/heads/main"
  for attempt in 1 2; do
    echo "   ↻ Push (HTTP/1.1, --no-thin) intento ${attempt}…"
    GIT_HTTP_VERSION=HTTP/1.1 git push -u origin "$refspec" --force --no-thin && return 0 || true
    echo "   ↻ Push falló; reintentando…"
    sleep 1
  done
  return 1
}

dir_has_files() {
  # ¿Hay algún archivo (excluyendo .git)?
  find "$1" -mindepth 1 -not -path "*/.git/*" -type f -print -quit | grep -q .
}

# ───────────── construir lista (orden temporal) ─────────────
declare -a ROWS=()
i=0
shopt -s nullglob
for dir in */; do
  [[ -d "$dir" ]] || continue
  repo_dir="${dir%/}"
  [[ "$repo_dir" == ".git" || "$repo_dir" == .* ]] && continue

  if ! dir_has_files "$repo_dir"; then
    echo "⚠️  Carpeta '$repo_dir' no contiene archivos (excluyendo .git). Saltando."
    continue
  fi

  slug="$(slugify "$repo_dir")"
  [[ -n "$slug" ]] || { echo "⚠️  Nombre inválido: '$repo_dir'"; continue; }

  ISO="$(${DATE_CMD} -u -d "${BASE_YEARS} years ago + ${i} weeks" +%Y-%m-%dT%H:%M:%SZ)"
  EPOCH="$(${DATE_CMD} -u -d "${BASE_YEARS} years ago + ${i} weeks" +%s)"
  ROWS+=("${EPOCH}|${ISO}|${repo_dir}|${slug}")
  i=$((i+1))
done
shopt -u nullglob

[[ ${#ROWS[@]} -gt 0 ]] || { echo "No hay carpetas con archivos para subir."; exit 0; }

IFS=$'\n' ROWS_SORTED=($(printf "%s\n" "${ROWS[@]}" | sort -n -t'|' -k1,1))
unset IFS

# ───────────────── procesar ────────────────
for row in "${ROWS_SORTED[@]}"; do
  IFS='|' read -r _ ISO repo_dir slug <<< "$row"; unset IFS

  echo
  echo "📦 ${repo_dir} → repo: ${slug} | fecha commit: ${ISO} | visibilidad: ${VIS_TXT}"

  pushd "$repo_dir" >/dev/null

  # init si no existe .git (NO borra nada)
  [[ -d .git ]] || git init

  # Asegurar identidad básica
  git config user.name  >/dev/null 2>&1 || git config user.name  "$OWNER"
  git config user.email >/dev/null 2>&1 || git config user.email "${OWNER}@users.noreply.github.com"

  # Preparar índice con TODO el árbol de trabajo
  git add -A .

  # Traza de archivos staged (sin pager)
  echo "   ── Archivos a commitear ──"
  git -c core.pager=cat diff --cached --name-only | sed 's/^/   • /' || true
  TOTAL_STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
  echo "   (total: ${TOTAL_STAGED})"
  echo "   ──────────────────────────"

  if [[ "$TOTAL_STAGED" -eq 0 ]]; then
    echo "   ⚠️  Nada nuevo para subir en '${repo_dir}'."
  fi

  # Crear COMMIT SINTÉTICO sin tocar tu working tree:
  TREE_SHA=$(git write-tree)
  COMMIT_MSG="Snapshot (retrofechado) @ ${ISO}"
  COMMIT_SHA=$(
    GIT_AUTHOR_NAME="$(git config user.name)" \
    GIT_AUTHOR_EMAIL="$(git config user.email)" \
    GIT_AUTHOR_DATE="${ISO}" \
    GIT_COMMITTER_NAME="$(git config user.name)" \
    GIT_COMMITTER_EMAIL="$(git config user.email)" \
    GIT_COMMITTER_DATE="${ISO}" \
    git commit-tree -m "${COMMIT_MSG}" "${TREE_SHA}"
  )

  # Crear repo remoto si no existe (API sin prompt)
  if repo_exists "${slug}"; then
    echo "ℹ️  Repo ${OWNER}/${slug} ya existe. Reusando…"
  else
    echo "🆕 Creando repo ${OWNER}/${slug} (${VIS_TXT})…"
    create_repo_via_api "${slug}" "${VISIBILITY_STR}" || {
      echo "   ⚠️  No pude crear ${slug} (¿ya existe o sin permisos?). Continuo…"
    }
  fi

  # origin → HTTPS a tu repo
  ensure_origin_https "${slug}"

  # Empujar ese único commit a 'main' en remoto (NO cambia archivos locales)
  if push_https_with_retry "${COMMIT_SHA}:refs/heads/${DEFAULT_BRANCH}"; then
    echo "🔗 origin: $(git remote get-url origin)"
    echo "✅ Subido: https://github.com/${OWNER}/${slug}"
  else
    echo "   ❌ Push falló. Revisa token (scope repo) / conectividad."
  fi

  popd >/dev/null
done

echo
echo "🎯 Listo. Repos ${VIS_TXT}s creados/reusados y commits fechados 'hace ${BASE_YEARS} años' + 1 semana por carpeta, sin borrar nada local."

