# subir_multi_repos.sh — README

> **Proyecto:** `lab_PCPDF_CREADORAGENDALAB_04_PY` (módulo CLI para subir múltiples carpetas como repos a GitHub con un commit retrofechado por carpeta)  
> **Autor:** braco96  
> **Licencia:** MIT

---

## 📌 ¿Qué hace este script?

`subir_multi_repos.sh` recorre **todas las carpetas hijas** del directorio actual (ignorando `.git` y ocultas), y por **cada carpeta que contenga archivos**:

1. Crea un **commit sintético** (no toca tu working tree) con fecha **retrocedida** `ANIOS` desde hoy, y **+1 semana** por cada carpeta subsiguiente (para mantener un orden temporal).
2. Crea (si no existe) un repositorio en GitHub con la **visibilidad** indicada.
3. Empuja ese commit a la rama **main** del repo remoto (por **HTTPS**) sin reescribir ni borrar nada local.

> ⚠️ **Modo seguro:**  
> - **No** borra archivos locales  
> - **No** hace `git rm`  
> - **No** usa `git --orphan`  
> - Usa `git commit-tree` para generar un commit **sin** modificar tu árbol de trabajo

---

## 🧩 Requisitos

- **GitHub CLI**: `gh` (autenticado: `gh auth login`)
- **git**
- **GNU date** (en macOS, instalar `gdate` vía `brew install coreutils`)
- **Helper de credenciales** para HTTPS (o tener configurado un **PAT** con **scope `repo`**)
- Bash (Linux/macOS). En Windows, usar WSL.

---

## ⚙️ Parámetros

```bash
./subir_multi_repos.sh <VISIBILIDAD> <ANIOS>
```

| Parámetro       | Tipo | Valores            | Descripción                                                                 |
|-----------------|------|--------------------|-----------------------------------------------------------------------------|
| `VISIBILIDAD`   | int  | `0` ó `1`          | `0` = **privado**, `1` = **público**                                       |
| `ANIOS`         | int  | p. ej. `2`, `5`    | Años atrás para la **primera** carpeta; cada carpeta suma **+1 semana**     |

**Ejemplo de fecha por carpeta:** si pones `ANIOS=3`, la primera carpeta se fecha “hace 3 años”, la segunda “hace 3 años + 1 semana”, la tercera “hace 3 años + 2 semanas”, etc.

---

## 🚀 Uso rápido

### 1) Preparación

```bash
gh auth login              # autentícate en GitHub CLI
git --version
gh --version
```

**macOS:** instala GNU date  
```bash
brew install coreutils     # usará 'gdate' internamente
```

### 2) Estructura de carpetas

Coloca el script en la carpeta padre que contiene **subcarpetas** (cada una será un repo).  
Ejemplo:

```
/mi_carpeta_raiz
├─ proyecto-a/
│  ├─ src/...
│  └─ README.md
├─ proyecto-b/
│  └─ main.py
└─ subir_multi_repos.sh
```

### 3) Ejecutar

```bash
chmod +x subir_multi_repos.sh
./subir_multi_repos.sh 0 2    # 0 = privado, 2 = hace 2 años (base)
```

o

```bash
./subir_multi_repos.sh 1 5    # 1 = público, 5 = hace 5 años (base)
```

---

## 🧠 Cómo funciona (resumen técnico)

- Detecta tu usuario: `OWNER="$(gh api user -q .login)"`
- Valida **GNU date** (`date` o `gdate`) y configura `DATE_CMD`.
- Para cada subcarpeta:
  - **Filtra**: ignora `.git` y carpetas sin archivos.
  - **slugify** del nombre de carpeta → nombre del repo.
  - Calcula fechas: `ANIOS years ago + i weeks` → `ISO` + `EPOCH`.
  - `git init` si hace falta, configura `user.name/email` si no existen.
  - `git add -A .` (solo index), **no cambia tu working tree**.
  - `git write-tree` → `git commit-tree` con **fechas `ISO`** para autor/committer.
  - Crea el repo vía **API** (`gh api /user/repos`) si no existe.
  - Fija `origin` a `https://github.com/${OWNER}/${slug}.git` (HTTPS).
  - `git push` **forzado** de ese commit a `refs/heads/main` (con **retry** y `--no-thin`).
- Orden temporal: **ordena** por EPOCH para procesar de más antiguo a más reciente.

---

## 📌 Convenciones y decisiones de diseño

- **Seguro por defecto:** no se usa `--orphan`, no se limpia el working tree; el commit se genera desde el index (`write-tree` + `commit-tree`).
- **HTTPS + helper/PAT:** asegura empujar sin configuraciones SSH, útil en CI/entornos estándar.
- **Retrofechado reproducible:** usa `GNU date` para computar `ISO` y `EPOCH` de forma estable.
- **Slug del repo:** minúsculas, espacios→`-`, caracteres seguros (`[:alnum:]._-`).

---

## 🔐 Visibilidad

- `0` → crea el repo como **privado** (`private=true` en API).
- `1` → crea el repo como **público**.

Si el repo ya existe, el script **lo reutiliza** sin error.

---

## 🧪 Ejemplos prácticos

Subir todas las carpetas como **públicas**, empezando **hace 4 años**:

```bash
./subir_multi_repos.sh 1 4
```

Subir como **privadas**, empezando **hace 1 año**:

```bash
./subir_multi_repos.sh 0 1
```

---

## 🛠️ Solución de problemas

- **“❌ Falta GitHub CLI”**  
  Instala y autentícate:  
  ```bash
  https://cli.github.com/
  gh auth login
  ```

- **“❌ Necesitas GNU date” (macOS)**  
  ```bash
  brew install coreutils   # usará 'gdate'
  ```

- **Push falla / credenciales**  
  Asegura helper HTTPS o PAT con `scope: repo`. Reintenta:
  ```bash
  git config --global credential.helper store
  ```
  Y vuelve a empujar con el script.

- **Carpeta sin archivos**  
  El script mostrará: `⚠️  Carpeta 'X' no contiene archivos (...)`. Agrega algún fichero y relanza.

---

## ⚠️ Advertencias

- Empuja con `--force` al branch `main` (del **repo remoto recién creado** o vacío). No reescribe nada en tu **local**.
- Las fechas de los commits **se retroceden** intencionalmente por diseño; si no lo deseas, adapta la línea:
  ```bash
  "${BASE_YEARS} years ago + ${i} weeks"
  ```
- El orden de subida depende del **sort por EPOCH** calculado con `GNU date`.

---

## 🧾 Variables relevantes

- `DEFAULT_BRANCH="main"`
- `OWNER` (derivado de `gh api user`)
- `DATE_CMD` (`date` o `gdate`)
- `VISIBILITY_STR` (`private`/`public`), `VIS_TXT` (texto)
- `GIT_PAGER`, `PAGER`, `LESS` desactivados para salidas limpias

---

## 🧱 Limitaciones y extensiones posibles

- **No hay dry-run**: si lo necesitas, puedes envolver los comandos `gh api` y `git push` con variables de control y echo.
- **Sin README automático**: podrías inyectar un README base por carpeta antes de `git add -A .`.
- **Branch único**: trabaja sobre `main`. Extensiones: crear tags por fecha, ramas por carpeta, etc.

---

## 📝 Licencia

MIT © braco96
