# JARVIS PC Companion (Windows)

A small, paired, audited helper that lets the AutoLoom Media Glasses (JARVIS) iPhone app work on your Windows PC: find and read files in folders you share, pull text out of documents, inspect code projects, create or edit files, start allowed programs and run allowed commands. Every change waits for **your** approval on the phone or at the PC. Nothing is shared by default.

- Runtime: **Node.js 22.18 or newer** (24 LTS recommended). No third-party runtime packages; TypeScript is used only to type-check during development.
- Transport: HTTPS with the companion's own ECDSA P-256 key. The phone pins that key (see [docs/PC_COMPANION.md](../docs/PC_COMPANION.md)).
- Status: **EXPERIMENTAL**. 71 automated tests pass on Windows 11 and on GitHub's windows-latest runner (see `test/`). The iPhone side still needs a device test.

## Hızlı başlangıç (Türkçe)

```powershell
cd pc-companion
node src/cli.ts doctor                                   # Node sürümü ve ağ adresleri
node src/cli.ts roots add "C:\Users\<ad>\Projeler" --name Projeler --write
node src/cli.ts roots add "C:\Users\<ad>\Documents" --name Belgeler     # salt okunur
node src/cli.ts start --lan --pair                       # yerel ağda dinle ve eşleştirme QR'ını göster
```

1. Windows Güvenlik Duvarı sorarsa yalnızca **Özel ağlar** için izin ver.
2. Telefonda JARVIS → Ayarlar → **Bilgisayar (PC)** → "QR ile eşleştir" ile terminaldeki kodu okut. Konsol "evet" onayı ister.
3. Telefondan "Bilgisayar ile AutoLoom projesini bul" ya da PC ekranındaki araçları kullan. Dosya değiştiren, program açan veya komut çalıştıran her istek **onay bekler**; onayı telefondaki PC ekranından ya da konsolda `approve <id>` ile verirsin.

Konsol komutları: `pair`, `devices`, `revoke <id>`, `tasks`, `approve <id>`, `deny <id>`, `cancel <id>`, `roots`, `reload`, `status`, `quit`.

## What it can do

| Tool | Risk | Default |
|---|---|---|
| `list_dir`, `search_files`, `search_text`, `read_text`, `file_info`, `extract_text` (docx/xlsx/pptx/odt/html/rtf/text, PDF best effort), `analyze_project` | read | runs at once |
| `create_file`, `append_text`, `replace_in_file`, `make_dir`, `rename_path`, `undo_task` | write | asks |
| `create_file` with `overwrite`, `move_to_trash` | destructive | always asks |
| `open_app` (allowlisted programs), `run_command` (allowlisted commands) | execute | always asks |

Tools that only the model channel (MCP) sees: `pc_status`, `list_tasks`, `get_task`, `cancel_task`. There is **no approval tool**: the model can never approve its own request.

**Test runs.** When a `run_command` prints test results, the companion reads the counts and the failing test names from the output. It understands:
- node --test (spec and TAP), Jest, Vitest, pytest, dotnet test, cargo test, go test -v and plain TAP.

It compares them with the previous run of the same command in the same folder ("TAP: 70 geçti, 1 başarısız. Önceki çalıştırmaya göre: 1 yeni başarısız (…), 2 düzeldi.").
- A run with a failing test is reported as unsuccessful even if the program exits with 0.
- Only the output is read; no report file is opened.
- The last summary per command and folder is kept in `test-history.json` in the data folder (counts and at most 20 test names, 50 entries).

## What it never does

- No shell for the model, no arbitrary programs or command lines: the model picks an **allowlisted id** and a **shared folder**; the owner writes the command in `config.json`.
- No access outside shared folders. Paths are checked as text and again on the real path (symlinks, junctions, 8.3 names); `..`, UNC, `\\?\`, device names (`NUL`, `COM1`…), alternate data streams and invisible/bidi characters are refused.
- Never reads secrets (`.env`, keys, `.ssh`, wallets, credentials…), never writes `.git`, Windows start-up folders, programs, shortcuts, installers or registry files, never writes through a hard link.
- Never deletes: "delete" moves into the companion's own trash for 30 days and can be undone.
- Never runs `git` (a repository's own config could run code); the branch is read from `.git/HEAD`.
- Never listens on a public address; LAN mode binds to one private address, and only private-range peers may connect. Browser requests (`Origin` header) are refused.

## Configuration

`%LOCALAPPDATA%\JarvisPC\config.json` (or `JARVIS_PC_HOME`). Example command entries:

```json
"commands": [
  { "id": "npm-test", "label": "npm test", "exe": "C:\\Program Files\\nodejs\\npm.cmd", "args": ["test"], "shell": true, "timeoutSec": 600, "needsWriteAccess": true },
  { "id": "pytest", "label": "pytest", "exe": "C:\\Python312\\python.exe", "args": ["-m", "pytest", "-q"], "shell": false, "timeoutSec": 900, "needsWriteAccess": true }
]
```

Arguments of `shell: true` entries may not contain `& | < > ^ % ! "`. After editing, type `reload` in the console: approvals that were waiting under the old rules are cancelled.

Policy overrides (`policy.tools`): `"allow"`, `"ask"` or `"deny"` per tool. Destructive and execute tools always ask, whatever the override.

## Files

| File | Content |
|---|---|
| `config.json` | Your settings |
| `identity\key.pem`, `identity\cert.pem` | TLS key (protected by your Windows profile's permissions) and certificate (renewed with the same key) |
| `devices.json` | Paired phones: names, scopes, **SHA-256 of the token** (never the token) |
| `tasks.json` | The last 500 tasks |
| `audit.log` | Hash-chained audit log (no tokens, no file contents). `node src/cli.ts audit verify` |
| `trash\`, `backups\` | Undo data, removed after 30 days |

## Development

```powershell
npm ci            # TypeScript only
npm run typecheck
npm test
```

CI: `.github/workflows/pc-companion.yml` runs both on `windows-latest`.

Third-party code: `src/vendor/qrcodegen.ts` is Project Nayuki's QR Code generator (MIT), adapted to module syntax; see `THIRD_PARTY_NOTICES.md`.
